#!/usr/bin/env python3
"""Offline inference over JSON lines. No token, HTTP client, or audio logging."""
import contextlib
import json
import os
from pathlib import Path
import sys

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                  DO_NOT_TRACK="1", TOKENIZERS_PARALLELISM="false")

from relay_common import WorkerRequestError, local_path
from relay_recognition import (ASR_SAMPLE_RATE, SPEAKER_MIN_SAMPLES, preferred_turns, speaker_scores_accepted,
                               speaker_window_ranges, speech_turn_spans, usable_segments, voiced_audio,
                               voiced_sample_count)
from relay_speech import (SpeechLengthLimit, checked_sentence, clean_voice_reference, joined_speech_parts,
                          speech_boundary, speech_lines, speech_plan, speech_token_limit)


class Worker:
    def __init__(self):
        self.vad = None
        self.encoder = None
        self.tts = None
        self.tts_path = None
        self.warm_key = None
        self.reference_key = None
        self.reference_signal = None
        self.tts_stream = None
        self.speech_resplits = 0

    def load_audio(self, value):
        """Load a file as 16 kHz mono float32; the recording must hold 0.25-60 s of finite samples."""
        import numpy as np
        import soundfile as sf
        from scipy.signal import resample_poly
        from math import gcd
        audio, rate = sf.read(str(local_path(value)), dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        if rate != ASR_SAMPLE_RATE:
            divisor = gcd(rate, ASR_SAMPLE_RATE)
            audio = resample_poly(audio, ASR_SAMPLE_RATE // divisor, rate // divisor)
        if len(audio) < 4000 or len(audio) > ASR_SAMPLE_RATE * 60 or not np.isfinite(audio).all():
            raise WorkerRequestError("録音は0.25〜60秒の有効な音声を使用してください。")
        return np.asarray(audio, dtype=np.float32)

    def speech_spans(self, audio):
        import torch
        from silero_vad import load_silero_vad, get_speech_timestamps
        if self.vad is None:
            torch.set_num_threads(2)
            self.vad = load_silero_vad()  # Weights ship in the installed wheel; no torch.hub.
        return get_speech_timestamps(torch.from_numpy(audio), self.vad, sampling_rate=ASR_SAMPLE_RATE,
                                     threshold=0.65, min_speech_duration_ms=300, min_silence_duration_ms=200)

    def embedding(self, audio):
        from resemblyzer import VoiceEncoder, preprocess_wav
        if self.encoder is None:
            self.encoder = VoiceEncoder(device="cpu", verbose=False)
        return self.encoder.embed_utterance(preprocess_wav(audio, source_sr=ASR_SAMPLE_RATE))

    def reference_voice_embedding(self, request, too_short):
        """Embed the voiced part of the registered reference; too_short is raised below 3 s of speech."""
        reference = self.load_audio(request["reference_audio"])
        spans = self.speech_spans(reference)
        if voiced_sample_count(spans) < 3 * ASR_SAMPLE_RATE:
            raise WorkerRequestError(too_short)
        return self.embedding(voiced_audio(reference, spans))

    def check_speaker(self, audio, spans, request):
        import numpy as np
        samples = voiced_sample_count(spans)
        duration = samples / ASR_SAMPLE_RATE
        ranges = speaker_window_ranges(samples)
        if not ranges:
            return {"accepted": False, "speech_seconds": duration,
                    "rejected": "本人照合には指示の発話が短すぎます。合言葉から、指示をもう少し長く話してください（音声区間1.6秒以上）。"}
        reference_embedding = self.reference_voice_embedding(request, "本人照合用に3秒以上の発話を含む音声を登録してください。")
        # Join voiced spans before windowing: isolated syllables would be padded to 1.6 s by the encoder.
        utterance = voiced_audio(audio, spans)
        overall = float(np.dot(reference_embedding, self.embedding(utterance)))
        windows = [{"seconds": (end - start) / ASR_SAMPLE_RATE,
                    "similarity": float(np.dot(reference_embedding, self.embedding(utterance[start:end])))}
                   for start, end in ranges]
        scores = [overall] + [window["similarity"] for window in windows]
        accepted = speaker_scores_accepted(scores, float(request.get("speaker_threshold", 0.76)))
        metrics = {"accepted": accepted, "similarity": min(scores), "overall_similarity": overall,
                   "speaker_windows": windows, "speech_seconds": duration}
        if not accepted:
            metrics["rejected"] = "登録した話者と一致しない音声を除外しました。"
        return metrics

    def verify_speaker(self, request):
        audio = self.load_audio(request["audio"])
        return self.check_speaker(audio, self.speech_spans(audio), request)

    def prefer_speaker(self, audio, spans, request):
        import numpy as np
        voiced = voiced_audio(audio, spans)
        if len(voiced) < SPEAKER_MIN_SAMPLES:
            return audio, {"speaker_note": "声の優先: 短い発話も受け付けます。合言葉と認識結果で判断します。"}
        reference_embedding = self.reference_voice_embedding(request, "声の優先用に3秒以上の発話を含む参照音声を登録してください。")
        overall = float(np.dot(reference_embedding, self.embedding(voiced)))
        groups = speech_turn_spans(spans)
        turns = [voiced_audio(audio, group) for group in groups]
        embeddings = [self.embedding(turn) if len(turn) >= SPEAKER_MIN_SAMPLES else None for turn in turns]
        scores = [float(np.dot(reference_embedding, value)) if value is not None else None for value in embeddings]
        measured = [i for i, value in enumerate(scores) if value is not None]
        pairs = [1.0] * len(scores)
        if measured:
            best = max(measured, key=lambda i: scores[i])
            pairs = [float(np.dot(embeddings[best], value)) if value is not None else 1.0 for value in embeddings]
        selected = preferred_turns(scores, pairs)
        metrics = {"similarity": overall, "overall_similarity": overall,
                   "speaker_note": "声の優先: 単独・区別が不確かな発話を受け付けました。"}
        if len(selected) != len(groups):
            metrics["speaker_note"] = "声の優先: 区別できた複数の声から、登録した声に近い発話を優先しました。"
            # Preserve entire turns, including short ones; never cut commands into scoring windows.
            audio = np.concatenate([audio[groups[i][0]["start"]:groups[i][-1]["end"]] for i in selected])
        return audio, metrics

    def transcribe(self, request):
        import numpy as np
        import mlx_whisper
        import noisereduce as nr
        from scipy.signal import butter, sosfilt
        model = local_path(request["model"], directory=True)
        audio = self.load_audio(request["audio"])
        spans = self.speech_spans(audio)
        duration = voiced_sample_count(spans) / ASR_SAMPLE_RATE
        if duration < 0.45 or duration / (len(audio) / ASR_SAMPLE_RATE) < 0.12:
            return {"text": "", "rejected": "音声区間が不足しています。"}
        similarity = None
        speaker_metrics = {}
        if request.get("prefer_speaker"):
            audio, speaker_metrics = self.prefer_speaker(audio, spans, request)
            similarity = speaker_metrics.get("similarity")
        elif request.get("verify_speaker"):
            speaker_metrics = self.check_speaker(audio, spans, request)
            similarity = speaker_metrics.get("similarity")
            if not speaker_metrics["accepted"]:
                return {"text": "", **speaker_metrics}
        # Band filtering + gentle spectral reduction complements AVAudioEngine voice processing.
        filtered = sosfilt(butter(3, [80, 7600], btype="bandpass", fs=ASR_SAMPLE_RATE, output="sos"), audio).astype(np.float32)
        cleaned = nr.reduce_noise(y=filtered, sr=ASR_SAMPLE_RATE, stationary=False, prop_decrease=0.35).astype(np.float32)
        result = mlx_whisper.transcribe(cleaned, path_or_hf_repo=str(model), language="ja", task="transcribe",
                                        temperature=0.0, condition_on_previous_text=False, verbose=None,
                                        no_speech_threshold=0.55, logprob_threshold=-1.0,
                                        compression_ratio_threshold=2.4)
        segments = result.get("segments", [])
        accepted = usable_segments(segments)
        # Reject the complete utterance if any segment was uncertain: never silently send partial commands.
        if len(accepted) != len(segments) or not accepted:
            return {"text": "", "rejected": "認識の信頼度が不足しています。もう一度話してください。", "similarity": similarity, **speaker_metrics}
        text = "".join(s["text"] for s in accepted).strip()
        return {"text": text, "similarity": similarity, "speech_seconds": duration, **speaker_metrics}

    def cached_voice_reference(self, reference, sample_rate, reduce_noise=True):
        import numpy as np
        import soundfile as sf
        from scipy.signal import resample_poly
        from math import gcd
        stat = Path(reference).stat()
        key = (reference, stat.st_mtime_ns, stat.st_size, sample_rate, reduce_noise)
        if self.reference_key != key:
            audio, rate = sf.read(reference, dtype='float32', always_2d=True)
            audio = audio.mean(axis=1)
            if not 3 <= len(audio) / rate <= 30 or not np.isfinite(audio).all():
                raise WorkerRequestError("声の再現用の参照音声は3〜30秒の有効な音声を使用してください。")
            if rate != sample_rate:
                divisor = gcd(rate, sample_rate)
                audio = resample_poly(audio, sample_rate // divisor, rate // divisor)
            cleaned = clean_voice_reference(audio, sample_rate) if reduce_noise else audio
            self.reference_signal, self.reference_key = cleaned, key
        return self.reference_signal

    def prepare_tts(self, request):
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        model_path = str(local_path(request["model"], directory=True))
        reference = str(local_path(request["reference_audio"]))
        ref_text = request.get("reference_text", "").strip()
        if not ref_text:
            raise WorkerRequestError("音声再現には参照音声と一致する文字起こしが必要です。")
        if self.tts is None or self.tts_path != model_path:
            self.tts = load_model(model_path)
            self.tts_path = model_path
            self.warm_key = None
        reduce_noise = request.get("reduce_reference_noise", True)
        if not isinstance(reduce_noise, bool):
            raise WorkerRequestError("参照音声のノイズ軽減設定が不正です。")
        audio = self.cached_voice_reference(reference, self.tts.sample_rate, reduce_noise)
        return mx.array(audio), ref_text

    def generate_speech(self, text, reference, ref_text, max_tokens):
        return self.tts.generate(text=text, ref_audio=reference, ref_text=ref_text, lang_code="Japanese",
                                 verbose=False, stream=True, streaming_interval=0.8, max_tokens=max_tokens)

    def warm_speech(self, request):
        import time
        started = time.perf_counter()
        reference, ref_text = self.prepare_tts(request)
        key = (self.tts_path, self.reference_key, ref_text)
        if self.warm_key != key:
            # Exercise inference and populate the model's reference-code cache. Never play or save this audio.
            for _ in self.generate_speech("準備できました。", reference, ref_text, 32):
                pass
            self.warm_key = key
        return {"ready": True, "elapsed_seconds": time.perf_counter() - started}

    def speech_part(self, text, reference, ref_text, depth=0):
        limit = speech_token_limit(text)
        generation = self.generate_speech(text, reference, ref_text, limit)
        too_long = False
        try:
            result = checked_sentence(generation, limit)
        except SpeechLengthLimit:
            too_long = True
        finally:
            generation.close()
            self.tts.speech_tokenizer.decoder.reset_streaming_state()
        if not too_long:
            yield result
            return
        if depth >= 3 or len(text) <= 4:
            raise WorkerRequestError("短い区間に分割しても音声を生成できませんでした。参照音声・参照本文を確認し、読み上げを試してください。返信全文はホームで確認できます。")
        boundary = speech_boundary(text, (len(text) + 1) // 2)
        self.speech_resplits += 1
        for part in (text[:boundary].strip(), text[boundary:].strip()):
            if part:
                yield from self.speech_part(part, reference, ref_text, depth + 1)

    def audio_chunks(self, request):
        plan = list(speech_plan(request["text"]))
        reference, ref_text = self.prepare_tts(request)
        for index, total, unit in plan:
            with contextlib.closing(self.speech_part(unit, reference, ref_text)) as parts:
                result = joined_speech_parts(parts)
            result.line_index, result.line_count = index, total
            yield result

    def begin_speech(self, request):
        self.end_speech()
        lines = speech_lines(request["text"])
        self.speech_resplits = 0
        self.tts_stream = self.audio_chunks(request)
        return {"ready": True, "lines": len(lines)}

    def end_speech(self):
        if self.tts_stream is not None:
            self.tts_stream.close()
            self.tts_stream = None
        return {"done": True}

    @staticmethod
    def write_chunk(result, output):
        import numpy as np
        import soundfile as sf
        array = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if not len(array) or not np.isfinite(array).all():
            raise WorkerRequestError("音声生成結果が不正です。")
        sf.write(str(output), array, result.sample_rate)
        output.chmod(0o600)

    def next_speech(self, request):
        import time
        if self.tts_stream is None:
            raise WorkerRequestError("読み上げ処理が開始されていません。")
        output = local_path(request["output"])
        try:
            started = time.perf_counter()
            previous_splits = self.speech_resplits
            result = next(self.tts_stream)
            self.write_chunk(result, output)
            return {"done": False, "resplits": self.speech_resplits - previous_splits,
                    "line_index": result.line_index, "line_count": result.line_count,
                    "generation_seconds": time.perf_counter() - started,
                    "audio_seconds": len(result.audio) / result.sample_rate,
                    "fragments": result.fragments}
        except StopIteration:
            self.end_speech()
            return {"done": True}
        except Exception:
            self.end_speech()
            raise

    def synthesize(self, request):
        import numpy as np
        import soundfile as sf
        output = Path(request["output"])
        if not output.is_absolute() or not output.parent.is_dir():
            raise WorkerRequestError("読み上げ音声の保存先が不正です。")
        arrays, rate = [], None
        with contextlib.closing(self.audio_chunks(request)) as chunks:
            for result in chunks:
                arrays.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
                rate = result.sample_rate
        if not arrays:
            raise WorkerRequestError("読み上げ音声を生成できませんでした。")
        sf.write(str(output), np.concatenate(arrays), rate)
        output.chmod(0o600)
        return {"output": str(output)}

    def diagnose(self, request):
        import importlib
        import numpy as np
        for package in ["mlx_whisper", "scipy", "soundfile", "silero_vad", "resemblyzer", "noisereduce"]:
            importlib.import_module(package)
        model = local_path(request["model"], directory=True)
        if not (model / "config.json").is_file() or not any(model.glob("*.safetensors")):
            raise WorkerRequestError("Whisperモデルが未配置です。scripts/download-models.sh asr を実行してください。")
        self.speech_spans(np.zeros(ASR_SAMPLE_RATE, dtype=np.float32))
        if request.get("voice_model"):
            voice = local_path(request["voice_model"], directory=True)
            importlib.import_module("mlx_audio.tts.utils")
            if not (voice / "config.json").is_file() or not any(voice.glob("*.safetensors")):
                raise WorkerRequestError("音声再現モデルが未配置です。scripts/download-models.sh voice を実行してください。")
        return {"ready": True, "summary": "依存関係・モデル配置・ローカルVADを確認しました。音声認識の精度と声質は実際の録音で確認してください。"}

    def handle(self, request):
        action = request.get("action")
        if action == "diagnose": return self.diagnose(request)
        if action == "transcribe": return self.transcribe(request)
        if action == "verify_speaker": return self.verify_speaker(request)
        if action == "synthesize": return self.synthesize(request)
        if action == "warm_speech": return self.warm_speech(request)
        if action == "begin_speech": return self.begin_speech(request)
        if action == "next_speech": return self.next_speech(request)
        if action == "end_speech": return self.end_speech()
        if action == "ping":
            return {"ready": True, "offline": os.environ["HF_HUB_OFFLINE"] == "1"}
        raise WorkerRequestError("未対応の音声処理です。")


MAX_REQUEST_BYTES = 1_000_000


def serve(input_stream, output_stream, worker):
    """Bound input before decoding. An oversized frame closes this worker session."""
    while True:
        line = input_stream.readline(MAX_REQUEST_BYTES + 2)
        if not line:
            return
        oversized = len(line) > MAX_REQUEST_BYTES + 1
        try:
            if oversized:
                raise WorkerRequestError("リクエストが長すぎます。")
            if not line.endswith(b"\n"):
                raise WorkerRequestError("音声処理のリクエストが途中で終了しました。")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise WorkerRequestError("音声処理のリクエストはJSONオブジェクトで指定してください。")
            with contextlib.redirect_stdout(sys.stderr):
                result = worker.handle(request)
            response = json.dumps(result, ensure_ascii=False, allow_nan=False)
        except Exception as error:
            message = str(error) if isinstance(error, WorkerRequestError) else "ローカルモデルを実行できません。環境・モデルの配置を確認してください。"
            response = json.dumps({"error": message}, ensure_ascii=False)
        print(response, file=output_stream, flush=True)
        if oversized or not line.endswith(b"\n"):
            return


def main():
    serve(sys.stdin.buffer, sys.stdout, Worker())


if __name__ == "__main__":
    main()
