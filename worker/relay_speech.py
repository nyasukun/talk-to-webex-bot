"""Speech text planning, generated-audio checks and reference-audio cleanup for the voice model."""
from functools import lru_cache
import sys

from relay_common import WorkerRequestError


SPEECH_MAX_LINE_CHARACTERS = 160
SPEECH_OPENING_CHARACTERS = 32
SPEECH_TOKENS_PER_SECOND = 12.5  # Codec tokens per second of generated audio.


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
