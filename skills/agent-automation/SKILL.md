---
name: agent-automation
description: Use when preserving repeated agent-only checks, diagnostics and task helpers. Reuse existing development scripts and game tests; keep reusable agent-only automation in agent-tests/ and disposable work in agent-temp-files/.
---

# Agent automation

Preserve useful, repeatable automation for agent work instead of rebuilding the
same commands each time. It need not be feature-related: review evidence,
artifact checks, diagnostics and routine task preparation can qualify too.
Choose its home by the workflow it serves, not whether an agent wrote it.

## Choose the right home

- Normal development tasks, such as formatting, builds, smoke tests and game
  regression tests, stay in the existing project scripts and tests. Reuse or
  extend those entry points even when an agent is the one running them.
- Repeated work specifically for agents belongs in repository-root
  `agent-tests/`. Despite the folder name, it can contain scripts and routine
  operations as well as tests. Group by task when useful. These files are
  maintained source and may be committed with explicit user authorization. Run
  them explicitly when needed for an agent task.
- Disposable experiments, temporary copies, logs and generated output belong in
  the gitignored `agent-temp-files/`. Keeping a script does not make its runtime
  artifacts committable. Create maintained folders only when adding real content.

Keep existing development scripts and game tests in their current locations.
Do not add agent-only helpers to the default build or test commands just because
the helpers are maintained source.

## Keep automation reusable and proportionate

Search for existing scripts, fixtures and helpers first. An agent helper may
call normal project scripts. When local environment adaptations are needed, use
thin wrappers that call those scripts, preserve their defaults and explicit
overrides, and forward arguments and exit status. Avoid duplicated execution
logic. In particular, reuse the prescribed format/build/smoke workflow rather
than creating another game runner.

Document the task, invocation, prerequisites and side effects briefly, such as
in a script header. Make inputs explicit, report useful results or failures, and
verify the routine against its intended outcome. Do not build a general-purpose
framework for a small task or preserve every one-off experiment.

When a check verifies a product feature, exercise its actual game, probe or
script entry point and observable outcomes as appropriate. Focused tests can
protect complex DSP or timing behavior. Other agent tasks use checks appropriate
to their purpose; they are not required to become feature tests or launch the
game merely because they are automated.

## Preserve task authority and data

An agent-only or committed script is not blanket permission to run it. Stay
within the current task and existing execution approvals; request authorization
for destructive or otherwise out-of-scope operations when required.
Keep secrets and generated data out of maintained scripts, isolate temporary
state and clean up only the routine's own artifacts. Do not conceal new side
effects inside an already approved script.
