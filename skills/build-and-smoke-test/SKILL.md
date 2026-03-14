---
name: build-and-smoke-test
description: Run this skill automatically after finishing any task that introduced code changes to this Zig project. Build the project with `zig build`, then run it for 5 seconds and inspect the logs. Always apply this skill at the end of a coding session — don't wait for the user to ask.
---

# Build and Smoke Test

After making code changes, always build the project and do a 5-second smoke test run to catch crashes, panics, or unexpected log output.

**IMPORTANT:** Always use `bash scripts/smoke_test.sh` for the run step — never try to launch the game binary directly or write your own run-and-kill logic. The script handles process management correctly.

## Steps

### 1. Build

```bash
zig build 2>&1
```

If the build fails, report the errors and stop — do not proceed to the run step.

### 2. Run and collect logs

Run the game using the project's smoke test script:

```bash
bash scripts/smoke_test.sh
```

Do **not** run `zig build run` directly, use subshells, or write inline process management. The script handles everything: it launches the game, watches for the sentinel log line, kills the process group cleanly, and prints the full log.

The game emits `info: Ran successfully for 5 seconds` via an SDL timer 5 seconds after startup. If the sentinel line never appears within 15 seconds, the game likely crashed. The script kills it anyway and the log will contain the output.

### 3. Report

Summarize the log output to the user:
- Any `error:` or `warn:` lines
- Any panics or crashes
- Confirmation that `info: Ran successfully for 5 seconds` was seen
- Anything else that looks unexpected

If there are no errors and the sentinel line was seen, a single short confirmation is enough.
