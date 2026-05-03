#!/usr/bin/env python3
"""Build one WAV for comparing event-level guitar phrase variants."""

import argparse
import json
import math
import sys
import wave
from array import array
from pathlib import Path


EPSILON = 1.0e-12


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Concatenate one reference phrase and generated event-phrase "
            "variants into a cue-beep audition WAV."
        )
    )
    parser.add_argument(
        "--manifest",
        action="append",
        required=True,
        help="event_phrase_manifest.json from render_guitar_event_phrase.py",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="output directory; default derives from the first manifest round",
    )
    parser.add_argument("--name", default="event_phrase_audition_pack")
    parser.add_argument("--rms", type=float, default=0.075)
    parser.add_argument("--gap", type=float, default=0.35)
    parser.add_argument("--section-gap", type=float, default=0.80)
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
    scale = 32768.0 * params.nchannels
    for index in range(0, len(samples), params.nchannels):
        total = 0
        for channel in range(params.nchannels):
            total += samples[index + channel]
        mono.append(total / scale)

    return {"sample_rate": params.framerate, "samples": mono}


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
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def normalize_for_audition(samples, target_rms):
    value = rms(samples)
    if value <= EPSILON or target_rms <= 0.0:
        return list(samples)
    peak = max((abs(sample) for sample in samples), default=0.0)
    scale = min(target_rms / value, 0.98 / (peak + EPSILON))
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


def load_manifests(paths):
    manifests = []
    for path in paths:
        manifest_path = Path(path)
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        data["_manifest_path"] = relative_path(manifest_path)
        manifests.append(data)
    return manifests


def output_dir_for(args, first_manifest):
    if args.output_dir:
        return Path(args.output_dir)
    round_id = first_manifest.get("meta", {}).get("round_id", "event_phrase")
    return Path("artifacts/event_phrase_renders") / f"{round_id}_comparison"


def append_section(output, cue, samples, sample_rate, gap, section_gap, target_rms):
    output.extend(cue_beeps(cue, sample_rate))
    output.extend(gap)
    output.extend(normalize_for_audition(samples, target_rms))
    output.extend(section_gap)


def main():
    args = parse_args()
    manifests = load_manifests(args.manifest)
    if not manifests:
        print("error: no manifests provided", file=sys.stderr)
        return 2

    first_meta = manifests[0].get("meta", {})
    reference_path = Path(first_meta["reference_phrase"])
    reference = read_pcm16_wav(reference_path)
    sample_rate = reference["sample_rate"]
    gap = [0.0 for _ in range(int(round(args.gap * sample_rate)))]
    section_gap = [0.0 for _ in range(int(round(args.section_gap * sample_rate)))]

    output = []
    order = []
    append_section(
        output,
        1,
        reference["samples"],
        sample_rate,
        gap,
        section_gap,
        args.rms,
    )
    order.append({"cue": 1, "kind": "reference", "path": relative_path(reference_path)})

    for index, manifest in enumerate(manifests, start=2):
        meta = manifest.get("meta", {})
        generated_path = Path(meta["generated_phrase"])
        generated = read_pcm16_wav(generated_path)
        if generated["sample_rate"] != sample_rate:
            raise ValueError(
                "sample rate differs: "
                f"{generated['sample_rate']} vs reference {sample_rate}"
            )
        append_section(
            output,
            index,
            generated["samples"],
            sample_rate,
            gap,
            section_gap,
            args.rms,
        )
        order.append(
            {
                "cue": index,
                "kind": "generated",
                "round_id": meta.get("round_id", ""),
                "score": meta.get("phrase_score"),
                "path": relative_path(generated_path),
                "manifest": manifest["_manifest_path"],
                "param_overrides": meta.get("param_overrides", {}),
                "velocity_mapping": meta.get("velocity_mapping", {}),
            }
        )

    output_dir = output_dir_for(args, manifests[0])
    output_path = output_dir / f"{args.name}.wav"
    manifest_path = output_dir / f"{args.name}.json"
    write_mono_pcm16_wav(output_path, output, sample_rate)
    manifest = {
        "meta": {
            "version": 1,
            "purpose": "Cue-beep audition pack for event-level guitar phrase variants.",
            "sample_rate": sample_rate,
            "rms_normalization": args.rms,
            "cue_note": "Cue 1 is the reference; cue 2+ are generated variants in the order listed.",
        },
        "order": order,
        "output_wav": relative_path(output_path),
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"audition_pack={relative_path(output_path)}")
    print(f"manifest={relative_path(manifest_path)}")
    for item in order:
        label = item.get("round_id", item["kind"])
        score = item.get("score")
        score_text = "" if score is None else f" score={score:.4f}"
        print(f"- cue={item['cue']} {item['kind']} {label}{score_text} path={item['path']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
