"""Validated Qwen controls shared by warmup and playback. Defaults preserve the existing sound."""
import math
from relay_common import WorkerRequestError

# name: (default, minimum, maximum, integer). Keep aligned with RelayCore/SpeechSettings.swift.
SPEECH_OPTION_SPECS = {
    'temperature': (0.9, 0.1, 1.5, False),
    'top_k': (50, 1, 200, True),
    'top_p': (1, 0.1, 1, False),
    'repetition_penalty': (1.05, 1, 2, False),
    'repetition_window': (64, 1, 512, True),
    'streaming_interval': (0.8, 0.2, 2, False),
    'opening_characters': (32, 8, 160, True),
    'max_line_characters': (160, 32, 300, True),
    'output_leading_seconds': (0.08, 0, 0.5, False),
    'output_trailing_seconds': (0.3, 0, 2, False),
    'reference_noise_strength': (0.65, 0, 1, False),
    'reference_high_pass_hz': (60, 0, 300, False),
    'reference_target_rms_db': (-20, -30, -10, False),
    'reference_max_attenuation_db': (12, 0, 24, False),
    'reference_max_gain_db': (18, 0, 24, False),
    'output_high_pass_hz': (50, 0, 300, False),
    'output_target_rms_db': (-18, -30, -10, False),
    'output_max_attenuation_db': (8, 0, 24, False),
    'output_max_gain_db': (8, 0, 24, False),
    'output_fade_in_seconds': (0.005, 0, 0.1, False),
    'output_fade_out_seconds': (0.02, 0, 0.2, False),
    'peak_ceiling': (0.95, 0.1, 1, False),
}

def speech_options(value=None):
    if value is None:
        value = {}
    if not isinstance(value, dict) or set(value) - SPEECH_OPTION_SPECS.keys():
        raise WorkerRequestError("Invalid speech quality settings.")
    result = {}
    for key, (default, lower, upper, integer) in SPEECH_OPTION_SPECS.items():
        item = value.get(key, default)
        if (isinstance(item, bool) or not isinstance(item, (int, float))
                or not math.isfinite(item) or not lower <= item <= upper
                or (integer and int(item) != item)):
            raise WorkerRequestError(f"Invalid speech quality setting: {key} ({lower}–{upper}).")
        result[key] = int(item) if integer else float(item)
    if result['opening_characters'] > result['max_line_characters']:
        raise WorkerRequestError("Opening character limit must not exceed the segment character limit.")
    return result
