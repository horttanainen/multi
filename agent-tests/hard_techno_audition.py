#!/usr/bin/env python3
"""Render techno listening comparisons through the existing music probe.

Run from any directory: python3 agent-tests/hard_techno_audition.py --phase 3
Phases 1/2 reproduce the kick/rumble and percussion comparisons. Phase 3 renders
the full arrangement at three seeds, verifies stems and ending, and cuts previews.
Requires the project's Zig toolchain and ffmpeg. Writes raw/stem WAVs, logs,
constant-gain loudness-matched copies and a JSON receipt to --output-dir.
The default destination is ignored scratch space. No game launch or downloads.
"""

import argparse
from array import array
from contextlib import ExitStack
import json
import math
import re
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_guitar_pluck_audition_pack import (  # noqa: E402
    SAMPLE_RATE,
    cue_for_index,
    write_wav,
)

FOUNDATIONS = [
    ("tight", 2.3, 0.28, 0.52, "foundation"),
    ("driving", 3.8, 0.42, 0.65, "foundation"),
    ("crushed", 6.0, 0.50, 0.72, "foundation"),
]
GROOVES = [(name, 2.3, 0.28, 0.52, name)
           for name in ("warehouse", "rolling", "machine")]


def run(command, log_path):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log_path}")
    return result.stdout + result.stderr


def loudness(path):
    output = run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-af",
         "loudnorm=I=-18:TP=-2:LRA=11:print_format=json", "-f", "null", "-"],
        path.with_suffix(".loudness.log"),
    )
    start, end = output.rfind("{"), output.rfind("}")
    measurement = json.loads(output[start:end + 1])
    integrated = float(measurement["input_i"])
    true_peak = float(measurement["input_tp"])
    if not math.isfinite(integrated) or not math.isfinite(true_peak):
        raise RuntimeError(f"Non-finite loudness measurement for {path}")
    return {"integrated_lufs": integrated, "true_peak_dbtp": true_peak}


def render(output_dir, name, drive, decay, rumble, groove, bus, duration, seed, arrangement="loop"):
    path = output_dir / f"{name}_{bus}_raw.wav"
    command = [
        "zig", "build", "procedural-music-probe", "-Doptimize=ReleaseFast", "--",
        "hard-techno", "--seed", str(seed), "--arrangement", arrangement,
        "--kick-drive", str(drive), "--kick-decay", str(decay),
        "--rumble", str(rumble), "--groove", groove,
        "--techno-bus", bus, "--out", str(path),
    ]
    if duration is not None:
        command.extend(["--duration", str(duration)])
    log = run(command, path.with_suffix(".render.log"))
    stats = [line for line in log.splitlines() if "techno_render:" in line]
    if len(stats) != 1:
        raise RuntimeError(f"Missing render diagnostics for {path}")
    print(stats[0], flush=True)
    sections = [{"name": match[0], "bar": int(match[1]), "frame": int(match[2]),
                 "seconds": float(match[3])} for match in re.findall(
        r"techno_section: name=(\w+) bar=(\d+) frame=(\d+) seconds=([\d.]+)", log)]
    return {
        "name": name, "bus": bus, "drive": drive, "decay": decay,
        "rumble": rumble, "groove": groove, "raw": str(path), "command": command,
        "render_stats": stats[0], "raw_loudness": loudness(path),
        "arrangement": arrangement, "sections": sections,
    }


def match_loudness(item, target, output_dir):
    gain = target - item["raw_loudness"]["integrated_lufs"]
    path = output_dir / f"{item['name']}_matched.wav"
    run(["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", item["raw"],
         "-af", f"volume={gain:.6f}dB", "-c:a", "pcm_s16le", str(path)],
        path.with_suffix(".gain.log"))
    measured = loudness(path)
    if abs(measured["integrated_lufs"] - target) > 0.15:
        raise RuntimeError(f"Loudness matching missed its target: {path}")
    if measured["true_peak_dbtp"] > -1.95:
        raise RuntimeError(f"Matched audio exceeds true-peak ceiling: {path}")
    item.update(matched=str(path), gain_db=gain, matched_loudness=measured)


def preview_pack(output_dir, clips, name):
    order, inputs, filters, segments = [], [], [], []
    position = 0.0
    for index, clip in enumerate(clips):
        cue = cue_for_index(index)
        cue_path = output_dir / f"cue_{index + 1}.wav"
        write_wav(cue_path, cue)
        inputs.extend(["-i", str(cue_path), "-i", clip["path"]])
        cue_label, music_label = f"cue{index}", f"music{index}"
        filters.append(f"[{index * 2}:a]aformat=sample_rates=48000:channel_layouts=stereo[{cue_label}]")
        filters.append(f"[{index * 2 + 1}:a]atrim=start_sample={clip['start_frame']}:"
                       f"end_sample={clip['end_frame']},asetpts=PTS-STARTPTS,"
                       f"apad=pad_dur=0.6,aformat=sample_rates=48000:channel_layouts=stereo[{music_label}]")
        segments.extend([f"[{cue_label}]", f"[{music_label}]"])
        duration = (clip["end_frame"] - clip["start_frame"]) / SAMPLE_RATE
        start = position + len(cue) / SAMPLE_RATE
        position = start + duration + 0.6
        order.append({"cue_beeps": index + 1, "name": clip["name"],
                      "start_seconds": start, "duration_seconds": duration,
                      "source_start_seconds": clip["start_frame"] / SAMPLE_RATE})
    path = output_dir / f"{name}.wav"
    filters.append("".join(segments) + f"concat=n={len(segments)}:v=0:a=1[out]")
    run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *inputs,
         "-filter_complex", ";".join(filters), "-map", "[out]", "-c:a", "pcm_s16le",
         str(path)], output_dir / f"{name}.log")
    return str(path), order


def pcm16(data):
    samples = array("h", data)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def verify_track(mix, stems):
    sections = mix["sections"]
    if [s["name"] for s in sections] != [
            "intro", "drive", "contrast", "pressure", "breakdown", "returning", "outro", "finished"]:
        raise RuntimeError("Incomplete or unexpected track section trace")
    for section in sections:
        if section["frame"] != section["bar"] * 76800:
            raise RuntimeError(f"Section is off the 150 BPM bar grid: {section}")
    if "kicks=480 " not in mix["render_stats"]:
        raise RuntimeError("Track did not preserve the intended kick count/break")
    max_error = 0
    with ExitStack() as stack:
        readers = [stack.enter_context(wave.open(item["raw"], "rb")) for item in [mix, *stems]]
        frames = readers[0].getnframes()
        for reader in readers:
            if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getnframes()) != (2, 2, SAMPLE_RATE, frames):
                raise RuntimeError("Track/stem WAV format mismatch")
        while True:
            blocks = [pcm16(reader.readframes(8192)) for reader in readers]
            if not blocks[0]:
                break
            if any(len(block) != len(blocks[0]) for block in blocks):
                raise RuntimeError("Track/stem WAV length mismatch")
            if stems:
                max_error = max(max_error, max(abs(values[0] - sum(values[1:])) for values in zip(*blocks)))
        if max_error > len(stems) + 1:
            raise RuntimeError(f"Track stems do not sum within PCM quantization: {max_error} LSB")
        reader = readers[0]
        finished = sections[-1]["frame"]
        if frames < finished + SAMPLE_RATE:
            raise RuntimeError("Track lacks the one-second ending check")
        reader.setpos(finished)
        if any(pcm16(reader.readframes(frames - finished))):
            raise RuntimeError("Track output continues after the arranged ending")
        jumps = []
        for section in sections[1:]:
            reader.setpos(section["frame"] - 1)
            samples = pcm16(reader.readframes(2))
            jump = max(abs(samples[2] - samples[0]), abs(samples[3] - samples[1])) / 32768.0
            if jump >= 0.03:
                raise RuntimeError(f"Discontinuity at section {section['name']}: {jump}")
            jumps.append({"section": section["name"], "sample_jump": jump})
    return {"stem_max_error_lsb": max_error if stems else None,
            "section_jumps": jumps, "ending_is_silent": True}


def track_audition(output_dir, seed):
    seeds = list(dict.fromkeys([seed, 54321, 98765, 314159]))[:3]
    mixes = [render(output_dir, f"track_seed_{value}", 2.3, 0.28, 0.52,
                    "warehouse", "mix", None, value, "track") for value in seeds]
    stems = [render(output_dir, "track", 2.3, 0.28, 0.52, "warehouse", bus,
                    None, seed, "track") for bus in ("low_end", "hats", "clap", "metal")]
    validation = [verify_track(item, stems if index == 0 else [])
                  for index, item in enumerate(mixes)]
    if any(item["sections"] != mixes[0]["sections"] for item in [*mixes[1:], *stems]):
        raise RuntimeError("Seed or bus selection changed the section timeline")
    target = min([-18.0] + [item["raw_loudness"]["integrated_lufs"] -
                           item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in mixes])
    for item in mixes:
        match_loudness(item, target, output_dir)
    # All excerpts retain the full track's single gain. The break stays quieter.
    timeline = {section["name"]: section["frame"] for section in mixes[0]["sections"]}
    clips = [
        {"name": "main_entry", "start_frame": timeline["drive"] - 2 * 76800,
         "end_frame": timeline["drive"] + 4 * 76800},
        {"name": "machine_contrast", "start_frame": timeline["contrast"] - 2 * 76800,
         "end_frame": timeline["contrast"] + 4 * 76800},
        {"name": "break_and_return", "start_frame": timeline["breakdown"] - 2 * 76800,
         "end_frame": timeline["returning"] + 4 * 76800},
        {"name": "ending", "start_frame": timeline["finished"] - 6 * 76800,
         "end_frame": timeline["finished"] + SAMPLE_RATE},
    ]
    for clip in clips:
        clip["path"] = mixes[0]["matched"]
    pack, order = preview_pack(output_dir, clips, "transitions")
    receipt = {"phase": 3, "bpm": 150, "bars": 128, "target_lufs": target,
               "mixes": mixes, "stems": stems, "validation": validation,
               "comparison": pack, "comparison_order": order,
               "note": "Full-track constant gain is preserved in transition previews. "
                       "Technical checks do not establish musical quality."}
    (output_dir / "audition.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Full track: {mixes[0]['matched']}")
    print(f"Transition previews: {pack}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", type=int, choices=(1, 2, 3), default=3)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--duration", type=float, help="clip length for phases 1/2 (default 25.6 seconds)")
    parser.add_argument("--seed", type=int, default=12345)
    args = parser.parse_args()
    if args.phase == 3 and args.duration is not None:
        parser.error("phase 3 renders the complete 128-bar arrangement; omit --duration")
    if args.duration is None:
        args.duration = 25.6
    if not math.isfinite(args.duration) or not 12.8 <= args.duration <= 120.0:
        parser.error("duration must be between 12.8 and 120 seconds")
    if not 0 < args.seed < 2**32:
        parser.error("seed must be a nonzero u32")
    destination = args.output_dir or ROOT / f"agent-temp-files/hard-techno/phase{args.phase}"
    output_dir = destination.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if args.phase == 3:
        return track_audition(output_dir, args.seed)
    candidates = FOUNDATIONS if args.phase == 1 else GROOVES
    mixes = [render(output_dir, *candidate, "mix", args.duration, args.seed)
             for candidate in candidates]
    buses = ("kick", "rumble") if args.phase == 1 else (
        "kick", "rumble", "low_end", "hats", "clap", "metal", "percussion")
    stems = [render(output_dir, *candidates[0], bus, args.duration, args.seed)
             for bus in buses]

    # Measure only with loudnorm; apply constant gain so the dynamics survive.
    # Lower the common target if any candidate would exceed -2 dB true peak.
    target = min([-18.0] + [
        item["raw_loudness"]["integrated_lufs"] -
        item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in mixes
    ])
    for item in mixes:
        match_loudness(item, target, output_dir)
    clips = [{"name": item["name"], "path": item["matched"],
              "start_frame": 0, "end_frame": 614400} for item in mixes]
    pack_path, order = preview_pack(output_dir, clips, "compare")
    receipt = {
        "phase": args.phase, "bpm": 150, "seed": args.seed, "duration": args.duration,
        "target_lufs": target, "mixes": mixes, "stems": stems,
        "comparison": str(pack_path), "comparison_order": order,
        "note": "Stems retain raw mix gain; matched mixes use constant gain. "
                "Measurements establish signal properties, not musical quality.",
    }
    (output_dir / "audition.json").write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Listening comparison: {pack_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
