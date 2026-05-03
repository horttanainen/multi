#!/usr/bin/env python3
"""Render and score one single-pluck guitar iteration round."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_TARGET = "artifacts/music_targets/americana_raga/guitar/selected/first_pluck.wav"
DEFAULT_TARGET_SET = (
    "artifacts/music_targets/americana_raga/guitar/selected/pluck_target_set.json"
)
DEFAULT_PREVIOUS_WINNER = (
    "artifacts/instrument_renders/"
    "target_set_fit_pass1_scorer2_fit_001_first_pluck.wav"
)
DEFAULT_INSTRUMENT = "guitar-modal-pluck"
DEFAULT_FREQ_HZ = "390.2439"
DEFAULT_VELOCITY = "0.8"
DEFAULT_DURATION = "0.22"
DEFAULT_GUITAR_PARAMS = {
    "pluck_position": "0.1678",
    "pluck_brightness": "0.8165",
    "string_mix": "1.7309",
    "body_mix": "1.3536",
    "attack_mix": "0.8253",
    "mute": "0.114",
    "string_decay": "0.7765",
    "body_gain": "1.0442",
    "body_decay": "0.7817",
    "body_freq": "0.8752",
    "pick_noise": "0.6683",
    "attack_gain": "0.6903",
    "attack_decay": "0.5456",
    "inharmonicity": "0.4292",
    "high_decay": "0.6963",
    "output_gain": "0.9934",
}
DEFAULT_PROBE_CANDIDATES = [
    "name=guitar_modal,instrument=guitar-modal",
    "name=guitar_contact_pick_modal,instrument=guitar-contact-pick-modal",
    "name=guitar_modal_pluck,instrument=guitar-modal-pluck",
    "name=guitar_two_pol_modal,instrument=guitar-two-pol-modal",
    "name=guitar_commuted,instrument=guitar-commuted",
    "name=guitar_sms_fit,instrument=guitar-sms-fit",
    "name=guitar_ks,instrument=guitar-ks",
]
GUITAR_PARAM_OPTIONS = {
    "pluck_position": "--pluck-position",
    "pluck_brightness": "--pluck-brightness",
    "string_mix": "--string-mix",
    "body_mix": "--body-mix",
    "attack_mix": "--attack-mix",
    "mute": "--mute",
    "string_decay": "--string-decay",
    "body_gain": "--body-gain",
    "body_decay": "--body-decay",
    "body_freq": "--body-freq",
    "pick_noise": "--pick-noise",
    "attack_gain": "--attack-gain",
    "attack_decay": "--attack-decay",
    "bridge_coupling": "--bridge-coupling",
    "inharmonicity": "--inharmonicity",
    "high_decay": "--high-decay",
    "output_gain": "--output-gain",
}
SUPPORTED_CANDIDATE_KEYS = (
    ["name", "instrument", "freq", "note", "velocity", "duration", "out"]
    + list(GUITAR_PARAM_OPTIONS.keys())
)


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
        "--target-set",
        default=None,
        help=(
            "validated target set manifest; renders every candidate at every "
            "target pitch and ranks by average score"
        ),
    )
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
            "Supported keys: " + ",".join(SUPPORTED_CANDIDATE_KEYS) + ". "
            "If omitted, renders the standard guitar probe suite."
        ),
    )
    parser.add_argument("--instrument", default=DEFAULT_INSTRUMENT)
    parser.add_argument("--freq", default=DEFAULT_FREQ_HZ)
    parser.add_argument("--note", default=None)
    parser.add_argument("--velocity", default=DEFAULT_VELOCITY)
    parser.add_argument("--duration", default=DEFAULT_DURATION)
    for key, option in GUITAR_PARAM_OPTIONS.items():
        parser.add_argument(option, dest=key, default=DEFAULT_GUITAR_PARAMS.get(key))
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
            key = normalize_candidate_key(key)
            value = value.strip()
            if key not in candidate and key != "out":
                raise ValueError(f"unsupported candidate key: {key}")
            if key == "note":
                candidate["freq"] = None
            if value.lower() in {"", "none", "null"}:
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


def normalize_candidate_key(key):
    return key.strip().replace("-", "_")


def default_candidates(args):
    if args.candidate:
        return args.candidate
    return DEFAULT_PROBE_CANDIDATES


def candidate_defaults(args):
    defaults = {
        "name": None,
        "instrument": args.instrument,
        "freq": args.freq,
        "note": args.note,
        "velocity": args.velocity,
        "duration": args.duration,
        "out": None,
        "render_dir": args.render_dir,
    }
    for key in GUITAR_PARAM_OPTIONS:
        defaults[key] = getattr(args, key)
    return defaults


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

    for key, option in GUITAR_PARAM_OPTIONS.items():
        value = candidate.get(key)
        if value is None:
            continue
        command.extend([option, value])

    run_quietly(root, command)


def target_set_render_candidate(candidate, target, round_id, render_dir):
    result = dict(candidate)
    name_slug = slugify(result["name"])
    target_slug = slugify(target["id"])
    result["freq"] = f"{target['frequency_hz']:.4f}"
    result["note"] = None
    result["duration"] = f"{target['duration_seconds']:.6f}"
    result["out"] = str(Path(render_dir) / f"{round_id}_{name_slug}_{target_slug}.wav")
    return result


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


def load_target_set(root, target_set_path):
    manifest_path = root / target_set_path
    if not manifest_path.exists():
        raise FileNotFoundError(f"target set manifest not found: {target_set_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    targets = []
    for entry in manifest.get("targets", []):
        target = normalized_target_entry(root, entry)
        if target is None:
            continue
        targets.append(target)

    if not targets:
        raise ValueError(f"target set has no accepted targets: {target_set_path}")

    return manifest, targets


def normalized_target_entry(root, entry):
    path = entry.get("path")
    pitch = entry.get("pitch", {})
    if not path or not pitch.get("accepted"):
        return None

    target_path = root / path
    if not target_path.exists():
        raise FileNotFoundError(f"target WAV not found: {path}")

    frequency_hz = pitch.get("frequency_hz")
    if frequency_hz is None:
        raise ValueError(f"target {entry.get('id')} has no pitch frequency")

    duration = entry.get("duration_seconds")
    if duration is None:
        duration = entry.get("audio", {}).get("duration_seconds")
    if duration is None:
        raise ValueError(f"target {entry.get('id')} has no duration")

    return {
        "id": entry.get("id", Path(path).stem),
        "path": path,
        "frequency_hz": float(frequency_hz),
        "duration_seconds": float(duration),
        "nearest_note": pitch.get("nearest_note", ""),
        "confidence": pitch.get("confidence", 0.0),
        "absolute_start_seconds": entry.get("absolute_start_seconds"),
    }


def aggregate_report_path(args, target_id):
    report = Path(report_path_for(args))
    stem = report.stem
    if stem.endswith("_compare"):
        stem = stem[: -len("_compare")]
    return str(report.with_name(f"{stem}_{slugify(target_id)}_compare.json"))


def write_json_report(root, report_path, report):
    path = root / report_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


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


def validate_single_target_inputs(root, args):
    validate_inputs(root, args.target, args.previous_winner)


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


def run_target_set_round(root, args, candidates):
    target_set_manifest, targets = load_target_set(root, args.target_set)
    per_candidate = {
        candidate["name"]: {
            "name": candidate["name"],
            "instrument": candidate["instrument"],
            "generated_wavs": [],
            "target_results": [],
        }
        for candidate in candidates
    }
    per_target_reports = []

    for target in targets:
        rendered = []
        path_to_name = {}
        for candidate in candidates:
            target_candidate = target_set_render_candidate(
                candidate,
                target,
                args.round_id,
                candidate["render_dir"],
            )
            render_candidate(root, target_candidate)
            rendered.append(target_candidate)
            path_to_name[target_candidate["out"]] = candidate["name"]
            per_candidate[candidate["name"]]["generated_wavs"].append(
                target_candidate["out"]
            )

        generated_paths = [candidate["out"] for candidate in rendered]
        target_report_path = aggregate_report_path(args, target["id"])
        run_scorer(root, target["path"], generated_paths, target_report_path)
        target_report = load_report(root, target_report_path)
        per_target_reports.append(
            {
                "target_id": target["id"],
                "target_path": target["path"],
                "report": target_report_path,
            }
        )

        for result in target_report["results"]:
            candidate_name = path_to_name[result["generated"]]
            per_candidate[candidate_name]["target_results"].append(
                {
                    "target_id": target["id"],
                    "target_path": target["path"],
                    "generated": result["generated"],
                    "score": result["score"],
                    "loss": result["loss"],
                    "component_losses": result.get("component_losses", {}),
                }
            )

    ranking = target_set_ranking(per_candidate.values())
    report = {
        "meta": {
            "version": 1,
            "purpose": "Aggregate candidate ranking across a validated guitar pluck target set.",
            "round_id": args.round_id,
            "target_set": args.target_set,
            "source_target_set_version": target_set_manifest.get("meta", {}).get("version"),
            "promotion_rule": "listener confirms improvement and scorer agreement",
        },
        "targets": targets,
        "per_target_reports": per_target_reports,
        "ranking": ranking,
    }
    write_json_report(root, report_path_for(args), report)
    return target_set_summary(args, report)


def target_set_ranking(candidate_entries):
    ranking = []
    for entry in candidate_entries:
        scores = [result["score"] for result in entry["target_results"]]
        losses = [result["loss"] for result in entry["target_results"]]
        if not scores:
            continue
        ranking.append(
            {
                "name": entry["name"],
                "instrument": entry["instrument"],
                "score": round(sum(scores) / len(scores), 4),
                "min_score": round(min(scores), 4),
                "max_score": round(max(scores), 4),
                "loss": round(sum(losses) / len(losses), 6),
                "target_count": len(scores),
                "generated_wavs": entry["generated_wavs"],
                "target_results": sorted(
                    entry["target_results"],
                    key=lambda item: item["target_id"],
                ),
            }
        )

    ranking.sort(key=lambda item: item["score"], reverse=True)
    for index, item in enumerate(ranking, start=1):
        item["rank"] = index
    return ranking


def target_set_summary(args, report):
    ranking = report["ranking"]
    highest = ranking[0] if ranking else None
    return {
        "target_set": args.target_set,
        "targets": report["targets"],
        "report": report_path_for(args),
        "per_target_reports": report["per_target_reports"],
        "highest_scorer": highest["name"] if highest else None,
        "ranking": [
            {
                "rank": item["rank"],
                "score": item["score"],
                "min_score": item["min_score"],
                "loss": item["loss"],
                "name": item["name"],
                "instrument": item["instrument"],
            }
            for item in ranking
        ],
        "promotion_rule": "listener confirms improvement and scorer agreement",
    }


def print_text_summary(summary):
    if "target_set" in summary:
        print_target_set_summary(summary)
        return

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


def print_target_set_summary(summary):
    print("target_set_round")
    print(f"target_set={summary['target_set']}")
    print(f"report={summary['report']}")
    print("targets:")
    for target in summary["targets"]:
        print(
            f"- {target['id']} freq={target['frequency_hz']:.4f} "
            f"note={target['nearest_note']} path={target['path']}"
        )
    print("per_target_reports:")
    for report in summary["per_target_reports"]:
        print(f"- {report['target_id']}: {report['report']}")
    print("ranking:")
    for item in summary["ranking"]:
        print(
            f"{item['rank']}. avg_score={item['score']:.4f} "
            f"min_score={item['min_score']:.4f} avg_loss={item['loss']:.6f} "
            f"name={item['name']} instrument={item['instrument']}"
        )
    print(f"highest_scorer={summary['highest_scorer']}")
    print(f"promotion_rule={summary['promotion_rule']}")


def main():
    args = parse_args()
    root = repo_root()

    defaults = candidate_defaults(args)
    candidates = [
        parse_candidate_spec(spec, defaults, args.round_id)
        for spec in default_candidates(args)
    ]

    if args.target_set:
        summary = run_target_set_round(root, args, candidates)
        if args.json:
            print(json.dumps(summary, indent=2))
            return

        print_text_summary(summary)
        return

    validate_single_target_inputs(root, args)

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
