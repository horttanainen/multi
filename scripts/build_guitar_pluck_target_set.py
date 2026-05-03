#!/usr/bin/env python3
"""Build a validated multi-pluck guitar target set."""

import argparse
import json
import math
import re
import sys
import wave
from array import array
from pathlib import Path

import estimate_target_pitch as pitch


EPSILON = 1.0e-12
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Export fixed-length pluck targets from extracted guitar candidates, "
            "estimate pitch, reject weak/ambiguous targets, and write a target "
            "set manifest for multi-target scoring."
        )
    )
    parser.add_argument(
        "--candidate-manifest",
        default="artifacts/music_targets/americana_raga/guitar/targets_manifest.json",
        help="targets_manifest.json from extract_reference_targets.py",
    )
    parser.add_argument(
        "--selected-manifest",
        default="artifacts/music_targets/americana_raga/guitar/selected/selected_targets.json",
        help="optional existing selected_targets.json to seed the set",
    )
    parser.add_argument(
        "--output",
        default="artifacts/music_targets/americana_raga/guitar/selected/pluck_target_set.json",
        help="output target set manifest",
    )
    parser.add_argument(
        "--output-dir",
        default="artifacts/music_targets/americana_raga/guitar/selected/pluck_set",
        help="directory for exported target clips",
    )
    parser.add_argument("--target-count", type=int, default=6)
    parser.add_argument("--candidate-limit", type=int, default=16)
    parser.add_argument("--duration", type=float, default=0.22)
    parser.add_argument("--pre-roll", type=float, default=0.035)
    parser.add_argument("--pitch-start", type=float, default=0.035)
    parser.add_argument("--pitch-duration", type=float, default=0.145)
    parser.add_argument("--min-frequency", type=float, default=70.0)
    parser.add_argument("--max-frequency", type=float, default=700.0)
    parser.add_argument("--min-confidence", type=float, default=0.45)
    parser.add_argument("--min-methods", type=int, default=2)
    parser.add_argument(
        "--min-semitone-gap",
        type=float,
        default=1.0,
        help="preferred spacing between accepted target pitches; fallback fills if needed",
    )
    parser.add_argument(
        "--skip-selected",
        action="store_true",
        help="do not seed the set with existing human-selected targets",
    )
    return parser.parse_args()


def relative_path(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def slugify(text):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(text).strip())
    return slug.strip("._-") or "target"


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

    return params, frames, samples


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


def wav_info(path):
    with wave.open(str(path), "rb") as wav:
        return {
            "sample_rate": wav.getframerate(),
            "channels": wav.getnchannels(),
            "sample_width_bytes": wav.getsampwidth(),
            "duration_seconds": round(wav.getnframes() / wav.getframerate(), 6),
        }


def midi_for_frequency(frequency_hz):
    if frequency_hz <= EPSILON:
        return 0.0
    return 69.0 + 12.0 * math.log(frequency_hz / 440.0, 2.0)


def note_name_for_midi(midi_float):
    midi = int(round(midi_float))
    note = NOTE_NAMES[midi % 12]
    octave = midi // 12 - 1
    return f"{note}{octave}"


def semitone_distance(a_hz, b_hz):
    if a_hz <= EPSILON or b_hz <= EPSILON:
        return 99.0
    return abs(12.0 * math.log(a_hz / b_hz, 2.0))


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def pitch_report_for(path, args):
    audio = pitch.read_pcm16_wav(path)
    segment = pitch.analysis_segment(audio, args.pitch_start, args.pitch_duration)
    if len(segment) < 256:
        return {
            "combined_candidates": [],
            "methods": {},
            "analysis": {
                "error": "analysis segment too short",
                "duration_seconds": len(segment) / max(1, audio["sample_rate"]),
            },
        }

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


def pitch_validation(report, args):
    candidates = report.get("combined_candidates", [])
    if not candidates:
        return {
            "accepted": False,
            "reject_reason": "no pitch candidates",
            "confidence": 0.0,
        }

    top = candidates[0]
    top_score = float(top.get("score", 0.0))
    second_score = float(candidates[1].get("score", 0.0)) if len(candidates) > 1 else 0.0
    method_count = len(top.get("methods", []))
    margin_ratio = max(0.0, (top_score - second_score) / (top_score + EPSILON))
    method_ratio = min(1.0, method_count / 3.0)
    absolute_ratio = min(1.0, top_score / 2.0)
    confidence = method_ratio * 0.45 + margin_ratio * 0.35 + absolute_ratio * 0.20

    frequency_hz = float(top.get("frequency_hz", 0.0))
    accepted = True
    reject_reason = ""
    if method_count < args.min_methods:
        accepted = False
        reject_reason = f"only {method_count} pitch methods agreed"
    elif confidence < args.min_confidence:
        accepted = False
        reject_reason = f"pitch confidence {confidence:.3f} below threshold"
    elif frequency_hz < args.min_frequency or frequency_hz > args.max_frequency:
        accepted = False
        reject_reason = "pitch outside configured frequency range"

    midi = midi_for_frequency(frequency_hz)
    return {
        "accepted": accepted,
        "reject_reason": reject_reason,
        "frequency_hz": round(frequency_hz, 4),
        "midi": round(midi, 3),
        "nearest_note": note_name_for_midi(midi),
        "confidence": round(confidence, 4),
        "method_count": method_count,
        "score": round(top_score, 6),
        "score_margin": round(top_score - second_score, 6),
        "methods": top.get("methods", []),
        "alternates": candidates[1:5],
    }


def entry_from_selected(target, args):
    path = Path(target["path"])
    if not path.is_file():
        return None
    report = pitch_report_for(path, args)
    validation = pitch_validation(report, args)
    return {
        "id": target["id"],
        "path": relative_path(path),
        "source": "selected_target",
        "duration_seconds": target.get(
            "duration_seconds", target.get("audio", {}).get("duration_seconds")
        ),
        "absolute_start_seconds": target.get("absolute_start_seconds"),
        "absolute_end_seconds": target.get("absolute_end_seconds"),
        "audio": wav_info(path),
        "pitch": validation,
        "pitch_report": {
            "analysis": report.get("analysis", {}),
            "combined_candidates": report.get("combined_candidates", [])[:8],
        },
        "selection_note": target.get("note", ""),
    }


def export_candidate_clip(candidate, args, output_dir):
    candidate_path = Path(candidate["path"])
    params, source_frames, _ = read_pcm16_wav(candidate_path)
    event_offset_seconds = max(
        0.0,
        float(candidate.get("event_seconds", candidate.get("start_seconds", 0.0)))
        - float(candidate.get("start_seconds", 0.0)),
    )
    clip_start_seconds = max(0.0, event_offset_seconds - args.pre_roll)
    clip_start_frame = int(round(clip_start_seconds * params.framerate))
    frame_count = max(1, int(round(args.duration * params.framerate)))
    if clip_start_frame + frame_count > params.nframes:
        clip_start_frame = max(0, params.nframes - frame_count)

    target_id = f"pluck_{candidate.get('rank', 0):03d}_{slugify(candidate.get('id', 'target'))}"
    output_path = output_dir / f"{target_id}.wav"
    write_clip(source_frames, params, clip_start_frame, frame_count, output_path)

    absolute_start = float(candidate.get("start_seconds", 0.0)) + (
        clip_start_frame / params.framerate
    )
    report = pitch_report_for(output_path, args)
    validation = pitch_validation(report, args)
    return {
        "id": target_id,
        "path": relative_path(output_path),
        "source": "candidate_manifest",
        "source_candidate": candidate.get("path"),
        "candidate_id": candidate.get("id"),
        "candidate_rank": candidate.get("rank"),
        "duration_seconds": round(frame_count / params.framerate, 6),
        "absolute_start_seconds": round(absolute_start, 6),
        "absolute_end_seconds": round(absolute_start + frame_count / params.framerate, 6),
        "event_seconds": candidate.get("event_seconds"),
        "peak_seconds": candidate.get("peak_seconds"),
        "onset_rms": candidate.get("onset_rms"),
        "peak_rms": candidate.get("peak_rms"),
        "audio": wav_info(output_path),
        "pitch": validation,
        "pitch_report": {
            "analysis": report.get("analysis", {}),
            "combined_candidates": report.get("combined_candidates", [])[:8],
        },
    }


def select_targets(entries, args):
    accepted = [entry for entry in entries if entry["pitch"].get("accepted")]
    selected = []
    for entry in accepted:
        frequency = entry["pitch"]["frequency_hz"]
        if any(
            semitone_distance(frequency, chosen["pitch"]["frequency_hz"])
            < args.min_semitone_gap
            for chosen in selected
        ):
            continue
        selected.append(entry)
        if len(selected) >= args.target_count:
            return selected

    for entry in accepted:
        if entry in selected:
            continue
        entry = dict(entry)
        entry["selection_warning"] = "filled despite pitch proximity"
        selected.append(entry)
        if len(selected) >= args.target_count:
            break
    return selected


def main():
    args = parse_args()
    if args.target_count <= 0:
        print("error: --target-count must be positive", file=sys.stderr)
        return 2

    candidate_manifest_path = Path(args.candidate_manifest)
    if not candidate_manifest_path.is_file():
        print(f"error: candidate manifest not found: {candidate_manifest_path}", file=sys.stderr)
        return 2

    output = Path(args.output)
    output_dir = Path(args.output_dir)
    candidate_manifest = load_json(candidate_manifest_path)
    entries = []

    if not args.skip_selected:
        selected_manifest_path = Path(args.selected_manifest)
        if selected_manifest_path.is_file():
            selected_manifest = load_json(selected_manifest_path)
            for target in selected_manifest.get("targets", []):
                entry = entry_from_selected(target, args)
                if entry is not None:
                    entries.append(entry)

    candidates = candidate_manifest.get("targets", [])[: args.candidate_limit]
    for candidate in candidates:
        entries.append(export_candidate_clip(candidate, args, output_dir))

    targets = select_targets(entries, args)
    rejected = [entry for entry in entries if not entry["pitch"].get("accepted")]
    manifest = {
        "meta": {
            "version": 1,
            "purpose": (
                "Validated multi-pluck guitar target set for scoring generated "
                "single-note probe candidates across more than one real pluck."
            ),
            "candidate_manifest": relative_path(candidate_manifest_path),
            "selected_manifest": relative_path(args.selected_manifest),
            "output_dir": relative_path(output_dir),
            "target_count_requested": args.target_count,
            "target_count_selected": len(targets),
            "candidate_limit": args.candidate_limit,
            "clip_duration_seconds": args.duration,
            "pre_roll_seconds": args.pre_roll,
            "min_pitch_confidence": args.min_confidence,
            "min_pitch_methods": args.min_methods,
            "min_semitone_gap": args.min_semitone_gap,
        },
        "targets": targets,
        "rejected": rejected,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"target_set={relative_path(output)}")
    print(f"selected_count={len(targets)}")
    for target in targets:
        pitch_info = target["pitch"]
        print(
            f"- {target['id']} freq={pitch_info['frequency_hz']:.4f} "
            f"note={pitch_info['nearest_note']} confidence={pitch_info['confidence']:.3f} "
            f"path={target['path']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
