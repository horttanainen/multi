#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_reference_pipeline.sh <youtube_url> <style_name>

Runs the current reference pipeline:
  1. download and normalize reference audio
  2. split stems with Demucs htdemucs_6s
  3. extract guitar target candidates

As new pipeline stages are added, call them from this script in order.

Environment overrides:
  REFERENCES_OUTPUT_ROOT  default: references
  STEMS_OUTPUT_ROOT       default: artifacts/stems
  TARGETS_OUTPUT_ROOT     default: artifacts/music_targets
  SECTION                 optional yt-dlp --download-sections value
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

youtube_url="$1"
style_name="$2"

slugify() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

style_slug="$(slugify "$style_name")"
if [[ -z "$style_slug" ]]; then
  echo "error: style_name produced an empty slug" >&2
  exit 2
fi

references_output_root="${REFERENCES_OUTPUT_ROOT:-references}"
reference_wav="$references_output_root/$style_slug.wav"

echo "stage 1/3: download reference audio"
OUTPUT="$reference_wav" scripts/fetch_reference_wav.sh "$youtube_url"

echo "stage 2/3: split stems"
OUTPUT_ROOT="${STEMS_OUTPUT_ROOT:-artifacts/stems}" \
  scripts/split_reference_stems.sh "$reference_wav" "$style_slug"

echo "stage 3/3: extract guitar target candidates"
scripts/extract_reference_targets.py \
  --source "${STEMS_OUTPUT_ROOT:-artifacts/stems}/$style_slug/guitar.wav" \
  --style "$style_slug" \
  --instrument guitar \
  --output-root "${TARGETS_OUTPUT_ROOT:-artifacts/music_targets}"

echo "done"
echo "reference_wav: $reference_wav"
echo "stems_dir: ${STEMS_OUTPUT_ROOT:-artifacts/stems}/$style_slug"
echo "targets_dir: ${TARGETS_OUTPUT_ROOT:-artifacts/music_targets}/$style_slug/guitar"
