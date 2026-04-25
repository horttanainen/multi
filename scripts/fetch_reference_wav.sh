#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/fetch_reference_wav.sh <youtube_url>

Downloads audio using yt-dlp, then converts it to a predictable WAV container
without changing channel count or sample rate.

Optional env overrides:
  SECTION   optional yt-dlp --download-sections value (default: disabled)
  OUTPUT    default: references/<video_title>.wav
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "error: yt-dlp is not installed or not on PATH" >&2
  exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg is not installed or not on PATH" >&2
  exit 2
fi

url="$1"
section="${SECTION:-}"

if [ -z "${OUTPUT:-}" ]; then
  echo "Fetching video title..."
  raw_title="$(yt-dlp --print title "$url")"
  safe_title="$(printf '%s' "$raw_title" | sed 's/[^a-zA-Z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  if [ -z "$safe_title" ]; then
    safe_title="reference"
  fi
  output_rel="references/${safe_title}.wav"
else
  output_rel="$OUTPUT"
fi
output_path="$output_rel"

mkdir -p "$(dirname -- "$output_path")"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/m6_ref.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

echo "Downloading reference audio..."
yt_dlp_cmd=(
  yt-dlp "$url"
  -f bestaudio
  -o "$tmp_dir/source.%(ext)s"
)
if [ -n "$section" ]; then
  yt_dlp_cmd+=(--download-sections "$section")
  echo "Using section filter: $section"
fi
"${yt_dlp_cmd[@]}"

source_path="$(find "$tmp_dir" -maxdepth 1 -type f -name 'source.*' | head -n1)"
if [ -z "$source_path" ]; then
  echo "error: yt-dlp did not produce an audio file" >&2
  exit 2
fi

echo "Converting to PCM16 WAV without changing channels or sample rate..."
ffmpeg -y -hide_banner -loglevel error \
  -i "$source_path" \
  -c:a pcm_s16le \
  "$output_path"

echo "done: $output_path"
echo "next: scripts/split_reference_stems.sh \"$output_path\" <style_name>"
