#!/usr/bin/env python3
"""Offline checks on generated, generic Japanese speech; never records the microphone."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
DATA = Path.home() / "Library/Application Support/LocalVoiceRelay"
SAMPLES = [
    "オッケー、アシスタント。今日の予定を短く説明してください。",
    "画面に表示されている文章を読んで、重要な点を三つにまとめてください。",
    "明日の午後三時から三十分、資料の内容を確認します。",
]


def normalized(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text) if c.isalnum())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="whisper")
    parser.add_argument("--voice", action="store_true")
    args = parser.parse_args()
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", DO_NOT_TRACK="1")
    work = ROOT / ".build/smoke"
    work.mkdir(parents=True, exist_ok=True)
    os.environ["NUMBA_CACHE_DIR"] = str(work / "numba")
    sys.path.insert(0, str(ROOT / "worker"))
    import relay_worker as module
    worker = module.Worker()
    import numpy as np
    import soundfile as sf
    import mlx.core as mx
    summary = {"model": args.model, "synthetic_speech_only": True, "samples": []}
    for index, text in enumerate(SAMPLES):
        path = work / f"sample-{index}.wav"
        subprocess.run(["/usr/bin/say", "-v", "Kyoko", "--data-format=LEI16@16000", "-o", str(path), text], check=True)
        started = time.perf_counter()
        with contextlib.redirect_stdout(sys.stderr):
            result = worker.transcribe({"audio": str(path), "model": str(DATA / "models" / args.model)})
        elapsed = time.perf_counter() - started
        expected, actual = normalized(text), normalized(result.get("text", ""))
        record = {"index": index, "audio_seconds": sf.info(path).duration, "elapsed_seconds": round(elapsed, 3),
                  "character_error_rate": round(distance(expected, actual) / len(expected), 4),
                  "recognized": result.get("text", ""), "rejected": result.get("rejected")}
        summary["samples"].append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
        if not actual:
            raise RuntimeError("Synthetic speech was rejected; investigate before proceeding")
    for kind in ["silence", "noise", "tone"]:
        rng = np.random.default_rng(42)
        audio = {"silence": np.zeros(80000), "noise": rng.normal(0, .015, 80000),
                 "tone": .05 * np.sin(2 * np.pi * 440 * np.arange(80000) / 16000)}[kind]
        path = work / f"{kind}.wav"; sf.write(path, audio, 16000)
        with contextlib.redirect_stdout(sys.stderr):
            result = worker.transcribe({"audio": str(path), "model": str(DATA / "models" / args.model)})
        assert not result["text"], kind
        summary[kind + "_rejected"] = True
    reference = str(work / "sample-1.wav")
    with contextlib.redirect_stdout(sys.stderr):
        result = worker.transcribe({"audio": reference, "model": str(DATA / "models" / args.model),
                                   "verify_speaker": True, "reference_audio": reference, "speaker_threshold": .76})
    summary["identical_synthetic_speaker_similarity"] = result.get("similarity")
    assert result.get("text"), "Speaker embedding could not match identical audio"
    summary["asr_peak_rss_gib"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**3, 3)
    summary["asr_peak_metal_gib"] = round(mx.get_peak_memory() / 1024**3, 3)
    if args.voice:
        started = time.perf_counter()
        output = work / "synthetic-reference-tts.wav"
        with contextlib.redirect_stdout(sys.stderr):
            worker.synthesize({"model": str(DATA / "models/voice"), "reference_audio": reference,
                               "reference_text": SAMPLES[1], "text": "音声の確認です。必要な情報を分かりやすく説明します。", "output": str(output)})
        wave, rate = sf.read(output)
        assert np.isfinite(wave).all() and len(wave) > rate and np.max(np.abs(wave)) > .001
        summary["tts_seconds"] = round(time.perf_counter() - started, 3)
        summary["tts_audio_seconds"] = len(wave) / rate
        with contextlib.redirect_stdout(sys.stderr):
            roundtrip = worker.transcribe({"audio": str(output), "model": str(DATA / "models" / args.model)})
        summary["tts_roundtrip_text"] = roundtrip.get("text", "")
    summary["combined_peak_rss_gib"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**3, 3)
    summary["combined_peak_metal_gib"] = round(mx.get_peak_memory() / 1024**3, 3)
    (work / f"{args.model}-report.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
