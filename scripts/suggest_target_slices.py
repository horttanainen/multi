#!/usr/bin/env python3
"""Suggest tighter audition slices inside one extracted target candidate."""

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
        description="Suggest tighter real-audio slices inside a candidate WAV."
    )
    parser.add_argument("candidate", help="candidate WAV from extract_reference_targets.py")
    parser.add_argument(
        "--manifest",
        default=None,
        help="optional targets_manifest.json for absolute source timestamps",
    )
    parser.add_argument("--count", type=int, default=8, help="slice count")
    parser.add_argument(
        "--min-duration",
        type=float,
        default=0.22,
        help="minimum suggested slice duration in seconds",
    )
    parser.add_argument(
        "--max-duration",
        type=float,
        default=0.55,
        help="maximum suggested slice duration in seconds",
    )
    parser.add_argument(
        "--pre-roll",
        type=float,
        default=0.035,
        help="seconds before detected onset to include",
    )
    parser.add_argument(
        "--tail-threshold-ratio",
        type=float,
        default=0.34,
        help="slice tail ends when RMS decays below this fraction of peak",
    )
    parser.add_argument(
        "--min-gap",
        type=float,
        default=0.09,
        help="minimum spacing between suggested onsets in seconds",
    )
    parser.add_argument(
        "--frame-ms",
        type=float,
        default=5.0,
        help="analysis frame size in milliseconds",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="optional output directory",
    )
    return parser.parse_args()


def slugify(text):
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", text).strip("_")
    return slug or "slice"


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


def rms_for_range(samples, first, last):
    if last <= first:
        return 0.0
    total = 0.0
    count = last - first
    for sample in samples[first:last]:
        total += sample * sample
    return math.sqrt(total / count) / 32768.0


def build_rms_curve(samples, channels, sample_rate, frame_samples):
    values = []
    total_frames = len(samples) // channels
    for start_frame in range(0, total_frames, frame_samples):
        end_frame = min(total_frames, start_frame + frame_samples)
        first = start_frame * channels
        last = end_frame * channels
        values.append(rms_for_range(samples, first, last))
    return values


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


def default_output_dir(candidate_path):
    parent = candidate_path.parent
    if parent.name == "candidates":
        target_root = parent.parent
    else:
        target_root = parent
    return target_root / "suggestions" / candidate_path.stem


def find_manifest(candidate_path, explicit_manifest):
    if explicit_manifest:
        path = Path(explicit_manifest)
        return path if path.is_file() else None

    for parent in [candidate_path.parent, *candidate_path.parents]:
        manifest = parent / "targets_manifest.json"
        if manifest.is_file():
            return manifest
    return None


def load_candidate_meta(candidate_path, manifest_path):
    if manifest_path is None:
        return None

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    candidate_rel = relative_path(candidate_path)
    candidate_name = candidate_path.name
    for target in manifest.get("targets", []):
        target_path = str(target.get("path", ""))
        if target_path == candidate_rel or Path(target_path).name == candidate_name:
            return {
                "manifest_path": relative_path(manifest_path),
                "candidate_id": target.get("id"),
                "candidate_start_seconds": target.get("start_seconds"),
                "candidate_end_seconds": target.get("end_seconds"),
                "source_wav": manifest.get("meta", {}).get("source_wav"),
            }
    return {
        "manifest_path": relative_path(manifest_path),
        "candidate_id": None,
        "candidate_start_seconds": None,
        "candidate_end_seconds": None,
        "source_wav": manifest.get("meta", {}).get("source_wav"),
    }


def local_onset_candidates(rms_values, frame_seconds):
    if len(rms_values) < 3:
        return []

    median_rms = percentile(rms_values, 0.50)
    high_rms = percentile(rms_values, 0.92)
    threshold = median_rms + max(0.0, high_rms - median_rms) * 0.25
    background_frames = max(1, int(round(0.04 / frame_seconds)))
    peak_search_frames = max(1, int(round(0.08 / frame_seconds)))
    candidates = []

    for index in range(background_frames, len(rms_values)):
        background = mean(rms_values[index - background_frames : index])
        current = rms_values[index]
        previous = rms_values[index - 1]
        rise = current - background
        local_jump = current - previous
        if current < threshold or rise <= 0.0 or local_jump <= 0.0:
            continue
        if current < background * 1.08:
            continue

        search_end = min(len(rms_values), index + peak_search_frames)
        peak_frame = max(range(index, search_end), key=lambda pos: rms_values[pos])
        peak_rms = rms_values[peak_frame]
        score = rise + local_jump * 0.8 + peak_rms * 0.15
        candidates.append(
            {
                "onset_frame": index,
                "peak_frame": peak_frame,
                "background_rms": background,
                "onset_rms": current,
                "peak_rms": peak_rms,
                "rise_rms": rise,
                "local_jump_rms": local_jump,
                "score": score,
            }
        )

    return sorted(candidates, key=lambda item: item["score"], reverse=True)


def suggest_slices(rms_values, frame_seconds, args):
    raw_candidates = local_onset_candidates(rms_values, frame_seconds)
    min_gap_frames = max(1, int(round(args.min_gap / frame_seconds)))
    min_duration_frames = max(1, int(round(args.min_duration / frame_seconds)))
    max_duration_frames = max(min_duration_frames, int(round(args.max_duration / frame_seconds)))
    pre_roll_frames = max(0, int(round(args.pre_roll / frame_seconds)))

    selected = []
    for candidate in raw_candidates:
        onset_frame = candidate["onset_frame"]
        if any(abs(onset_frame - chosen["onset_frame"]) < min_gap_frames for chosen in selected):
            continue

        peak_rms = max(candidate["peak_rms"], candidate["onset_rms"])
        tail_threshold = max(
            percentile(rms_values, 0.50),
            peak_rms * args.tail_threshold_ratio,
        )
        start_frame = max(0, onset_frame - pre_roll_frames)
        min_end = min(len(rms_values), start_frame + min_duration_frames)
        max_end = min(len(rms_values), start_frame + max_duration_frames)
        if min_end - start_frame < min_duration_frames:
            continue

        end_frame = max_end
        for frame in range(max(min_end, candidate["peak_frame"] + 1), max_end):
            if rms_values[frame] <= tail_threshold:
                end_frame = frame
                break

        selected.append(
            {
                **candidate,
                "start_frame": start_frame,
                "end_frame": max(end_frame, min_end),
                "tail_threshold_rms": tail_threshold,
            }
        )
        if len(selected) >= args.count:
            break

    return selected, len(raw_candidates)


def write_clip(source_frames, params, start_frame, frame_count, output_path):
    channels = params.nchannels
    sample_width = params.sampwidth
    byte_start = start_frame * channels * sample_width
    byte_end = (start_frame + frame_count) * channels * sample_width
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(params.framerate)
        wav.writeframes(source_frames[byte_start:byte_end])


def clean_previous_slices(output_dir):
    if not output_dir.is_dir():
        return
    for path in output_dir.glob("slice_*.wav"):
        path.unlink()


def main():
    args = parse_args()
    candidate_path = Path(args.candidate)
    if not candidate_path.is_file():
        print(f"error: candidate WAV not found: {candidate_path}", file=sys.stderr)
        return 2

    params, source_frames, samples = read_pcm16_wav(candidate_path)
    frame_samples = max(1, int(round(params.framerate * args.frame_ms / 1000.0)))
    frame_seconds = frame_samples / params.framerate
    rms_values = build_rms_curve(
        samples,
        params.nchannels,
        params.framerate,
        frame_samples,
    )

    slices, raw_candidate_count = suggest_slices(rms_values, frame_seconds, args)
    output_dir = Path(args.output_dir) if args.output_dir else default_output_dir(candidate_path)
    clean_previous_slices(output_dir)
    manifest_path = find_manifest(candidate_path, args.manifest)
    candidate_meta = load_candidate_meta(candidate_path, manifest_path)
    candidate_start = None
    if candidate_meta is not None:
        candidate_start = candidate_meta.get("candidate_start_seconds")

    slice_entries = []
    for rank, suggestion in enumerate(slices):
        start_frame = suggestion["start_frame"] * frame_samples
        end_frame = min(params.nframes, suggestion["end_frame"] * frame_samples)
        frame_count = max(1, end_frame - start_frame)
        name = f"slice_{rank:03d}_{slugify(candidate_path.stem)}.wav"
        output_path = output_dir / name
        write_clip(source_frames, params, start_frame, frame_count, output_path)

        start_seconds_in_clip = start_frame / params.framerate
        duration_seconds = frame_count / params.framerate
        absolute_start = None
        if isinstance(candidate_start, (int, float)):
            absolute_start = candidate_start + start_seconds_in_clip

        entry = {
            "rank": rank,
            "id": f"slice_{rank:03d}",
            "path": relative_path(output_path),
            "source_candidate": relative_path(candidate_path),
            "start_seconds_in_clip": round(start_seconds_in_clip, 6),
            "duration_seconds": round(duration_seconds, 6),
            "end_seconds_in_clip": round(start_seconds_in_clip + duration_seconds, 6),
            "onset_seconds_in_clip": round(
                suggestion["onset_frame"] * frame_seconds,
                6,
            ),
            "peak_seconds_in_clip": round(
                suggestion["peak_frame"] * frame_seconds,
                6,
            ),
            "background_rms": round(suggestion["background_rms"], 8),
            "onset_rms": round(suggestion["onset_rms"], 8),
            "peak_rms": round(suggestion["peak_rms"], 8),
            "rise_rms": round(suggestion["rise_rms"], 8),
            "local_jump_rms": round(suggestion["local_jump_rms"], 8),
            "tail_threshold_rms": round(suggestion["tail_threshold_rms"], 8),
            "suggestion_score": round(suggestion["score"], 8),
            "reason": "strong_internal_energy_onset",
        }
        if absolute_start is not None:
            entry["absolute_start_seconds"] = round(absolute_start, 6)
            entry["absolute_end_seconds"] = round(absolute_start + duration_seconds, 6)
        slice_entries.append(entry)

    manifest = {
        "meta": {
            "version": 1,
            "candidate_wav": relative_path(candidate_path),
            "candidate_manifest": candidate_meta,
            "sample_rate": params.framerate,
            "channels": params.nchannels,
            "duration_seconds": round(params.nframes / params.framerate, 6),
            "output_dir": relative_path(output_dir),
            "slice_count_requested": args.count,
            "slice_count_exported": len(slice_entries),
            "raw_internal_onset_count": raw_candidate_count,
            "frame_ms": args.frame_ms,
            "min_duration": args.min_duration,
            "max_duration": args.max_duration,
            "pre_roll": args.pre_roll,
            "min_gap": args.min_gap,
            "analysis_note": (
                "Suggestions are tighter real-audio audition slices inside one "
                "candidate. They are not generated-audio quality scores."
            ),
        },
        "slices": slice_entries,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    output_manifest = output_dir / "slice_suggestions.json"
    output_manifest.write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"candidate: {candidate_path}")
    print(f"wrote slices: {output_dir}")
    print(f"wrote manifest: {output_manifest}")
    print(f"slice_count: {len(slice_entries)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
