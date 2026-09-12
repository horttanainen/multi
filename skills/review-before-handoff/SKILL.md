---
name: review-before-handoff
description: Run one independent review of implementation changes in this Zig game before handing them to the user. Check applicable repository skills, reuse of existing code and tooling, and correctness; address actionable findings and validate the fixes. Apply to code, asset-format, and build/tooling changes, or when explicitly requested, rather than ordinary explanations or documentation-only edits.
---

# Review before handoff

Give the user a change that has already received one independent review and a
correction pass. The reviewer finds problems; the implementing agent owns the
fixes and verification. This does not replace the user's review or authorize a
commit. Follow explicit user constraints over skill defaults.

## Implementing agent

1. Finish a reviewable implementation and identify the current task's changes.
   Include staged, unstaged, and relevant new files. Use the task's starting
   baseline or recorded diff; staging alone does not identify ownership. Exclude
   unrelated work, and preserve the user's index and working changes.
2. Read the applicable repository instructions and skills. The maintained
   sources are under `skills/`; also account for instructions active in the
   session. Pass the exact applicable paths and any explicit user exceptions
   to the reviewer. If copies differ, identify which instructions govern this
   task instead of silently choosing the more convenient version.
3. Launch **one independent reviewer** using the available sub-agent tool. Start
   with fresh context (`fork_turns="none"` when supported). Inherit the configured
   model unless the user requested another; independence comes from a separate
   review invocation, not a hardcoded model name.
4. Give the reviewer the packet below and ask it to follow **Reviewer mode** in
   this file. Do not send your preferred verdict, suspected findings, or prior
   self-review conclusions. While it reviews, finish documentation or inspect
   validation evidence; keep the reviewed implementation stable.
5. Assess its findings against the code and the user's requirements. Fix the
   actionable findings within the authorized task. Explain any rejected finding
   with concrete evidence. An architectural fix should reuse or extend the
   appropriate owner, not merely rename or relocate a duplicate implementation.
6. Inspect the resulting diff and run the appropriate existing checks. Apply the
   build-and-smoke-test skill after code corrections, using the existing task
   validation script when it covers those requirements. Reuse current results
   when no changes or unresolved concerns invalidate them.
7. Hand the work to the user using the user-handoff instructions below. Leave
   the changes uncommitted until the user accepts them; follow
   [phased-collaboration](../phased-collaboration/SKILL.md) for phase planning,
   review iterations, acceptance, and commits.

Use one review invocation and one correction pass per handoff, not a recursive
review loop. The implementing agent may continue fixing and testing its corrections;
the pass limit is not a reason to leave a known, fixable problem unresolved.
If the task materially changes, identify what the earlier review no longer covers.
If no independent reviewer tool is available, perform the same checks locally and
state that the independent pass could not run; do not claim a separate review.

### User handoff

Tell the user what the independent reviewer found and what you improved before
asking them to review and test the code. Do not reduce this to "review passed"
or omit findings because they have already been fixed.

For each actionable finding, briefly give the problem, its priority and affected
file, and its disposition: fixed (what changed), rejected (the concrete reason),
or unresolved (why and the remaining impact). Separate optional suggestions from
actionable findings and distinguish reviewer findings from your own discoveries.
Use a compact list or table when there are several findings.

State the reviewed scope, checks run after corrections and their results, and
any remaining verification gaps. If there were no actionable findings, say so.
If the independent pass did not run, say why. The user should be able to understand
this account from the final handoff without reading earlier progress messages.

### Reviewer packet

Supply enough raw context to review without the implementation conversation:

- Repository root, task requirements, accepted scope, and explicit user constraints.
- Baseline and exact changed files/hunks, including new files; name exclusions.
- This `SKILL.md` path and the applicable instruction/skill paths.
- Existing validation commands and available logs or artifacts, distinguishing
  checks already run from checks still pending.
- The instruction: **You are the reviewer. Read only; report findings to the
  implementing agent. Do not edit files, modify the index, run mutating checks,
  commit, or launch another reviewer.**

## Reviewer mode

When assigned the reviewer role, perform this section only. Do not run the
implementing-agent workflow or recursively delegate. Inspect relevant callers
and existing components outside the diff when needed, but report findings about
the scoped change rather than auditing unrelated legacy code.

### Repository skills

Read the actual applicable `SKILL.md` files, not just their descriptions. For Zig
changes, this normally includes `code-style`, `zig-guard-clause`, and
`zig-defensive-logging`; check validation evidence against `build-and-smoke-test`.
Verify new and materially changed code against those instructions. Cite the
specific skill and rule for a compliance finding. Respect documented exceptions
and user choices; existing inconsistencies do not justify copying them into new
code, or rewriting unrelated code during this review.

### Existing code and tooling

For each new subsystem, utility, loader, UI, or development script, search for the
closest existing implementation and read its API and callers. Establish whether
the change should call it directly, extend it with a small optional capability,
or remain separate because the responsibilities differ.

Examples of the intended boundary checks:

- A debug menu should be assessed against `menu.zig`, its item definitions,
  navigation, rendering, and input handling. An overlay or letter shortcuts may
  warrant shared options rather than a second menu engine.
- Asset loading should be assessed against `data.zig` and `fs.zig`. Distinguish
  file reading and JSON decoding from necessary domain validation, such as bone
  relationships and curve limits, and from runtime ownership and replacement.

Use these as examples, not universal rules that every UI belongs in `menu.zig`
or every validation belongs in `data.zig`. For a duplication finding, name the
existing file/function, the overlapping responsibility, and a concrete reuse or
extension. Avoid speculative abstractions and broad cleanup beyond the task.

### Correctness and verification

Check behavior at the affected boundaries: initialization and cleanup, ownership,
failed replacement, input routing, and existing callers' default behavior, as
applicable. Check whether the relevant tests and smoke run cover the change;
passing tests do not by themselves settle architecture or skill compliance.
Do not run formatting, builds, GUI smoke tests, or other mutating commands in
reviewer mode. Tell the implementing agent which missing check would resolve a
specific concern.

### Findings

Return actionable findings in priority order. Each finding should contain:

- Priority and a precise changed file/line.
- The concrete problem and its effect or violated repository rule.
- Evidence, including the existing component to reuse when relevant.
- A focused correction and any necessary verification.

Separate material findings from optional suggestions. Do not invent findings to
meet a quota. If none are supported, say **No actionable findings within the
reviewed scope**, briefly name the shared components and skills inspected, and
state any verification gaps. A clean review is evidence for the user, not approval
to commit or a guarantee that the change is correct.
