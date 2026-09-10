"""Transcription confidence and speaker decisions for recognized audio."""


ASR_SAMPLE_RATE = 16000
SPEAKER_MIN_SAMPLES = 25600


def usable_segments(segments):
    return [s for s in segments if float(s.get("no_speech_prob", 1)) < 0.55
            and float(s.get("avg_logprob", -100)) >= -1.0
            and float(s.get("compression_ratio", 100)) < 2.4]


def speaker_window_ranges(sample_count):
    minimum, maximum, step = SPEAKER_MIN_SAMPLES, 48000, 24000
    if sample_count < minimum:
        return []
    if sample_count <= maximum:
        return [(0, sample_count)]
    starts = list(range(0, sample_count - maximum + 1, step))
    tail = sample_count - maximum
    if starts[-1] != tail:
        starts.append(tail)
    return [(start, start + maximum) for start in starts]


def voiced_sample_count(spans):
    return sum(s["end"] - s["start"] for s in spans)


def voiced_audio(audio, spans):
    """Join the voiced spans only; an empty span list raises like np.concatenate does."""
    import numpy as np
    return np.concatenate([audio[s["start"]:s["end"]] for s in spans])


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


def speech_turn_spans(spans, gap=7200):
    """Group voiced spans into turns; a pause shorter than gap keeps the next span in the same turn."""
    groups = []
    for span in spans:
        if groups and span["start"] - groups[-1][-1]["end"] < gap:
            groups[-1].append(span)
        else:
            groups.append([span])
    return groups
