# Repository workflow

Read and follow the applicable repository skills below. The linked `SKILL.md`
files contain the detailed rules; this file defines when to apply them.

| Skill | When to apply |
| --- | --- |
| [phased-collaboration](skills/phased-collaboration/SKILL.md) | Repository changes: commit-sized phase plans, user review and iterations, explicit commit authorization, and agreement on the next phase before starting it. |
| [review-before-handoff](skills/review-before-handoff/SKILL.md) | Substantial or risk-sensitive changes, or explicit review requests: one independent review and correction pass. Small mechanical changes use local inspection and relevant checks. |
| [agent-automation](skills/agent-automation/SKILL.md) | Repeated agent-only checks, diagnostics and task helpers: reuse existing development scripts and game tests, keep reusable agent-only helpers in `agent-tests/`, and disposable work in `agent-temp-files/`. |
| [code-style](skills/code-style/SKILL.md) | Writing or refactoring code: component architecture, ownership, APIs, and repository conventions. |
| [zig-guard-clause](skills/zig-guard-clause/SKILL.md) | Writing or refactoring Zig code: handle special cases with guard clauses, then apply the defensive-logging skill. |
| [zig-defensive-logging](skills/zig-defensive-logging/SKILL.md) | Writing or refactoring Zig code: apply the logging rules to unexpected and error-handling branches. |
| [build-and-smoke-test](skills/build-and-smoke-test/SKILL.md) | After code changes: use the prescribed formatting, build, and smoke-test workflow and inspect the results. |

An agent assigned as the reviewer follows the review skill's Reviewer mode only:
inspect the applicable rules and validation evidence without running mutating
checks or launching another reviewer. Documentation-only work does not require
the independent pass unless the user requests it.

Leave changes uncommitted until the user explicitly asks to commit the reviewed
changes. Acceptance alone does not authorize a commit, and independent review
does not replace the user's acceptance.
