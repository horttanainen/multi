# Repository workflow

Read and follow the applicable repository skills below. The linked `SKILL.md`
files contain the detailed rules; this file defines when to apply them.

| Skill | When to apply |
| --- | --- |
| [phased-collaboration](skills/phased-collaboration/SKILL.md) | Repository changes: commit-sized phase plans, user review and iterations, acceptance before commits, and agreement on the next phase before starting it. |
| [review-before-handoff](skills/review-before-handoff/SKILL.md) | Before handing off code, asset-format, or build/tooling changes, or when explicitly requested: independent review, corrections, and reporting findings and improvements to the user. |
| [code-style](skills/code-style/SKILL.md) | Writing or refactoring code: component architecture, ownership, APIs, and repository conventions. |
| [zig-guard-clause](skills/zig-guard-clause/SKILL.md) | Writing or refactoring Zig code: handle special cases with guard clauses, then apply the defensive-logging skill. |
| [zig-defensive-logging](skills/zig-defensive-logging/SKILL.md) | Writing or refactoring Zig code: apply the logging rules to unexpected and error-handling branches. |
| [build-and-smoke-test](skills/build-and-smoke-test/SKILL.md) | After code changes: use the prescribed formatting, build, and smoke-test workflow and inspect the results. |

An agent assigned as the reviewer follows the review skill's Reviewer mode only:
inspect the applicable rules and validation evidence without running mutating
checks or launching another reviewer. Documentation-only work does not require
the independent pass unless the user requests it.

Leave changes uncommitted until the user accepts them. The independent review
does not replace that acceptance.
