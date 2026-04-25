#!/usr/bin/env python3
"""Register an auditioned real-audio slice as a stable reference target."""

import argparse
import json
import re
import shutil
import wave
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Copy a chosen slice into selected targets and record metadata."
    )
    parser.add_argument("--source", required=True, help="chosen slice WAV")
    parser.add_argument("--style", required=True, help="style/run name")
    parser.add_argument("--instrument", default="guitar", help="instrument name")
    parser.add_argument("--id", required=True, help="stable selected target id")
    parser.add_argument("--note", default="", help="human listening note")
    parser.add_argument(
        "--output-root",
        default="artifacts/music_targets",
        help="target output root",
    )
    return parser.parse_args()


def slugify(text):
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", text).strip("_")
    return slug or "target"


def relative_path(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def wav_info(path):
    with wave.open(str(path), "rb") as wav:
        return {
            "sample_rate": wav.getframerate(),
            "channels": wav.getnchannels(),
            "sample_width_bytes": wav.getsampwidth(),
            "duration_seconds": round(wav.getnframes() / wav.getframerate(), 6),
        }


def find_slice_manifest(source):
    for parent in [source.parent, *source.parents]:
        manifest = parent / "slice_suggestions.json"
        if manifest.is_file():
            return manifest
    return None


def find_slice_entry(source, manifest_path):
    if manifest_path is None:
        return None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source_rel = relative_path(source)
    source_name = source.name
    for entry in manifest.get("slices", []):
        entry_path = str(entry.get("path", ""))
        if entry_path == source_rel or Path(entry_path).name == source_name:
            result = dict(entry)
            result["slice_manifest"] = relative_path(manifest_path)
            candidate_manifest = manifest.get("meta", {}).get("candidate_manifest")
            if candidate_manifest:
                result["candidate_manifest"] = candidate_manifest
            return result
    return {
        "slice_manifest": relative_path(manifest_path),
    }


def load_selected_manifest(path):
    if not path.is_file():
        return {
            "meta": {
                "version": 1,
                "purpose": (
                    "Human-selected real-audio targets used for direct "
                    "generated-audio comparison."
                ),
            },
            "targets": [],
        }
    return json.loads(path.read_text(encoding="utf-8"))


def upsert_target(manifest, target):
    targets = manifest.setdefault("targets", [])
    for index, existing in enumerate(targets):
        if existing.get("id") == target["id"]:
            targets[index] = target
            return
    targets.append(target)


def main():
    args = parse_args()
    source = Path(args.source)
    if not source.is_file():
        print(f"error: source WAV not found: {source}")
        return 2

    style = slugify(args.style)
    instrument = slugify(args.instrument)
    target_id = slugify(args.id)
    selected_dir = Path(args.output_root) / style / instrument / "selected"
    selected_dir.mkdir(parents=True, exist_ok=True)

    destination = selected_dir / f"{target_id}.wav"
    shutil.copyfile(source, destination)

    slice_manifest = find_slice_manifest(source)
    slice_entry = find_slice_entry(source, slice_manifest)
    target = {
        "id": target_id,
        "path": relative_path(destination),
        "source_slice": relative_path(source),
        "note": args.note,
        "audio": wav_info(destination),
    }
    if slice_entry:
        target["source_metadata"] = slice_entry
        for key in [
            "absolute_start_seconds",
            "absolute_end_seconds",
            "start_seconds_in_clip",
            "end_seconds_in_clip",
            "duration_seconds",
        ]:
            if key in slice_entry:
                target[key] = slice_entry[key]

    manifest_path = selected_dir / "selected_targets.json"
    manifest = load_selected_manifest(manifest_path)
    manifest["meta"]["style"] = args.style
    manifest["meta"]["instrument"] = args.instrument
    manifest["meta"]["output_dir"] = relative_path(selected_dir)
    upsert_target(manifest, target)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"selected: {destination}")
    print(f"manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
