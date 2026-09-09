#!/usr/bin/env python3
"""Offline inference over JSON lines. No token, HTTP client, or audio logging."""
import contextlib
from functools import lru_cache
import json
import os
from pathlib import Path
import sys

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                  DO_NOT_TRACK="1", TOKENIZERS_PARALLELISM="false")


class WorkerRequestError(ValueError):
    """An app-authored error safe to show; dependency exception text stays private."""


def local_path(value, directory=False):
    path = Path(value).expanduser()
    if not path.is_absolute() or not (path.is_dir() if directory else path.is_file()):
        raise WorkerRequestError("ローカルファイルが見つかりません。モデルと音声の設定を確認してください。")
    return path.resolve()


SPEECH_MAX_LINE_CHARACTERS = 160
SPEECH_OPENING_CHARACTERS = 32


@lru_cache(maxsize=1)
def speech_tokenizer_api():
    """Use the Mac's offline word dictionary without adding a model or dependency."""
    import ctypes as ct
    class CFRange(ct.Structure):
        _fields_ = [('location', ct.c_long), ('length', ct.c_long)]
    api = ct.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    signatures = {
        'CFStringCreateWithBytes': (ct.c_void_p, [ct.c_void_p, ct.c_char_p, ct.c_long, ct.c_uint32, ct.c_bool]),
        'CFStringTokenizerCreate': (ct.c_void_p, [ct.c_void_p, ct.c_void_p, CFRange, ct.c_ulong, ct.c_void_p]),
        'CFStringTokenizerAdvanceToNextToken': (ct.c_ulong, [ct.c_void_p]),
        'CFStringTokenizerGetCurrentTokenRange': (CFRange, [ct.c_void_p]),
        'CFRelease': (None, [ct.c_void_p]),
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(api, name)
        function.restype, function.argtypes = result, arguments
    return api, CFRange


def speech_word_starts(text):
    if sys.platform != 'darwin':
        return []
    api, CFRange = speech_tokenizer_api()
    # CoreFoundation ranges use UTF-16; Python indexes use Unicode code points.
    offsets, offset = {0: 0}, 0
    for index, character in enumerate(text, 1):
        offset += 2 if ord(character) > 0xffff else 1
        offsets[offset] = index
    encoded = text.encode('utf-8')
    source = api.CFStringCreateWithBytes(None, encoded, len(encoded), 0x08000100, False)
    if not source:
        raise WorkerRequestError('読み上げ本文の単語を解析できません。')
    tokenizer = None
    try:
        tokenizer = api.CFStringTokenizerCreate(None, source, CFRange(0, offset), 0, None)
        if not tokenizer:
            raise WorkerRequestError('読み上げ本文の単語を解析できません。')
        starts = []
        previous = ''
        while api.CFStringTokenizerAdvanceToNextToken(tokenizer):
            span = api.CFStringTokenizerGetCurrentTokenRange(tokenizer)
            start, end = offsets[span.location], offsets[span.location + span.length]
            # Keep the honorific prefix attached even when the dictionary separates it.
            if previous not in ('お', 'ご'):
                starts.append(start)
            previous = text[start:end]
        return starts
    finally:
        if tokenizer:
            api.CFRelease(tokenizer)
        api.CFRelease(source)


def speech_boundary(text, maximum):
    import unicodedata
    # Avoid leaving a tiny independently generated ending such as a polite suffix.
    maximum = max(1, min(maximum, len(text) - min(8, len(text) // 2)))
    def safe_start(index):
        return (unicodedata.category(text[index])[0] != 'M'
                and text[index] not in 'ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶー\u200d'
                and text[index - 1] != '\u200d')
    boundaries = []
    for index, character in enumerate(text[:maximum], 1):
        category = unicodedata.category(character)
        if not (character.isspace() or category[0] in 'PS') or category in ('Ps', 'Pi'):
            continue
        # Keep decimal numbers, times, and grouped digits together when a nearby break exists.
        if character in '.,:，．：/／-−' and index > 1 and index < len(text) and text[index - 2].isdigit() and text[index].isdigit():
            continue
        if index >= 2 and safe_start(index):
            boundaries.append(index)
    if boundaries:
        return boundaries[-1]
    words = [index for index in speech_word_starts(text) if 0 < index <= maximum and safe_start(index)]
    # Prefer a phrase start to a particle, inflection, or the middle of kana readings.
    phrases = [index for index in words if not ('\u3041' <= text[index] <= '\u309f')
               and not ('\u30a1' <= text[index - 1] <= '\u30ff' and '\u30a1' <= text[index] <= '\u30ff')]
    if phrases or words:
        return (phrases or words)[-1]
    # A single oversized word still has to obey the generation cap.
    while maximum > 1 and not safe_start(maximum):
        maximum -= 1
    return maximum


def speech_lines(text):
    if not isinstance(text, str) or not text.strip() or len(text) > 20000:
        raise WorkerRequestError("読み上げ本文は1〜20,000文字で指定してください。")
    return [line.strip() for line in text.splitlines() if line.strip()]


def sentence_parts(line):
    import re
    return [match.group().strip() for match in re.finditer(r'.+?(?:[。！？!?]+[」』）”\"]*|\.(?=\s|$)|$)', line) if match.group().strip()]


def speech_line_units(line, opening=False):
    # Missing newlines must not merge many sentences into one expensive generation.
    parts = sentence_parts(line) if len(line) > SPEECH_MAX_LINE_CHARACTERS else [line]
    for part in parts:
        while part:
            maximum = SPEECH_OPENING_CHARACTERS if opening else SPEECH_MAX_LINE_CHARACTERS
            if len(part) <= maximum:
                yield part
                opening = False
                break
            first_sentence = sentence_parts(part)[0]
            boundary = len(first_sentence) if opening and len(first_sentence) <= maximum else speech_boundary(part, maximum)
            yield part[:boundary].strip()
            part = part[boundary:].strip()
            opening = False


def speech_plan(text):
    lines = speech_lines(text)
    for index, line in enumerate(lines, 1):
        for unit in speech_line_units(line, opening=index == 1):
            yield index, len(lines), unit


def speech_token_limit(text):
    # 12.5 codec tokens/second. Bound even a model that never generates its stop token.
    import math
    return math.ceil(min(24, max(5, len(text) * 0.45 + 3)) * 12.5)


class SpeechLengthLimit(ValueError):
    """The unplayed segment needs subdivision; never emit its incomplete audio."""


def checked_sentence(results, token_limit):
    import numpy as np
    from types import SimpleNamespace
    arrays, rate, tokens = [], None, 0
    for result in results:
        tokens += result.token_count
        if tokens >= token_limit:
            raise SpeechLengthLimit("音声区間をさらに短く分割します。")
        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if not len(audio) or not np.isfinite(audio).all() or result.sample_rate <= 0:
            raise WorkerRequestError("音声生成結果が不正です。")
        if rate is not None and rate != result.sample_rate:
            raise WorkerRequestError("音声生成中にサンプルレートが変わりました。")
        rate = result.sample_rate
        arrays.append(audio.copy())
        if sum(len(a) for a in arrays) / rate > token_limit / 12.5 + 0.5:
            raise SpeechLengthLimit("音声区間をさらに短く分割します。")
    if not arrays:
        raise WorkerRequestError("読み上げ音声を生成できませんでした。")
    return SimpleNamespace(audio=np.concatenate(arrays), sample_rate=rate, token_count=tokens)


def joined_speech_parts(results):
    """Commit a whole line only after all fallback fragments have succeeded."""
    import numpy as np
    from types import SimpleNamespace
    arrays, rate = [], None
    for result in results:
        if rate is not None and rate != result.sample_rate:
            raise WorkerRequestError("音声生成中にサンプルレートが変わりました。")
        rate = result.sample_rate
        arrays.append(result.audio)
    if not arrays:
        raise WorkerRequestError("読み上げ音声を生成できませんでした。")
    return SimpleNamespace(audio=np.concatenate(arrays), sample_rate=rate, fragments=len(arrays))


def usable_segments(segments):
    return [s for s in segments if float(s.get("no_speech_prob", 1)) < 0.55
            and float(s.get("avg_logprob", -100)) >= -1.0
            and float(s.get("compression_ratio", 100)) < 2.4]


def speaker_window_ranges(sample_count):
    minimum, maximum, step = 25600, 48000, 24000
    if sample_count < minimum:
        return []
    if sample_count <= maximum:
        return [(0, sample_count)]
    starts = list(range(0, sample_count - maximum + 1, step))
    tail = sample_count - maximum
    if starts[-1] != tail:
        starts.append(tail)
    return [(start, start + maximum) for start in starts]


def speaker_scores_accepted(scores, threshold):
    import math
    return bool(scores) and math.isfinite(threshold) and 0.5 <= threshold <= 0.99 and all(
        math.isfinite(value) and value >= threshold for value in scores)


def preferred_turns(scores, similarities_to_best):
    """Keep uncertain turns; drop only a clearly different voice next to a credible reference match."""
    import math
    measured = [i for i, value in enumerate(scores) if value is not None and math.isfinite(value)]
    if len(measured) < 2:
        return list(range(len(scores)))
    best = max(measured, key=lambda i: scores[i])
    if scores[best] < 0.64:
        return list(range(len(scores)))
    return [i for i in range(len(scores)) if i not in measured or
            not (scores[best] - scores[i] > 0.16 and
                 math.isfinite(similarities_to_best[i]) and similarities_to_best[i] < 0.65)]


def clean_voice_reference(audio, sample_rate):
    """Reduce quiet, stationary background before the voice model learns it."""
    import numpy as np
    import noisereduce as nr
    audio = np.asarray(audio, dtype=np.float32)
    frame_size = max(1, round(sample_rate * 0.02))
    frames = audio[:len(audio) // frame_size * frame_size].reshape(-1, frame_size)
    if not len(frames):
        return audio.copy()
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    quiet, speech = np.percentile(rms, [15, 90])
    # Without a clearly quieter part, weak speech is not a safe noise profile.
    if quiet < 0.0001 or quiet > speech * 0.2:
        return audio.copy()
    noise = frames[rms <= quiet].reshape(-1)
    cleaned = nr.reduce_noise(y=audio, y_noise=noise, sr=sample_rate, stationary=True,
                              prop_decrease=0.65, n_fft=1024, hop_length=256)
    cleaned = np.asarray(cleaned, dtype=np.float32)
    if cleaned.shape != audio.shape or not np.isfinite(cleaned).all():
        raise WorkerRequestError("参照音声のノイズ処理に失敗しました。参照録音を確認してください。")
    return cleaned


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

    def audio(self, value):
        import numpy as np
        import soundfile as sf
        from scipy.signal import resample_poly
        from math import gcd
        audio, rate = sf.read(str(local_path(value)), dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        if rate != 16000:
            divisor = gcd(rate, 16000)
            audio = resample_poly(audio, 16000 // divisor, rate // divisor)
        if len(audio) < 4000 or len(audio) > 16000 * 60 or not np.isfinite(audio).all():
            raise WorkerRequestError("録音は0.25〜60秒の有効な音声を使用してください。")
        return np.asarray(audio, dtype=np.float32)

    def speech(self, audio):
        import torch
        from silero_vad import load_silero_vad, get_speech_timestamps
        if self.vad is None:
            torch.set_num_threads(2)
            self.vad = load_silero_vad()  # Weights ship in the installed wheel; no torch.hub.
        return get_speech_timestamps(torch.from_numpy(audio), self.vad, sampling_rate=16000,
                                     threshold=0.65, min_speech_duration_ms=300, min_silence_duration_ms=200)

    def embedding(self, audio):
        from resemblyzer import VoiceEncoder, preprocess_wav
        if self.encoder is None:
            self.encoder = VoiceEncoder(device="cpu", verbose=False)
        return self.encoder.embed_utterance(preprocess_wav(audio, source_sr=16000))

    def check_speaker(self, audio, speech, request):
        import numpy as np
        duration = sum(s["end"] - s["start"] for s in speech) / 16000
        ranges = speaker_window_ranges(round(duration * 16000))
        if not ranges:
            return {"accepted": False, "speech_seconds": duration,
                    "rejected": "本人照合には指示の発話が短すぎます。合言葉から、指示をもう少し長く話してください（音声区間1.6秒以上）。"}
        reference = self.audio(request["reference_audio"])
        ref_speech = self.speech(reference)
        if sum(s["end"] - s["start"] for s in ref_speech) < 3 * 16000:
            raise WorkerRequestError("本人照合用に3秒以上の発話を含む音声を登録してください。")
        reference_voice = np.concatenate([reference[s["start"]:s["end"]] for s in ref_speech])
        reference_embedding = self.embedding(reference_voice)
        # Join voiced spans before windowing: isolated syllables would be padded to 1.6 s by the encoder.
        utterance = np.concatenate([audio[s["start"]:s["end"]] for s in speech])
        overall = float(np.dot(reference_embedding, self.embedding(utterance)))
        windows = [{"seconds": (end - start) / 16000,
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
        audio = self.audio(request["audio"])
        return self.check_speaker(audio, self.speech(audio), request)

    def prefer_speaker(self, audio, speech, request):
        import numpy as np
        voiced = np.concatenate([audio[s["start"]:s["end"]] for s in speech])
        if len(voiced) < 25600:
            return audio, {"speaker_note": "声の優先: 短い発話も受け付けます。合言葉と認識結果で判断します。"}
        reference = self.audio(request["reference_audio"])
        ref_speech = self.speech(reference)
        if sum(s["end"] - s["start"] for s in ref_speech) < 48000:
            raise WorkerRequestError("声の優先用に3秒以上の発話を含む参照音声を登録してください。")
        ref = self.embedding(np.concatenate([reference[s["start"]:s["end"]] for s in ref_speech]))
        overall = float(np.dot(ref, self.embedding(voiced)))
        groups = []
        for span in speech:
            if groups and span["start"] - groups[-1][-1]["end"] < 7200:
                groups[-1].append(span)
            else:
                groups.append([span])
        turns = [np.concatenate([audio[s["start"]:s["end"]] for s in group]) for group in groups]
        embeddings = [self.embedding(turn) if len(turn) >= 25600 else None for turn in turns]
        scores = [float(np.dot(ref, value)) if value is not None else None for value in embeddings]
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
        audio = self.audio(request["audio"])
        speech = self.speech(audio)
        duration = sum(s["end"] - s["start"] for s in speech) / 16000
        if duration < 0.45 or duration / (len(audio) / 16000) < 0.12:
            return {"text": "", "rejected": "音声区間が不足しています。"}
        similarity = None
        speaker_metrics = {}
        if request.get("prefer_speaker"):
            audio, speaker_metrics = self.prefer_speaker(audio, speech, request)
            similarity = speaker_metrics.get("similarity")
        elif request.get("verify_speaker"):
            speaker_metrics = self.check_speaker(audio, speech, request)
            similarity = speaker_metrics.get("similarity")
            if not speaker_metrics["accepted"]:
                return {"text": "", **speaker_metrics}
        # Band filtering + gentle spectral reduction complements AVAudioEngine voice processing.
        filtered = sosfilt(butter(3, [80, 7600], btype="bandpass", fs=16000, output="sos"), audio).astype(np.float32)
        cleaned = nr.reduce_noise(y=filtered, sr=16000, stationary=False, prop_decrease=0.35).astype(np.float32)
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

    def warm_speech(self, request):
        import time
        started = time.perf_counter()
        reference, ref_text = self.prepare_tts(request)
        key = (self.tts_path, self.reference_key, ref_text)
        if self.warm_key != key:
            # Exercise inference and populate the model's reference-code cache. Never play or save this audio.
            for _ in self.tts.generate(text="準備できました。", ref_audio=reference, ref_text=ref_text,
                                       lang_code="Japanese", verbose=False, stream=True,
                                       streaming_interval=0.8, max_tokens=32):
                pass
            self.warm_key = key
        return {"ready": True, "elapsed_seconds": time.perf_counter() - started}

    def speech_part(self, text, reference, ref_text, depth=0):
        limit = speech_token_limit(text)
        generation = self.tts.generate(text=text, ref_audio=reference, ref_text=ref_text,
                                       lang_code="Japanese", verbose=False, stream=True,
                                       streaming_interval=0.8, max_tokens=limit)
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
        self.speech(np.zeros(16000, dtype=np.float32))
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
