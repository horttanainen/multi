#!/usr/bin/env python3
"""Estimate likely pitch candidates for a selected plucked-note target."""

import argparse
import json
import math
import sys
import wave
from array import array
from pathlib import Path


EPSILON = 1.0e-12
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Estimate pitch candidates from a short plucked-note WAV. "
            "The script ignores the earliest attack by default and reports "
            "autocorrelation, YIN-style, spectral peak, and harmonic-product "
            "hints so octave/partial ambiguity is visible."
        )
    )
    parser.add_argument("wav", help="target WAV")
    parser.add_argument("--min-freq", type=float, default=70.0)
    parser.add_argument("--max-freq", type=float, default=700.0)
    parser.add_argument(
        "--start",
        type=float,
        default=0.035,
        help="analysis start seconds, after the noisy pluck attack",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0.145,
        help="analysis duration seconds",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print full JSON report",
    )
    return parser.parse_args()


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
        "path": str(path),
        "sample_rate": params.framerate,
        "channels": params.nchannels,
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


def normalize(samples):
    value = rms(samples)
    if value <= EPSILON:
        return list(samples)
    return [sample / value for sample in samples]


def hann_window(size):
    if size <= 1:
        return [1.0]
    return [
        0.5 - 0.5 * math.cos(2.0 * math.pi * index / (size - 1))
        for index in range(size)
    ]


def analysis_segment(audio, start_seconds, duration_seconds):
    sample_rate = audio["sample_rate"]
    start = max(0, int(round(start_seconds * sample_rate)))
    end = min(len(audio["samples"]), start + max(1, int(round(duration_seconds * sample_rate))))
    if end <= start:
        return []
    segment = list(audio["samples"][start:end])
    remove_dc(segment)
    return normalize(segment)


def autocorrelation_candidates(samples, sample_rate, min_freq, max_freq, limit):
    min_lag = max(1, int(sample_rate / max_freq))
    max_lag = min(len(samples) - 2, int(sample_rate / min_freq))
    if max_lag <= min_lag:
        return []

    scored = []
    for lag in range(min_lag, max_lag + 1):
        corr = 0.0
        energy_a = 0.0
        energy_b = 0.0
        for index in range(0, len(samples) - lag):
            a = samples[index]
            b = samples[index + lag]
            corr += a * b
            energy_a += a * a
            energy_b += b * b
        score = corr / (math.sqrt(energy_a * energy_b) + EPSILON)
        scored.append({"frequency_hz": sample_rate / lag, "score": max(0.0, score)})

    return peak_candidates(scored, limit, min_semitones=0.45)


def yin_candidates(samples, sample_rate, min_freq, max_freq, limit):
    min_lag = max(1, int(sample_rate / max_freq))
    max_lag = min(len(samples) - 2, int(sample_rate / min_freq))
    if max_lag <= min_lag:
        return []

    diffs = [0.0 for _ in range(max_lag + 1)]
    running = 0.0
    candidates = []

    for lag in range(1, max_lag + 1):
        total = 0.0
        for index in range(0, len(samples) - lag):
            diff = samples[index] - samples[index + lag]
            total += diff * diff
        diffs[lag] = total
        running += total
        if lag < min_lag:
            continue
        cmnd = total * lag / (running + EPSILON)
        score = max(0.0, 1.0 - cmnd)
        candidates.append({"frequency_hz": sample_rate / lag, "score": score})

    return peak_candidates(candidates, limit, min_semitones=0.45)


def spectral_candidates(samples, sample_rate, min_freq, max_freq, limit):
    size = next_power_of_two(max(2048, len(samples) * 2))
    window = hann_window(min(len(samples), size))
    frame = [0.0 for _ in range(size)]
    for index, sample in enumerate(samples[: len(window)]):
        frame[index] = sample * window[index]

    freqs = log_freqs(min_freq, max_freq * 8.0, 180)
    powers = [goertzel_power(frame, freq, sample_rate) for freq in freqs]
    total = sum(powers) + EPSILON
    scored = [
        {"frequency_hz": freq, "score": power / total}
        for freq, power in zip(freqs, powers)
        if min_freq <= freq <= max_freq
    ]
    return peak_candidates(scored, limit, min_semitones=0.35)


def harmonic_product_candidates(samples, sample_rate, min_freq, max_freq, limit):
    size = next_power_of_two(max(2048, len(samples) * 2))
    window = hann_window(min(len(samples), size))
    frame = [0.0 for _ in range(size)]
    for index, sample in enumerate(samples[: len(window)]):
        frame[index] = sample * window[index]

    candidates = []
    test_freqs = log_freqs(min_freq, max_freq, 240)
    for freq in test_freqs:
        score = 0.0
        weight = 1.0
        harmonic = 1
        while harmonic <= 8:
            harmonic_freq = freq * harmonic
            if harmonic_freq >= sample_rate * 0.45:
                break
            power = goertzel_power(frame, harmonic_freq, sample_rate)
            score += math.log(power + EPSILON) * weight
            weight *= 0.72
            harmonic += 1
        candidates.append({"frequency_hz": freq, "score": score})

    normalize_scores(candidates)
    return peak_candidates(candidates, limit, min_semitones=0.35)


def log_freqs(min_freq, max_freq, count):
    ratio = max_freq / min_freq
    return [
        min_freq * math.pow(ratio, index / max(1, count - 1))
        for index in range(count)
    ]


def goertzel_power(samples, frequency_hz, sample_rate):
    coeff = 2.0 * math.cos(2.0 * math.pi * frequency_hz / sample_rate)
    q1 = 0.0
    q2 = 0.0
    for sample in samples:
        q0 = sample + coeff * q1 - q2
        q2 = q1
        q1 = q0
    return max(0.0, q1 * q1 + q2 * q2 - coeff * q1 * q2)


def next_power_of_two(value):
    result = 1
    while result < value:
        result *= 2
    return result


def normalize_scores(candidates):
    if not candidates:
        return
    values = [candidate["score"] for candidate in candidates]
    low = min(values)
    high = max(values)
    width = high - low
    if width <= EPSILON:
        for candidate in candidates:
            candidate["score"] = 0.0
        return
    for candidate in candidates:
        candidate["score"] = (candidate["score"] - low) / width


def peak_candidates(candidates, limit, min_semitones):
    if not candidates:
        return []
    ordered = sorted(candidates, key=lambda item: item["score"], reverse=True)
    selected = []
    for candidate in ordered:
        if any(
            abs(semitone_distance(candidate["frequency_hz"], chosen["frequency_hz"]))
            < min_semitones
            for chosen in selected
        ):
            continue
        selected.append(candidate)
        if len(selected) >= limit:
            break
    return [rounded_candidate(candidate) for candidate in selected]


def semitone_distance(a_hz, b_hz):
    if a_hz <= EPSILON or b_hz <= EPSILON:
        return 99.0
    return 12.0 * math.log(a_hz / b_hz, 2.0)


def rounded_candidate(candidate):
    freq = candidate["frequency_hz"]
    return {
        "frequency_hz": round(freq, 4),
        "nearest_note": nearest_note_name(freq),
        "score": round(candidate["score"], 6),
    }


def nearest_note_name(frequency_hz):
    if frequency_hz <= EPSILON:
        return ""
    midi = round(69 + 12 * math.log(frequency_hz / 440.0, 2.0))
    note = NOTE_NAMES[midi % 12]
    octave = midi // 12 - 1
    cents = 1200.0 * math.log(frequency_hz / midi_to_frequency(midi), 2.0)
    return f"{note}{octave} ({cents:+.1f}c)"


def midi_to_frequency(midi):
    return 440.0 * math.pow(2.0, (midi - 69) / 12.0)


def combine_candidates(methods):
    combined = {}
    method_weights = {
        "yin": 1.0,
        "autocorrelation": 0.85,
        "harmonic_product": 1.0,
        "spectral_peaks": 0.55,
    }

    for method_name, candidates in methods.items():
        for rank, candidate in enumerate(candidates):
            freq = candidate["frequency_hz"]
            if freq <= EPSILON:
                continue
            midi_bucket = round(69 + 12 * math.log(freq / 440.0, 2.0))
            entry = combined.setdefault(
                midi_bucket,
                {
                    "frequency_values": [],
                    "score": 0.0,
                    "methods": [],
                },
            )
            rank_weight = 1.0 / (rank + 1)
            entry["frequency_values"].append(freq)
            entry["score"] += candidate["score"] * method_weights[method_name] * rank_weight
            entry["methods"].append(method_name)

    results = []
    for entry in combined.values():
        freq = sum(entry["frequency_values"]) / len(entry["frequency_values"])
        methods = sorted(set(entry["methods"]))
        results.append(
            {
                "frequency_hz": round(freq, 4),
                "nearest_note": nearest_note_name(freq),
                "score": round(entry["score"], 6),
                "methods": methods,
            }
        )

    return sorted(results, key=lambda item: item["score"], reverse=True)


def print_report(report):
    print(f"target: {report['target']['path']}")
    print(
        f"analysis window: {report['analysis']['start_seconds']:.3f}s - "
        f"{report['analysis']['end_seconds']:.3f}s "
        f"({report['analysis']['duration_seconds']:.3f}s)"
    )
    print()
    print("combined candidates:")
    for index, candidate in enumerate(report["combined_candidates"][:8], start=1):
        print(
            f"  {index}. {candidate['frequency_hz']:8.3f} Hz  "
            f"{candidate['nearest_note']:14s}  score={candidate['score']:.4f}  "
            f"methods={','.join(candidate['methods'])}"
        )
    print()
    for method_name, candidates in report["methods"].items():
        print(f"{method_name}:")
        for candidate in candidates[:6]:
            print(
                f"  {candidate['frequency_hz']:8.3f} Hz  "
                f"{candidate['nearest_note']:14s}  score={candidate['score']:.4f}"
            )


def main():
    args = parse_args()
    path = Path(args.wav)
    if not path.is_file():
        print(f"error: WAV not found: {path}", file=sys.stderr)
        return 2

    if args.min_freq <= 0 or args.max_freq <= args.min_freq:
        print("error: invalid frequency range", file=sys.stderr)
        return 2

    try:
        audio = read_pcm16_wav(path)
    except (OSError, ValueError, wave.Error) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    segment = analysis_segment(audio, args.start, args.duration)
    if len(segment) < 256:
        print("error: analysis segment is too short", file=sys.stderr)
        return 1

    sample_rate = audio["sample_rate"]
    methods = {
        "yin": yin_candidates(segment, sample_rate, args.min_freq, args.max_freq, 8),
        "autocorrelation": autocorrelation_candidates(
            segment, sample_rate, args.min_freq, args.max_freq, 8
        ),
        "harmonic_product": harmonic_product_candidates(
            segment, sample_rate, args.min_freq, args.max_freq, 8
        ),
        "spectral_peaks": spectral_candidates(
            segment, sample_rate, args.min_freq, args.max_freq, 8
        ),
    }
    report = {
        "target": {
            "path": str(path),
            "sample_rate": sample_rate,
            "channels": audio["channels"],
            "duration_seconds": round(audio["duration_seconds"], 6),
        },
        "analysis": {
            "start_seconds": args.start,
            "end_seconds": round(args.start + len(segment) / sample_rate, 6),
            "duration_seconds": round(len(segment) / sample_rate, 6),
            "min_freq": args.min_freq,
            "max_freq": args.max_freq,
            "rms": round(rms(segment), 8),
        },
        "combined_candidates": combine_candidates(methods),
        "methods": methods,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
