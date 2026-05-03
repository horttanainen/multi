#!/usr/bin/env python3
"""Render and score one single-pluck guitar iteration round."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_TARGET = "artifacts/music_targets/americana_raga/guitar/selected/first_pluck.wav"
DEFAULT_PREVIOUS_WINNER = (
    "artifacts/instrument_renders/"
    "guitar_modal_pluck_iter3_level_pitch_estimate_g4.wav"
)
DEFAULT_INSTRUMENT = "guitar-modal-pluck"
DEFAULT_FREQ_HZ = "390.2439"
DEFAULT_VELOCITY = "0.8"
DEFAULT_DURATION = "0.22"
DEFAULT_PROBE_CANDIDATES = [
    "name=guitar_modal,instrument=guitar-modal",
    "name=guitar_contact_pick_modal,instrument=guitar-contact-pick-modal",
    "name=guitar_modal_pluck,instrument=guitar-modal-pluck",
    "name=guitar_two_pol_modal,instrument=guitar-two-pol-modal",
    "name=guitar_commuted,instrument=guitar-commuted",
    "name=guitar_sms_fit,instrument=guitar-sms-fit",
    "name=guitar_ks,instrument=guitar-ks",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Render candidate guitar plucks through music_probe, run the "
            "target scorer, and print concise paths for listener review."
        )
    )
    parser.add_argument("--round-id", required=True, help="round label for output files")
    parser.add_argument("--target", default=DEFAULT_TARGET, help="reference target WAV")
    parser.add_argument(
        "--previous-winner",
        default=DEFAULT_PREVIOUS_WINNER,
        help="last accepted winner WAV, included in scoring",
    )
    parser.add_argument(
        "--candidate",
        action="append",
        default=[],
        help=(
            "candidate spec; either a name or comma-separated key=value pairs. "
            "Supported keys: name,instrument,freq,note,velocity,duration,out. "
            "If omitted, renders the standard guitar probe suite."
        ),
    )
    parser.add_argument("--instrument", default=DEFAULT_INSTRUMENT)
    parser.add_argument("--freq", default=DEFAULT_FREQ_HZ)
    parser.add_argument("--note", default=None)
    parser.add_argument("--velocity", default=DEFAULT_VELOCITY)
    parser.add_argument("--duration", default=DEFAULT_DURATION)
    parser.add_argument(
        "--render-dir",
        default="artifacts/instrument_renders",
        help="directory for generated candidate WAVs",
    )
    parser.add_argument(
        "--report",
        default=None,
        help="JSON comparison report path; default derives from round id",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print only machine-readable JSON summary",
    )
    return parser.parse_args()


def repo_root():
    return Path(__file__).resolve().parents[1]


def slugify(value):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    slug = slug.strip("._-")
    if slug:
        return slug
    raise ValueError("candidate name becomes empty after sanitizing")


def parse_candidate_spec(spec, defaults, round_id):
    candidate = dict(defaults)
    candidate["name"] = spec

    if "=" in spec:
        candidate["name"] = None
        for raw_part in spec.split(","):
            part = raw_part.strip()
            if not part:
                continue
            if "=" not in part:
                raise ValueError(f"candidate field lacks '=': {part}")
            key, value = part.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key not in candidate and key != "out":
                raise ValueError(f"unsupported candidate key: {key}")
            if key == "note":
                candidate["freq"] = None
            if key == "freq" and value.lower() in {"", "none", "null"}:
                value = None
            candidate[key] = value

    if not candidate.get("name"):
        candidate["name"] = round_id

    if candidate.get("out") is None:
        name_slug = slugify(candidate["name"])
        candidate["out"] = str(Path(defaults["render_dir"]) / f"{round_id}_{name_slug}.wav")

    if not candidate.get("freq") and not candidate.get("note"):
        raise ValueError(f"candidate {candidate['name']} needs freq or note")

    return candidate


def default_candidates(args):
    if args.candidate:
        return args.candidate
    return DEFAULT_PROBE_CANDIDATES


def candidate_defaults(args):
    return {
        "name": None,
        "instrument": args.instrument,
        "freq": args.freq,
        "note": args.note,
        "velocity": args.velocity,
        "duration": args.duration,
        "out": None,
        "render_dir": args.render_dir,
    }


def render_candidate(root, candidate):
    command = [
        "zig",
        "build",
        "music-probe",
        "--",
        candidate["instrument"],
        "--velocity",
        candidate["velocity"],
        "--duration",
        candidate["duration"],
        "--out",
        candidate["out"],
    ]
    if candidate.get("freq"):
        command.extend(["--freq", candidate["freq"]])
    else:
        command.extend(["--note", candidate["note"]])

    run_quietly(root, command)


def run_scorer(root, target, generated_paths, report_path):
    command = [
        sys.executable,
        str(root / "scripts" / "compare_reference_target.py"),
        "--target",
        target,
        "--generated",
        *generated_paths,
        "--output",
        report_path,
    ]
    run_quietly(root, command)


def run_quietly(root, command):
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


def load_report(root, report_path):
    path = root / report_path
    return json.loads(path.read_text(encoding="utf-8"))


def report_path_for(args):
    if args.report:
        return args.report
    return str(Path("artifacts/music_reports") / f"{args.round_id}_compare.json")


def validate_inputs(root, target, previous_winner):
    target_path = root / target
    if not target_path.exists():
        raise FileNotFoundError(f"target WAV not found: {target}")

    previous_path = root / previous_winner
    if not previous_path.exists():
        raise FileNotFoundError(f"previous winner WAV not found: {previous_winner}")


def build_summary(args, candidates, report):
    generated = [candidate["out"] for candidate in candidates]
    ranking = [
        {
            "rank": index,
            "score": result["score"],
            "loss": result["loss"],
            "path": result["generated"],
        }
        for index, result in enumerate(report["results"], start=1)
    ]
    highest = ranking[0] if ranking else None
    return {
        "target": args.target,
        "previous_winner": args.previous_winner,
        "generated_wavs": generated,
        "report": report_path_for(args),
        "highest_scorer": highest["path"] if highest else None,
        "ranking": ranking,
        "promotion_rule": "listener confirms improvement and scorer agreement",
    }


def print_text_summary(summary):
    print("round_paths")
    print(f"target={summary['target']}")
    print(f"previous_winner={summary['previous_winner']}")
    print(f"report={summary['report']}")
    print("generated_wavs:")
    for path in summary["generated_wavs"]:
        print(f"- {path}")
    print("ranking:")
    for item in summary["ranking"]:
        print(
            f"{item['rank']}. score={item['score']:.4f} "
            f"loss={item['loss']:.6f} path={item['path']}"
        )
    print(f"highest_scorer={summary['highest_scorer']}")
    print(f"promotion_rule={summary['promotion_rule']}")


def main():
    args = parse_args()
    root = repo_root()
    validate_inputs(root, args.target, args.previous_winner)

    defaults = candidate_defaults(args)
    candidates = [
        parse_candidate_spec(spec, defaults, args.round_id)
        for spec in default_candidates(args)
    ]

    for candidate in candidates:
        render_candidate(root, candidate)

    generated_paths = [args.previous_winner] + [candidate["out"] for candidate in candidates]
    report_path = report_path_for(args)
    run_scorer(root, args.target, generated_paths, report_path)
    report = load_report(root, report_path)
    summary = build_summary(args, candidates, report)

    if args.json:
        print(json.dumps(summary, indent=2))
        return

    print_text_summary(summary)


if __name__ == "__main__":
    main()
