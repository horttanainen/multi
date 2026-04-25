#!/usr/bin/env python3
"""Extract short real-audio target candidates from an isolated instrument stem."""

import argparse
import json
import math
import re
import sys
import wave
from array import array
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract short candidate target WAVs from an isolated stem."
    )
    parser.add_argument("--source", required=True, help="isolated instrument WAV")
    parser.add_argument("--style", required=True, help="style/run name")
    parser.add_argument("--instrument", default="guitar", help="instrument name")
    parser.add_argument(
        "--output-root",
        default="artifacts/music_targets",
        help="target output root",
    )
    parser.add_argument("--count", type=int, default=16, help="candidate count")
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=1.0,
        help="seconds to export per candidate",
    )
    parser.add_argument(
        "--pre-roll-seconds",
        type=float,
        default=0.08,
        help="seconds to include before the detected energy rise",
    )
    parser.add_argument(
        "--min-gap-seconds",
        type=float,
        default=1.0,
        help="minimum spacing between selected candidates",
    )
    parser.add_argument(
        "--frame-ms",
        type=float,
        default=20.0,
        help="analysis frame size in milliseconds",
    )
    parser.add_argument(
        "--threshold-ratio",
        type=float,
        default=0.35,
        help="energy threshold between median and high percentile RMS",
    )
    parser.add_argument(
        "--onset-ratio",
        type=float,
        default=1.2,
        help="current RMS must exceed recent background by this ratio",
    )
    parser.add_argument(
        "--min-rms",
        type=float,
        default=0.003,
        help="absolute RMS floor for candidate detection",
    )
    return parser.parse_args()


def slugify(text):
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", text).strip("_")
    return slug or "target"


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

    samples = array("h")
    samples.frombytes(frames)
    if sys.byteorder != "little":
        samples.byteswap()

    return params, frames, samples


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(round((len(ordered) - 1) * pct))
    return ordered[max(0, min(len(ordered) - 1, index))]


def rms_for_range(samples, first, last):
    if last <= first:
        return 0.0

    total = 0.0
    count = last - first
    for sample in samples[first:last]:
        total += sample * sample
    return math.sqrt(total / count) / 32768.0


def build_rms_curve(samples, channels, sample_rate, frame_samples):
    frame_values = []
    total_frames = len(samples) // channels
    for start_frame in range(0, total_frames, frame_samples):
        end_frame = min(total_frames, start_frame + frame_samples)
        first = start_frame * channels
        last = end_frame * channels
        frame_values.append(rms_for_range(samples, first, last))
    return frame_values


def mean(values):
    if not values:
        return 0.0
    return sum(values) / len(values)


def detect_candidates(rms_values, frame_seconds, args):
    if not rms_values:
        return [], {}

    median_rms = percentile(rms_values, 0.50)
    high_rms = percentile(rms_values, 0.95)
    threshold = max(
        args.min_rms,
        median_rms + max(0.0, high_rms - median_rms) * args.threshold_ratio,
    )

    background_frames = max(1, int(round(0.16 / frame_seconds)))
    peak_search_frames = max(1, int(round(0.20 / frame_seconds)))
    raw_candidates = []
    frame_index = background_frames
    while frame_index < len(rms_values):
        recent = rms_values[frame_index - background_frames : frame_index]
        background = mean(recent)
        current = rms_values[frame_index]
        if current < threshold or current < background * args.onset_ratio:
            frame_index += 1
            continue

        search_end = min(len(rms_values), frame_index + peak_search_frames)
        peak_frame = max(
            range(frame_index, search_end),
            key=lambda index: rms_values[index],
        )
        peak_rms = rms_values[peak_frame]
        onset_delta = max(0.0, current - background)
        score = onset_delta + peak_rms * 0.25
        raw_candidates.append(
            {
                "event_frame": frame_index,
                "peak_frame": peak_frame,
                "background_rms": background,
                "onset_rms": current,
                "peak_rms": peak_rms,
                "onset_delta": onset_delta,
                "candidate_rank_score": score,
            }
        )
        frame_index += peak_search_frames

    selected = []
    min_gap_frames = max(1, int(round(args.min_gap_seconds / frame_seconds)))
    for candidate in sorted(
        raw_candidates,
        key=lambda item: item["candidate_rank_score"],
        reverse=True,
    ):
        event_frame = candidate["event_frame"]
        overlaps = False
        for chosen in selected:
            if abs(event_frame - chosen["event_frame"]) < min_gap_frames:
                overlaps = True
                break
        if overlaps:
            continue
        selected.append(candidate)
        if len(selected) >= args.count:
            break

    stats = {
        "frame_seconds": frame_seconds,
        "rms_median": median_rms,
        "rms_p95": high_rms,
        "detection_threshold": threshold,
        "raw_candidate_count": len(raw_candidates),
    }
    return selected, stats


def write_clip(source_frames, params, start_frame, frame_count, output_path):
    channels = params.nchannels
    sample_width = params.sampwidth
    byte_start = start_frame * channels * sample_width
    byte_end = (start_frame + frame_count) * channels * sample_width
    clip_frames = source_frames[byte_start:byte_end]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(params.framerate)
        wav.writeframes(clip_frames)


def main():
    args = parse_args()
    source = Path(args.source)
    if not source.is_file():
        print(f"error: source WAV not found: {source}", file=sys.stderr)
        return 2

    params, source_frames, samples = read_pcm16_wav(source)
    frame_samples = max(1, int(round(params.framerate * args.frame_ms / 1000.0)))
    frame_seconds = frame_samples / params.framerate
    rms_values = build_rms_curve(
        samples,
        params.nchannels,
        params.framerate,
        frame_samples,
    )
    candidates, analysis_stats = detect_candidates(rms_values, frame_seconds, args)

    output_dir = Path(args.output_root) / slugify(args.style) / slugify(args.instrument)
    candidates_dir = output_dir / "candidates"
    target_entries = []

    total_source_frames = params.nframes
    window_frames = max(1, int(round(args.window_seconds * params.framerate)))
    pre_roll_frames = max(0, int(round(args.pre_roll_seconds * params.framerate)))

    for rank, candidate in enumerate(candidates):
        event_frame_index = candidate["event_frame"]
        event_source_frame = event_frame_index * frame_samples
        start_frame = max(0, event_source_frame - pre_roll_frames)
        if start_frame + window_frames > total_source_frames:
            start_frame = max(0, total_source_frames - window_frames)
        frame_count = min(window_frames, total_source_frames - start_frame)

        start_seconds = start_frame / params.framerate
        duration_seconds = frame_count / params.framerate
        start_label = f"{start_seconds:.3f}".replace(".", "p")
        name = f"target_{rank:03d}_{start_label}s.wav"
        output_path = candidates_dir / name
        write_clip(source_frames, params, start_frame, frame_count, output_path)

        target_entries.append(
            {
                "rank": rank,
                "id": f"target_{rank:03d}",
                "path": relative_path(output_path),
                "start_seconds": round(start_seconds, 6),
                "duration_seconds": round(duration_seconds, 6),
                "end_seconds": round(start_seconds + duration_seconds, 6),
                "event_seconds": round(event_source_frame / params.framerate, 6),
                "peak_seconds": round(
                    candidate["peak_frame"] * frame_seconds,
                    6,
                ),
                "onset_rms": round(candidate["onset_rms"], 8),
                "peak_rms": round(candidate["peak_rms"], 8),
                "background_rms": round(candidate["background_rms"], 8),
                "onset_delta": round(candidate["onset_delta"], 8),
                "candidate_rank_score": round(
                    candidate["candidate_rank_score"],
                    8,
                ),
                "selection_note": "energy_onset_candidate",
            }
        )

    manifest = {
        "meta": {
            "version": 1,
            "source_wav": relative_path(source),
            "style": args.style,
            "instrument": args.instrument,
            "sample_rate": params.framerate,
            "channels": params.nchannels,
            "sample_width_bytes": params.sampwidth,
            "duration_seconds": round(params.nframes / params.framerate, 6),
            "output_dir": relative_path(output_dir),
            "candidate_count_requested": args.count,
            "candidate_count_exported": len(target_entries),
            "window_seconds": args.window_seconds,
            "pre_roll_seconds": args.pre_roll_seconds,
            "min_gap_seconds": args.min_gap_seconds,
            "frame_ms": args.frame_ms,
            "threshold_ratio": args.threshold_ratio,
            "onset_ratio": args.onset_ratio,
            "min_rms": args.min_rms,
            "analysis_note": (
                "Candidates are real audio segments selected by simple energy "
                "onsets. These scores are only for picking clips to listen to; "
                "they are not generated-audio quality scores."
            ),
        },
        "analysis": {
            key: round(value, 8) for key, value in analysis_stats.items()
        },
        "targets": target_entries,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / "targets_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"source: {source}")
    print(f"wrote candidates: {candidates_dir}")
    print(f"wrote manifest: {manifest_path}")
    print(f"candidate_count: {len(target_entries)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
