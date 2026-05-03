#!/usr/bin/env python3
"""Random-search fit for guitar pluck probe parameters across a target set."""

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path


DEFAULT_TARGET_SET = (
    "artifacts/music_targets/americana_raga/guitar/selected/pluck_target_set.json"
)
DEFAULT_INSTRUMENT = "guitar-modal-pluck"
DEFAULT_RENDER_DIR = "artifacts/instrument_renders"
DEFAULT_REPORT_DIR = "artifacts/music_reports"
DEFAULT_PRESET_DIR = "artifacts/music_presets"
BASELINE_PARAMS = {
    "pluck_position": 0.175,
    "body_gain": 1.15,
}
SEARCH_SPACE = {
    "pluck_position": (0.115, 0.235),
    "pluck_brightness": (0.58, 1.0),
    "string_mix": (0.75, 1.75),
    "body_mix": (0.70, 1.70),
    "attack_mix": (0.55, 1.65),
    "mute": (0.0, 0.28),
    "string_decay": (0.62, 1.25),
    "body_gain": (0.90, 1.55),
    "body_decay": (0.62, 1.45),
    "body_freq": (0.86, 1.20),
    "pick_noise": (0.55, 1.55),
    "attack_gain": (0.55, 1.65),
    "attack_decay": (0.48, 1.55),
    "inharmonicity": (0.15, 2.40),
    "high_decay": (0.45, 1.55),
    "output_gain": (0.78, 1.24),
}


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Generate reproducible random guitar probe parameter candidates, "
            "score them across the validated target set, and write the best "
            "preset proposal."
        )
    )
    parser.add_argument("--round-id", required=True)
    parser.add_argument("--target-set", default=DEFAULT_TARGET_SET)
    parser.add_argument("--instrument", default=DEFAULT_INSTRUMENT)
    parser.add_argument("--samples", type=int, default=8)
    parser.add_argument("--seed", type=int, default=20260503)
    parser.add_argument("--precision", type=int, default=4)
    parser.add_argument("--render-dir", default=DEFAULT_RENDER_DIR)
    parser.add_argument("--report", default=None)
    parser.add_argument("--preset-output", default=None)
    parser.add_argument("--candidates-output", default=None)
    parser.add_argument(
        "--include-baseline",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="include the accepted baseline as candidate 0",
    )
    return parser.parse_args()


def repo_root():
    return Path(__file__).resolve().parents[1]


def report_path_for(args):
    if args.report:
        return args.report
    return str(Path(DEFAULT_REPORT_DIR) / f"{args.round_id}_compare.json")


def preset_path_for(args):
    if args.preset_output:
        return args.preset_output
    return str(Path(DEFAULT_PRESET_DIR) / f"{args.round_id}_best_guitar_pluck_params.json")


def candidates_path_for(args):
    if args.candidates_output:
        return args.candidates_output
    return str(Path(DEFAULT_PRESET_DIR) / f"{args.round_id}_candidates.json")


def rounded(value, precision):
    return round(value, precision)


def sample_params(rng, precision):
    return {
        key: rounded(rng.uniform(low, high), precision)
        for key, (low, high) in SEARCH_SPACE.items()
    }


def candidate_spec(name, instrument, params):
    parts = [f"name={name}", f"instrument={instrument}"]
    for key in sorted(params):
        parts.append(f"{key}={params[key]}")
    return ",".join(parts)


def build_candidates(args):
    rng = random.Random(args.seed)
    candidates = []
    if args.include_baseline:
        candidates.append(
            {
                "name": "baseline",
                "instrument": args.instrument,
                "params": dict(BASELINE_PARAMS),
                "source": "accepted_baseline",
            }
        )

    for index in range(args.samples):
        candidates.append(
            {
                "name": f"fit_{index:03d}",
                "instrument": args.instrument,
                "params": sample_params(rng, args.precision),
                "source": "seeded_random_search",
            }
        )
    return candidates


def write_json(root, path, data):
    output = root / path
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def run_round(root, args, candidates):
    command = [
        sys.executable,
        str(root / "scripts" / "run_guitar_pluck_round.py"),
        "--round-id",
        args.round_id,
        "--target-set",
        args.target_set,
        "--render-dir",
        args.render_dir,
        "--report",
        report_path_for(args),
    ]
    for candidate in candidates:
        command.extend(
            [
                "--candidate",
                candidate_spec(candidate["name"], candidate["instrument"], candidate["params"]),
            ]
        )

    result = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.returncode == 0:
        return
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    raise subprocess.CalledProcessError(result.returncode, command)


def load_report(root, path):
    return json.loads((root / path).read_text(encoding="utf-8"))


def best_entry(report):
    ranking = report.get("ranking", [])
    if not ranking:
        raise ValueError("optimizer report has no ranking entries")
    return ranking[0]


def params_by_name(candidates):
    return {candidate["name"]: candidate for candidate in candidates}


def write_best_preset(root, args, candidates, report):
    best = best_entry(report)
    candidates_by_name = params_by_name(candidates)
    candidate = candidates_by_name[best["name"]]
    preset = {
        "meta": {
            "version": 1,
            "purpose": "Best guitar pluck probe parameters from seeded random search.",
            "round_id": args.round_id,
            "seed": args.seed,
            "samples": args.samples,
            "target_set": args.target_set,
            "report": report_path_for(args),
            "promotion_rule": "listener confirms improvement before baseline promotion",
        },
        "candidate": {
            "name": best["name"],
            "instrument": best["instrument"],
            "source": candidate["source"],
            "score": best["score"],
            "min_score": best["min_score"],
            "max_score": best["max_score"],
            "loss": best["loss"],
        },
        "params": candidate["params"],
        "generated_wavs": best.get("generated_wavs", []),
        "target_results": best.get("target_results", []),
    }
    write_json(root, preset_path_for(args), preset)
    return preset


def main():
    args = parse_args()
    if args.samples < 0:
        print("error: --samples must be non-negative", file=sys.stderr)
        return 2

    root = repo_root()
    candidates = build_candidates(args)
    candidate_manifest = {
        "meta": {
            "version": 1,
            "round_id": args.round_id,
            "seed": args.seed,
            "samples": args.samples,
            "target_set": args.target_set,
            "search_space": SEARCH_SPACE,
        },
        "candidates": candidates,
    }
    write_json(root, candidates_path_for(args), candidate_manifest)
    run_round(root, args, candidates)
    report = load_report(root, report_path_for(args))
    preset = write_best_preset(root, args, candidates, report)

    best = preset["candidate"]
    print("optimizer_result")
    print(f"candidates={candidates_path_for(args)}")
    print(f"report={report_path_for(args)}")
    print(f"best_preset={preset_path_for(args)}")
    print(
        f"best={best['name']} score={best['score']:.4f} "
        f"min_score={best['min_score']:.4f} loss={best['loss']:.6f}"
    )
    print(f"promotion_rule={preset['meta']['promotion_rule']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
