#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_reference_pipeline.sh <youtube_url> <style_name>

Runs the current reference pipeline:
  1. download and normalize reference audio
  2. split stems with Demucs htdemucs_6s

As new pipeline stages are added, call them from this script in order.

Environment overrides:
  REFERENCES_OUTPUT_ROOT  default: references
  STEMS_OUTPUT_ROOT       default: artifacts/stems
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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

style_slug="$(slugify "$style_name")"
if [[ -z "$style_slug" ]]; then
  echo "error: style_name produced an empty slug" >&2
  exit 2
fi

references_output_root="${REFERENCES_OUTPUT_ROOT:-references}"
reference_wav="$references_output_root/$style_slug.wav"

echo "stage 1/2: download reference audio"
OUTPUT="$reference_wav" "$script_dir/fetch_reference_wav.sh" "$youtube_url"

echo "stage 2/2: split stems"
OUTPUT_ROOT="${STEMS_OUTPUT_ROOT:-artifacts/stems}" \
  "$script_dir/split_reference_stems.sh" "$repo_root/$reference_wav" "$style_slug"

echo "done"
echo "reference_wav: $repo_root/$reference_wav"
echo "stems_dir: $repo_root/${STEMS_OUTPUT_ROOT:-artifacts/stems}/$style_slug"
