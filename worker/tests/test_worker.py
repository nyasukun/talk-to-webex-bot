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
spec = importlib.util.spec_from_file_location("relay_worker", ROOT / "relay_worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def planned_units(text):
    return [unit for _, _, unit in worker.speech_plan(text)]


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
        cleaned = worker.clean_voice_reference(source, rate)
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
                self.assertTrue(np.array_equal(worker.clean_voice_reference(source, 24000), source))

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
            with patch.object(worker, 'clean_voice_reference', side_effect=lambda audio, rate: audio) as clean:
                first = instance.cached_voice_reference(str(path), 24000)
                second = instance.cached_voice_reference(str(path), 24000)
                self.assertIs(first, second)
                self.assertEqual(clean.call_count, 1)
                self.assertEqual(len(first), 72000)
                self.assertAlmostEqual(float(np.mean(first[100:-100])), 0.2, places=3)
                self.assertEqual(path.read_bytes(), original)
                stamp = path.stat()
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 1_000_000))
                instance.cached_voice_reference(str(path), 24000)
                self.assertEqual(clean.call_count, 2)
                instance.cached_voice_reference(str(path), 16000)
                self.assertEqual(clean.call_count, 3)
                instance.cached_voice_reference(str(path), 16000, reduce_noise=False)
                self.assertEqual(clean.call_count, 3)
                instance.cached_voice_reference(str(path), 16000, reduce_noise=True)
                self.assertEqual(clean.call_count, 4)
                sf.write(path, np.zeros(16000), 16000)
                with self.assertRaisesRegex(ValueError, '3〜30秒'):
                    instance.cached_voice_reference(str(path), 24000)

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
        plan = list(worker.speech_plan(first + '\n\n' + later))
        self.assertLessEqual(len(plan[0][2]), worker.SPEECH_OPENING_CHARACTERS)
        self.assertEqual(''.join(unit for index, _, unit in plan if index == 1), first)
        self.assertEqual([unit for index, _, unit in plan if index == 2], [later])
        self.assertTrue(all(total == 2 for _, total, _ in plan))

    def test_short_opening_does_not_cut_words_and_decimal_numbers_remain_whole(self):
        source = '接続を確認しました。' + '資料を準備してから次の作業へ進みます。' * 10
        self.assertEqual(planned_units(source)[0], '接続を確認しました。')
        self.assertEqual(worker.sentence_parts('Version 2.5 is ready. Time is 13:25. Next step.'),
                         ['Version 2.5 is ready.', 'Time is 13:25.', 'Next step.'])

    def test_preference_preserves_short_single_and_uncertain_turns(self):
        for scores in ([None], [0.68], [0.71, None], [0.85, 0.68], [0.59, 0.3]):
            self.assertEqual(worker.preferred_turns(scores, [1.0] * len(scores)), list(range(len(scores))))
        self.assertEqual(worker.preferred_turns([0.84, 0.43, None], [1.0, 0.45, 1.0]), [0, 2])
        self.assertEqual(worker.preferred_turns([0.43, 0.84], [0.45, 1.0]), [1])
        self.assertEqual(worker.preferred_turns([0.84, 0.43], [1.0, float('nan')]), [0, 1])

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
        self.assertEqual(worker.usable_segments([good]), [good])
        for field, value in [("no_speech_prob", 0.9), ("avg_logprob", -1.5), ("compression_ratio", 3.1)]:
            self.assertEqual(worker.usable_segments([dict(good, **{field: value})]), [])
        self.assertEqual(worker.usable_segments([{}]), [])

    def test_remote_or_missing_model_rejected(self):
        for path in ["model/name", "https://example.invalid/model", "/missing/model"]:
            with self.assertRaises(ValueError):
                worker.local_path(path, directory=True)

    def test_local_file_accepted(self):
        with tempfile.NamedTemporaryFile() as file:
            self.assertTrue(worker.local_path(file.name).is_file())

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
        self.assertTrue(all(len(piece) <= worker.SPEECH_MAX_LINE_CHARACTERS for piece in pieces))

    def test_long_clauses_split_at_punctuation_symbols_and_keep_the_tail(self):
        for separator in ('、', '，', ';', '：', '→', '／', '・', '—'):
            source = 'あ' * 18 + separator + 'い' * 18 + '、' + 'う' * 18 + '。'
            with patch.object(worker, 'SPEECH_MAX_LINE_CHARACTERS', 32):
                pieces = planned_units(source)
            self.assertEqual(pieces[0], 'あ' * 18 + separator)
            self.assertEqual(''.join(pieces), source)
            self.assertTrue(all(len(part) <= 32 for part in pieces))
        self.assertEqual(planned_units('Version 2.5 is ready.\n時刻は13:25、数は1,200です。'),
                         ['Version 2.5 is ready.', '時刻は13:25、数は1,200です。'])

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_japanese_split_keeps_words_and_polite_ending_together(self):
        source = 'サービスの概要といくつかの機能についての要約をしっかりお届けしています。'
        with patch.object(worker, 'SPEECH_MAX_LINE_CHARACTERS', 32):
            pieces = planned_units(source)
        self.assertEqual(''.join(pieces), source)
        self.assertTrue(any('お届けしています。' in part for part in pieces))
        self.assertTrue(all(8 <= len(part) <= 32 for part in pieces))

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_early_comma_and_long_kana_words_are_not_cut_at_character_limit(self):
        source = 'このあとは、じゅうごじさんじゅっぷんからの動画チェックと資料整理がありますが、先に予定を確認しますか？'
        with patch.object(worker, 'SPEECH_MAX_LINE_CHARACTERS', 32):
            pieces = planned_units(source)
        self.assertEqual(pieces[0], 'このあとは、')
        self.assertEqual(''.join(pieces), source)
        for phrase in ('じゅうごじさんじゅっぷん', 'チェック', '確認しますか？'):
            self.assertTrue(any(phrase in part for part in pieces), (phrase, pieces))
        self.assertTrue(all(len(part) <= 32 for part in pieces))

    @unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS offline word dictionary.')
    def test_word_offsets_handle_non_bmp_characters_and_honorific_prefix(self):
        source = '😀予定のチェックをお届けしています。'
        starts = worker.speech_word_starts(source)
        self.assertIn(source.index('チェック'), starts)
        self.assertNotIn(source.index('届け'), starts)
        self.assertTrue(all(0 <= index < len(source) for index in starts))

    def test_forced_break_keeps_small_kana_and_combining_mark_with_previous_character(self):
        with patch.object(worker, 'speech_word_starts', return_value=[]), patch.object(worker, 'SPEECH_MAX_LINE_CHARACTERS', 32):
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
                raise worker.SpeechLengthLimit()
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
        for error, expected_calls in ((worker.SpeechLengthLimit(), 4), (ValueError('invalid audio'), 1)):
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
                worker.speech_lines(invalid)

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
            worker.joined_speech_parts([audio_result(1), SimpleNamespace(audio=[2], sample_rate=16000)])

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'Full audio checks require the local runtime.')
    def test_bad_or_runaway_sentence_never_reaches_playback(self):
        import numpy as np
        from types import SimpleNamespace
        def chunk(tokens, audio=None):
            return SimpleNamespace(audio=np.zeros(240) if audio is None else audio, sample_rate=24000, token_count=tokens)
        valid = worker.checked_sentence(iter([chunk(10), chunk(9)]), 20)
        self.assertEqual(len(valid.audio), 480)
        for chunks in ([chunk(10), chunk(10)], [chunk(20)], [], [chunk(1, [float('nan')])],
                       [chunk(1, [])], [chunk(1, np.zeros(24000 * 10))]):
            with self.assertRaises(ValueError):
                worker.checked_sentence(iter(chunks), 20)

    def test_speaker_windows_do_not_create_short_padded_tails(self):
        self.assertEqual(worker.speaker_window_ranges(18880), [])
        for length in (25600, 49600, 154880):
            windows = worker.speaker_window_ranges(length)
            self.assertEqual(windows[0][0], 0)
            self.assertEqual(windows[-1][1], length)
            self.assertTrue(all(25600 <= end - start <= 48000 for start, end in windows))
            self.assertTrue(all(right[0] <= left[1] for left, right in zip(windows, windows[1:])))

    def test_speaker_rejects_low_window_even_when_overall_matches(self):
        self.assertTrue(worker.speaker_scores_accepted([0.86, 0.83, 0.85], 0.76))
        for scores in ([], [0.94, 0.52], [0.94, float('nan')], [float('inf')]):
            self.assertFalse(worker.speaker_scores_accepted(scores, 0.76))
        self.assertFalse(worker.speaker_scores_accepted([0.95], float('nan')))


if __name__ == "__main__":
    unittest.main()
