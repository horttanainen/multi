#!/usr/bin/env python3
"""Render techno listening comparisons through the existing music probe.

Run from any directory: python3 agent-tests/hard_techno_audition.py --phase 2
Use --phase 1 to reproduce the original kick/rumble comparison.
Requires the project's Zig toolchain and ffmpeg. Writes raw/stem WAVs, logs,
constant-gain loudness-matched copies and a JSON receipt to --output-dir.
The default destination is ignored scratch space. No game launch or downloads.
"""

import argparse
import json
import math
import subprocess
import sys
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


def render(output_dir, name, drive, decay, rumble, groove, bus, duration, seed):
    path = output_dir / f"{name}_{bus}_raw.wav"
    command = [
        "zig", "build", "procedural-music-probe", "-Doptimize=ReleaseFast", "--",
        "hard-techno", "--duration", str(duration), "--seed", str(seed),
        "--kick-drive", str(drive), "--kick-decay", str(decay),
        "--rumble", str(rumble), "--groove", groove,
        "--techno-bus", bus, "--out", str(path),
    ]
    log = run(command, path.with_suffix(".render.log"))
    stats = [line for line in log.splitlines() if "techno_render:" in line]
    if len(stats) != 1:
        raise RuntimeError(f"Missing render diagnostics for {path}")
    print(stats[0], flush=True)
    return {
        "name": name, "bus": bus, "drive": drive, "decay": decay,
        "rumble": rumble, "groove": groove, "raw": str(path), "command": command,
        "render_stats": stats[0], "raw_loudness": loudness(path),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", type=int, choices=(1, 2), default=2)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--duration", type=float, default=25.6)
    parser.add_argument("--seed", type=int, default=12345)
    args = parser.parse_args()
    if not math.isfinite(args.duration) or not 12.8 <= args.duration <= 120.0:
        parser.error("duration must be between 12.8 and 120 seconds")
    if not 0 < args.seed < 2**32:
        parser.error("seed must be a nonzero u32")
    destination = args.output_dir or ROOT / f"agent-temp-files/hard-techno/phase{args.phase}"
    output_dir = destination.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
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
    order, inputs, filters, segments = [], [], [], []
    position = 0.0
    for index, item in enumerate(mixes):
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
        cue = cue_for_index(index)
        cue_path = output_dir / f"cue_{index + 1}.wav"
        write_wav(cue_path, cue)
        inputs.extend(["-i", str(cue_path), "-i", str(path)])
        # Preserve stereo in the comparison as well as the individual clips.
        cue_label, music_label = f"cue{index}", f"music{index}"
        filters.append(f"[{index * 2}:a]aformat=sample_rates=48000:channel_layouts=stereo[{cue_label}]")
        filters.append(f"[{index * 2 + 1}:a]atrim=duration=12.8,asetpts=PTS-STARTPTS,"
                       f"apad=pad_dur=0.6,aformat=sample_rates=48000:channel_layouts=stereo[{music_label}]")
        segments.extend([f"[{cue_label}]", f"[{music_label}]"])
        start = position + len(cue) / SAMPLE_RATE
        position = start + 12.8 + 0.6
        order.append({"cue_beeps": index + 1, "name": item["name"],
                      "start_seconds": start, "duration_seconds": 12.8})
    pack_path = output_dir / "compare.wav"
    filters.append("".join(segments) + f"concat=n={len(segments)}:v=0:a=1[out]")
    run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *inputs,
         "-filter_complex", ";".join(filters), "-map", "[out]", "-c:a", "pcm_s16le",
         str(pack_path)], output_dir / "compare.log")
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
