#!/usr/bin/env python3
"""Offline speech QA. Input, audio, and transcripts must stay outside the repository."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runs', type=int, default=2)
parser.add_argument('--temperature', type=float)
parser.add_argument('--max-characters', type=int)
parser.add_argument('--whole-decode', action='store_true')
reference_mode = parser.add_mutually_exclusive_group()
reference_mode.add_argument('--clean-reference', action='store_true', help='Test a specified reduction strength instead of the production cleanup.')
reference_mode.add_argument('--raw-reference', action='store_true', help='Bypass reference cleanup to reproduce the old baseline.')
parser.add_argument('--reference-reduction', type=float, default=0.85)
parser.add_argument('--asr-only', action='store_true')
parser.add_argument('--asr-model', type=Path)
args = parser.parse_args()
if args.runs < 1 or not 0 <= args.reference_reduction <= 1:
    parser.error('runs must be positive and reference-reduction must be between 0 and 1.')
root = Path(__file__).resolve().parents[1]
output = args.output.expanduser().resolve()
if output == root or root in output.parents:
    parser.error('Use a private directory outside the repository for audio and transcripts.')
os.umask(0o077)
output.mkdir(parents=True, exist_ok=True, mode=0o700)
os.environ['NUMBA_CACHE_DIR'] = str(output / 'numba')
spec = importlib.util.spec_from_file_location('relay_worker', root / 'worker/relay_worker.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if args.raw_reference or args.clean_reference:
    module.clean_voice_reference = lambda audio, rate: audio
import numpy as np
import soundfile as sf
import mlx.core as mx
settings = json.loads((Path.home() / 'Library/Application Support/LocalVoiceRelay/settings.json').read_text())
if args.max_characters:
    module.SPEECH_MAX_LINE_CHARACTERS = args.max_characters
text = args.input.read_text()
plan = list(module.speech_plan(text))
records_path = output / 'records.json'
if not args.asr_only:
    worker = module.Worker()
    request = dict(model=settings['ttsModelPath'], reference_audio=settings['referenceAudioPath'], reference_text=settings['referenceText'], text=text)
    if args.clean_reference:
        import noisereduce as nr
        reference, rate = sf.read(request['reference_audio'], dtype='float32', always_2d=True)
        reference = reference.mean(axis=1)
        size = int(rate * 0.02)
        frames = reference[:len(reference) // size * size].reshape(-1, size)
        rms = np.sqrt(np.mean(frames ** 2, axis=1))
        noise = frames[rms <= np.percentile(rms, 15)].reshape(-1)
        cleaned = nr.reduce_noise(y=reference, y_noise=noise, sr=rate, stationary=True,
                                  prop_decrease=args.reference_reduction, n_fft=1024, hop_length=256)
        path = output / 'cleaned-reference.wav'
        sf.write(path, cleaned, rate)
        request['reference_audio'] = str(path)
    def call(payload):
        with contextlib.redirect_stdout(sys.stderr):
            return worker.handle(payload)
    warm = call(dict(request, action='warm_speech'))
    original_generate = worker.tts.generate
    def generate(**kwargs):
        if args.temperature is not None:
            kwargs['temperature'] = args.temperature
        if args.whole_decode:
            kwargs['stream'] = False
        return original_generate(**kwargs)
    worker.tts.generate = generate
    records = []
    print(json.dumps({'warm_seconds': warm['elapsed_seconds'], 'units': len(plan)}), flush=True)
    for run in range(args.runs):
        mx.random.seed(20260909 + run)
        call(dict(request, action='begin_speech'))
        arrays = []
        index = 0
        while True:
            path = output / f'run-{run + 1}-unit-{index + 1:02}.wav'
            path.touch(mode=0o600)
            result = call(dict(action='next_speech', output=str(path)))
            if result['done']:
                path.unlink(); break
            audio, rate = sf.read(path, dtype='float32')
            assert audio.size and np.isfinite(audio).all()
            arrays.append(audio)
            frame = max(1, int(rate * 0.02))
            frames = audio[:len(audio) // frame * frame].reshape(-1, frame)
            rms = np.sqrt(np.mean(frames ** 2, axis=1))
            active = rms > max(0.001, float(rms.max()) * 0.02)
            indices = np.flatnonzero(active)
            pauses, start = [], None
            for i, value in enumerate(active):
                if not value and start is None: start = i
                if value and start is not None:
                    if start > 0 and (i - start) * 0.02 >= 0.3:
                        pauses.append({'at': round(start * 0.02, 2), 'seconds': round((i - start) * 0.02, 2)})
                    start = None
            record = {key: result[key] for key in ['line_index', 'line_count', 'generation_seconds', 'audio_seconds', 'resplits', 'fragments']}
            record.update(run=run + 1, unit=index + 1, text=plan[index][2], path=str(path), leading_silence=float(indices[0] * 0.02) if indices.size else None, trailing_silence=float((len(active) - 1 - indices[-1]) * 0.02) if indices.size else None, internal_pauses=pauses, clipping_fraction=float(np.mean(np.abs(audio) >= 0.999)))
            records.append(record)
            print(json.dumps({key: record[key] for key in ['run', 'unit', 'line_index', 'generation_seconds', 'audio_seconds', 'resplits', 'internal_pauses']}), flush=True)
            records_path.write_text(json.dumps(records, ensure_ascii=False, indent=2))
            index += 1
        assert index == len(plan)
        sf.write(output / f'run-{run + 1}-joined.wav', np.concatenate(arrays), rate)
    worker.end_speech()
    worker.tts = None
    del original_generate, generate, worker
    import gc
    gc.collect(); mx.clear_cache()
else:
    records = json.loads(records_path.read_text())
import mlx_whisper
asr = str(args.asr_model or settings['asrModelPath'])
for record in records:
    with contextlib.redirect_stdout(sys.stderr):
        result = mlx_whisper.transcribe(record['path'], path_or_hf_repo=asr, language='ja', temperature=0, condition_on_previous_text=False, word_timestamps=True, verbose=False)
    record['recognized'] = result['text']
    record['asr_segments'] = result.get('segments', [])
    records_path.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print(json.dumps({'run': record['run'], 'unit': record['unit'], 'line': record['line_index'], 'recognized': record['recognized']}, ensure_ascii=False), flush=True)
print(json.dumps({'records': len(records), 'peak_metal_gib': mx.get_peak_memory() / 2**30, 'report': str(records_path)}), flush=True)
