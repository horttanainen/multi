#!/bin/bash
set -m  # job control: background jobs get their own process group, enabling kill -- -$PID
# Smoke test: run the game, wait for the 5-second sentinel log line, then kill it.
zig build run > /tmp/game_run.log 2>&1 &
PID=$!
i=0
while [ $i -lt 150 ]; do
  sleep 0.1
  if grep -q "Ran successfully for 5 seconds" /tmp/game_run.log 2>/dev/null; then
    kill -- -$PID 2>/dev/null
    wait $PID 2>/dev/null
    break
  fi
  i=$(( i + 1 ))
done
kill -- -$PID 2>/dev/null
wait $PID 2>/dev/null
cat /tmp/game_run.log
