#!/usr/bin/env python3
"""Compare a selected real-audio target against generated probe WAVs."""

import argparse
import json
import math
import sys
import wave
from array import array
from pathlib import Path


LOG_BIN_COUNT = 48
LOG_BIN_MIN_HZ = 70.0
LOG_BIN_MAX_HZ = 12000.0
EPSILON = 1.0e-12


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Score generated audio against a selected reference target. "
            "The comparison is audio-to-audio: onset alignment, envelope, "
            "decay, loudness, pitch, and multi-resolution spectral shape."
        )
    )
    parser.add_argument("--target", required=True, help="selected reference target WAV")
    parser.add_argument(
        "--generated",
        action="append",
        nargs="+",
        required=True,
        help="generated WAV to compare; accepts one or more paths and may be repeated",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="optional JSON report path",
    )
    parser.add_argument(
        "--pre-roll",
        type=float,
        default=0.005,
        help="seconds before detected onset to include in comparison",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="optional comparison duration in seconds; default uses remaining target length",
    )
    parser.add_argument(
        "--onset-frame-ms",
        type=float,
        default=2.0,
        help="RMS frame size used for onset detection",
    )
    parser.add_argument(
        "--envelope-frame-ms",
        type=float,
        default=2.0,
        help="RMS frame size used for envelope comparison",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print the full JSON report instead of the text table",
    )
    return parser.parse_args()


def relative_path(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def read_pcm16_wav(path):
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        frames = wav.readframes(params.nframes)

    if params.comptype != "NONE":
        raise ValueError(f"compressed WAV is not supported: {params.comptype}")
    if params.sampwidth != 2:
        raise ValueError(
            f"expected PCM16 WAV, got sample width {params.sampwidth} bytes"
        )
    if params.nchannels <= 0:
        raise ValueError(f"invalid channel count: {params.nchannels}")

    samples = array("h")
    samples.frombytes(frames)
    if sys.byteorder != "little":
        samples.byteswap()

    mono = []
    channels = params.nchannels
    scale = 32768.0 * channels
    for index in range(0, len(samples), channels):
        total = 0
        for channel in range(channels):
            total += samples[index + channel]
        mono.append(total / scale)

    remove_dc(mono)
    return {
        "path": path,
        "sample_rate": params.framerate,
        "channels": params.nchannels,
        "sample_width_bytes": params.sampwidth,
        "duration_seconds": len(mono) / params.framerate,
        "samples": mono,
    }


def remove_dc(samples):
    if not samples:
        return
    offset = sum(samples) / len(samples)
    for index, sample in enumerate(samples):
        samples[index] = sample - offset


def rms(samples):
    if not samples:
        return 0.0
    total = 0.0
    for sample in samples:
        total += sample * sample
    return math.sqrt(total / len(samples))


def peak_abs(samples):
    if not samples:
        return 0.0
    return max(abs(sample) for sample in samples)


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(round((len(ordered) - 1) * pct))
    return ordered[max(0, min(len(ordered) - 1, index))]


def mean(values):
    if not values:
        return 0.0
    return sum(values) / len(values)


def frame_rms_curve(samples, frame_samples):
    if frame_samples <= 0:
        raise ValueError("frame_samples must be positive")

    values = []
    for start in range(0, len(samples), frame_samples):
        frame = samples[start : start + frame_samples]
        values.append(rms(frame))
    return values


def detect_onset(samples, sample_rate, frame_ms):
    frame_samples = max(1, int(round(sample_rate * frame_ms / 1000.0)))
    curve = frame_rms_curve(samples, frame_samples)
    if not curve:
        return 0

    peak = max(curve)
    if peak <= 0.0:
        return 0

    if curve[0] >= max(peak * 0.02, 0.00012):
        return 0

    early_count = max(1, min(len(curve), int(round(0.05 * sample_rate / frame_samples))))
    early_floor = percentile(curve[:early_count], 0.70)
    threshold = max(peak * 0.02, early_floor * 3.5, 0.00012)
    background_frames = max(1, int(round(0.018 * sample_rate / frame_samples)))

    for index, value in enumerate(curve):
        if value < threshold:
            continue
        start = max(0, index - background_frames)
        background = mean(curve[start:index]) if index > start else early_floor
        if index == 0 or value >= background * 1.35 or value >= curve[index - 1] * 1.05:
            return index * frame_samples

    peak_index = max(range(len(curve)), key=lambda item: curve[item])
    return peak_index * frame_samples


def aligned_segments(target, generated, args):
    if target["sample_rate"] != generated["sample_rate"]:
        raise ValueError(
            "sample rates differ: "
            f"{target['sample_rate']} target vs {generated['sample_rate']} generated"
        )

    sample_rate = target["sample_rate"]
    pre_roll_samples = max(0, int(round(args.pre_roll * sample_rate)))
    target_onset = detect_onset(target["samples"], sample_rate, args.onset_frame_ms)
    generated_onset = detect_onset(
        generated["samples"], sample_rate, args.onset_frame_ms
    )
    target_start = max(0, target_onset - pre_roll_samples)
    generated_start = max(0, generated_onset - pre_roll_samples)

    if args.duration > 0:
        requested = int(round(args.duration * sample_rate))
    else:
        requested = len(target["samples"]) - target_start

    available = min(
        requested,
        len(target["samples"]) - target_start,
        len(generated["samples"]) - generated_start,
    )
    if available < max(64, int(round(sample_rate * 0.01))):
        raise ValueError(
            "aligned comparison region is too short "
            f"({available / sample_rate:.6f} seconds)"
        )

    return {
        "target": target["samples"][target_start : target_start + available],
        "generated": generated["samples"][
            generated_start : generated_start + available
        ],
        "sample_rate": sample_rate,
        "target_onset_seconds": target_onset / sample_rate,
        "generated_onset_seconds": generated_onset / sample_rate,
        "target_start_seconds": target_start / sample_rate,
        "generated_start_seconds": generated_start / sample_rate,
        "duration_seconds": available / sample_rate,
    }


def normalized(samples):
    value = rms(samples)
    if value <= EPSILON:
        return list(samples)
    scale = 1.0 / value
    return [sample * scale for sample in samples]


def envelope_summary(samples, sample_rate, frame_ms):
    frame_samples = max(1, int(round(sample_rate * frame_ms / 1000.0)))
    curve = frame_rms_curve(samples, frame_samples)
    if not curve:
        return {
            "curve": [],
            "peak_index": 0,
            "attack_seconds": 0.0,
            "half_decay_seconds": 0.0,
            "quarter_decay_seconds": 0.0,
        }

    peak = max(curve)
    if peak <= EPSILON:
        return {
            "curve": [0.0 for _ in curve],
            "peak_index": 0,
            "attack_seconds": 0.0,
            "half_decay_seconds": 0.0,
            "quarter_decay_seconds": 0.0,
        }

    norm_curve = [value / peak for value in curve]
    peak_index = max(range(len(curve)), key=lambda item: curve[item])
    frame_seconds = frame_samples / sample_rate
    half_decay = first_decay_time(norm_curve, peak_index, 0.5, frame_seconds)
    quarter_decay = first_decay_time(norm_curve, peak_index, 0.25, frame_seconds)

    return {
        "curve": norm_curve,
        "peak_index": peak_index,
        "attack_seconds": peak_index * frame_seconds,
        "half_decay_seconds": half_decay,
        "quarter_decay_seconds": quarter_decay,
    }


def first_decay_time(curve, peak_index, threshold, frame_seconds):
    for index in range(peak_index + 1, len(curve)):
        if curve[index] <= threshold:
            return (index - peak_index) * frame_seconds
    return max(0.0, (len(curve) - peak_index - 1) * frame_seconds)


def envelope_distance(target_curve, generated_curve):
    count = min(len(target_curve), len(generated_curve))
    if count == 0:
        return 1.0

    total = 0.0
    for index in range(count):
        target_db = normalized_db(target_curve[index])
        generated_db = normalized_db(generated_curve[index])
        total += abs(target_db - generated_db) / 60.0
    return clamp01(total / count)


def normalized_db(value):
    return max(-60.0, 20.0 * math.log10(max(value, EPSILON)))


def log_bins():
    ratio = LOG_BIN_MAX_HZ / LOG_BIN_MIN_HZ
    return [
        LOG_BIN_MIN_HZ * math.pow(ratio, index / (LOG_BIN_COUNT - 1))
        for index in range(LOG_BIN_COUNT)
    ]


def hann_window(size):
    if size <= 1:
        return [1.0]
    return [
        0.5 - 0.5 * math.cos(2.0 * math.pi * index / (size - 1))
        for index in range(size)
    ]


def spectral_profile(samples, sample_rate, frame_size, freqs):
    hop = max(1, frame_size // 2)
    window = hann_window(frame_size)
    coeffs = [2.0 * math.cos(2.0 * math.pi * freq / sample_rate) for freq in freqs]
    profile = [0.0 for _ in freqs]
    linear = [0.0 for _ in freqs]
    frame_count = 0

    if len(samples) <= frame_size:
        starts = [0]
    else:
        starts = list(range(0, len(samples) - frame_size + 1, hop))
        if starts[-1] != len(samples) - frame_size:
            starts.append(len(samples) - frame_size)

    for start in starts:
        frame = padded_windowed_frame(samples, start, frame_size, window)
        powers = [goertzel_power(frame, coeff) for coeff in coeffs]
        total_power = sum(powers) + EPSILON

        for index, power in enumerate(powers):
            normalized_power = power / total_power
            profile[index] += math.log10(normalized_power + EPSILON)
            linear[index] += power
        frame_count += 1

    if frame_count == 0:
        frame_count = 1

    profile = [value / frame_count for value in profile]
    linear = [value / frame_count for value in linear]
    profile_mean = mean(profile)
    centered = [value - profile_mean for value in profile]
    centroid = spectral_centroid(freqs, linear)
    rolloff = spectral_rolloff(freqs, linear, 0.85)
    tilt = spectral_tilt_db_per_octave(freqs, linear)

    return {
        "profile": centered,
        "linear_powers": linear,
        "centroid_hz": centroid,
        "rolloff_hz": rolloff,
        "tilt_db_per_octave": tilt,
    }


def padded_windowed_frame(samples, start, frame_size, window):
    frame = [0.0 for _ in range(frame_size)]
    available = max(0, min(frame_size, len(samples) - start))
    for index in range(available):
        frame[index] = samples[start + index] * window[index]
    return frame


def goertzel_power(frame, coeff):
    q1 = 0.0
    q2 = 0.0
    for sample in frame:
        q0 = sample + coeff * q1 - q2
        q2 = q1
        q1 = q0
    return max(0.0, q1 * q1 + q2 * q2 - coeff * q1 * q2)


def spectral_centroid(freqs, powers):
    total = sum(powers)
    if total <= EPSILON:
        return 0.0
    weighted = 0.0
    for freq, power in zip(freqs, powers):
        weighted += freq * power
    return weighted / total


def spectral_rolloff(freqs, powers, ratio):
    total = sum(powers)
    if total <= EPSILON:
        return 0.0
    threshold = total * ratio
    running = 0.0
    for freq, power in zip(freqs, powers):
        running += power
        if running >= threshold:
            return freq
    return freqs[-1]


def spectral_tilt_db_per_octave(freqs, powers):
    x_values = []
    y_values = []
    for freq, power in zip(freqs, powers):
        if power <= EPSILON:
            continue
        x_values.append(math.log(freq / 1000.0, 2.0))
        y_values.append(10.0 * math.log10(power + EPSILON))

    if len(x_values) < 2:
        return 0.0

    x_mean = mean(x_values)
    y_mean = mean(y_values)
    numerator = 0.0
    denominator = 0.0
    for x_value, y_value in zip(x_values, y_values):
        dx = x_value - x_mean
        numerator += dx * (y_value - y_mean)
        denominator += dx * dx
    if denominator <= EPSILON:
        return 0.0
    return numerator / denominator


def profile_distance(target_profile, generated_profile):
    count = min(len(target_profile), len(generated_profile))
    if count == 0:
        return 1.0

    total = 0.0
    for index in range(count):
        diff = target_profile[index] - generated_profile[index]
        total += diff * diff
    rms_diff = math.sqrt(total / count)
    return clamp01(rms_diff / 4.5)


def multi_resolution_spectral_distance(target, generated, sample_rate):
    freqs = log_bins()
    frame_sizes = [512, 2048, 4096]
    distances = []
    profiles = []

    for frame_size in frame_sizes:
        target_profile = spectral_profile(target, sample_rate, frame_size, freqs)
        generated_profile = spectral_profile(generated, sample_rate, frame_size, freqs)
        distance = profile_distance(
            target_profile["profile"], generated_profile["profile"]
        )
        distances.append(distance)
        profiles.append((frame_size, target_profile, generated_profile, distance))

    return {
        "loss": clamp01(mean(distances)),
        "profiles": profiles,
    }


def samples_for_window(samples, sample_rate, start_seconds, duration_seconds):
    start = max(0, int(round(start_seconds * sample_rate)))
    end = min(len(samples), start + max(1, int(round(duration_seconds * sample_rate))))
    return samples[start:end]


def spectral_window_stats(samples, sample_rate, start_seconds, duration_seconds):
    freqs = log_bins()
    window_samples = samples_for_window(
        samples, sample_rate, start_seconds, duration_seconds
    )
    profile = spectral_profile(window_samples, sample_rate, 2048, freqs)
    powers = profile["linear_powers"]
    total = sum(powers) + EPSILON
    normalized_powers = [power / total for power in powers]
    flatness = spectral_flatness(normalized_powers)
    entropy = spectral_entropy(normalized_powers)

    return {
        "flatness": flatness,
        "entropy": entropy,
        "peak_ratio": max(normalized_powers) if normalized_powers else 0.0,
        "low_ratio": band_power_ratio(freqs, normalized_powers, 0.0, 250.0),
        "mid_ratio": band_power_ratio(freqs, normalized_powers, 250.0, 1500.0),
        "upper_mid_ratio": band_power_ratio(
            freqs, normalized_powers, 500.0, 2500.0
        ),
        "high_ratio": band_power_ratio(freqs, normalized_powers, 1000.0, 12000.0),
        "centroid_hz": profile["centroid_hz"],
        "tilt_db_per_octave": profile["tilt_db_per_octave"],
    }


def band_power_ratio(freqs, powers, low_hz, high_hz):
    total = sum(powers) + EPSILON
    band = 0.0
    for freq, power in zip(freqs, powers):
        if freq < low_hz or freq >= high_hz:
            continue
        band += power
    return band / total


def spectral_flatness(normalized_powers):
    if not normalized_powers:
        return 0.0
    geometric = math.exp(
        sum(math.log(power + EPSILON) for power in normalized_powers)
        / len(normalized_powers)
    )
    arithmetic = mean(normalized_powers)
    if arithmetic <= EPSILON:
        return 0.0
    return geometric / arithmetic


def spectral_entropy(normalized_powers):
    if not normalized_powers:
        return 0.0
    entropy = 0.0
    for power in normalized_powers:
        entropy -= power * math.log(power + EPSILON)
    return entropy / math.log(len(normalized_powers))


def spectral_flux(samples, sample_rate, start_seconds, duration_seconds):
    freqs = log_bins()
    frame_size = 1024
    hop = 256
    window = hann_window(frame_size)
    coeffs = [2.0 * math.cos(2.0 * math.pi * freq / sample_rate) for freq in freqs]
    window_samples = samples_for_window(
        samples, sample_rate, start_seconds, duration_seconds
    )

    if len(window_samples) <= frame_size:
        starts = [0]
    else:
        starts = list(range(0, len(window_samples) - frame_size + 1, hop))
        if starts[-1] != len(window_samples) - frame_size:
            starts.append(len(window_samples) - frame_size)

    previous = None
    values = []
    for start in starts:
        frame = padded_windowed_frame(window_samples, start, frame_size, window)
        powers = [goertzel_power(frame, coeff) for coeff in coeffs]
        total_power = sum(powers) + EPSILON
        profile = [math.log10(power / total_power + EPSILON) for power in powers]
        profile_mean = mean(profile)
        centered = [value - profile_mean for value in profile]
        if previous is not None:
            diff = 0.0
            for current_value, previous_value in zip(centered, previous):
                step = current_value - previous_value
                diff += step * step
            values.append(math.sqrt(diff / len(centered)))
        previous = centered

    return mean(values)


def pluck_features(samples, sample_rate):
    attack_pitch = dominant_frequency(
        samples_for_window(samples, sample_rate, 0.0, 0.045), sample_rate
    )
    sustain_pitch = dominant_frequency(
        samples_for_window(samples, sample_rate, 0.045, 0.140), sample_rate
    )
    dominant_motion = dominant_frequency_motion(
        attack_pitch["frequency_hz"], sustain_pitch["frequency_hz"]
    )

    return {
        "attack": spectral_window_stats(samples, sample_rate, 0.0, 0.035),
        "sustain": spectral_window_stats(samples, sample_rate, 0.045, 0.140),
        "attack_flux": spectral_flux(samples, sample_rate, 0.0, 0.045),
        "sustain_flux": spectral_flux(samples, sample_rate, 0.045, 0.140),
        "attack_pitch": attack_pitch,
        "sustain_pitch": sustain_pitch,
        "dominant_motion_octaves": dominant_motion,
    }


def dominant_frequency_motion(attack_frequency, sustain_frequency):
    if attack_frequency <= EPSILON or sustain_frequency <= EPSILON:
        return 0.0
    return abs(math.log(sustain_frequency / attack_frequency, 2.0))


def transient_loss(target_features, generated_features):
    target_attack = target_features["attack"]
    generated_attack = generated_features["attack"]
    mid_loss = ratio_loss(
        target_attack["mid_ratio"], generated_attack["mid_ratio"], 2.0
    )
    upper_mid_loss = ratio_loss(
        target_attack["upper_mid_ratio"],
        generated_attack["upper_mid_ratio"],
        2.5,
    )
    high_loss = ratio_loss(
        target_attack["high_ratio"], generated_attack["high_ratio"], 3.0
    )
    flux_loss = ratio_loss(
        target_features["attack_flux"], generated_features["attack_flux"], 1.4
    )
    return clamp01(
        mid_loss * 0.36
        + upper_mid_loss * 0.20
        + high_loss * 0.18
        + flux_loss * 0.26
    )


def texture_loss(target_features, generated_features):
    attack_flux_loss = ratio_loss(
        target_features["attack_flux"], generated_features["attack_flux"], 1.5
    )
    sustain_flux_loss = ratio_loss(
        target_features["sustain_flux"], generated_features["sustain_flux"], 1.2
    )
    entropy_loss = abs(
        target_features["sustain"]["entropy"]
        - generated_features["sustain"]["entropy"]
    )
    return clamp01(
        sustain_flux_loss * 0.58 + attack_flux_loss * 0.28 + entropy_loss * 0.14
    )


def oscillator_loss(target_features, generated_features):
    target_motion = target_features["dominant_motion_octaves"]
    generated_motion = generated_features["dominant_motion_octaves"]
    if target_motion <= EPSILON:
        motion_loss = 0.0
    else:
        motion_loss = clamp01(max(0.0, target_motion - generated_motion) / target_motion)

    target_confidence = target_features["sustain_pitch"]["confidence"]
    generated_confidence = generated_features["sustain_pitch"]["confidence"]
    confidence_overshoot = clamp01(
        max(0.0, generated_confidence - target_confidence) / 0.18
    )
    generated_peak = generated_features["sustain"]["peak_ratio"]
    target_peak = target_features["sustain"]["peak_ratio"]
    peak_overshoot = clamp01(max(0.0, generated_peak - target_peak) / 0.25)

    return clamp01(
        motion_loss * 0.70
        + confidence_overshoot * 0.20
        + peak_overshoot * 0.10
    )


def rounded_pluck_features(features):
    return {
        "attack_flux": round(features["attack_flux"], 6),
        "sustain_flux": round(features["sustain_flux"], 6),
        "dominant_motion_octaves": round(features["dominant_motion_octaves"], 6),
        "attack_mid_ratio": round(features["attack"]["mid_ratio"], 6),
        "attack_upper_mid_ratio": round(features["attack"]["upper_mid_ratio"], 6),
        "attack_high_ratio": round(features["attack"]["high_ratio"], 6),
        "sustain_entropy": round(features["sustain"]["entropy"], 6),
        "sustain_peak_ratio": round(features["sustain"]["peak_ratio"], 6),
        "attack_dominant_frequency_hz": round(
            features["attack_pitch"]["frequency_hz"], 4
        ),
        "attack_dominant_frequency_confidence": round(
            features["attack_pitch"]["confidence"], 4
        ),
        "sustain_dominant_frequency_hz": round(
            features["sustain_pitch"]["frequency_hz"], 4
        ),
        "sustain_dominant_frequency_confidence": round(
            features["sustain_pitch"]["confidence"], 4
        ),
    }


def dominant_frequency(samples, sample_rate):
    if not samples:
        return {"frequency_hz": 0.0, "confidence": 0.0}

    analysis_samples = samples[: min(len(samples), int(round(sample_rate * 0.22)))]
    if len(analysis_samples) < int(sample_rate / 70.0):
        return {"frequency_hz": 0.0, "confidence": 0.0}

    work = list(analysis_samples)
    remove_dc(work)
    signal_energy = sum(sample * sample for sample in work)
    if signal_energy <= EPSILON:
        return {"frequency_hz": 0.0, "confidence": 0.0}

    min_lag = max(1, int(sample_rate / 800.0))
    max_lag = min(len(work) - 2, int(sample_rate / 70.0))
    if max_lag <= min_lag:
        return {"frequency_hz": 0.0, "confidence": 0.0}

    best_lag = min_lag
    best_score = -1.0
    for lag in range(min_lag, max_lag + 1):
        corr = 0.0
        energy_a = 0.0
        energy_b = 0.0
        for index in range(0, len(work) - lag):
            a = work[index]
            b = work[index + lag]
            corr += a * b
            energy_a += a * a
            energy_b += b * b
        denom = math.sqrt(energy_a * energy_b) + EPSILON
        score = corr / denom
        if score > best_score:
            best_score = score
            best_lag = lag

    return {
        "frequency_hz": sample_rate / best_lag,
        "confidence": clamp01(best_score),
    }


def compare_pair(target, generated, args):
    segments = aligned_segments(target, generated, args)
    sample_rate = segments["sample_rate"]
    target_raw = segments["target"]
    generated_raw = segments["generated"]
    target_norm = normalized(target_raw)
    generated_norm = normalized(generated_raw)

    target_env = envelope_summary(target_norm, sample_rate, args.envelope_frame_ms)
    generated_env = envelope_summary(
        generated_norm, sample_rate, args.envelope_frame_ms
    )
    env_loss = envelope_distance(target_env["curve"], generated_env["curve"])
    attack_loss = clamp01(
        abs(target_env["attack_seconds"] - generated_env["attack_seconds"]) / 0.035
    )
    half_decay_loss = clamp01(
        abs(target_env["half_decay_seconds"] - generated_env["half_decay_seconds"])
        / max(0.050, segments["duration_seconds"])
    )
    quarter_decay_loss = clamp01(
        abs(
            target_env["quarter_decay_seconds"]
            - generated_env["quarter_decay_seconds"]
        )
        / max(0.070, segments["duration_seconds"])
    )
    decay_loss = clamp01(half_decay_loss * 0.55 + quarter_decay_loss * 0.45)

    spectral = multi_resolution_spectral_distance(
        target_norm, generated_norm, sample_rate
    )
    spectral_loss = spectral["loss"]
    target_profile = spectral["profiles"][1][1]
    generated_profile = spectral["profiles"][1][2]
    target_pluck = pluck_features(target_norm, sample_rate)
    generated_pluck = pluck_features(generated_norm, sample_rate)
    pluck_transient_loss = transient_loss(target_pluck, generated_pluck)
    sustain_texture_loss = texture_loss(target_pluck, generated_pluck)
    stable_oscillator_loss = oscillator_loss(target_pluck, generated_pluck)

    centroid_loss = ratio_loss(
        target_profile["centroid_hz"], generated_profile["centroid_hz"], 2.0
    )
    rolloff_loss = ratio_loss(
        target_profile["rolloff_hz"], generated_profile["rolloff_hz"], 2.2
    )
    tilt_loss = clamp01(
        abs(
            target_profile["tilt_db_per_octave"]
            - generated_profile["tilt_db_per_octave"]
        )
        / 18.0
    )

    target_pitch = dominant_frequency(target_norm, sample_rate)
    generated_pitch = dominant_frequency(generated_norm, sample_rate)
    pitch_weight = min(target_pitch["confidence"], generated_pitch["confidence"])
    pitch_loss = ratio_loss(
        target_pitch["frequency_hz"], generated_pitch["frequency_hz"], 1.0
    )
    pitch_loss *= pitch_weight

    target_rms = rms(target_raw)
    generated_rms = rms(generated_raw)
    loudness_db = 20.0 * math.log10((generated_rms + EPSILON) / (target_rms + EPSILON))
    loudness_loss = clamp01(abs(loudness_db) / 18.0)

    total_loss = (
        spectral_loss * 0.16
        + env_loss * 0.12
        + pluck_transient_loss * 0.14
        + attack_loss * 0.04
        + decay_loss * 0.08
        + sustain_texture_loss * 0.20
        + stable_oscillator_loss * 0.14
        + centroid_loss * 0.03
        + rolloff_loss * 0.02
        + tilt_loss * 0.02
        + pitch_loss * 0.01
        + loudness_loss * 0.04
    )
    similarity_score = max(0.0, 100.0 * (1.0 - clamp01(total_loss)))

    return {
        "generated": relative_path(generated["path"]),
        "score": round(similarity_score, 4),
        "loss": round(total_loss, 6),
        "component_losses": {
            "multi_spectral": round(spectral_loss, 6),
            "envelope": round(env_loss, 6),
            "pluck_transient": round(pluck_transient_loss, 6),
            "attack": round(attack_loss, 6),
            "decay": round(decay_loss, 6),
            "sustain_texture": round(sustain_texture_loss, 6),
            "stable_oscillator": round(stable_oscillator_loss, 6),
            "centroid": round(centroid_loss, 6),
            "rolloff": round(rolloff_loss, 6),
            "tilt": round(tilt_loss, 6),
            "pitch": round(pitch_loss, 6),
            "loudness": round(loudness_loss, 6),
        },
        "alignment": {
            "target_onset_seconds": round(segments["target_onset_seconds"], 6),
            "generated_onset_seconds": round(
                segments["generated_onset_seconds"], 6
            ),
            "target_start_seconds": round(segments["target_start_seconds"], 6),
            "generated_start_seconds": round(
                segments["generated_start_seconds"], 6
            ),
            "duration_seconds": round(segments["duration_seconds"], 6),
        },
        "target": {
            "rms": round(target_rms, 8),
            "peak": round(peak_abs(target_raw), 8),
            "attack_seconds": round(target_env["attack_seconds"], 6),
            "half_decay_seconds": round(target_env["half_decay_seconds"], 6),
            "quarter_decay_seconds": round(target_env["quarter_decay_seconds"], 6),
            "centroid_hz": round(target_profile["centroid_hz"], 4),
            "rolloff_hz": round(target_profile["rolloff_hz"], 4),
            "tilt_db_per_octave": round(target_profile["tilt_db_per_octave"], 4),
            "dominant_frequency_hz": round(target_pitch["frequency_hz"], 4),
            "dominant_frequency_confidence": round(target_pitch["confidence"], 4),
            "pluck_features": rounded_pluck_features(target_pluck),
        },
        "generated_stats": {
            "rms": round(generated_rms, 8),
            "peak": round(peak_abs(generated_raw), 8),
            "loudness_db_vs_target": round(loudness_db, 4),
            "attack_seconds": round(generated_env["attack_seconds"], 6),
            "half_decay_seconds": round(generated_env["half_decay_seconds"], 6),
            "quarter_decay_seconds": round(
                generated_env["quarter_decay_seconds"], 6
            ),
            "centroid_hz": round(generated_profile["centroid_hz"], 4),
            "rolloff_hz": round(generated_profile["rolloff_hz"], 4),
            "tilt_db_per_octave": round(
                generated_profile["tilt_db_per_octave"], 4
            ),
            "dominant_frequency_hz": round(generated_pitch["frequency_hz"], 4),
            "dominant_frequency_confidence": round(
                generated_pitch["confidence"], 4
            ),
            "pluck_features": rounded_pluck_features(generated_pluck),
        },
        "spectral_resolutions": [
            {
                "frame_size": frame_size,
                "loss": round(distance, 6),
            }
            for frame_size, _, _, distance in spectral["profiles"]
        ],
    }


def ratio_loss(reference, candidate, octave_span):
    if reference <= EPSILON or candidate <= EPSILON:
        return 1.0
    return clamp01(abs(math.log(candidate / reference, 2.0)) / octave_span)


def clamp01(value):
    return max(0.0, min(1.0, value))


def write_report(path, report):
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def print_text_report(report):
    print(f"target: {report['target']['path']}")
    print(
        "comparison: score is higher-better, loss is lower-better; "
        "ranking is by score"
    )
    print()
    print(f"{'rank':>4}  {'score':>8}  {'loss':>8}  {'generated'}")
    for index, result in enumerate(report["results"], start=1):
        print(
            f"{index:>4}  {result['score']:>8.3f}  "
            f"{result['loss']:>8.5f}  {result['generated']}"
        )

    print()
    for result in report["results"]:
        losses = result["component_losses"]
        generated = result["generated_stats"]
        alignment = result["alignment"]
        print(result["generated"])
        print(
            "  "
            f"aligned={alignment['duration_seconds']:.3f}s "
            f"target_onset={alignment['target_onset_seconds']:.4f}s "
            f"generated_onset={alignment['generated_onset_seconds']:.4f}s"
        )
        print(
            "  losses "
            f"spectral={losses['multi_spectral']:.3f} "
            f"env={losses['envelope']:.3f} "
            f"pluck={losses['pluck_transient']:.3f} "
            f"attack={losses['attack']:.3f} "
            f"decay={losses['decay']:.3f} "
            f"texture={losses['sustain_texture']:.3f} "
            f"osc={losses['stable_oscillator']:.3f} "
            f"centroid={losses['centroid']:.3f} "
            f"tilt={losses['tilt']:.3f} "
            f"pitch={losses['pitch']:.3f} "
            f"loudness={losses['loudness']:.3f}"
        )
        pluck = generated["pluck_features"]
        print(
            "  generated "
            f"rms={generated['rms']:.5f} "
            f"peak={generated['peak']:.5f} "
            f"loudness_db={generated['loudness_db_vs_target']:.2f} "
            f"centroid={generated['centroid_hz']:.1f}Hz "
            f"pitch={generated['dominant_frequency_hz']:.1f}Hz "
            f"motion={pluck['dominant_motion_octaves']:.3f}oct "
            f"flux={pluck['sustain_flux']:.3f}"
        )


def main():
    args = parse_args()
    target_path = Path(args.target)
    if not target_path.is_file():
        print(f"error: target WAV not found: {target_path}", file=sys.stderr)
        return 2

    generated_paths = [Path(path) for group in args.generated for path in group]
    for path in generated_paths:
        if not path.is_file():
            print(f"error: generated WAV not found: {path}", file=sys.stderr)
            return 2

    try:
        target = read_pcm16_wav(target_path)
        generated_audio = [read_pcm16_wav(path) for path in generated_paths]
        results = [compare_pair(target, generated, args) for generated in generated_audio]
    except (OSError, ValueError, wave.Error) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    results.sort(key=lambda item: item["score"], reverse=True)
    report = {
        "meta": {
            "version": 2,
            "purpose": (
                "Direct audio comparison between selected real-audio target "
                "and generated probe WAVs."
            ),
            "scoring_note": (
                "Score is higher-better. Losses are lower-better. "
                "The pluck transient, sustain texture, and stable oscillator "
                "losses are intended to catch synthetic oscillator behavior "
                "that broad spectral averages can miss. Metrics are a "
                "listening-alignment check, not a final replacement for "
                "human auditioning."
            ),
        },
        "target": {
            "path": relative_path(target_path),
            "sample_rate": target["sample_rate"],
            "channels": target["channels"],
            "duration_seconds": round(target["duration_seconds"], 6),
        },
        "results": results,
    }

    if args.output:
        write_report(args.output, report)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_text_report(report)
        if args.output:
            print()
            print(f"report: {args.output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
