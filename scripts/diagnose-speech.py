#!/usr/bin/env python3
"""Offline speech QA. Input, audio, and transcripts must stay outside the repository."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import sys
import time
import unicodedata

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runs', type=int, default=2)
parser.add_argument('--model', type=Path, help='Voice model folder; defaults to the app setting.')
parser.add_argument('--temperature', type=float)
parser.add_argument('--top-k', type=int)
parser.add_argument('--repetition-penalty', type=float)
parser.add_argument('--max-characters', type=int)
parser.add_argument('--whole-decode', action='store_true')
parser.add_argument('--legacy', action='store_true',
                    help='Reproduce build 12: reference noise reduction only, no output finishing, library sampling.')
parser.add_argument('--no-finish', action='store_true', help='Skip the per-segment output finishing.')
parser.add_argument('--legacy-reference', action='store_true', help='Reference noise reduction only, without trimming, level or low-cut conditioning.')
parser.add_argument('--reference-steps', help='Comma-separated subset of highpass,noise,level (plus the rejected trim) to apply to the reference (ablation).')
parser.add_argument('--legacy-sampling', action='store_true', help='Use the library sampler without the local fixes.')
reference_mode = parser.add_mutually_exclusive_group()
reference_mode.add_argument('--clean-reference', action='store_true', help='Test a specified reduction strength instead of the production conditioning.')
reference_mode.add_argument('--raw-reference', action='store_true', help='Bypass all reference conditioning to reproduce the old baseline.')
parser.add_argument('--reference-reduction', type=float, default=0.85)
parser.add_argument('--similarity', action='store_true', help='Score each segment against the reference with the local speaker encoder.')
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
sys.path.insert(0, str(root / 'worker'))
import relay_speech
import relay_worker as module
if args.raw_reference or args.clean_reference:
    module.prepare_voice_reference = lambda audio, rate, reduce_noise: audio
elif args.legacy or args.legacy_reference:
    module.prepare_voice_reference = lambda audio, rate, reduce_noise: relay_speech.clean_voice_reference(audio, rate) if reduce_noise else audio
elif args.reference_steps is not None:
    steps = set(args.reference_steps.split(','))
    def partial_reference(audio, rate, reduce_noise):
        import numpy as np
        audio = np.asarray(audio, dtype=np.float32)
        if 'highpass' in steps:
            audio = relay_speech.high_passed(audio, rate, relay_speech.REFERENCE_HIGH_PASS_HZ)
        if reduce_noise and 'noise' in steps:
            audio = relay_speech.clean_voice_reference(audio, rate)
        if 'trim' in steps:
            # Rejected on 2026-09-10 (lower similarity with 0.6B); kept only for ablation.
            trimmed = relay_speech.trimmed_speech(audio, rate, 0.15, 0.15)
            if len(trimmed) >= 3 * rate:
                audio = trimmed
        if 'level' in steps:
            audio = audio * relay_speech.level_gain(audio, rate, relay_speech.REFERENCE_TARGET_RMS_DB,
                                                    relay_speech.REFERENCE_GAIN_RANGE_DB, relay_speech.OUTPUT_PEAK_CEILING)
        return np.asarray(audio, dtype=np.float32)
    module.prepare_voice_reference = partial_reference
if args.legacy or args.no_finish:
    module.finished_speech = lambda audio, rate: audio
import numpy as np
import soundfile as sf
import mlx.core as mx
settings = json.loads((Path.home() / 'Library/Application Support/LocalVoiceRelay/settings.json').read_text())
if args.max_characters:
    relay_speech.SPEECH_MAX_LINE_CHARACTERS = args.max_characters
text = args.input.read_text()
plan = list(module.speech_plan(text))
records_path = output / 'records.json'
summary_path = output / 'summary.json'


def normalized(value):
    return ''.join(c for c in unicodedata.normalize('NFKC', value) if c.isalnum())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def level_metrics(audio, rate):
    levels, _ = relay_speech.frame_levels(audio, rate)
    if not len(levels):
        return {}
    active = relay_speech.active_frames(levels)
    def db(value):
        return round(float(20 * np.log10(max(value, 1e-9))), 1)
    return {'speech_rms_db': db(float(np.sqrt(np.mean(levels[active] ** 2)))) if active.any() else None,
            'quiet_db': db(float(np.percentile(levels, 10))), 'peak': round(float(np.abs(audio).max()), 3)}


summary = {'model': str(args.model or settings['ttsModelPath']), 'units': len(plan), 'runs': args.runs,
           'legacy': args.legacy, 'no_finish': args.no_finish, 'legacy_sampling': args.legacy_sampling,
           'legacy_reference': args.legacy_reference, 'reference_steps': args.reference_steps,
           'raw_reference': args.raw_reference, 'clean_reference': args.clean_reference,
           'sampling': dict(relay_speech.SPEECH_SAMPLING)}
if not args.asr_only:
    worker = module.Worker()
    request = dict(model=str(args.model or settings['ttsModelPath']), reference_audio=settings['referenceAudioPath'],
                   reference_text=settings['referenceText'], text=text)
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
    load_started = time.perf_counter()
    warm = call(dict(request, action='warm_speech'))
    summary['warm_seconds'] = warm['elapsed_seconds']
    summary['load_and_warm_seconds'] = time.perf_counter() - load_started
    if args.legacy or args.legacy_sampling:
        # The instance attribute holds the local wrapper; the class method is the library sampler.
        if '_sample_token' in vars(worker.tts):
            del worker.tts._sample_token
    original_generate = worker.tts.generate
    overrides = {key: value for key, value in [('temperature', args.temperature), ('top_k', args.top_k),
                                               ('repetition_penalty', args.repetition_penalty)] if value is not None}
    summary['sampling'].update(overrides)
    def generate(**kwargs):
        kwargs.update(overrides)
        if args.whole_decode:
            kwargs['stream'] = False
        return original_generate(**kwargs)
    worker.tts.generate = generate
    embed = None
    if args.similarity:
        reference_signal = worker.cached_voice_reference(request['reference_audio'], worker.tts.sample_rate,
                                                         request.get('reduce_reference_noise', True))
        from scipy.signal import resample_poly
        reference_embedding = worker.embedding(np.asarray(resample_poly(reference_signal, 2, 3), dtype=np.float32))
        def embed(audio, rate):
            from math import gcd
            divisor = gcd(rate, 16000)
            resampled = resample_poly(audio, 16000 // divisor, rate // divisor)
            return float(np.dot(reference_embedding, worker.embedding(np.asarray(resampled, dtype=np.float32))))
    records = []
    print(json.dumps({'warm_seconds': warm['elapsed_seconds'], 'units': len(plan)}), flush=True)
    for run in range(args.runs):
        mx.random.seed(20260909 + run)
        call(dict(request, action='begin_speech'))
        arrays = []
        index = 0
        run_started = time.perf_counter()
        while True:
            path = output / f'run-{run + 1}-unit-{index + 1:02}.wav'
            path.touch(mode=0o600)
            result = call(dict(action='next_speech', output=str(path)))
            if result['done']:
                path.unlink()
                break
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
                if not value and start is None:
                    start = i
                if value and start is not None:
                    if start > 0 and (i - start) * 0.02 >= 0.3:
                        pauses.append({'at': round(start * 0.02, 2), 'seconds': round((i - start) * 0.02, 2)})
                    start = None
            record = {key: result[key] for key in ['line_index', 'line_count', 'generation_seconds', 'audio_seconds', 'resplits', 'fragments']}
            record.update(run=run + 1, unit=index + 1, text=plan[index][2], path=str(path),
                          leading_silence=float(indices[0] * 0.02) if indices.size else None,
                          trailing_silence=float((len(active) - 1 - indices[-1]) * 0.02) if indices.size else None,
                          internal_pauses=pauses, clipping_fraction=float(np.mean(np.abs(audio) >= 0.999)),
                          **level_metrics(audio, rate))
            if embed is not None:
                record['similarity'] = round(embed(audio, rate), 4)
            records.append(record)
            print(json.dumps({key: record[key] for key in ['run', 'unit', 'line_index', 'generation_seconds', 'audio_seconds', 'resplits', 'internal_pauses', 'speech_rms_db', 'quiet_db'] + (['similarity'] if embed else [])}), flush=True)
            records_path.write_text(json.dumps(records, ensure_ascii=False, indent=2))
            index += 1
        assert index == len(plan)
        summary.setdefault('run_seconds', []).append(round(time.perf_counter() - run_started, 3))
        sf.write(output / f'run-{run + 1}-joined.wav', np.concatenate(arrays), rate)
    worker.end_speech()
    summary['peak_metal_gib'] = round(mx.get_peak_memory() / 2**30, 3)
    worker.tts = None
    del original_generate, generate, worker
    import gc
    gc.collect()
    mx.clear_cache()
else:
    records = json.loads(records_path.read_text())
    summary = json.loads(summary_path.read_text()) if summary_path.is_file() else summary
import mlx_whisper
asr = str(args.asr_model or settings['asrModelPath'])
for record in records:
    with contextlib.redirect_stdout(sys.stderr):
        result = mlx_whisper.transcribe(record['path'], path_or_hf_repo=asr, language='ja', temperature=0, condition_on_previous_text=False, word_timestamps=True, verbose=False)
    record['recognized'] = result['text']
    record['asr_segments'] = result.get('segments', [])
    expected = normalized(record['text'])
    record['character_error_rate'] = round(distance(expected, normalized(record['recognized'])) / max(1, len(expected)), 4)
    records_path.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print(json.dumps({'run': record['run'], 'unit': record['unit'], 'line': record['line_index'], 'cer': record['character_error_rate'], 'recognized': record['recognized']}, ensure_ascii=False), flush=True)


def stat(key, reducer=np.median):
    values = [record[key] for record in records if record.get(key) is not None]
    return round(float(reducer(values)), 4) if values else None


summary.update(records=len(records), total_audio_seconds=round(sum(r['audio_seconds'] for r in records), 2),
               total_generation_seconds=round(sum(r['generation_seconds'] for r in records), 2),
               first_unit_generation_seconds=[round(r['generation_seconds'], 3) for r in records if r['unit'] == 1],
               resplits=sum(r['resplits'] for r in records), median_cer=stat('character_error_rate'),
               mean_cer=stat('character_error_rate', np.mean), median_similarity=stat('similarity'),
               median_speech_rms_db=stat('speech_rms_db'), median_quiet_db=stat('quiet_db'),
               median_trailing_silence=stat('trailing_silence'), median_leading_silence=stat('leading_silence'),
               report=str(records_path))
summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print(json.dumps(summary, ensure_ascii=False), flush=True)
