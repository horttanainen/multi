---
name: phased-collaboration
description: Follow this user's repository workflow for planned changes, implementation, review iterations, and commits. Work in commit-sized phases, show the plan before each phase, report independent review findings and corrections, and wait for explicit user authorization before committing.
---

# Phased collaboration

Apply this workflow to repository changes, including small fixes and tooling or
documentation work. Ordinary explanations do not need an implementation phase.
Follow the user's explicit instructions for the current task and carry forward
plans, feedback, and approvals already given in the conversation.

## Keep temporary work in the repository

Use the gitignored repository-root `agent-temp-files/` directory for all
agent-owned scratch work: temporary scripts, backups, review snapshots, logs,
generated artifacts and experiments. Create it when missing and use task-specific
subfolders. Do not use `/tmp` or `/private/tmp` for this work. Configure helper
tools' temporary paths to use this directory where supported; if a tool cannot
use it, explain the limitation before using an outside location. This avoids
recurring approvals for ordinary scratch-file writes; it does not bypass
execution permissions or expand task authority.

Never force-add scratch files to Git or treat them as the maintained source.
When cleaning up, remove only artifacts owned by the current task, preserving
other work in the directory.

Maintained, reusable agent-only automation is not scratch work. Place it in
`agent-tests/` according to [agent-automation](../agent-automation/SKILL.md);
keep its temporary data and generated output in `agent-temp-files/`.

## Plan before implementing

Present an overall plan divided into commit-sized phases. Each phase should
deliver one coherent result that the user can review and test independently.
A small task can have one phase and a short plan in the conversation; do not
invent extra phases or require a separate plan document. Keep an existing task
plan up to date when one is already being maintained.

Before starting a phase, show its intended outcome, scope, technical approach,
existing components or tooling to reuse or extend, and validation and user-test
steps appropriate to the change. Make the commit boundary clear. Later phases
can remain brief until it is time to discuss their implementation.

Proceed within the phase the user has authorized. A direct request to implement
a clearly scoped change, or to execute an already presented plan, supplies that
authorization; show the phase plan without asking for the same permission again.
If a new decision materially changes the agreed outcome or commit boundary,
update the plan and get agreement before taking that direction.

## Implement and prepare the handoff

Complete the current phase and its applicable checks. Use existing validation
scripts and prior command authorizations. Apply
[review-before-handoff](../review-before-handoff/SKILL.md) when its trigger applies;
it owns the independent reviewer and correction workflow. Report its findings
and their disposition using that skill's user-handoff instructions.

Present the finished phase for the user's review and testing with:

- What changed and why, with useful file links.
- The independent review findings and improvements made before handoff, or an
  explicit statement that no actionable findings were found or the pass did not
  run, with the reason.
- Checks run and their results, plus concrete manual steps for the user where
  needed. Distinguish completed validation from testing still left to the user.
- Any remaining limitations or decisions that affect acceptance.

Leave the changes uncommitted while awaiting the user's review. Passing checks
and a clean independent review do not constitute the user's acceptance.

## Iterate, accept, and commit

Treat requested corrections as another iteration of the current phase. Address
them, run affected checks and the applicable review workflow, then hand back the
revised changes with an updated account of findings and fixes. Remain in this
phase until the user accepts the resulting changes.

Commit only when the user explicitly asks to commit the reviewed phase. Approval
of a plan authorizes implementation, not a commit. Acceptance of the changes
alone is not commit authorization. Questions, test reports, partial approval,
silence, or a request for further changes do not authorize a commit. Interpret
explicit commit requests in context; no special wording is required.

Once the user authorizes the commit, make it without requesting the same
authorization again. Include only the accepted phase changes and preserve
unrelated work and staging. If further changes are needed after acceptance,
return those changes for review before including them in the commit. Report
the commit and the phase it completes.

## Plan the next phase

After completing the accepted phase, present the concrete next-phase plan before
starting its implementation. Wait for the user's go-ahead so they can confirm
or revise the approach. Acceptance of the previous phase does not authorize the
next phase. A plan and authorization already given for that exact next phase
still count; do not ask again unless the plan materially changes.

Keep the current phase, review status, acceptance, and next planned step clear
across turns. Do not combine unreviewed phases into the accepted phase's commit.
