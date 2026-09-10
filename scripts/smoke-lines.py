#!/usr/bin/env python3
"""Offline line-generation check. Audio stays in a temporary directory and is never played."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--input', type=Path, help='Optional local text file; never copied to the repository.')
parser.add_argument('--saved-reference', action='store_true', help='Read only the saved local voice reference and model paths.')
parser.add_argument('--flatten', action='store_true', help='Simulate a reply whose paragraph breaks were lost.')
parser.add_argument('--inspect-lines', default='', help='Comma-separated line numbers to retranscribe to stdout only.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
data = Path.home() / 'Library/Application Support/LocalVoiceRelay'
sys.path.insert(0, str(root / 'worker'))
import relay_worker as module
text = args.input.read_text() if args.input else '\n\n'.join([
    '承知しました。',
    '音声読み上げを確認するため、少し長い文章を順番にお届けします。',
    'ただいまの時刻は、ごごさんじじゅうごふんを回ったところです。予定を一緒に確認しましょう。',
    '本日もたくさんの作業を進めていただき、本当にお疲れ様です。',
    '最初に資料を確認し、必要な情報を整理してから、次の作業に取りかかりました。',
    '途中で新しい連絡が入りましたが、順番に対応して、予定どおりの内容を進められました。',
    '続いて、画面の内容を確認し、説明が分かりにくい箇所を見直して、読みやすい文章に整えました。',
    '一つずつ確認した結果、必要な資料がそろい、これから進める作業の見通しがつきました。',
    'ここからは少し長い説明です。予定の確認、必要な情報の整理、資料の作成、内容の見直し、関係する作業の確認、進み具合の記録、最後の仕上げという順番で進めます。',
    'これからも、必要な情報を適切なタイミングで確認しながら、無理のないペースで作業を進めていきましょう。',
    '急いでいるときほど、最初に目的を確かめて、今すぐ必要な作業から取りかかることが大切です。',
    '分からないことがあれば、遠慮なく確認してください。一緒に内容を整理し、次の一歩を考えていきます。',
    '長い文章でも、改行で示した区切りに沿って、順番に音声をお届けできるかを確認しています。',
    'これで本日の振り返りを終わります。最後まで聞いていただき、ありがとうございました。',
    '最後の行です。途中のつながりや声の聞き取りやすさはいかがでしたか？',
])
inspect = {int(value) for value in args.inspect_lines.split(',') if value}
if args.flatten:
    text = ' '.join(module.speech_lines(text))

with tempfile.TemporaryDirectory(prefix='relay-lines-') as directory:
    work = Path(directory)
    os.environ['NUMBA_CACHE_DIR'] = str(work / 'numba')
    import numpy as np
    import soundfile as sf
    import mlx.core as mx
    if args.saved_reference:
        settings = json.loads((data / 'settings.json').read_text())
        reference, ref_text = settings['referenceAudioPath'], settings['referenceText']
        model, asr = settings['ttsModelPath'], settings['asrModelPath']
    else:
        reference = str(work / 'reference.wav')
        ref_text = '今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。'
        subprocess.run(['/usr/bin/say', '-v', 'Kyoko', '--data-format=LEI16@24000', '-o', reference, ref_text], check=True)
        model, asr = str(data / 'models/voice'), str(data / 'models/whisper')
    worker = module.Worker()
    request = dict(model=model, reference_audio=reference, reference_text=ref_text, text=text)
    def call(payload):
        with contextlib.redirect_stdout(sys.stderr):
            return worker.handle(payload)
    call(dict(request, action='warm_speech'))
    call(dict(request, action='begin_speech'))
    records, files = [], []
    while True:
        output = work / f'line-{len(records)}.wav'
        output.touch(mode=0o600)
        result = call(dict(action='next_speech', output=str(output)))
        if result['done']:
            break
        audio, rate = sf.read(output, dtype='float32')
        assert audio.size and np.isfinite(audio).all()
        assert output.stat().st_mode & 0o777 == 0o600
        frames = audio[:len(audio) // 480 * 480].reshape(-1, 480)
        rms = np.sqrt(np.mean(frames ** 2, axis=1))
        voiced = np.flatnonzero(rms > max(0.001, float(rms.max()) * 0.02))
        assert len(voiced), 'Generated a silent line.'
        record = {key: result[key] for key in ['line_index', 'line_count', 'generation_seconds', 'audio_seconds', 'resplits', 'fragments']}
        record['leading_silence_seconds'] = round(voiced[0] * 480 / rate, 3)
        record['trailing_silence_seconds'] = round((len(rms) - 1 - voiced[-1]) * 480 / rate, 3)
        records.append(record); files.append(output)
        print(json.dumps(record), flush=True)
    expected = [index for index, _, _ in module.speech_plan(text)]
    assert [r['line_index'] for r in records] == expected
    # Start on the first unit; subsequent generation shares the app's ahead limit.
    now, queued, started, gaps, initial_ready = 0.0, [], False, [], None
    for index, record in enumerate(records):
        if started:
            while len(queued) > 2 or (queued[-1] - now if queued else 0) > 30:
                now += max(queued[0] - now if len(queued) > 2 else 0, max(0, queued[-1] - now - 30))
                queued = [end for end in queued if end > now + 1e-9]
        previous_end = queued[-1] if queued else now
        now += record['generation_seconds']
        if started:
            if now > previous_end:
                gaps.append({'line': record['line_index'], 'seconds': round(now - previous_end, 3)})
            queued = [end for end in queued if end > now]
        queued.append((queued[-1] if queued else now) + record['audio_seconds'])
        if not started:
            started, initial_ready = True, now
            queued = np.cumsum([r['audio_seconds'] for r in records[:index + 1]]).tolist()
            queued = [end + now for end in queued]
    print(json.dumps({'lines': len(module.speech_lines(text)), 'audio_units': len(records),
                      'audio_seconds': sum(r['audio_seconds'] for r in records),
                      'generation_seconds': sum(r['generation_seconds'] for r in records),
                      'initial_ready_seconds': initial_ready, 'estimated_gaps': gaps,
                      'peak_metal_gib': round(mx.get_peak_memory() / 2**30, 3)}), flush=True)
    if inspect:
        import mlx_whisper
        for record, output in zip(records, files):
            if record['line_index'] in inspect:
                with contextlib.redirect_stdout(sys.stderr):
                    result = mlx_whisper.transcribe(str(output), path_or_hf_repo=asr, language='ja',
                                                  temperature=0, condition_on_previous_text=False, verbose=False)
                print(json.dumps({'line': record['line_index'], 'recognized': result['text']}, ensure_ascii=False), flush=True)
