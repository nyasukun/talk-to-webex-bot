#!/usr/bin/env python3
"""Exercise long, line-separated speech offline with a generic synthetic reference; never play it."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DATA = Path.home() / 'Library/Application Support/LocalVoiceRelay'
os.environ['NUMBA_CACHE_DIR'] = str(DATA / 'runtime/cache/numba')
WORK = ROOT / '.build/sentences'
WORK.mkdir(parents=True, exist_ok=True)
reference = WORK / 'synthetic-reference.wav'
ref_text = '今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。'
subprocess.run(['/usr/bin/say', '-v', 'Kyoko', '--data-format=LEI16@24000', '-o', str(reference), ref_text], check=True)
spec = importlib.util.spec_from_file_location('relay_worker', ROOT / 'worker/relay_worker.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
worker = module.Worker()
import numpy as np
import soundfile as sf
import mlx.core as mx

lines = [
    'ウェブエックスの接続を確認しました。',
    'エーピーアイの確認間隔は百ミリ秒です。',
    '今日の予定を順番に説明します。',
    '午前中は資料を確認してください。',
    '午後は必要な情報を整理します。',
    '進み具合は五十パーセントです。',
    '音量はプラスボタンで調整できます。',
    'これで最後の文です。',
]
request = {'model': str(DATA / 'models/voice'), 'reference_audio': str(reference),
           'reference_text': ref_text, 'text': '\n'.join(lines)}

def call(request):
    with contextlib.redirect_stdout(sys.stderr):
        return worker.handle(request)

call({'action': 'transcribe', 'audio': str(reference), 'model': str(DATA / 'models/whisper')})
print(json.dumps(call({**request, 'action': 'warm_speech'})), flush=True)
records = []
long_text = 'ここから長い説明です、まず今日の予定を確認して必要な資料を手元にそろえてください；次に画面の内容を順番に読み取り、気になる点があれば短い言葉で質問してください：確認が終わったら次の作業へ進みます／途中で休憩を入れても構いません→これで最後の説明です。'
cases = [('lines-0', '\n'.join(lines), False), ('lines-1', '\n'.join(lines), False),
         ('long', long_text, False), ('recovery', '今日の予定を確認してから作業を進めます。\nこれで最後の文です。', True)]
for run, text, force_limit in cases:
    started = time.perf_counter()
    call({**request, 'text': text, 'action': 'begin_speech'})
    arrays, files, first, rate = [], [], None, None
    original_limit = module.speech_token_limit
    limits = 0
    resplits = 0
    def test_limit(part):
        global limits
        limits += 1
        return 1 if force_limit and limits == 1 else original_limit(part)
    # Force one real-model cap in the recovery case to exercise subdivision deterministically.
    with patch.object(module, 'speech_token_limit', side_effect=test_limit):
        while True:
            output = WORK / f'synthetic-{run}-{len(files)}.wav'
            output.touch(mode=0o600)
            result = call({'action': 'next_speech', 'output': str(output)})
            if result['done']:
                output.unlink()
                break
            resplits += result.get('resplits', 0)
            if first is None:
                first = time.perf_counter() - started
            audio, rate = sf.read(output, dtype='float32')
            assert audio.size and np.isfinite(audio).all()
            assert len(audio) / rate <= 24.5 * result['fragments']
            files.append(output)
            arrays.append(audio)
    assert len(files) == len(list(module.speech_plan(text)))
    if force_limit:
        assert resplits >= 1
    elapsed = time.perf_counter() - started
    sf.write(WORK / f'synthetic-full-{run}.wav', np.concatenate(arrays), rate)
    texts = []
    for output in files:
        result = call({'action': 'transcribe', 'audio': str(output), 'model': str(DATA / 'models/whisper')})
        assert result.get('text'), result
        texts.append(result['text'])
    assert '最後' in texts[-1], texts[-1]
    record = {'run': run, 'first_sentence_seconds': round(first, 3), 'generation_seconds': round(elapsed, 3),
              'audio_seconds': round(sum(len(a) for a in arrays) / rate, 3), 'sentences': len(files), 'resplits': resplits,
              'retranscribed': texts}
    records.append(record)
    print(json.dumps(record, ensure_ascii=False), flush=True)
print(json.dumps({'peak_metal_gib': round(mx.get_peak_memory() / 2**30, 3)}), flush=True)
(WORK / 'summary.json').write_text(json.dumps(records, ensure_ascii=False, indent=2))
