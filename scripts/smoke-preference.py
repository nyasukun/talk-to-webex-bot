#!/usr/bin/env python3
"""Exercise voice preference using two installed synthetic voices, never a real recording."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DATA = Path.home() / "Library/Application Support/LocalVoiceRelay"
WORK = ROOT / ".build/preference"
WORK.mkdir(parents=True, exist_ok=True)
os.environ["NUMBA_CACHE_DIR"] = str(DATA / "runtime/cache/numba")
spec = importlib.util.spec_from_file_location("relay_worker", ROOT / "worker/relay_worker.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
worker = module.Worker()
import numpy as np
import soundfile as sf

def synthetic(name, voice, text):
    output = WORK / f"{name}.wav"
    subprocess.run(["/usr/bin/say", "-v", voice, "--data-format=LEI16@16000", "-o", str(output), text], check=True)
    return output

reference = synthetic("reference", "Kyoko", "今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。")
short = synthetic("short", "Kyoko", "短く答えて。")
own = synthetic("preferred", "Kyoko", "オッケー、アシスタント。今日の予定を短く教えてください。")
other = synthetic("other", "Reed (Japanese (Japan))", "音楽の話をしています。週末は散歩に出かけます。")
joined = WORK / "alternating.wav"
sf.write(joined, np.concatenate([sf.read(own)[0], np.zeros(12800), sf.read(other)[0]]), 16000)
for label, audio in [("short", short), ("single", own), ("alternating", joined)]:
    with contextlib.redirect_stdout(sys.stderr):
        result = worker.transcribe({"audio": str(audio), "model": str(DATA / "models/whisper"),
                                    "prefer_speaker": True, "reference_audio": str(reference)})
    assert result.get("text"), result
    assert "rejected" not in result, result
    if label != "short":
        assert "予定" in result["text"], result
    print(json.dumps({"case": label, "recognized": True, "selection": result.get("speaker_note"),
                      "other_turn_retained": "散歩" in result["text"]}, ensure_ascii=False), flush=True)
