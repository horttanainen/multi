#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/split_reference_stems.sh <reference_wav> [style_name]

Splits a fetched reference WAV into instrument stems and writes normalized WAVs to:
  artifacts/stems/<style_name>/

Backend:
  Demucs htdemucs_6s. This is fixed because the current pipeline is focused on
  guitar target extraction.

Environment overrides:
  OUTPUT_ROOT   default: artifacts/stems

Dependencies:
  ffmpeg is always required.
  demucs is required in the repo pyenv Python or as `demucs` on PATH.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg is not installed or not on PATH" >&2
  exit 2
fi

reference_wav="$1"
if [[ ! -f "$reference_wav" ]]; then
  echo "error: reference WAV not found: $reference_wav" >&2
  exit 2
fi

slugify() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

if [[ $# -eq 2 ]]; then
  style_name="$(slugify "$2")"
else
  base_name="$(basename -- "$reference_wav")"
  style_name="$(slugify "${base_name%.*}")"
fi
if [[ -z "$style_name" ]]; then
  style_name="reference"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
output_root="${OUTPUT_ROOT:-artifacts/stems}"
output_dir="$repo_root/$output_root/$style_name"
mkdir -p "$output_dir"

mix_wav="$output_dir/mix.wav"
echo "Normalizing mix: $mix_wav"
ffmpeg -y -hide_banner -loglevel error \
  -i "$reference_wav" \
  -ac 1 -ar 48000 -c:a pcm_s16le \
  "$mix_wav"

run_demucs() {
  local model="$1"
  local tmp_dir="$2"

  if command -v pyenv >/dev/null 2>&1; then
    if pyenv exec python3 -c 'import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("demucs") else 1)' >/dev/null 2>&1; then
      echo "Using Demucs from pyenv Python: $(pyenv exec python3 --version)"
      pyenv exec python3 -m demucs --out "$tmp_dir" --name "$model" "$mix_wav"
      return
    fi
  fi

  if command -v demucs >/dev/null 2>&1; then
    echo "Using Demucs command: $(command -v demucs)"
    demucs --out "$tmp_dir" --name "$model" "$mix_wav"
    return
  fi

  if python3 -c 'import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("demucs") else 1)' >/dev/null 2>&1; then
    echo "Using Demucs from system Python: $(python3 --version)"
    python3 -m demucs --out "$tmp_dir" --name "$model" "$mix_wav"
    return
  fi

  echo "error: Demucs is not installed" >&2
  if command -v pyenv >/dev/null 2>&1; then
    echo "pyenv version: $(pyenv version 2>/dev/null || true)" >&2
  fi
  echo "hint: install it for the repo Python, for example: pyenv exec python3 -m pip install demucs" >&2
  exit 2
}

normalize_stem() {
  local input="$1"
  local name="$2"
  local output="$output_dir/$name.wav"
  ffmpeg -y -hide_banner -loglevel error \
    -i "$input" \
    -ac 1 -ar 48000 -c:a pcm_s16le \
    "$output"
  echo "wrote: $output"
}

copy_demucs_stems() {
  local tmp_dir="$1"
  local stem_dir
  stem_dir="$(find "$tmp_dir" -type f -name 'drums.wav' -print -quit | xargs dirname)"
  if [[ -z "$stem_dir" || ! -d "$stem_dir" ]]; then
    echo "error: could not find Demucs stem directory under $tmp_dir" >&2
    exit 2
  fi

  local stems=(drums bass vocals other guitar piano)
  local stem
  for stem in "${stems[@]}"; do
    if [[ -f "$stem_dir/$stem.wav" ]]; then
      normalize_stem "$stem_dir/$stem.wav" "$stem"
    fi
  done
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/music_stems.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

model="htdemucs_6s"
echo "Splitting stems with Demucs model: $model"
run_demucs "$model" "$tmp_dir"
copy_demucs_stems "$tmp_dir"

if [[ ! -f "$output_dir/guitar.wav" ]]; then
  echo "error: Demucs did not produce guitar.wav with model $model" >&2
  exit 1
fi

cat > "$output_dir/stem_manifest.json" <<MANIFEST
{
  "style_name": "$style_name",
  "source_wav": "$reference_wav",
  "mix_wav": "$mix_wav",
  "backend": "demucs",
  "demucs_model": "$model",
  "output_dir": "$output_dir"
}
MANIFEST

echo "done: $output_dir"
echo "next: inspect stems, then extract isolated note/hit targets"
