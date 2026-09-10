"""Language routing with synthetic audio and stub models; no downloads or microphone access."""
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay_worker as worker
import relay_speech


class LanguageTests(unittest.TestCase):
    def test_recognition_passes_selected_language_and_preserves_english_spacing(self):
        import numpy as np
        # Load native extensions before patch.dict restores sys.modules on exit.
        import noisereduce
        import scipy.signal
        instance = worker.Worker()
        whisper = SimpleNamespace(transcribe=Mock(return_value={"segments": [
            {"text": " Okay, assistant.", "no_speech_prob": 0.01, "avg_logprob": -0.1, "compression_ratio": 1},
            {"text": " What is next?", "no_speech_prob": 0.01, "avg_logprob": -0.1, "compression_ratio": 1},
        ]}))
        with patch.dict(sys.modules, {"mlx_whisper": whisper}), \
                patch.object(worker, "local_path", return_value=Path("/model")), \
                patch.object(instance, "load_audio", return_value=np.ones(16000, dtype=np.float32)), \
                patch.object(instance, "speech_spans", return_value=[{"start": 0, "end": 16000}]), \
                patch("noisereduce.reduce_noise", side_effect=lambda y, **_: y):
            for language in ("en", "ja"):
                result = instance.transcribe({"model": "/model", "audio": "/synthetic.wav", "language": language})
                self.assertEqual(whisper.transcribe.call_args.kwargs["language"], language)
                self.assertEqual(whisper.transcribe.call_args.kwargs["task"], "transcribe")
                self.assertEqual(result["text"], "Okay, assistant. What is next?")

    def test_qwen_preparation_warmup_and_generation_follow_language(self):
        instance = worker.Worker()
        model = Mock(sample_rate=24000)
        model.generate.side_effect = lambda **_: iter([])
        mx = SimpleNamespace(array=lambda values: values)
        modules = {"mlx": SimpleNamespace(core=mx), "mlx.core": mx,
                   "mlx_audio.tts.utils": SimpleNamespace(load_model=Mock(return_value=model))}
        request = {"model": "/model", "reference_audio": "/reference.wav", "reference_text": "Exact reference transcript."}
        with patch.dict(sys.modules, modules), patch.object(worker, "local_path", side_effect=lambda value, **_: Path(value)), \
                patch.object(worker, "install_sampling_fixes"), patch.object(instance, "cached_voice_reference", return_value=[0.0]):
            for language in ("ja", "en", "en", "ja"):
                instance.warm_speech({**request, "language": language})
            self.assertEqual(model.generate.call_count, 3)
            self.assertEqual([call.kwargs["lang_code"] for call in model.generate.call_args_list], ["Japanese", "English", "Japanese"])
            self.assertEqual([call.kwargs["text"] for call in model.generate.call_args_list], ["準備できました。", "Ready.", "準備できました。"])
            reference, transcript = instance.prepare_tts({**request, "language": "en"})
            list(instance.generate_speech("Hello, world.", reference, transcript, 64))
            self.assertEqual(model.generate.call_args.kwargs["lang_code"], "English")
            self.assertEqual(model.generate.call_args.kwargs["ref_text"], request["reference_text"])
            self.assertEqual(model.generate.call_args.kwargs["text"], "Hello, world.")

    def test_language_defaults_to_japanese_for_old_protocol_and_rejects_unsupported_values(self):
        self.assertEqual(worker.Worker.language({}), "ja")
        for value in ("fr", "English", None, 1, []):
            with self.assertRaises(worker.WorkerRequestError):
                worker.Worker.language({"language": value})

    def test_long_english_speech_splits_between_words_and_preserves_sentences(self):
        text = "The meeting starts at 13:25. " + "We will review the documents and discuss the next steps. " * 8
        plan = list(relay_speech.speech_plan(text))
        self.assertGreater(len(plan), 1)
        units = [unit for _, _, unit in plan]
        self.assertEqual(" ".join(units), text.strip())
        self.assertIn("13:25", units[0])
        self.assertTrue(all(len(unit) <= relay_speech.SPEECH_MAX_LINE_CHARACTERS for unit in units))


if __name__ == "__main__":
    unittest.main()
