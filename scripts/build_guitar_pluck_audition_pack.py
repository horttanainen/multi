#!/usr/bin/env python3
"""Build listening WAV packs from a guitar pluck target-set comparison report."""

import argparse
import json
import math
import sys
import wave
from array import array
from pathlib import Path


SAMPLE_RATE = 48000
EPSILON = 1.0e-12


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Create concatenated WAVs that make target-set candidate comparison "
            "practical by ear."
        )
    )
    parser.add_argument(
        "--report",
        required=True,
        help="aggregate report from run_guitar_pluck_round.py --target-set",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="output directory; default derives from the report stem",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=5,
        help="number of ranked candidates to include",
    )
    parser.add_argument(
        "--gap",
        type=float,
        default=0.35,
        help="seconds of silence between clips",
    )
    parser.add_argument(
        "--section-gap",
        type=float,
        default=0.80,
        help="seconds of silence between larger sections",
    )
    parser.add_argument(
        "--rms",
        type=float,
        default=0.075,
        help="per-clip audition RMS target; use 0 to disable loudness normalization",
    )
    parser.add_argument(
        "--include-reference",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="include the real target before generated candidates in per-target packs",
    )
    return parser.parse_args()


def relative_path(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def read_pcm16_mono(path):
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        frames = wav.readframes(params.nframes)

    if params.comptype != "NONE":
        raise ValueError(f"compressed WAV is not supported: {params.comptype}")
    if params.sampwidth != 2:
        raise ValueError(
            f"expected PCM16 WAV, got sample width {params.sampwidth} bytes"
        )
    if params.framerate != SAMPLE_RATE:
        raise ValueError(
            f"expected {SAMPLE_RATE} Hz WAV, got {params.framerate}: {path}"
        )

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
    return mono


def rms(samples):
    if not samples:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def peak(samples):
    if not samples:
        return 0.0
    return max(abs(sample) for sample in samples)


def normalized_clip(samples, target_rms):
    if target_rms <= 0.0:
        return list(samples)

    value = rms(samples)
    if value <= EPSILON:
        return list(samples)

    gain = target_rms / value
    max_peak = peak(samples)
    if max_peak * gain > 0.92:
        gain = 0.92 / max_peak
    return [sample * gain for sample in samples]


def sine_tone(frequency_hz, duration_seconds, gain=0.08):
    count = int(round(SAMPLE_RATE * duration_seconds))
    return [
        math.sin(2.0 * math.pi * frequency_hz * index / SAMPLE_RATE) * gain
        for index in range(count)
    ]


def silence(duration_seconds):
    return [0.0 for _ in range(int(round(SAMPLE_RATE * duration_seconds)))]


def cue_for_index(index):
    result = []
    for _ in range(index + 1):
        result.extend(sine_tone(1760.0, 0.055, 0.055))
        result.extend(silence(0.045))
    result.extend(silence(0.08))
    return result


def write_wav(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = array("h")
    for sample in samples:
        clipped = max(-1.0, min(1.0, sample))
        pcm.append(int(round(clipped * 32767.0)))

    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm.tobytes())


def load_report(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def target_by_id(report):
    return {target["id"]: target for target in report.get("targets", [])}


def candidate_results_by_target(candidate):
    return {
        result["target_id"]: result
        for result in candidate.get("target_results", [])
    }


def top_candidates(report, limit):
    ranking = report.get("ranking", [])
    if limit <= 0:
        return ranking
    return ranking[:limit]


def default_output_dir(report_path):
    report = Path(report_path)
    stem = report.stem
    if stem.endswith("_compare"):
        stem = stem[: -len("_compare")]
    return Path("artifacts/instrument_renders") / f"{stem}_audition"


def build_per_target_pack(output_dir, target, candidates, args):
    samples = []
    notes = []
    if args.include_reference:
        samples.extend(cue_for_index(0))
        samples.extend(normalized_clip(read_pcm16_mono(target["path"]), args.rms))
        samples.extend(silence(args.section_gap))
        notes.append(
            {
                "cue": 1,
                "kind": "reference",
                "path": target["path"],
            }
        )

    cue_offset = 1 if args.include_reference else 0
    for index, candidate in enumerate(candidates):
        result = candidate_results_by_target(candidate).get(target["id"])
        if result is None:
            continue
        samples.extend(cue_for_index(index + cue_offset))
        samples.extend(normalized_clip(read_pcm16_mono(result["generated"]), args.rms))
        samples.extend(silence(args.gap))
        notes.append(
            {
                "cue": index + cue_offset + 1,
                "kind": "generated",
                "candidate": candidate["name"],
                "score": result["score"],
                "path": result["generated"],
            }
        )

    path = output_dir / f"by_target_{target['id']}.wav"
    write_wav(path, samples)
    return {
        "path": relative_path(path),
        "target_id": target["id"],
        "target_note": target.get("nearest_note", ""),
        "target_frequency_hz": target.get("frequency_hz"),
        "order": notes,
    }


def build_per_candidate_pack(output_dir, candidate, targets, args):
    results = candidate_results_by_target(candidate)
    samples = []
    notes = []
    for index, target in enumerate(targets):
        result = results.get(target["id"])
        if result is None:
            continue
        samples.extend(cue_for_index(index))
        samples.extend(normalized_clip(read_pcm16_mono(result["generated"]), args.rms))
        samples.extend(silence(args.gap))
        notes.append(
            {
                "cue": index + 1,
                "target_id": target["id"],
                "target_note": target.get("nearest_note", ""),
                "score": result["score"],
                "path": result["generated"],
            }
        )

    path = output_dir / f"by_candidate_{candidate['rank']:02d}_{candidate['name']}.wav"
    write_wav(path, samples)
    return {
        "path": relative_path(path),
        "candidate": candidate["name"],
        "rank": candidate["rank"],
        "avg_score": candidate["score"],
        "min_score": candidate["min_score"],
        "order": notes,
    }


def write_manifest(output_dir, report_path, target_packs, candidate_packs, args):
    manifest = {
        "meta": {
            "version": 1,
            "purpose": "Listening packs for comparing guitar pluck candidates by ear.",
            "source_report": relative_path(report_path),
            "rms_normalization": args.rms,
            "cue_note": (
                "Each clip is preceded by one or more short beeps. The cue "
                "number maps to the order list for that WAV."
            ),
        },
        "recommended_order": [
            "Start with by_candidate WAVs for whole-algorithm character.",
            "Use by_target WAVs to compare candidates on the same reference note.",
        ],
        "by_target": target_packs,
        "by_candidate": candidate_packs,
    }
    path = output_dir / "audition_manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return path


def main():
    args = parse_args()
    report_path = Path(args.report)
    if not report_path.is_file():
        print(f"error: report not found: {report_path}", file=sys.stderr)
        return 2

    report = load_report(report_path)
    targets = report.get("targets", [])
    candidates = top_candidates(report, args.top)
    output_dir = Path(args.output_dir) if args.output_dir else default_output_dir(report_path)

    target_packs = [
        build_per_target_pack(output_dir, target, candidates, args)
        for target in targets
    ]
    candidate_packs = [
        build_per_candidate_pack(output_dir, candidate, targets, args)
        for candidate in candidates
    ]
    manifest = write_manifest(output_dir, report_path, target_packs, candidate_packs, args)

    print(f"audition_dir={relative_path(output_dir)}")
    print(f"manifest={relative_path(manifest)}")
    print("candidate_packs:")
    for pack in candidate_packs:
        print(
            f"- rank={pack['rank']} avg={pack['avg_score']:.4f} "
            f"candidate={pack['candidate']} path={pack['path']}"
        )
    print("target_packs:")
    for pack in target_packs:
        print(
            f"- target={pack['target_id']} note={pack['target_note']} "
            f"path={pack['path']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
