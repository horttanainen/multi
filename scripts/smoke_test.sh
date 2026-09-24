#!/bin/bash
set -m  # job control: background jobs get their own process group, enabling kill -- -$PID
# Smoke test: run the game, wait for the 5-second sentinel log line, then kill it.
# Keep concurrent worktree runs separate; callers may override the destination.
SMOKE_LOG_PATH="${SMOKE_LOG_PATH:-agent-temp-files/smoke_test.log}"
mkdir -p "$(dirname "$SMOKE_LOG_PATH")" || exit 1
zig build run -- "$@" > "$SMOKE_LOG_PATH" 2>&1 &
PID=$!
i=0
while [ $i -lt 150 ]; do
  sleep 0.1
  if grep -q "Ran successfully for 5 seconds" "$SMOKE_LOG_PATH" 2>/dev/null; then
    kill -- -$PID 2>/dev/null
    wait $PID 2>/dev/null
    break
  fi
  i=$(( i + 1 ))
done
kill -- -$PID 2>/dev/null
wait $PID 2>/dev/null
cat "$SMOKE_LOG_PATH"
