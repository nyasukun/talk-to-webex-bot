"""Speech text planning, generated-audio checks and reference-audio cleanup for the voice model."""
from functools import lru_cache
import sys

from relay_common import WorkerRequestError
from relay_speech_settings import speech_options


DEFAULT_SPEECH_OPTIONS = speech_options()
SPEECH_MAX_LINE_CHARACTERS = DEFAULT_SPEECH_OPTIONS['max_line_characters']
SPEECH_OPENING_CHARACTERS = DEFAULT_SPEECH_OPTIONS['opening_characters']
SPEECH_TOKENS_PER_SECOND = 12.5  # Codec tokens per second of generated audio.

# Audio conditioning. Levels are RMS over 20 ms frames; "active" frames carry speech rather than room tone.
SPEECH_FRAME_SECONDS = 0.02
SPEECH_ACTIVE_FLOOR_DB = -40.0  # Never treat a frame this far below the loudest one as speech.
SPEECH_ACTIVE_CEILING_DB = -25.0  # Never treat a frame this close to the loudest one as silence.
REFERENCE_HIGH_PASS_HZ = DEFAULT_SPEECH_OPTIONS['reference_high_pass_hz']
REFERENCE_TARGET_RMS_DB = DEFAULT_SPEECH_OPTIONS['reference_target_rms_db']
REFERENCE_GAIN_RANGE_DB = (-DEFAULT_SPEECH_OPTIONS['reference_max_attenuation_db'], DEFAULT_SPEECH_OPTIONS['reference_max_gain_db'])
OUTPUT_HIGH_PASS_HZ = DEFAULT_SPEECH_OPTIONS['output_high_pass_hz']
OUTPUT_TARGET_RMS_DB = DEFAULT_SPEECH_OPTIONS['output_target_rms_db']
OUTPUT_GAIN_RANGE_DB = (-DEFAULT_SPEECH_OPTIONS['output_max_attenuation_db'], DEFAULT_SPEECH_OPTIONS['output_max_gain_db'])
OUTPUT_LEADING_SECONDS = DEFAULT_SPEECH_OPTIONS['output_leading_seconds']
OUTPUT_TRAILING_SECONDS = DEFAULT_SPEECH_OPTIONS['output_trailing_seconds']
OUTPUT_FADE_IN_SECONDS = DEFAULT_SPEECH_OPTIONS['output_fade_in_seconds']
OUTPUT_FADE_OUT_SECONDS = DEFAULT_SPEECH_OPTIONS['output_fade_out_seconds']
OUTPUT_PEAK_CEILING = DEFAULT_SPEECH_OPTIONS['peak_ceiling']

# Sampling: the library defaults, plus two later upstream fixes applied here without changing the pinned
# runtime. The repetition penalty looks only at recent tokens (a whole-history penalty made long segments
# speed up), and the stop token competes in top-k/top-p like every other token instead of being exempt.
SPEECH_SAMPLING = {key: DEFAULT_SPEECH_OPTIONS[key] for key in ('temperature', 'top_k', 'top_p', 'repetition_penalty')}
SPEECH_REPETITION_WINDOW = DEFAULT_SPEECH_OPTIONS['repetition_window']


def install_sampling_fixes(model, repetition_window=SPEECH_REPETITION_WINDOW):
    """Wrap the model's token sampler once; the wrapper is a no-op on a runtime that already has the fixes."""
    original = model._sample_token
    if getattr(original, 'relay_sampling_fixes', False):
        original.relay_repetition_window = repetition_window
        return
    def sample(logits, *args, generated_tokens=None, eos_token_id=None, **kwargs):
        del eos_token_id
        if generated_tokens:
            generated_tokens = generated_tokens[-sample.relay_repetition_window:]
        return original(logits, *args, generated_tokens=generated_tokens, **kwargs)
    sample.relay_sampling_fixes = True
    sample.relay_repetition_window = repetition_window
    model._sample_token = sample


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


def speech_line_units(line, opening=False, options=None):
    options = speech_options(options)
    line_limit = options['max_line_characters']
    # Missing newlines must not merge many sentences into one expensive generation.
    parts = sentence_parts(line) if len(line) > line_limit else [line]
    for part in parts:
        while part:
            maximum = options['opening_characters'] if opening else line_limit
            if len(part) <= maximum:
                yield part
                opening = False
                break
            first_sentence = sentence_parts(part)[0]
            boundary = len(first_sentence) if opening and len(first_sentence) <= maximum else speech_boundary(part, maximum)
            yield part[:boundary].strip()
            part = part[boundary:].strip()
            opening = False


def speech_plan(text, options=None):
    options = speech_options(options)
    lines = speech_lines(text)
    for index, line in enumerate(lines, 1):
        for unit in speech_line_units(line, opening=index == 1, options=options):
            yield index, len(lines), unit


def speech_token_limit(text):
    # Bound even a model that never generates its stop token.
    import math
    return math.ceil(min(24, max(5, len(text) * 0.45 + 3)) * SPEECH_TOKENS_PER_SECOND)


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
        if sum(len(a) for a in arrays) / rate > token_limit / SPEECH_TOKENS_PER_SECOND + 0.5:
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


def frame_levels(audio, sample_rate):
    """RMS of each 20 ms frame and the frame length in samples."""
    import numpy as np
    size = max(1, round(sample_rate * SPEECH_FRAME_SECONDS))
    count = len(audio) // size
    if not count:
        return np.zeros(0, dtype=np.float32), size
    frames = np.asarray(audio[:count * size], dtype=np.float32).reshape(count, size)
    return np.sqrt(np.mean(frames ** 2, axis=1)), size


def active_frames(levels):
    """Frames clearly above the recording's own quiet floor; short inputs count entirely as speech."""
    import numpy as np
    if len(levels) < 5:
        return np.ones(len(levels), dtype=bool)
    quiet, peak = float(np.percentile(levels, 15)), float(levels.max())
    lower = max(peak * 10 ** (SPEECH_ACTIVE_FLOOR_DB / 20), 1e-4)
    upper = max(lower, peak * 10 ** (SPEECH_ACTIVE_CEILING_DB / 20))
    return levels > min(max(quiet * 3, lower), upper)


def high_passed(audio, sample_rate, cutoff):
    """Zero-phase removal of DC offset and rumble below the voice band."""
    import numpy as np
    from scipy.signal import butter, sosfiltfilt
    if cutoff == 0 or len(audio) < 64:
        return np.asarray(audio, dtype=np.float32).copy()
    filtered = sosfiltfilt(butter(2, cutoff, btype='highpass', fs=sample_rate, output='sos'), audio)
    return np.asarray(filtered, dtype=np.float32)


def speech_bounds(audio, sample_rate):
    """Sample range from the first to the last active frame, or None when nothing is active."""
    import numpy as np
    levels, size = frame_levels(audio, sample_rate)
    active = np.flatnonzero(active_frames(levels))
    if not active.size:
        return None
    return int(active[0]) * size, min(len(audio), (int(active[-1]) + 1) * size)


def trimmed_speech(audio, sample_rate, leading, trailing):
    """Cut silence beyond `leading` seconds before and `trailing` seconds after the speech."""
    bounds = speech_bounds(audio, sample_rate)
    if bounds is None:
        return audio
    start = max(0, bounds[0] - round(leading * sample_rate))
    end = min(len(audio), bounds[1] + round(trailing * sample_rate))
    return audio[start:end]


def level_gain(audio, sample_rate, target_db, gain_range_db, ceiling):
    """Linear gain that brings the speech RMS to `target_db` within bounds and under the peak ceiling."""
    import math
    import numpy as np
    levels, _ = frame_levels(audio, sample_rate)
    active = active_frames(levels)
    if not active.any():
        return 1.0
    level = float(np.sqrt(np.mean(levels[active] ** 2)))
    if level <= 0:
        return 1.0
    gain_db = min(max(target_db - 20 * math.log10(level), gain_range_db[0]), gain_range_db[1])
    gain = 10 ** (gain_db / 20)
    peak = float(np.abs(audio).max())
    if peak * gain > ceiling:
        gain = ceiling / peak
    return gain


def faded(audio, sample_rate, fade_in, fade_out):
    import numpy as np
    audio = np.asarray(audio, dtype=np.float32).copy()
    head = min(len(audio), round(fade_in * sample_rate))
    tail = min(len(audio) - head, round(fade_out * sample_rate))
    if head > 1:
        audio[:head] *= np.linspace(0, 1, head, dtype=np.float32)
    if tail > 1:
        audio[len(audio) - tail:] *= np.linspace(1, 0, tail, dtype=np.float32)
    return audio


def prepare_voice_reference(audio, sample_rate, reduce_noise=True, options=None):
    """Condition the registered recording before the voice model learns from it.

    Rumble is removed, optional noise reduction runs on the whole take, and the speech level is
    normalized. The take keeps its full length: cutting the silence around the speech measurably
    lowered speaker similarity with the 0.6B model, so the timing of the recording is left alone and
    the reference transcript remains valid. Nothing is written back to the file.
    """
    import numpy as np
    options = speech_options(options)
    audio = high_passed(np.asarray(audio, dtype=np.float32), sample_rate, options['reference_high_pass_hz'])
    if reduce_noise:
        audio = clean_voice_reference(audio, sample_rate, strength=options['reference_noise_strength'])
    gain = level_gain(audio, sample_rate, options['reference_target_rms_db'],
                      (-options['reference_max_attenuation_db'], options['reference_max_gain_db']), options['peak_ceiling'])
    audio = np.asarray(audio * gain, dtype=np.float32)
    if not len(audio) or not np.isfinite(audio).all():
        raise WorkerRequestError("参照音声の調整に失敗しました。参照録音を確認してください。")
    return audio


def finished_speech(audio, sample_rate, options=None):
    """Even out one generated segment before playback.

    Removes rumble, shortens leading silence, ends the segment with a fixed short pause, normalizes the
    speech level toward a common target and fades the edges so consecutive segments join without clicks.
    Segments shorter than a few frames are returned unchanged.
    """
    import numpy as np
    options = speech_options(options)
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if len(audio) < 5 * max(1, round(sample_rate * SPEECH_FRAME_SECONDS)):
        return audio
    audio = high_passed(audio, sample_rate, options['output_high_pass_hz'])
    audio = trimmed_speech(audio, sample_rate, options['output_leading_seconds'], options['output_trailing_seconds'])
    gain = level_gain(audio, sample_rate, options['output_target_rms_db'],
                      (-options['output_max_attenuation_db'], options['output_max_gain_db']), options['peak_ceiling'])
    audio = faded(audio * gain, sample_rate, options['output_fade_in_seconds'], options['output_fade_out_seconds'])
    bounds = speech_bounds(audio, sample_rate)
    pause = round(options['output_trailing_seconds'] * sample_rate)
    if bounds is not None and len(audio) - bounds[1] < pause:
        audio = np.concatenate([audio, np.zeros(pause - (len(audio) - bounds[1]), dtype=np.float32)])
    if not np.isfinite(audio).all():
        raise WorkerRequestError("音声生成結果が不正です。")
    return audio


def clean_voice_reference(audio, sample_rate, strength=0.65):
    """Reduce quiet, stationary background before the voice model learns it."""
    import numpy as np
    import noisereduce as nr
    audio = np.asarray(audio, dtype=np.float32)
    if strength == 0:
        return audio.copy()
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
                              prop_decrease=strength, n_fft=1024, hop_length=256)
    cleaned = np.asarray(cleaned, dtype=np.float32)
    if cleaned.shape != audio.shape or not np.isfinite(cleaned).all():
        raise WorkerRequestError("参照音声のノイズ処理に失敗しました。参照録音を確認してください。")
    return cleaned
