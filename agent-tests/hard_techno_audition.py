#!/usr/bin/env python3
"""Render Phase 1 listening comparisons through the existing music probe.

Run from any directory: python3 agent-tests/hard_techno_audition.py
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
    read_pcm16_mono,
    silence,
    write_wav,
)

CANDIDATES = [
    ("tight", 2.3, 0.28, 0.52),
    ("driving", 3.8, 0.42, 0.65),
    ("crushed", 6.0, 0.50, 0.72),
]


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


def render(output_dir, name, drive, decay, rumble, bus, duration, seed):
    path = output_dir / f"{name}_{bus}_raw.wav"
    command = [
        "zig", "build", "procedural-music-probe", "-Doptimize=ReleaseFast", "--",
        "hard-techno", "--duration", str(duration), "--seed", str(seed),
        "--kick-drive", str(drive), "--kick-decay", str(decay),
        "--rumble", str(rumble), "--techno-bus", bus, "--out", str(path),
    ]
    log = run(command, path.with_suffix(".render.log"))
    stats = [line for line in log.splitlines() if "techno_render:" in line]
    if len(stats) != 1:
        raise RuntimeError(f"Missing render diagnostics for {path}")
    print(stats[0], flush=True)
    return {
        "name": name, "bus": bus, "drive": drive, "decay": decay,
        "rumble": rumble, "raw": str(path), "command": command,
        "render_stats": stats[0], "raw_loudness": loudness(path),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path,
                        default=ROOT / "agent-temp-files/hard-techno/phase1")
    parser.add_argument("--duration", type=float, default=25.6)
    parser.add_argument("--seed", type=int, default=12345)
    args = parser.parse_args()
    if not math.isfinite(args.duration) or not 12.8 <= args.duration <= 120.0:
        parser.error("duration must be between 12.8 and 120 seconds")
    if not 0 < args.seed < 2**32:
        parser.error("seed must be a nonzero u32")
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    mixes = [render(output_dir, *candidate, "mix", args.duration, args.seed)
             for candidate in CANDIDATES]
    # The user selected the first (tight) candidate after listening.
    stems = [render(output_dir, *CANDIDATES[0], bus, args.duration, args.seed)
             for bus in ("kick", "rumble")]

    # Measure only with loudnorm; apply constant gain so the dynamics survive.
    # Lower the common target if any candidate would exceed -2 dB true peak.
    target = min([-18.0] + [
        item["raw_loudness"]["integrated_lufs"] -
        item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in mixes
    ])
    pack, order = [], []
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
        pack.extend(cue_for_index(index))
        start = len(pack) / SAMPLE_RATE
        # First eight bars, including the rumble building from a cold reset.
        pack.extend(read_pcm16_mono(path)[:int(12.8 * SAMPLE_RATE)])
        pack.extend(silence(0.6))
        order.append({"cue_beeps": index + 1, "name": item["name"],
                      "start_seconds": start, "duration_seconds": 12.8})
    pack_path = output_dir / "compare.wav"
    write_wav(pack_path, pack)
    receipt = {
        "bpm": 150, "seed": args.seed, "duration": args.duration,
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
