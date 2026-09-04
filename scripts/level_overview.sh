#!/bin/bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 LEVEL_JSON [OUTPUT_DIRECTORY]" >&2
  exit 2
fi

level_path=$1
output_directory=${2:-artifacts/level_overviews}

if [ ! -f "$level_path" ]; then
  echo "level overview: level file not found: $level_path" >&2
  exit 1
fi

level_filename=${level_path##*/}
level_name=${level_filename%.json}
overview_path="$output_directory/$level_name.png"
diagnostic_path="$output_directory/${level_name}_collision.png"

mkdir -p "$output_directory"

zig build run -- \
  --level-overview "$level_path" \
  --overview-output "$overview_path" \
  --overview-diagnostic-output "$diagnostic_path"

echo "level overview: $overview_path"
echo "level overview: $diagnostic_path"
