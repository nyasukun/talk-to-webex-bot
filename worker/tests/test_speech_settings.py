"""Quality controls change actual audio/planning and invalidate prepared speech without loading models."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay_speech as speech
from relay_speech_settings import SPEECH_OPTION_SPECS, speech_options
import relay_worker as worker


class SpeechSettingsTests(unittest.TestCase):
    def test_options_default_validate_and_do_not_leak_between_requests(self):
        self.assertEqual(speech_options({'temperature': 0.5})['temperature'], 0.5)
        self.assertEqual(speech_options()['temperature'], 0.9)
        for key, (default, lower, upper, integer) in SPEECH_OPTION_SPECS.items():
            invalid = [True, '0.5', [], None, float('nan'), float('inf'), lower - 1, upper + 1]
            if integer:
                invalid.append(default + 0.5)
            for value in invalid:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    speech_options({key: value})
        for value in [[], False, {'unknown': 1}, {'opening_characters': 64, 'max_line_characters': 32}]:
            with self.assertRaises(ValueError):
                speech_options(value)
        with self.assertRaises(ValueError):
            worker.Worker().begin_speech({'text': 'Hello.', 'speech_options': {'temperature': -1}})

    def test_custom_segmentation_preserves_words_and_obeys_both_limits(self):
        text = 'This is the opening sentence. ' + 'We will review the documents and decide what to do next. ' * 5
        options = {'opening_characters': 16, 'max_line_characters': 48}
        units = [unit for _, _, unit in speech.speech_plan(text, options=options)]
        self.assertLessEqual(len(units[0]), 16)
        self.assertTrue(all(len(unit) <= 48 for unit in units))
        self.assertEqual(' '.join(units), text.strip())
        self.assertNotEqual(units, [unit for _, _, unit in speech.speech_plan(text)])

    def test_sampling_window_updates_on_an_already_loaded_model(self):
        calls = []
        model = SimpleNamespace(_sample_token=lambda logits, **kw: calls.append(kw))
        speech.install_sampling_fixes(model, 16)
        wrapper = model._sample_token
        model._sample_token('logits', generated_tokens=list(range(100)), eos_token_id=1)
        self.assertEqual(calls[-1]['generated_tokens'], list(range(84, 100)))
        speech.install_sampling_fixes(model, 32)
        self.assertIs(model._sample_token, wrapper)
        model._sample_token('logits', generated_tokens=list(range(100)), eos_token_id=1)
        self.assertEqual(calls[-1]['generated_tokens'], list(range(68, 100)))
        self.assertNotIn('eos_token_id', calls[-1])

    def test_changed_reference_controls_invalidate_cache_but_output_controls_do_not(self):
        import numpy as np
        import soundfile as sf
        instance = worker.Worker()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'reference.wav'
            sf.write(path, np.full(24000 * 3, 0.1, dtype=np.float32), 24000)
            original = path.read_bytes()
            with patch.object(worker, 'prepare_voice_reference', side_effect=lambda audio, *_, **__: audio) as prepare:
                first = instance.cached_voice_reference(str(path), 24000)
                instance.tts = SimpleNamespace(_icl_cache={'old-fingerprint': 'stale-prompt'})
                self.assertIs(instance.cached_voice_reference(str(path), 24000, options={'output_target_rms_db': -25}), first)
                self.assertTrue(instance.tts._icl_cache)
                self.assertEqual(prepare.call_count, 1)
                for key, (default, lower, _, _) in SPEECH_OPTION_SPECS.items():
                    if key.startswith('reference_') or key == 'peak_ceiling':
                        before = prepare.call_count
                        changed = lower if default != lower else default + 1
                        instance.cached_voice_reference(str(path), 24000, options={key: changed})
                        self.assertEqual(prepare.call_count, before + 1)
                        self.assertEqual(prepare.call_args.kwargs['options'][key], changed)
                        self.assertEqual(instance.tts._icl_cache, {})
                self.assertEqual(path.read_bytes(), original)

    def test_quality_changes_rewarm_and_reach_generation_then_reset_for_old_requests(self):
        instance = worker.Worker()
        model = SimpleNamespace(sample_rate=24000, _sample_token=lambda *_, **__: None,
                                generate=Mock(side_effect=lambda **_: iter([])))
        mx = SimpleNamespace(array=lambda x: x)
        modules = {'mlx': SimpleNamespace(core=mx), 'mlx.core': mx,
                   'mlx_audio.tts.utils': SimpleNamespace(load_model=lambda _: model)}
        request = {'model': '/model', 'reference_audio': '/reference.wav', 'reference_text': 'Exact transcript.'}
        custom = {'temperature': 0.6, 'top_k': 20, 'top_p': 0.8, 'repetition_penalty': 1.2,
                  'repetition_window': 24, 'streaming_interval': 1.2}
        with patch.dict(sys.modules, modules), patch.object(worker, 'local_path', side_effect=lambda p, **_: Path(p)), \
                patch.object(instance, 'cached_voice_reference', return_value=[0.0]):
            instance.warm_speech(request)
            instance.warm_speech({**request, 'speech_options': custom})
            instance.warm_speech({**request, 'speech_options': custom})
            self.assertEqual(model.generate.call_count, 2)
            for key in ('temperature', 'top_k', 'top_p', 'repetition_penalty', 'streaming_interval'):
                self.assertEqual(model.generate.call_args.kwargs[key], custom[key])
            self.assertEqual(model._sample_token.relay_repetition_window, 24)
            instance.warm_speech(request)
            self.assertEqual(model.generate.call_count, 3)
            self.assertEqual(model.generate.call_args.kwargs['temperature'], 0.9)
            self.assertEqual(model._sample_token.relay_repetition_window, 64)

    def test_audio_output_target_pause_filter_fade_and_gain_controls_affect_samples(self):
        import numpy as np
        rate = 24000
        t = np.arange(rate * 3) / rate
        original = np.where((t >= 0.5) & (t < 2), 0.3 * np.sin(2 * np.pi * 220 * t), 0).astype(np.float32)
        options = {'output_high_pass_hz': 0, 'output_target_rms_db': -24,
                   'output_max_attenuation_db': 24, 'output_leading_seconds': 0.2,
                   'output_trailing_seconds': 0.8}
        result = speech.finished_speech(original, rate, options)
        self.assertAlmostEqual(len(result) / rate, 0.2 + 1.5 + 0.8, delta=0.04)
        levels, _ = speech.frame_levels(result, rate)
        self.assertAlmostEqual(20 * np.log10(np.sqrt(np.mean(levels[speech.active_frames(levels)] ** 2))), -24, delta=0.1)
        unchanged_gain = speech.finished_speech(original, rate, {**options, 'output_max_attenuation_db': 0})
        self.assertAlmostEqual(float(np.abs(unchanged_gain).max()), 0.3, delta=0.001)
        quiet = original * 0.02
        boosted = speech.finished_speech(quiet, rate, {**options, 'output_max_gain_db': 6})
        self.assertAlmostEqual(float(np.abs(boosted).max()) / float(np.abs(quiet).max()), 10 ** (6 / 20), delta=0.01)
        ceiling = speech.finished_speech(original, rate, {**options, 'output_target_rms_db': -10, 'peak_ceiling': 0.1})
        self.assertLessEqual(float(np.abs(ceiling).max()), 0.100001)
        tone = (0.1 * np.cos(2 * np.pi * 220 * t)).astype(np.float32)
        base = {**options, 'output_trailing_seconds': 0, 'output_fade_in_seconds': 0, 'output_fade_out_seconds': 0}
        unfaded = speech.finished_speech(tone, rate, base)
        faded = speech.finished_speech(tone, rate, {**base, 'output_fade_in_seconds': 0.05, 'output_fade_out_seconds': 0.1})
        self.assertEqual(float(faded[0]), 0)
        self.assertEqual(float(faded[-1]), 0)
        self.assertGreater(abs(float(unfaded[0])), 0.01)
        self.assertTrue(np.array_equal(speech.high_passed(tone, rate, 0), tone))
        rumble = np.sin(2 * np.pi * 40 * t).astype(np.float32) * 0.1
        self.assertLess(float(np.std(speech.high_passed(rumble, rate, 200))), float(np.std(rumble)) * 0.1)

    def test_reference_target_and_noise_strength_change_audio_without_cutting_it(self):
        import numpy as np
        rate = 24000
        t = np.arange(rate * 4) / rate
        rng = np.random.default_rng(7)
        audio = (np.where((t > 1) & (t < 3), 0.15 * np.sin(2 * np.pi * 220 * t), 0)
                 + rng.normal(0, 0.001, len(t))).astype(np.float32)
        options = {'reference_high_pass_hz': 0, 'reference_target_rms_db': -26,
                   'reference_max_attenuation_db': 24, 'reference_noise_strength': 0.3}
        with patch('noisereduce.reduce_noise', side_effect=lambda y, **_: y) as clean:
            prepared = speech.prepare_voice_reference(audio, rate, options=options)
            self.assertEqual(clean.call_args.kwargs['prop_decrease'], 0.3)
            self.assertEqual(len(prepared), len(audio))
            levels, _ = speech.frame_levels(prepared, rate)
            self.assertAlmostEqual(20 * np.log10(np.sqrt(np.mean(levels[speech.active_frames(levels)] ** 2))), -26, delta=0.1)
        self.assertTrue(np.array_equal(speech.clean_voice_reference(audio, rate, strength=0), audio))


if __name__ == '__main__':
    unittest.main()
