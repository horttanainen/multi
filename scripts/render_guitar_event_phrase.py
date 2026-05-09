#!/usr/bin/env python3
"""Render a short guitar phrase from detected reference-stem note events."""

import argparse
import json
import math
import re
import subprocess
import sys
import wave
from array import array
from pathlib import Path

import estimate_target_pitch as pitch


DEFAULT_SOURCE = "artifacts/stems/americana_raga/guitar.wav"
DEFAULT_PRESET = (
    "artifacts/music_presets/"
    "faust_direct_moredepth_listener_promoted_guitar_pluck_params.json"
)
DEFAULT_RENDER_ROOT = "artifacts/event_phrase_renders"
DEFAULT_REPORT_ROOT = "artifacts/music_reports"
DEFAULT_INSTRUMENT = "guitar-faust-pluck"
EPSILON = 1.0e-12


GUITAR_PARAM_OPTIONS = {
    "pluck_position": "--pluck-position",
    "pluck_brightness": "--pluck-brightness",
    "string_mix": "--string-mix",
    "body_mix": "--body-mix",
    "attack_mix": "--attack-mix",
    "mute": "--mute",
    "string_decay": "--string-decay",
    "body_gain": "--body-gain",
    "body_decay": "--body-decay",
    "body_freq": "--body-freq",
    "pick_noise": "--pick-noise",
    "attack_gain": "--attack-gain",
    "attack_decay": "--attack-decay",
    "bridge_coupling": "--bridge-coupling",
    "inharmonicity": "--inharmonicity",
    "high_decay": "--high-decay",
    "output_gain": "--output-gain",
}


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Build the first event-level guitar phrase loop: detect note onsets "
            "inside a reference stem window, estimate each event pitch, render "
            "current probe plucks, mix them back into a phrase, and score the "
            "phrase against the real reference segment."
        )
    )
    parser.add_argument("--round-id", default="guitar_event_phrase_faust_pass1")
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--preset", default=DEFAULT_PRESET)
    parser.add_argument("--instrument", default=DEFAULT_INSTRUMENT)
    parser.add_argument("--start", type=float, default=121.16)
    parser.add_argument("--duration", type=float, default=3.20)
    parser.add_argument("--max-events", type=int, default=8)
    parser.add_argument("--min-gap", type=float, default=0.13)
    parser.add_argument("--frame-ms", type=float, default=5.0)
    parser.add_argument("--pre-roll", type=float, default=0.035)
    parser.add_argument("--event-duration", type=float, default=0.42)
    parser.add_argument("--pitch-start", type=float, default=0.035)
    parser.add_argument("--pitch-duration", type=float, default=0.145)
    parser.add_argument("--min-frequency", type=float, default=70.0)
    parser.add_argument("--max-frequency", type=float, default=700.0)
    parser.add_argument("--min-confidence", type=float, default=0.32)
    parser.add_argument("--velocity-min", type=float, default=0.22)
    parser.add_argument("--velocity-base", type=float, default=0.34)
    parser.add_argument("--velocity-scale", type=float, default=0.62)
    parser.add_argument("--velocity-max", type=float, default=1.0)
    parser.add_argument("--duration-scale", type=float, default=1.0)
    parser.add_argument("--duration-velocity-scale", type=float, default=0.0)
    parser.add_argument("--timing-spread-ms", type=float, default=0.0)
    parser.add_argument("--pitch-spread-cents", type=float, default=0.0)
    parser.add_argument("--velocity-alternation", type=float, default=0.0)
    parser.add_argument(
        "--param",
        action="append",
        default=[],
        help=(
            "override guitar probe parameter as key=value; supported keys: "
            + ",".join(GUITAR_PARAM_OPTIONS)
        ),
    )
    parser.add_argument("--render-root", default=DEFAULT_RENDER_ROOT)
    parser.add_argument("--report", default=None)
    parser.add_argument(
        "--keep-weak-pitch",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="render events even when pitch confidence is below threshold",
    )
    return parser.parse_args()


def repo_root():
    return Path(__file__).resolve().parents[1]


def relative_path(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def slugify(value):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value).strip())
    return slug.strip("._-") or "item"


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

    return {
        "path": str(path),
        "sample_rate": params.framerate,
        "channels": params.nchannels,
        "sample_width_bytes": params.sampwidth,
        "duration_seconds": len(mono) / params.framerate,
        "samples": mono,
    }


def write_mono_pcm16_wav(path, samples, sample_rate):
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    pcm = array("h")
    for sample in samples:
        clipped = max(-1.0, min(1.0, sample))
        pcm.append(int(round(clipped * 32767.0)))
    if sys.byteorder != "little":
        pcm.byteswap()
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm.tobytes())


def rms(samples):
    if not samples:
        return 0.0
    total = 0.0
    for sample in samples:
        total += sample * sample
    return math.sqrt(total / len(samples))


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
    values = []
    for start in range(0, len(samples), frame_samples):
        values.append(rms(samples[start : start + frame_samples]))
    return values


def detect_phrase_events(samples, sample_rate, args):
    frame_samples = max(1, int(round(sample_rate * args.frame_ms / 1000.0)))
    frame_seconds = frame_samples / sample_rate
    rms_values = frame_rms_curve(samples, frame_samples)
    if not rms_values:
        return [], {"frame_seconds": frame_seconds, "raw_event_count": 0}

    median_rms = percentile(rms_values, 0.50)
    high_rms = percentile(rms_values, 0.92)
    threshold = max(0.003, median_rms + max(0.0, high_rms - median_rms) * 0.24)
    background_frames = max(1, int(round(0.045 / frame_seconds)))
    peak_search_frames = max(1, int(round(0.090 / frame_seconds)))
    min_gap_frames = max(1, int(round(args.min_gap / frame_seconds)))

    raw_events = []
    frame_index = background_frames
    while frame_index < len(rms_values):
        background = mean(rms_values[frame_index - background_frames : frame_index])
        current = rms_values[frame_index]
        previous = rms_values[frame_index - 1]
        rise = current - background
        local_jump = current - previous
        if current < threshold or rise <= 0.0 or local_jump <= 0.0:
            frame_index += 1
            continue
        if current < background * 1.08:
            frame_index += 1
            continue

        search_end = min(len(rms_values), frame_index + peak_search_frames)
        peak_frame = max(range(frame_index, search_end), key=lambda pos: rms_values[pos])
        peak_rms = rms_values[peak_frame]
        score = rise + local_jump * 0.75 + peak_rms * 0.18
        raw_events.append(
            {
                "onset_frame": frame_index,
                "peak_frame": peak_frame,
                "background_rms": background,
                "onset_rms": current,
                "peak_rms": peak_rms,
                "rise_rms": rise,
                "local_jump_rms": local_jump,
                "event_score": score,
            }
        )
        frame_index += max(1, peak_search_frames // 2)

    selected = []
    for event in sorted(raw_events, key=lambda item: item["event_score"], reverse=True):
        if any(
            abs(event["onset_frame"] - chosen["onset_frame"]) < min_gap_frames
            for chosen in selected
        ):
            continue
        selected.append(event)
        if len(selected) >= args.max_events:
            break

    selected.sort(key=lambda item: item["onset_frame"])
    stats = {
        "frame_seconds": frame_seconds,
        "median_rms": median_rms,
        "p92_rms": high_rms,
        "threshold": threshold,
        "raw_event_count": len(raw_events),
        "selected_event_count": len(selected),
    }
    return selected, stats


def export_event_clip(samples, sample_rate, event, event_index, output_dir, args):
    onset_sample = int(round(event["onset_seconds"] * sample_rate))
    start_sample = max(0, onset_sample - int(round(args.pre_roll * sample_rate)))
    frame_count = max(1, int(round(args.event_duration * sample_rate)))
    end_sample = min(len(samples), start_sample + frame_count)
    if end_sample - start_sample < frame_count:
        start_sample = max(0, end_sample - frame_count)

    clip = samples[start_sample:end_sample]
    path = output_dir / f"event_{event_index:03d}_target.wav"
    write_mono_pcm16_wav(path, clip, sample_rate)
    return path, start_sample / sample_rate, len(clip) / sample_rate


def pitch_report_for(path, args):
    audio = pitch.read_pcm16_wav(path)
    segment = pitch.analysis_segment(audio, args.pitch_start, args.pitch_duration)
    if len(segment) < 256:
        return {"combined_candidates": [], "methods": {}, "analysis": {}}

    sample_rate = audio["sample_rate"]
    methods = {
        "yin": pitch.yin_candidates(
            segment, sample_rate, args.min_frequency, args.max_frequency, 8
        ),
        "autocorrelation": pitch.autocorrelation_candidates(
            segment, sample_rate, args.min_frequency, args.max_frequency, 8
        ),
        "harmonic_product": pitch.harmonic_product_candidates(
            segment, sample_rate, args.min_frequency, args.max_frequency, 8
        ),
        "spectral_peaks": pitch.spectral_candidates(
            segment, sample_rate, args.min_frequency, args.max_frequency, 8
        ),
    }
    return {
        "combined_candidates": pitch.combine_candidates(methods),
        "methods": methods,
        "analysis": {
            "start_seconds": args.pitch_start,
            "duration_seconds": round(len(segment) / sample_rate, 6),
            "min_frequency": args.min_frequency,
            "max_frequency": args.max_frequency,
            "rms": round(pitch.rms(segment), 8),
        },
    }


def pitch_summary(report, args):
    candidates = report.get("combined_candidates", [])
    if not candidates:
        return {
            "accepted": False,
            "reject_reason": "no pitch candidates",
            "frequency_hz": 0.0,
            "nearest_note": "",
            "confidence": 0.0,
        }

    top = candidates[0]
    score = float(top.get("score", 0.0))
    second = float(candidates[1].get("score", 0.0)) if len(candidates) > 1 else 0.0
    method_count = len(top.get("methods", []))
    margin_ratio = max(0.0, (score - second) / (score + EPSILON))
    method_ratio = min(1.0, method_count / 3.0)
    absolute_ratio = min(1.0, score / 2.0)
    confidence = method_ratio * 0.45 + margin_ratio * 0.35 + absolute_ratio * 0.20
    frequency = float(top.get("frequency_hz", 0.0))
    accepted = confidence >= args.min_confidence and frequency > 0.0
    return {
        "accepted": accepted,
        "reject_reason": "" if accepted else "low pitch confidence",
        "frequency_hz": round(frequency, 4),
        "nearest_note": top.get("nearest_note", ""),
        "confidence": round(confidence, 4),
        "method_count": method_count,
        "score": round(score, 6),
        "score_margin": round(score - second, 6),
        "methods": top.get("methods", []),
        "alternates": candidates[1:5],
    }


def load_preset_params(root, preset_path):
    preset = json.loads((root / preset_path).read_text(encoding="utf-8"))
    return preset.get("params", {}), preset


def parse_param_overrides(raw_overrides):
    overrides = {}
    for raw in raw_overrides:
        if "=" not in raw:
            raise ValueError(f"parameter override lacks '=': {raw}")
        key, value = raw.split("=", 1)
        key = key.strip().replace("-", "_")
        if key not in GUITAR_PARAM_OPTIONS:
            raise ValueError(f"unsupported guitar parameter override: {key}")
        try:
            overrides[key] = float(value)
        except ValueError as err:
            raise ValueError(f"invalid numeric override {raw}") from err
    return overrides


def apply_param_overrides(params, overrides):
    result = dict(params)
    for key, value in overrides.items():
        result[key] = value
    return result


def render_event(root, event, output_path, instrument, params):
    command = [
        "zig",
        "build",
        "music-probe",
        "--",
        instrument,
        "--freq",
        f"{event['render_frequency_hz']:.4f}",
        "--velocity",
        f"{event['velocity']:.4f}",
        "--duration",
        f"{event['render_duration_seconds']:.4f}",
        "--out",
        str(output_path),
    ]
    for key, option in GUITAR_PARAM_OPTIONS.items():
        if key not in params:
            continue
        command.extend([option, str(params[key])])

    result = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode == 0:
        return
    if result.stdout:
        print(result.stdout, end="", file=sys.stderr)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    raise subprocess.CalledProcessError(result.returncode, command)


def mix_rendered_events(phrase_frame_count, sample_rate, events):
    mix = [0.0 for _ in range(phrase_frame_count)]
    for event in events:
        render_audio = read_pcm16_wav(event["render_path"])
        if render_audio["sample_rate"] != sample_rate:
            raise ValueError(
                "render sample rate differs from reference: "
                f"{render_audio['sample_rate']} vs {sample_rate}"
            )

        start_sample = int(round(event["render_onset_seconds"] * sample_rate))
        for index, sample in enumerate(render_audio["samples"]):
            target_index = start_sample + index
            if target_index >= phrase_frame_count:
                break
            mix[target_index] += sample

    peak = max((abs(sample) for sample in mix), default=0.0)
    scale = 1.0
    if peak > 0.98:
        scale = 0.98 / peak
        mix = [sample * scale for sample in mix]
    return mix, scale


def normalize_for_audition(samples, target_rms=0.075):
    value = rms(samples)
    if value <= EPSILON or target_rms <= 0.0:
        return list(samples)
    scale = min(target_rms / value, 0.98 / (max((abs(sample) for sample in samples), default=0.0) + EPSILON))
    return [sample * scale for sample in samples]


def cue_beeps(count, sample_rate):
    samples = []
    tone_frames = int(round(0.075 * sample_rate))
    gap_frames = int(round(0.055 * sample_rate))
    for cue_index in range(count):
        for index in range(tone_frames):
            phase = 2.0 * math.pi * 880.0 * index / sample_rate
            samples.append(math.sin(phase) * 0.15)
        if cue_index + 1 < count:
            samples.extend([0.0 for _ in range(gap_frames)])
    return samples


def build_phrase_audition(reference_samples, generated_samples, sample_rate):
    gap = [0.0 for _ in range(int(round(0.35 * sample_rate)))]
    section_gap = [0.0 for _ in range(int(round(0.80 * sample_rate)))]
    audition = []
    audition.extend(cue_beeps(1, sample_rate))
    audition.extend(gap)
    audition.extend(normalize_for_audition(reference_samples))
    audition.extend(section_gap)
    audition.extend(cue_beeps(2, sample_rate))
    audition.extend(gap)
    audition.extend(normalize_for_audition(generated_samples))
    return audition


def run_phrase_score(root, reference_path, generated_path, report_path):
    command = [
        sys.executable,
        str(root / "scripts" / "compare_reference_target.py"),
        "--target",
        str(reference_path),
        "--generated",
        str(generated_path),
        "--output",
        str(report_path),
    ]
    result = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode == 0:
        return
    if result.stdout:
        print(result.stdout, end="", file=sys.stderr)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    raise subprocess.CalledProcessError(result.returncode, command)


def report_path_for(args):
    if args.report:
        return Path(args.report)
    return Path(DEFAULT_REPORT_ROOT) / f"{args.round_id}_phrase_compare.json"


def enrich_events(phrase_samples, sample_rate, raw_events, output_dir, args):
    max_peak = max((event["peak_rms"] for event in raw_events), default=1.0)
    enriched = []
    for index, raw_event in enumerate(raw_events):
        event = dict(raw_event)
        event["index"] = index
        event["onset_seconds"] = event["onset_frame"] * args.frame_ms / 1000.0
        event["peak_seconds"] = event["peak_frame"] * args.frame_ms / 1000.0
        target_path, clip_start, clip_duration = export_event_clip(
            phrase_samples,
            sample_rate,
            event,
            index,
            output_dir,
            args,
        )
        report = pitch_report_for(target_path, args)
        event["target_path"] = relative_path(target_path)
        event["target_clip_start_seconds"] = round(clip_start, 6)
        event["target_clip_duration_seconds"] = round(clip_duration, 6)
        event["pitch"] = pitch_summary(report, args)
        event["pitch_report"] = {
            "analysis": report.get("analysis", {}),
            "combined_candidates": report.get("combined_candidates", [])[:8],
        }
        mapped_velocity = max(
            args.velocity_min,
            min(
                args.velocity_max,
                args.velocity_base
                + args.velocity_scale * event["peak_rms"] / (max_peak + EPSILON),
            ),
        )
        if args.velocity_alternation != 0.0:
            direction = 1.0 if index % 2 == 0 else -1.0
            mapped_velocity = max(
                args.velocity_min,
                min(args.velocity_max, mapped_velocity + direction * args.velocity_alternation),
            )
        event["velocity"] = round(mapped_velocity, 4)
        velocity_norm = max(
            0.0,
            min(
                1.0,
                (mapped_velocity - args.velocity_min)
                / (args.velocity_max - args.velocity_min + EPSILON),
            ),
        )
        timing_offset = performance_offset(index, args.timing_spread_ms) / 1000.0
        event["render_onset_seconds"] = round(
            max(
                0.0,
                min(
                    max(0.0, len(phrase_samples) / sample_rate - 0.01),
                    event["onset_seconds"] + timing_offset,
                ),
            ),
            6,
        )
        duration_scale = args.duration_scale * (
            1.0 + args.duration_velocity_scale * velocity_norm
        )
        event["render_duration_seconds"] = round(
            max(0.08, min(1.20, args.event_duration * duration_scale)),
            6,
        )
        event["render_pitch_cents"] = round(
            performance_offset(index, args.pitch_spread_cents),
            4,
        )
        event["render_frequency_hz"] = round(
            event["pitch"]["frequency_hz"]
            * math.pow(2.0, event["render_pitch_cents"] / 1200.0),
            4,
        )
        if event["pitch"]["accepted"] or args.keep_weak_pitch:
            enriched.append(event)
    return enriched


def performance_offset(index, spread):
    if spread == 0.0:
        return 0.0
    pattern = [0.0, -0.72, 0.48, -0.32, 0.64, -0.20, 0.36, -0.56]
    return pattern[index % len(pattern)] * spread


def write_manifest(path, data):
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    if args.duration <= 0.0:
        print("error: --duration must be positive", file=sys.stderr)
        return 2
    if args.max_events <= 0:
        print("error: --max-events must be positive", file=sys.stderr)
        return 2
    if args.velocity_min < 0.0 or args.velocity_max > 1.0 or args.velocity_min > args.velocity_max:
        print("error: invalid velocity range", file=sys.stderr)
        return 2
    if args.duration_scale <= 0.0:
        print("error: --duration-scale must be positive", file=sys.stderr)
        return 2

    root = repo_root()
    source_path = root / args.source
    preset_path = Path(args.preset)
    if not source_path.is_file():
        print(f"error: source WAV not found: {args.source}", file=sys.stderr)
        return 2
    if not (root / preset_path).is_file():
        print(f"error: preset JSON not found: {args.preset}", file=sys.stderr)
        return 2

    source = read_pcm16_wav(source_path)
    sample_rate = source["sample_rate"]
    start_sample = max(0, int(round(args.start * sample_rate)))
    frame_count = max(1, int(round(args.duration * sample_rate)))
    end_sample = min(len(source["samples"]), start_sample + frame_count)
    phrase_samples = source["samples"][start_sample:end_sample]
    if len(phrase_samples) < frame_count:
        frame_count = len(phrase_samples)

    output_dir = Path(args.render_root) / slugify(args.round_id)
    reference_path = output_dir / "reference_phrase.wav"
    generated_path = output_dir / "generated_phrase.wav"
    event_dir = output_dir / "events"
    event_dir.mkdir(parents=True, exist_ok=True)
    write_mono_pcm16_wav(reference_path, phrase_samples, sample_rate)

    raw_events, detection_stats = detect_phrase_events(phrase_samples, sample_rate, args)
    try:
        param_overrides = parse_param_overrides(args.param)
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    preset_params, preset = load_preset_params(root, preset_path)
    params = apply_param_overrides(preset_params, param_overrides)
    events = enrich_events(phrase_samples, sample_rate, raw_events, event_dir, args)
    for event in events:
        frequency = event["pitch"]["frequency_hz"]
        if frequency <= EPSILON:
            continue
        render_path = event_dir / f"event_{event['index']:03d}_render.wav"
        event["render_path"] = relative_path(render_path)
        render_event(root, event, render_path, args.instrument, params)

    rendered_events = [event for event in events if event.get("render_path")]
    generated_samples, mix_scale = mix_rendered_events(frame_count, sample_rate, rendered_events)
    write_mono_pcm16_wav(generated_path, generated_samples, sample_rate)
    audition_path = output_dir / "audition_reference_then_generated.wav"
    audition_samples = build_phrase_audition(phrase_samples, generated_samples, sample_rate)
    write_mono_pcm16_wav(audition_path, audition_samples, sample_rate)

    report_path = report_path_for(args)
    run_phrase_score(root, reference_path, generated_path, report_path)
    score_report = json.loads((root / report_path).read_text(encoding="utf-8"))
    score = None
    if score_report.get("results"):
        score = score_report["results"][0]["score"]

    manifest_path = output_dir / "event_phrase_manifest.json"
    manifest = {
        "meta": {
            "version": 1,
            "purpose": "Event-level guitar phrase render from detected reference-stem note events.",
            "round_id": args.round_id,
            "source_wav": relative_path(source_path),
            "source_start_seconds": args.start,
            "duration_seconds": round(frame_count / sample_rate, 6),
            "sample_rate": sample_rate,
            "instrument": args.instrument,
            "preset": relative_path(root / preset_path),
            "preset_candidate": preset.get("candidate", {}),
            "base_params": preset_params,
            "param_overrides": param_overrides,
            "render_params": params,
            "velocity_mapping": {
                "min": args.velocity_min,
                "base": args.velocity_base,
                "scale": args.velocity_scale,
                "max": args.velocity_max,
            },
            "performance_mapping": {
                "duration_scale": args.duration_scale,
                "duration_velocity_scale": args.duration_velocity_scale,
                "timing_spread_ms": args.timing_spread_ms,
                "pitch_spread_cents": args.pitch_spread_cents,
                "velocity_alternation": args.velocity_alternation,
            },
            "reference_phrase": relative_path(reference_path),
            "generated_phrase": relative_path(generated_path),
            "audition_phrase": relative_path(audition_path),
            "audition_order": [
                {
                    "cue": 1,
                    "kind": "reference",
                    "path": relative_path(reference_path),
                },
                {
                    "cue": 2,
                    "kind": "generated",
                    "path": relative_path(generated_path),
                },
            ],
            "score_report": relative_path(root / report_path),
            "phrase_score": score,
            "mix_peak_scale": round(mix_scale, 6),
            "detection": detection_stats,
            "analysis_note": (
                "This is the first Milestone 5 loop: render note events at "
                "detected reference onsets with estimated pitch and simple "
                "velocity mapping. It is not yet a full phrase optimizer."
            ),
        },
        "events": events,
    }
    write_manifest(manifest_path, manifest)

    print("event_phrase_round")
    print(f"reference_phrase={relative_path(reference_path)}")
    print(f"generated_phrase={relative_path(generated_path)}")
    print(f"audition_phrase={relative_path(audition_path)}")
    print(f"manifest={relative_path(manifest_path)}")
    print(f"score_report={relative_path(root / report_path)}")
    if score is not None:
        print(f"phrase_score={score:.4f}")
    print("events:")
    for event in events:
        pitch_info = event["pitch"]
        status = "accepted" if pitch_info["accepted"] else "weak"
        print(
            f"- {event['index']:02d} t={event['onset_seconds']:.3f}s "
            f"rt={event['render_onset_seconds']:.3f}s "
            f"freq={pitch_info['frequency_hz']:.2f} note={pitch_info['nearest_note']} "
            f"rfreq={event['render_frequency_hz']:.2f} "
            f"velocity={event['velocity']:.3f} pitch={status} "
            f"render={event.get('render_path', '')}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
