#!/usr/bin/env python3
"""Measure offline streaming with generic synthetic reference audio only; no microphone or playback."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import sys

ROOT = Path(__file__).resolve().parents[1]
DATA = Path.home() / "Library/Application Support/LocalVoiceRelay"
os.environ["NUMBA_CACHE_DIR"] = str(DATA / "runtime/cache/numba")
WORK = ROOT / ".build/streaming"
WORK.mkdir(parents=True, exist_ok=True)
reference = WORK / "synthetic-reference.wav"
ref_text = "今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。"
subprocess.run(["/usr/bin/say", "-v", "Kyoko", "--data-format=LEI16@24000", "-o", str(reference), ref_text], check=True)
spec = importlib.util.spec_from_file_location("relay_worker", ROOT / "worker/relay_worker.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
worker = module.Worker()
import numpy as np
import soundfile as sf
import mlx.core as mx

def call(request):
    with contextlib.redirect_stdout(sys.stderr):
        return worker.handle(request)

call({"action": "transcribe", "audio": str(reference), "model": str(DATA / "models/whisper")})
request = {"model": str(DATA / "models/voice"), "reference_audio": str(reference), "reference_text": ref_text,
           "text": "接続を確認しました。\n今日の予定を整理します。\n画面に表示された内容を順番に確認してください。"}
records = []
for label in ["cold", "warm"]:
    if label == "warm" or "--standby-first" in sys.argv:
        record = call({**request, "action": "warm_speech"})
        print(json.dumps({"warmup_seconds": record["elapsed_seconds"]}), flush=True)
    started = time.perf_counter()
    call({**request, "action": "begin_speech"})
    arrays, first, rate = [], None, None
    while True:
        output = WORK / "chunk.wav"
        output.touch(mode=0o600)
        result = call({"action": "next_speech", "output": str(output)})
        if result["done"]:
            output.unlink()
            break
        if first is None:
            first = time.perf_counter() - started
        audio, rate = sf.read(output, dtype="float32")
        assert audio.size and np.isfinite(audio).all()
        assert output.stat().st_mode & 0o777 == 0o600
        arrays.append(audio)
        output.unlink()
    record = {"case": label, "first_chunk_seconds": round(first, 3), "total_seconds": round(time.perf_counter() - started, 3),
              "audio_seconds": round(sum(len(a) for a in arrays) / rate, 3), "chunks": len(arrays)}
    assert len(arrays) == len(list(module.speech_plan(request['text'])))
    sf.write(WORK / f"synthetic-{label}.wav", np.concatenate(arrays), rate)
    records.append(record)
    print(json.dumps(record), flush=True)
recognized = call({"action": "transcribe", "audio": str(WORK / "synthetic-warm.wav"), "model": str(DATA / "models/whisper")})
assert "接続" in recognized.get("text", "") and "順番" in recognized["text"], recognized
print(json.dumps({"synthetic_stream_retranscribed": True}), flush=True)
call({**request, "action": "begin_speech"})
output = WORK / "cancel.wav"
output.touch(mode=0o600)
call({"action": "next_speech", "output": str(output)})
call({"action": "end_speech"})
output.unlink()
assert worker.tts_stream is None
print(json.dumps({"stream_cancelled": True, "peak_metal_gib": round(mx.get_peak_memory() / 2**30, 3)}), flush=True)
(WORK / "summary.json").write_text(json.dumps(records, indent=2))
