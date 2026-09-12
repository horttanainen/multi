#!/bin/bash
# Phase-one validation. Use --unit-only while working on the solver/assets.
# Extra arguments after -- are passed to the existing game smoke-test script.
set -euo pipefail

CHARACTER_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$CHARACTER_REPO_ROOT"

CHARACTER_UNIT_ONLY=false
if [[ "${1:-}" == "--unit-only" ]]; then
  CHARACTER_UNIT_ONLY=true
  shift
fi
if [[ "${1:-}" == "--" ]]; then
  shift
elif [[ $# -gt 0 ]]; then
  echo "Usage: bash scripts/character_animation_check.sh [--unit-only] [-- game arguments]" >&2
  exit 2
fi

CHARACTER_LOG_DIR="$CHARACTER_REPO_ROOT/artifacts/character_animation"
mkdir -p "$CHARACTER_LOG_DIR"

echo "Formatting project sources"
bash scripts/format.sh

echo "Checking character assets, curves, IK, and lifecycle"
zig build test-character-animation --summary new 2>&1 | tee "$CHARACTER_LOG_DIR/tests.log"

if [[ "$CHARACTER_UNIT_ONLY" == true ]]; then
  echo "Character animation unit checks passed"
  exit 0
fi

echo "Building the game"
zig build 2>&1 | tee "$CHARACTER_LOG_DIR/build.log"

echo "Running the five-second character animation smoke test"
CHARACTER_DEFAULT_CAPTURE=false
if [[ $# -eq 0 ]]; then
  CHARACTER_DEFAULT_CAPTURE=true
  bash scripts/smoke_test.sh --character-animation --character-animation-close \
    --character-animation-capture "$CHARACTER_LOG_DIR/phase1.png" 2>&1 | tee "$CHARACTER_LOG_DIR/smoke.log"
else
  bash scripts/smoke_test.sh "$@" 2>&1 | tee "$CHARACTER_LOG_DIR/smoke.log"
fi

if ! grep -Fq 'info: Ran successfully for 5 seconds' "$CHARACTER_LOG_DIR/smoke.log"; then
  echo "Smoke test failed: the five-second success marker was not logged" >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(error:|warn:|panic:|thread .* panic)' "$CHARACTER_LOG_DIR/smoke.log"; then
  echo "Smoke test logged a warning, error, or panic; inspect $CHARACTER_LOG_DIR/smoke.log" >&2
  exit 1
fi
if [[ "$CHARACTER_DEFAULT_CAPTURE" == true ]] && ! grep -Fq "info: character_animation: captured $CHARACTER_LOG_DIR/phase1.png" "$CHARACTER_LOG_DIR/smoke.log"; then
  echo "Smoke test failed: the character review image was not captured" >&2
  exit 1
fi

echo "Character animation checks passed; logs are in $CHARACTER_LOG_DIR"
