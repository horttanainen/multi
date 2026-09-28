#!/bin/bash
# Blender is optional for normal game builds. Override BLENDER with its executable path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BLENDER_BIN="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
if [[ ! -x "$BLENDER_BIN" ]]; then
    BLENDER_BIN="${BLENDER:-$ROOT/agent-temp-files/blender-authoring/Blender.app/Contents/MacOS/Blender}"
fi
if [[ ! -x "$BLENDER_BIN" ]]; then
    BLENDER_BIN="$(command -v blender || true)"
fi
if [[ -z "$BLENDER_BIN" || ! -x "$BLENDER_BIN" ]]; then
    echo 'Blender 4.5 LTS is required. Set BLENDER to its executable path.' >&2
    exit 1
fi
COMMAND="${1:-help}"
SCENE="$ROOT/character_authoring/run.blend"
OUTPUT="$ROOT/artifacts/character_blender"
case "$COMMAND" in
    create)
        # Refuse to replace an edited workspace. Supply a new destination to re-bootstrap.
        "$BLENDER_BIN" --background --factory-startup --python-exit-code 1 \
            --python scripts/blender_character.py -- create "${2:-$SCENE}"
        ;;
    open)
        "$BLENDER_BIN" "$SCENE"
        ;;
    check|export)
        if [[ "${2:-}" != "" && "${2:-}" != "--apply" ]]; then
            echo 'Usage: bash scripts/character_blender.sh export [--apply]' >&2
            exit 1
        fi
        "$BLENDER_BIN" --background "$SCENE" --python-exit-code 1 \
            --python scripts/blender_character.py -- "$COMMAND" "$OUTPUT"
        zig build check-character-export -- "$OUTPUT"
        if [[ "$COMMAND" == check ]]; then
            for CASE in edited bezier linear step; do
                zig build check-character-export -- "$OUTPUT/$CASE"
            done
        fi
        if [[ "$COMMAND" == export && "${2:-}" == --apply ]]; then
            mkdir -p "$OUTPUT/before-apply"
            cp character_motions/run_reference.json "$OUTPUT/before-apply/run_reference.json"
            cp character_locomotion/run.json "$OUTPUT/before-apply/run.json"
            cp "$OUTPUT/run_reference.json" character_motions/run_reference.json
            cp "$OUTPUT/run.json" character_locomotion/run.json
            echo 'Applied validated motion and locomotion JSON. Previous files: artifacts/character_blender/before-apply/'
        else
            echo 'Validation passed. Game assets unchanged; export --apply publishes saved Blender edits.'
        fi
        ;;
    *)
        echo 'Usage: bash scripts/character_blender.sh {open|create [new.blend]|check|export [--apply]}'
        [[ "$COMMAND" == help ]]
        ;;
esac
