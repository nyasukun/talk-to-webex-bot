import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import relay_common
import relay_recognition
import relay_speech
import relay_worker as worker


def planned_units(text, options=None):
    return [unit for _, _, unit in relay_speech.speech_plan(text, options=options)]


def audio_result(value, line=1, total=2):
    return SimpleNamespace(audio=[value], sample_rate=24000, line_index=line, line_count=total, fragments=1)


class WorkerTests(unittest.TestCase):
    def test_reference_cleanup_reduces_noise_without_cutting_or_changing_voiced_timing(self):
        import numpy as np
        rate = 24000
        rng = np.random.default_rng(42)
        t = np.arange(rate * 4) / rate
        noise = rng.normal(0, 0.002, len(t))
        voiced = (t >= 1) & (t < 3)
        voice = np.where(voiced, 0.2 * np.sin(2 * np.pi * 220 * t), 0)
        source = np.asarray(noise + voice, dtype=np.float32)
        before = source.copy()
        cleaned = relay_speech.clean_voice_reference(source, rate)
        self.assertEqual(cleaned.shape, source.shape)
        self.assertTrue(np.isfinite(cleaned).all())
        self.assertTrue(np.array_equal(source, before))
        quiet = (t > 0.1) & (t < 0.8)
        self.assertLess(np.sqrt(np.mean(cleaned[quiet] ** 2)), np.sqrt(np.mean(source[quiet] ** 2)) * 0.65)
        center = (t > 1.2) & (t < 2.8)
        self.assertGreater(np.corrcoef(cleaned[center], voice[center])[0, 1], 0.98)
        self.assertGreater(np.sqrt(np.mean(cleaned[center] ** 2)), np.sqrt(np.mean(voice[center] ** 2)) * 0.8)

    def test_reference_cleanup_skips_silence_and_recordings_without_a_quiet_noise_profile(self):
        import numpy as np
        for source in [np.zeros(72000, dtype=np.float32), np.full(72000, 0.2, dtype=np.float32)]:
            with patch('noisereduce.reduce_noise', side_effect=AssertionError('No usable noise profile')):
                self.assertTrue(np.array_equal(relay_speech.clean_voice_reference(source, 24000), source))

    def test_reference_cache_resamples_stereo_and_invalidates_without_writing_the_original(self):
        import numpy as np
        import soundfile as sf
        import os
        instance = worker.Worker()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'reference.wav'
            signal = np.column_stack([np.full(48000, 0.1), np.full(48000, 0.3)])
            sf.write(path, signal, 16000, subtype='FLOAT')
            original = path.read_bytes()
            with patch.object(worker, 'prepare_voice_reference', side_effect=lambda audio, rate, reduce_noise, **_: audio) as prepare:
                first = instance.cached_voice_reference(str(path), 24000)
                second = instance.cached_voice_reference(str(path), 24000)
                self.assertIs(first, second)
                self.assertEqual(prepare.call_count, 1)
                self.assertEqual(prepare.call_args.args[1:], (24000, True))
                self.assertEqual(len(first), 72000)
                self.assertAlmostEqual(float(np.mean(first[100:-100])), 0.2, places=3)
                self.assertEqual(path.read_bytes(), original)
                stamp = path.stat()
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 1_000_000))
                instance.cached_voice_reference(str(path), 24000)
                self.assertEqual(prepare.call_count, 2)
                instance.cached_voice_reference(str(path), 16000)
                self.assertEqual(prepare.call_count, 3)
                # Noise reduction on and off are separate cache entries, both conditioned the same way otherwise.
                instance.cached_voice_reference(str(path), 16000, reduce_noise=False)
                self.assertEqual(prepare.call_count, 4)
                self.assertEqual(prepare.call_args.args[1:], (16000, False))
                instance.cached_voice_reference(str(path), 16000, reduce_noise=False)
                self.assertEqual(prepare.call_count, 4)
                instance.cached_voice_reference(str(path), 16000, reduce_noise=True)
                self.assertEqual(prepare.call_count, 5)
                sf.write(path, np.zeros(16000), 16000)
                with self.assertRaisesRegex(ValueError, '3〜30秒'):
                    instance.cached_voice_reference(str(path), 24000)

    def test_reference_conditioning_removes_offset_and_normalizes_level_without_changing_the_take(self):
        import numpy as np
        rate = 24000
        t = np.arange(rate * 8) / rate
        voiced = (t >= 1.5) & (t < 5.5)
        # Quiet take with a DC offset: the words and the timing must survive, the offset must not.
        speech = np.where(voiced, 0.03 * np.sin(2 * np.pi * 220 * t), 0)
        source = np.asarray(speech + 0.02, dtype=np.float32)
        before = source.copy()
        prepared = relay_speech.prepare_voice_reference(source, rate, reduce_noise=False)
        self.assertTrue(np.array_equal(source, before))
        self.assertTrue(np.isfinite(prepared).all())
        self.assertEqual(len(prepared), len(source))
        levels, _ = relay_speech.frame_levels(prepared, rate)
        active = relay_speech.active_frames(levels)
        level_db = 20 * np.log10(np.sqrt(np.mean(levels[active] ** 2)))
        self.assertAlmostEqual(level_db, relay_speech.REFERENCE_TARGET_RMS_DB, delta=1.0)
        self.assertLess(abs(float(np.mean(prepared))), 0.002)
        # The speech keeps its position, duration and content: silence around it is left in place.
        bounds = relay_speech.speech_bounds(prepared, rate)
        self.assertAlmostEqual(bounds[0] / rate, 1.5, delta=0.03)
        self.assertAlmostEqual((bounds[1] - bounds[0]) / rate, 4, delta=0.05)
        spectrum = np.abs(np.fft.rfft(prepared[bounds[0] + rate // 4:bounds[0] + rate // 4 + rate]))
        self.assertAlmostEqual(float(np.argmax(spectrum)), 220, delta=2)
        self.assertLessEqual(float(np.abs(prepared).max()), relay_speech.OUTPUT_PEAK_CEILING)
        loud = np.asarray(np.where(voiced, 0.99 * np.sin(2 * np.pi * 220 * t), 0), dtype=np.float32)
        self.assertLessEqual(float(np.abs(relay_speech.prepare_voice_reference(loud, rate, reduce_noise=False)).max()), relay_speech.OUTPUT_PEAK_CEILING + 1e-6)

    def test_reference_conditioning_leaves_silence_alone_and_reduces_noise_only_when_asked(self):
        import numpy as np
        rate = 24000
        t = np.arange(int(rate * 4.5)) / rate
        speech = np.where((t >= 1) & (t < 3.5), 0.1 * np.sin(2 * np.pi * 220 * t), 0).astype(np.float32)
        silent = relay_speech.prepare_voice_reference(np.zeros(rate * 4, dtype=np.float32), rate, reduce_noise=True)
        self.assertEqual(len(silent), rate * 4)
        self.assertTrue(np.all(np.abs(silent) < 1e-6))
        with patch.object(relay_speech, 'clean_voice_reference', side_effect=lambda audio, rate, **_: audio) as clean:
            relay_speech.prepare_voice_reference(speech, rate, reduce_noise=True)
            relay_speech.prepare_voice_reference(speech, rate, reduce_noise=False)
            self.assertEqual(clean.call_count, 1)

    def test_finished_segment_has_short_lead_fixed_pause_common_level_and_soft_edges(self):
        import numpy as np
        rate = 24000
        t = np.arange(int(rate * 2.7)) / rate
        voiced = (t >= 0.5) & (t < 1.5)
        segment = np.where(voiced, 0.4 * np.sin(2 * np.pi * 220 * t), 0).astype(np.float32)
        finished = relay_speech.finished_speech(segment, rate)
        self.assertTrue(np.isfinite(finished).all())
        lead = relay_speech.OUTPUT_LEADING_SECONDS
        tail = relay_speech.OUTPUT_TRAILING_SECONDS
        self.assertAlmostEqual(len(finished) / rate, lead + 1 + tail, delta=0.05)
        bounds = relay_speech.speech_bounds(finished, rate)
        self.assertLessEqual(bounds[0] / rate, lead + 0.03)
        self.assertAlmostEqual((len(finished) - bounds[1]) / rate, tail, delta=0.03)
        self.assertLess(float(np.abs(finished[-int(0.25 * rate):]).max()), 1e-4)
        self.assertLess(abs(float(finished[0])), 0.01)
        levels, _ = relay_speech.frame_levels(finished, rate)
        level_db = 20 * np.log10(np.sqrt(np.mean(levels[relay_speech.active_frames(levels)] ** 2)))
        self.assertAlmostEqual(level_db, relay_speech.OUTPUT_TARGET_RMS_DB, delta=1.0)
        quiet = np.where(voiced, 0.01 * np.sin(2 * np.pi * 220 * t), 0).astype(np.float32)
        boosted = relay_speech.finished_speech(quiet, rate)
        # Bounded gain; the zero-phase filter may overshoot a synthetic step by a few percent.
        self.assertLessEqual(float(np.abs(boosted).max()), float(np.abs(quiet).max()) * 10 ** (relay_speech.OUTPUT_GAIN_RANGE_DB[1] / 20) * 1.1)
        loud = np.where(voiced, 0.99 * np.sin(2 * np.pi * 220 * t), 0).astype(np.float32)
        self.assertLessEqual(float(np.abs(relay_speech.finished_speech(loud, rate)).max()), relay_speech.OUTPUT_PEAK_CEILING + 1e-6)
        tiny = np.array([0.5, 0.5, 0.5], dtype=np.float32)
        self.assertTrue(np.array_equal(relay_speech.finished_speech(tiny, rate), tiny))
        with self.assertRaises(ValueError):
            relay_speech.finished_speech(np.full(rate, np.nan, dtype=np.float32), rate)

    def test_sampling_fixes_window_the_history_drop_the_stop_token_exemption_and_install_once(self):
        from unittest.mock import Mock
        model = Mock()
        seen = []
        model._sample_token = lambda logits, **kwargs: seen.append(kwargs) or 'token'
        relay_speech.install_sampling_fixes(model)
        first = model._sample_token
        relay_speech.install_sampling_fixes(model)
        self.assertIs(model._sample_token, first)
        history = list(range(200))
        self.assertEqual(model._sample_token('logits', temperature=0.9, generated_tokens=history, eos_token_id=7, top_k=50), 'token')
        self.assertEqual(seen[-1]['generated_tokens'], history[-relay_speech.SPEECH_REPETITION_WINDOW:])
        self.assertNotIn('eos_token_id', seen[-1])
        self.assertEqual(seen[-1]['top_k'], 50)
        model._sample_token('logits', generated_tokens=None)
        self.assertIsNone(seen[-1]['generated_tokens'])

    def test_flattened_paragraph_starts_with_its_first_sentence(self):
        first = '承知しました。'
        rest = '今日の予定を確認し、必要な資料を順番にお届けします。'
        source = first + rest * 8 + 'これで最後です。'
        pieces = planned_units(source)
        self.assertEqual(pieces[0], first)
        self.assertEqual(pieces[1:-1], [rest] * 8)
        self.assertEqual(''.join(pieces), source)

    def test_only_the_opening_is_shortened_and_later_newlines_stay_intact(self):
        first = '最初に今日の予定とこれから進める作業について必要な情報を順番にお届けします。'
        later = '次は少し長い説明です。必要な資料を確認したら、内容を整理して次の作業へ進んでください。'
        plan = list(relay_speech.speech_plan(first + '\n\n' + later))
        self.assertLessEqual(len(plan[0][2]), relay_speech.SPEECH_OPENING_CHARACTERS)
        self.assertEqual(''.join(unit for index, _, unit in plan if index == 1), first)
        self.assertEqual([unit for index, _, unit in plan if index == 2], [later])
        self.assertTrue(all(total == 2 for _, total, _ in plan))

    def test_short_opening_does_not_cut_words_and_decimal_numbers_remain_whole(self):
        source = '接続を確認しました。' + '資料を準備してから次の作業へ進みます。' * 10
        self.assertEqual(planned_units(source)[0], '接続を確認しました。')
        self.assertEqual(relay_speech.sentence_parts('Version 2.5 is ready. Time is 13:25. Next step.'),
                         ['Version 2.5 is ready.', 'Time is 13:25.', 'Next step.'])

    def test_preference_preserves_short_single_and_uncertain_turns(self):
        for scores in ([None], [0.68], [0.71, None], [0.85, 0.68], [0.59, 0.3]):
            self.assertEqual(relay_recognition.preferred_turns(scores, [1.0] * len(scores)), list(range(len(scores))))
        self.assertEqual(relay_recognition.preferred_turns([0.84, 0.43, None], [1.0, 0.45, 1.0]), [0, 2])
        self.assertEqual(relay_recognition.preferred_turns([0.43, 0.84], [0.45, 1.0]), [1])
        self.assertEqual(relay_recognition.preferred_turns([0.84, 0.43], [1.0, float('nan')]), [0, 1])

    def test_turn_spans_merge_pauses_below_the_gap_and_split_at_exactly_the_gap(self):
        first, second = {"start": 0, "end": 1000}, {"start": 8199, "end": 9000}
        third, fourth = {"start": 16200, "end": 17000}, {"start": 17500, "end": 17600}
        self.assertEqual(relay_recognition.speech_turn_spans([]), [])
        self.assertEqual(relay_recognition.speech_turn_spans([first]), [[first]])
        self.assertEqual(relay_recognition.speech_turn_spans([first, second, third, fourth]), [[first, second], [third, fourth]])
        self.assertEqual(relay_recognition.speech_turn_spans([first, second, third], gap=7199), [[first], [second], [third]])
        self.assertEqual(relay_recognition.speech_turn_spans([first, second, third], gap=7201), [[first, second, third]])

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_voiced_helpers_count_and_join_spans_only(self):
        import numpy as np
        audio = np.arange(100, dtype=np.float32)
        spans = [{"start": 10, "end": 13}, {"start": 50, "end": 52}]
        self.assertEqual(relay_recognition.voiced_sample_count([]), 0)
        self.assertEqual(relay_recognition.voiced_sample_count(spans), 5)
        self.assertEqual(relay_recognition.voiced_audio(audio, spans).tolist(), [10, 11, 12, 50, 51])
        with self.assertRaises(ValueError):
            relay_recognition.voiced_audio(audio, [])

    def test_stream_preserves_chunk_order_and_finishes(self):
        instance = worker.Worker()
        writes = []
        with tempfile.NamedTemporaryFile() as output:
            # A generator supports close, like the real model iterator.
            def chunks(_):
                yield from [audio_result(1), audio_result(2, line=2)]
            with patch.object(instance, 'audio_chunks', side_effect=chunks), patch.object(instance, 'write_chunk', side_effect=lambda value, _: writes.append(value.audio[0])):
                instance.begin_speech({'text': '動作確認です。'})
                first = instance.next_speech({'output': output.name})
                self.assertFalse(first['done'])
                self.assertEqual(first['line_index'], 1)
                self.assertEqual(first['line_count'], 2)
                self.assertGreaterEqual(first['generation_seconds'], 0)
                self.assertFalse(instance.next_speech({'output': output.name})['done'])
                self.assertTrue(instance.next_speech({'output': output.name})['done'])
                self.assertEqual(writes, [1, 2])
                self.assertIsNone(instance.tts_stream)

    def test_stream_failure_or_cancel_discards_remaining_audio(self):
        instance = worker.Worker()
        closed = []
        def chunks(_):
            try:
                yield audio_result(1)
                yield audio_result(2, line=2)
            finally:
                closed.append(True)
        with tempfile.NamedTemporaryFile() as output, patch.object(instance, 'audio_chunks', side_effect=chunks):
            with patch.object(instance, 'write_chunk', side_effect=ValueError('failed')):
                instance.begin_speech({'text': '動作確認です。'})
                with self.assertRaises(ValueError):
                    instance.next_speech({'output': output.name})
                self.assertIsNone(instance.tts_stream)
            with patch.object(instance, 'write_chunk'):
                instance.begin_speech({'text': '動作確認です。'})
                instance.next_speech({'output': output.name})
                instance.end_speech()
                with self.assertRaises(ValueError):
                    instance.next_speech({'output': output.name})
            self.assertEqual(closed, [True, True])

    def test_confidence_rejects_missing_no_speech_repetition_and_uncertain(self):
        good = dict(text="音声です", no_speech_prob=0.1, avg_logprob=-0.2, compression_ratio=1.1)
        self.assertEqual(relay_recognition.usable_segments([good]), [good])
        for field, value in [("no_speech_prob", 0.9), ("avg_logprob", -1.5), ("compression_ratio", 3.1)]:
            self.assertEqual(relay_recognition.usable_segments([dict(good, **{field: value})]), [])
        self.assertEqual(relay_recognition.usable_segments([{}]), [])

    def test_remote_or_missing_model_rejected(self):
        for path in ["model/name", "https://example.invalid/model", "/missing/model"]:
            with self.assertRaises(ValueError):
                relay_common.local_path(path, directory=True)

    def test_local_file_accepted(self):
        with tempfile.NamedTemporaryFile() as file:
            self.assertTrue(relay_common.local_path(file.name).is_file())

    def test_protocol_stays_alive_after_bad_request(self):
        run = subprocess.run([sys.executable, str(ROOT / "relay_worker.py")],
                             input='{"action":"ping"}\n{"action":"bad"}\n{"action":"ping"}\n',
                             text=True, capture_output=True, timeout=10, check=True)
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        self.assertTrue(rows[0]["offline"])
        self.assertIn("error", rows[1])
        self.assertTrue(rows[2]["ready"])
        self.assertNotIn("Traceback", run.stdout)

    def test_split_preserves_complete_long_response(self):
        source = "説明です。" + "長" * 5100 + "！\n最後です。"
        pieces = planned_units(source)
        self.assertEqual("".join(pieces), source.replace('\n', ''))
        self.assertTrue(all(len(piece) <= relay_speech.SPEECH_MAX_LINE_CHARACTERS for piece in pieces))

    def test_long_clauses_split_at_punctuation_symbols_and_keep_the_tail(self):
        for separator in ('、', '，', ';', '：', '→', '／', '・', '—'):
            source = 'あ' * 18 + separator + 'い' * 18 + '、' + 'う' * 18 + '。'
            pieces = planned_units(source, options={'max_line_characters': 32})
            self.assertEqual(pieces[0], 'あ' * 18 + separator)
            self.assertEqual(''.join(pieces), source)
            self.assertTrue(all(len(part) <= 32 for part in pieces))
        self.assertEqual(planned_units('Version 2.5 is ready.\n時刻は13:25、数は1,200です。'),
                         ['Version 2.5 is ready.', '時刻は13:25、数は1,200です。'])

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_japanese_split_keeps_words_and_polite_ending_together(self):
        source = 'サービスの概要といくつかの機能についての要約をしっかりお届けしています。'
        pieces = planned_units(source, options={'max_line_characters': 32})
        self.assertEqual(''.join(pieces), source)
        self.assertTrue(any('お届けしています。' in part for part in pieces))
        self.assertTrue(all(8 <= len(part) <= 32 for part in pieces))

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_early_comma_and_long_kana_words_are_not_cut_at_character_limit(self):
        source = 'このあとは、じゅうごじさんじゅっぷんからの動画チェックと資料整理がありますが、先に予定を確認しますか？'
        pieces = planned_units(source, options={'max_line_characters': 32})
        self.assertEqual(pieces[0], 'このあとは、')
        self.assertEqual(''.join(pieces), source)
        for phrase in ('じゅうごじさんじゅっぷん', 'チェック', '確認しますか？'):
            self.assertTrue(any(phrase in part for part in pieces), (phrase, pieces))
        self.assertTrue(all(len(part) <= 32 for part in pieces))

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_word_offsets_handle_non_bmp_characters_and_honorific_prefix(self):
        source = '😀予定のチェックをお届けしています。'
        starts = relay_speech.speech_word_starts(source)
        self.assertIn(source.index('チェック'), starts)
        self.assertNotIn(source.index('届け'), starts)
        self.assertTrue(all(0 <= index < len(source) for index in starts))

    def test_forced_break_keeps_small_kana_and_combining_mark_with_previous_character(self):
        with patch.object(relay_speech, 'speech_word_starts', return_value=[]), patch.object(relay_speech, 'SPEECH_MAX_LINE_CHARACTERS', 32):
            for text in ('ア' * 30 + 'チェックをします。', 'a' * 31 + 'e\u0301' + 'b' * 10):
                pieces = planned_units(text)
                self.assertEqual(''.join(pieces), text)
                self.assertTrue(all(not part.startswith(('ェ', '\u0301')) for part in pieces))

    def test_capped_audio_is_discarded_then_subdivided_in_order(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        instance = worker.Worker()
        instance.tts = Mock()
        closed = []
        def generate(**kw):
            try:
                yield kw['text']
            finally:
                closed.append(kw['text'])
        instance.tts.generate.side_effect = generate
        def checked(results, _):
            text = ''.join(results)
            if len(text) > 10:
                raise relay_speech.SpeechLengthLimit()
            return SimpleNamespace(text=text)
        text = '最初の予定を確認し、次の作業を始めます。'
        with patch.object(worker, 'checked_sentence', side_effect=checked):
            result = list(instance.speech_part(text, 'reference', '参照本文'))
        self.assertEqual(''.join(part.text for part in result), text.replace('\n', ''))
        self.assertTrue(all(len(part.text) <= 10 for part in result))
        self.assertGreater(instance.speech_resplits, 0)
        self.assertEqual(len(closed), instance.tts.generate.call_count)
        self.assertEqual(instance.tts.speech_tokenizer.decoder.reset_streaming_state.call_count, len(closed))

    def test_subdivision_is_bounded_and_other_failures_are_not_retried(self):
        from unittest.mock import Mock
        for error, expected_calls in ((relay_speech.SpeechLengthLimit(), 4), (ValueError('invalid audio'), 1)):
            instance = worker.Worker()
            instance.tts = Mock()
            instance.tts.generate.side_effect = lambda **_: (value for value in [])
            with patch.object(worker, 'checked_sentence', side_effect=error):
                with self.assertRaises(ValueError):
                    list(instance.speech_part('あ' * 32, 'reference', '参照本文'))
            self.assertEqual(instance.tts.generate.call_count, expected_calls)

    def test_newlines_sentence_boundaries_and_decimal_numbers(self):
        self.assertEqual(planned_units('最初の行\r\n\r\n次の行\n三つ目です。四つ目です！'),
                         ['最初の行', '次の行', '三つ目です。四つ目です！'])
        self.assertEqual(planned_units('Version 2.5 is ready. Next step.\n終了です。'),
                         ['Version 2.5 is ready. Next step.', '終了です。'])
        for invalid in ('', ' \n', None, 'あ' * 20001):
            with self.assertRaises(ValueError):
                relay_speech.speech_lines(invalid)

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_sentence_generation_restarts_for_every_line_and_limits_tokens(self):
        import numpy as np
        from types import SimpleNamespace
        from unittest.mock import Mock
        model = Mock()
        model.generate.side_effect = lambda **kw: (part for part in [kw['text']])
        instance = worker.Worker()
        instance.tts = model
        generated = []
        def collect(results, limit):
            self.assertLessEqual(limit, 300)
            generated.append(''.join(results))
            return SimpleNamespace(audio=np.ones(10) * len(generated), sample_rate=24000)
        lines = ['短い一文です。', '今日の予定について、必要な資料を順番にお届けします。確認後に次の作業へ進みます。']
        with patch.object(instance, 'prepare_tts', return_value=('reference', '参照本文')), \
                patch.object(worker, 'checked_sentence', side_effect=collect):
            result = list(instance.audio_chunks({'text': '\n\n'.join(lines)}))
        self.assertEqual(generated, lines)
        self.assertEqual([r.line_index for r in result], [1, 2])
        self.assertTrue(all(r.line_count == 2 for r in result))
        self.assertEqual([r.audio.tolist() for r in result], [[1] * 10, [2] * 10])
        self.assertEqual(model.generate.call_count, 2)
        for call in model.generate.call_args_list:
            self.assertEqual({key: call.kwargs[key] for key in relay_speech.SPEECH_SAMPLING}, relay_speech.SPEECH_SAMPLING)
            self.assertEqual(call.kwargs['lang_code'], 'Japanese')
        model.speech_tokenizer.decoder.reset_streaming_state.assert_called()

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_recovered_line_is_joined_before_it_reaches_playback(self):
        import numpy as np
        instance = worker.Worker()
        def parts(text, *_):
            yield SimpleNamespace(audio=np.array([1, 2], dtype=np.float32), sample_rate=24000)
            yield SimpleNamespace(audio=np.array([3, 4, 5], dtype=np.float32), sample_rate=24000)
        with patch.object(instance, 'prepare_tts', return_value=('reference', '参照本文')), \
                patch.object(instance, 'speech_part', side_effect=parts):
            output = list(instance.audio_chunks({'text': 'この行をまとめて読み上げます。'}))
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0].audio.tolist(), [1, 2, 3, 4, 5])
        self.assertEqual(output[0].fragments, 2)

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_failed_fragment_discards_the_entire_unplayed_line(self):
        instance = worker.Worker()
        def parts(*_):
            yield audio_result(1)
            raise ValueError('failed tail')
        with patch.object(instance, 'prepare_tts', return_value=('reference', '参照本文')), \
                patch.object(instance, 'speech_part', side_effect=parts):
            chunks = instance.audio_chunks({'text': '長い行です。\n次の行です。'})
            with self.assertRaises(ValueError):
                next(chunks)
        with self.assertRaises(ValueError):
            relay_speech.joined_speech_parts([audio_result(1), SimpleNamespace(audio=[2], sample_rate=16000)])

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Full audio checks require the local runtime.')
    def test_bad_or_runaway_sentence_never_reaches_playback(self):
        import numpy as np
        from types import SimpleNamespace
        def chunk(tokens, audio=None):
            return SimpleNamespace(audio=np.zeros(240) if audio is None else audio, sample_rate=24000, token_count=tokens)
        valid = relay_speech.checked_sentence(iter([chunk(10), chunk(9)]), 20)
        self.assertEqual(len(valid.audio), 480)
        for chunks in ([chunk(10), chunk(10)], [chunk(20)], [], [chunk(1, [float('nan')])],
                       [chunk(1, [])], [chunk(1, np.zeros(24000 * 10))]):
            with self.assertRaises(ValueError):
                relay_speech.checked_sentence(iter(chunks), 20)

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_speaker_paths_slice_voiced_audio_and_score_windows_and_turns_exactly(self):
        import numpy as np
        # Unit vectors keyed by (length, first sample) pin down every slice the speaker paths embed.
        vectors = {(50000, 0.0): [1.0, 0.0], (70000, 1000.0): [0.8, 0.6], (48000, 1000.0): [0.6, 0.8],
                   (48000, 23000.0): [0.8, 0.6], (67000, 1000.0): [0.8, 0.6], (40000, 1000.0): [1.0, 0.0],
                   (27000, 53000.0): [0.6, 0.8]}
        def embed(audio):
            return np.array(vectors[(len(audio), float(audio[0]))], dtype=np.float64)
        audio = np.arange(80000, dtype=np.float32)
        reference = np.arange(64000, dtype=np.float32)
        request = {"reference_audio": "reference.wav"}
        instance = worker.Worker()
        with patch.object(instance, 'load_audio', return_value=reference) as load, \
                patch.object(instance, 'speech_spans', return_value=[{"start": 0, "end": 50000}]) as spans, \
                patch.object(instance, 'embedding', side_effect=embed):
            metrics = instance.check_speaker(audio, [{"start": 1000, "end": 41000}, {"start": 45000, "end": 75000}], request)
            self.assertEqual(metrics, {"accepted": False, "similarity": 0.6, "overall_similarity": 0.8,
                                       "speaker_windows": [{"seconds": 3.0, "similarity": 0.6}, {"seconds": 3.0, "similarity": 0.8}],
                                       "speech_seconds": 4.375, "rejected": "登録した話者と一致しない音声を除外しました。"})
            accepted = instance.check_speaker(audio, [{"start": 1000, "end": 41000}, {"start": 45000, "end": 75000}],
                                              dict(request, speaker_threshold=0.5))
            self.assertEqual(accepted, {"accepted": True, "similarity": 0.6, "overall_similarity": 0.8,
                                        "speaker_windows": [{"seconds": 3.0, "similarity": 0.6}, {"seconds": 3.0, "similarity": 0.8}],
                                        "speech_seconds": 4.375})
            short = instance.check_speaker(audio, [{"start": 1000, "end": 21000}], request)
            self.assertEqual(short, {"accepted": False, "speech_seconds": 1.25,
                                     "rejected": "本人照合には指示の発話が短すぎます。合言葉から、指示をもう少し長く話してください（音声区間1.6秒以上）。"})
            load.assert_called_with("reference.wav")
            spans.assert_called_with(reference)
            self.assertEqual(load.call_count, 2)
            selected, preferred = instance.prefer_speaker(
                audio, [{"start": 1000, "end": 31000}, {"start": 35000, "end": 45000}, {"start": 53000, "end": 80000}], request)
            self.assertEqual(preferred, {"similarity": 0.8, "overall_similarity": 0.8,
                                         "speaker_note": "声の優先: 区別できた複数の声から、登録した声に近い発話を優先しました。"})
            self.assertTrue(np.array_equal(selected, audio[1000:45000]))
            unchanged, single = instance.prefer_speaker(audio, [{"start": 1000, "end": 41000}], request)
            self.assertIs(unchanged, audio)
            self.assertEqual(single, {"similarity": 1.0, "overall_similarity": 1.0,
                                      "speaker_note": "声の優先: 単独・区別が不確かな発話を受け付けました。"})
            brief, note = instance.prefer_speaker(audio, [{"start": 1000, "end": 21000}], request)
            self.assertIs(brief, audio)
            self.assertEqual(note, {"speaker_note": "声の優先: 短い発話も受け付けます。合言葉と認識結果で判断します。"})
            self.assertEqual(load.call_count, 4)

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Requires the local audio runtime.')
    def test_speaker_paths_reject_short_reference_speech_before_embedding(self):
        import numpy as np
        audio = np.arange(80000, dtype=np.float32)
        instance = worker.Worker()
        with patch.object(instance, 'load_audio', return_value=np.zeros(64000, dtype=np.float32)), \
                patch.object(instance, 'speech_spans', return_value=[{"start": 0, "end": 47999}]), \
                patch.object(instance, 'embedding', side_effect=AssertionError('embedding must not run')):
            with self.assertRaises(relay_common.WorkerRequestError) as verify:
                instance.check_speaker(audio, [{"start": 1000, "end": 41000}, {"start": 45000, "end": 75000}],
                                       {"reference_audio": "reference.wav"})
            self.assertEqual(str(verify.exception), "本人照合用に3秒以上の発話を含む音声を登録してください。")
            with self.assertRaises(relay_common.WorkerRequestError) as prefer:
                instance.prefer_speaker(audio, [{"start": 1000, "end": 41000}], {"reference_audio": "reference.wav"})
            self.assertEqual(str(prefer.exception), "声の優先用に3秒以上の発話を含む参照音声を登録してください。")
        # Exactly 3 s of reference speech and exactly 25600 voiced samples pass both strict gates.
        with patch.object(instance, 'load_audio', return_value=np.zeros(64000, dtype=np.float32)), \
                patch.object(instance, 'speech_spans', return_value=[{"start": 0, "end": 48000}]), \
                patch.object(instance, 'embedding', return_value=np.array([1.0, 0.0])) as embed:
            _, boundary = instance.prefer_speaker(audio, [{"start": 1000, "end": 26600}], {"reference_audio": "reference.wav"})
            self.assertEqual(boundary, {"similarity": 1.0, "overall_similarity": 1.0,
                                        "speaker_note": "声の優先: 単独・区別が不確かな発話を受け付けました。"})
            verified = instance.check_speaker(audio, [{"start": 1000, "end": 41000}, {"start": 45000, "end": 75000}],
                                              {"reference_audio": "reference.wav", "speaker_threshold": 0.5})
            self.assertEqual(verified, {"accepted": True, "similarity": 1.0, "overall_similarity": 1.0,
                                        "speaker_windows": [{"seconds": 3.0, "similarity": 1.0}, {"seconds": 3.0, "similarity": 1.0}],
                                        "speech_seconds": 4.375})
            self.assertEqual(embed.call_count, 7)

    def test_speaker_windows_do_not_create_short_padded_tails(self):
        self.assertEqual(relay_recognition.speaker_window_ranges(18880), [])
        for length in (25600, 49600, 154880):
            windows = relay_recognition.speaker_window_ranges(length)
            self.assertEqual(windows[0][0], 0)
            self.assertEqual(windows[-1][1], length)
            self.assertTrue(all(25600 <= end - start <= 48000 for start, end in windows))
            self.assertTrue(all(right[0] <= left[1] for left, right in zip(windows, windows[1:])))

    def test_speaker_rejects_low_window_even_when_overall_matches(self):
        self.assertTrue(relay_recognition.speaker_scores_accepted([0.86, 0.83, 0.85], 0.76))
        for scores in ([], [0.94, 0.52], [0.94, float('nan')], [float('inf')]):
            self.assertFalse(relay_recognition.speaker_scores_accepted(scores, 0.76))
        self.assertFalse(relay_recognition.speaker_scores_accepted([0.95], float('nan')))


if __name__ == "__main__":
    unittest.main()
