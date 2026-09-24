# Procedural hard techno: resume here

Prepared 2026-09-24. This folder is the dedicated music worktree.

## Workspace and current status

- Folder: `/Users/horttanainen/projects/multi-music`
- Branch: `codex/hard-techno`
- Starting commit: `657ac10714c13c602fbbe86e20ed74f73a43594d`
  (`Add procedural slope adaptation and automatic stair climbing`)
- Original checkout: `/Users/horttanainen/projects/multi`, where another agent
  is working on movement, animation, rubble, and related features.
- This is a Git worktree: separate checked-out files and index, shared Git
  history and branch references. Run music commands from this folder.
- Workflow skills were committed as `ea5e010` and pushed to `origin/main` at
  the user's request. That commit is the implementation baseline.
- Phase 1 is accepted for commit. The user preferred the first (tight)
  listening candidate; it is now the default.
- The user requested “commit and next phase”: commit this completed milestone,
  then begin Phase 2 around the selected tight foundation.

The user wants better procedural music and proposed a hard techno generator,
with shared-library improvements where useful. They selected a separate folder
so this work is easy to track while another agent works on other game features.
The next milestone is Phase 2 below, authorized by the user's request to commit
Phase 1 and continue. Prioritize the percussion groove and listening comparisons;
the previous bass/acid plan is optional under the user's sound-design guidance.
Workflow skills now distinguish accepting changes from explicitly authorizing
a commit; they also reserve independent review for substantial or risky changes.

Read [the investigation](docs/hard_techno_procedural_music_investigation.md) for
the code findings, measured baseline, technical sources, and full roadmap.
Its copy in the original checkout was left in place; maintain the copy here
for future music work.

## Musical direction

Working assumption: dark, driving techno at 150 BPM, distorted kick, rolling
rumble, restrained percussion, and a short repeating acid motif. The user has
not selected a particular substyle or supplied reference tracks. This direction
can be refined through listening examples. The user selected the first, tight
kick/rumble candidate: drive 2.3, decay 0.28 seconds, rumble 0.52.

The user explicitly released us from previous music-generation guidance because
the earlier approach produced poor results. Treat inherited synthesis recipes,
musical rules, reference-matching goals, and this roadmap's sound-design choices
as optional hypotheses. Change or replace them when listening supports it;
reusing an old musical algorithm is not a goal. The acid motif and planned
instrument list are optional too. Repository workflow and code-quality rules
still apply. Keep the selected tight groove as the audible comparison baseline.

Prioritize a good repeating groove, controlled low-frequency mixing, and
deliberate arrangement. Keep the pulse stable and vary timbre, accents, motifs,
and layer entrances at musical boundaries. Human listening is an acceptance
criterion; level and spectral metrics alone cannot decide whether it sounds good.

## Phase 1 results and listening

The new offline style provides a pitched electronic kick with shaped attack and
decay, alias-reduced cubic saturation, and a kick-fed delay/reverb rumble return.
The return is filtered and smoothly ducked on every quarter-note kick. A final
high-pass removes DC introduced by distortion and ducking; the parameter-extreme
test caught this during implementation. Both buses always process, so soloing
rumble preserves its kick input. Low end is centered. Configuration is applied
on reset; there are no live controls or game-style integration yet.

Listen to [the comparison pack](agent-temp-files/hard-techno/phase1/compare.wav).
It contains eight bars of each candidate, with one, two, or three cue beeps:

| Candidate | Start in pack | Drive / decay / rumble | Matched loudness | Full 16-bar clip |
| --- | --- | --- | --- | --- |
| Tight (selected/default) | 0.18 s | 2.3 / 0.28 s / 0.52 | -18.06 LUFS | [WAV](agent-temp-files/hard-techno/phase1/tight_matched.wav) |
| Driving | 13.86 s | 3.8 / 0.42 s / 0.65 | -18.00 LUFS | [WAV](agent-temp-files/hard-techno/phase1/driving_matched.wav) |
| Crushed | 27.64 s | 6.0 / 0.50 s / 0.72 | -17.96 LUFS | [WAV](agent-temp-files/hard-techno/phase1/crushed_matched.wav) |

The selected [kick](agent-temp-files/hard-techno/phase1/tight_kick_raw.wav) and
[rumble](agent-temp-files/hard-techno/phase1/tight_rumble_raw.wav) stems retain
their original mix gain. Matched mixes use constant attenuation, preserving
dynamics. Raw renders, render/loudness logs, settings and comparison timing are
recorded in [audition.json](agent-temp-files/hard-techno/phase1/audition.json).
All generated output is ignored scratch space; the reproducible recipe is
`agent-tests/hard_techno_audition.py` (requires Zig and ffmpeg):

```bash
python3 agent-tests/hard_techno_audition.py
zig build test-music
zig build procedural-music-probe -- hard-techno --duration 25.6 --seed 12345 --out agent-temp-files/hard-techno/custom.wav
```

Probe controls: `--kick-drive 1..8`, `--kick-decay 0.08..0.8`, `--rumble 0..1`,
`--techno-bus mix|kick|rumble`, plus existing tempo/reverb/volume/seed options.
Techno volume is a master gain; zero produces silence. The fixed pulse consumes
no RNG; the kick owns its sample-noise stream. `resetWithSeed` supports exact
reproducibility in focused tests, while the probe uses the shared entropy owner.

Completed validation:

- Eight music tests pass: immediate/legacy clock start, fractional timing,
  ducking recovery, saturation bounds and a folded-harmonic reduction check,
  seeded/buffer-independent rendering, bus summing/isolation/master mute, and
  finite/headroom/DC behavior at tempo/drive/decay extremes.
- Five ReleaseFast renders each produced 64 kicks in 25.6 seconds, zero clipped
  or non-finite samples, and absolute mean below 0.000005. Mix true peaks range
  from -5.01 to -4.71 dBTP before loudness matching. Rendering plus WAV writing
  took 75–101 ms on the latest run; this is offline throughput, not a measured game
  audio callback deadline.
- Existing taiko and guitar 32-second seed-12345 WAVs are byte-identical to the
  copied preimplementation baselines; hashes are in
  [regression.json](agent-temp-files/hard-techno/phase1/regression.json).
- Repository formatting, `zig build`, shell syntax and diff whitespace checks
  pass. The prescribed smoke script reports `Ran successfully for 5 seconds`,
  without warnings/errors, in [smoke_test.log](agent-temp-files/smoke_test.log).
  An initial sandboxed GUI attempt failed SDL initialization; the authorized
  script run outside that restriction passed.
- One independent read-only review covered all nine implementation/tooling/test
  files and the applicable skills. It found no actionable issues, after
  inspecting shared owners/callers, render and regression receipts, and the
  successful smoke log. No review-driven code corrections were needed. The DC
  correction above came from the implementer's stress test before review.
  The later tight-candidate selection updates defaults, help text and the stem
  recipe only; it received local inspection rather than another independent
  review. The eight tests, build, smoke run and audition recipe were rerun.
  A render with the new probe defaults is byte-identical to the explicitly
  configured tight candidate at the same seed and duration.

Listening feedback: the user preferred the first (tight) candidate. This picks
the low-end foundation to develop; it is not acceptance of a complete track.
Continue comparing changes by ear. Numerical checks establish technical
properties, not musical quality.

## Phase 1: audible kick and rumble proof

**Outcome:** reproducible offline clips of a convincing kick/rumble groove,
including isolated kick, isolated rumble, their combined mix, and a few
drive/decay alternatives at matched playback levels.

**One commit boundary:** the minimal new style, shared primitives it actually
uses, existing-probe support, and focused validation. Leave the completed phase
uncommitted until the user accepts the sound and implementation and explicitly
asks to commit.

Expected files:

- New `src/procedural_hard_techno.zig`: style-owned voices, state, routing,
  `reset`, and `fillBuffer`.
- `src/music/instruments.zig`: reusable electronic kick with independent
  pitch, attack, body, and decay controls.
- `src/music/dsp.zig`: only the required smoothing, saturation, and
  kick-triggered ducking. Reuse existing filters, delay, and reverb.
- `src/music/composition.zig`: narrowly extend the existing sample-driven step
  clock if explicit immediate start or bar information is needed. Preserve
  existing callers' timing.
- `src/procedural_music_probe.zig`: offline style selection and bus isolation;
  preserve the score and kick feed when auditioning rumble alone.
- `build.zig` only if a focused DSP/timing test target is necessary. Reuse the
  existing `procedural-music-probe` build step.

Implementation approach:

1. Keep a stable quarter-note kick at 150 BPM, using the existing 48 kHz engine.
2. Shape the kick attack, pitch drop, body, and tail separately. Keep the low
   end centered and leave output headroom. Compensate output when changing drive.
3. Feed a separate copy of the kick through delay/reverb, filtering, and
   saturation to create rumble. Duck that return at each kick and let it recover
   between beats. Rumble is the initial bass part.
4. Use separate seeded streams for musical decisions and sample-level noise.
5. Evaluate alias reduction for nonlinear processing; any oversampled path
   needs rate-aware coefficients and proper up/downsampling filters.
6. Render several short candidates. Use listening feedback to tune the core
   sound before expanding instrumentation.

Validation:

- Check finite samples, output headroom, DC, pulse spacing, rumble recovery,
  seed reproducibility, and rendering cost. Test timing across different
  buffer chunk sizes when adding or changing the clock.
- Keep unnormalized renders for measurements and prepare matched-level
  listening copies so louder candidates do not win by default.
- Run the repository's format, build, and five-second smoke workflow after
  code changes. Run one independent implementation review before handoff,
  correct actionable findings, and report findings plus validation evidence.
- Use the user's preference for the tight candidate as the baseline for further
  listening comparisons of kick weight, attack, rumble balance, and groove.

## Later phases

| Phase | Deliverable | Main validation |
| --- | --- | --- |
| 2. Complete groove | Hats with choking, clap, sparse metallic percussion, and a small repeating bass/acid motif; reusable resonant filter and alias-suppressed oscillators. Fix shared envelope release/idle behavior when those voices need it. | Repeatable 16-bar mix and isolated buses; early note-off and hat-choke tests; filter limits and deterministic score independent of timbre choices; listening. |
| 3. Musical development | Phrase-aligned builds, breaks, fills, recurring motifs, and controlled returns; reuse cue morphing and step/bar timing. | At least three-minute renders over several seeds; transition alignment, continuity, and whole-passage listening. |
| 4. Game integration | Playback style, persisted settings, existing menu controls, safe live-setting handoff, and consistent probe master gain. | Style switching, live changes, save/reload, runtime/offline comparison, callback performance, and existing-style regressions. |

These are proposed phases. Present the concrete plan before each phase; agree
the next phase with the user before starting it. Approval to implement, acceptance
of the result, and explicit commit authorization are separate decisions.

## Findings to carry forward

- `dsp.softClip` is a static cubic waveshaper, with small-signal gain 1.5; it
  does not provide dynamics limiting or kick/bass separation.
- The general filters are one-pole and lack resonance controls.
- Zero-sustain envelopes can get stuck on early note-off, and zero-sustain
  decay ends in `sustain` rather than `idle`. This is a latent reuse bug, not
  a demonstrated cause of the user's current sound complaint.
- Existing section/harmony novelty and taiko tempo drift should not dictate
  the new style's groove. Reuse the clock/helpers with a deliberate techno policy.
- Taiko consumes one RNG for both composition and instrument noise, making
  timbre edits affect later score decisions. Keep the new style's streams separate.
- The offline probe's `--volume` is not a common master control: taiko maps
  it to drum mix, and shime/kane remain audible at zero. The game also has a
  separate SDL stream gain. Account for this when comparing old and new audio.
- Existing settings/menu code writes style state used by the audio callback;
  inspect and establish synchronization during integration. No race was
  reproduced during investigation.
- April reference-matching documents describe older pipelines partly absent
  from current source. Do not treat their scores as current validation.

## Baseline evidence and local files

Copied baseline WAVs are under the Git-ignored directory
`artifacts/music_investigation/`:

| File | Render | RMS / peak, PCM dBFS |
| --- | --- | --- |
| `multi-music-investigation-taiko.wav` | Matsuri, 32 s, seed 12345, default probe parameters | -22.277 / -3.451 |
| `multi-music-investigation-guitar.wav` | Open-road guitar, 32 s, seed 12345, default probe parameters | -31.902 / -19.159 |
| `multi-music-investigation-taiko-volume-zero.wav` | Matsuri, 4 s, seed 12345, volume 0 | Nonzero output: linear RMS 0.01514, peak 0.41039 |

Both full renders completed without non-finite warnings; neither PCM file had
full-scale samples. The roughly 9.6 dB RMS difference is excerpt/settings
specific, not a perceived-loudness or quality score. No subjective listening
verdict was claimed. The investigation records reproducible render commands.

No build caches or unrelated ignored reference/artifact collections were copied.
Git-tracked assets, configuration, skills, and scripts come from the starting
commit. The other agent's uncommitted changes were not imported. The build and
smoke run have now passed in this worktree; the original baseline renders above
were produced in the original checkout before the move.

## Repository workflow and parallel-work details

Follow [AGENTS.md](AGENTS.md) and the maintained skills under `skills/`:

- [Phased collaboration](skills/phased-collaboration/SKILL.md): use
  `agent-temp-files/` for new agent-owned scratch work and generated outputs;
  commit only on explicit request. Existing baseline artifacts stay at the
  recorded paths above.
- [Agent automation](skills/agent-automation/SKILL.md): keep genuinely reusable
  agent-only routines in `agent-tests/`; reuse existing developer/test scripts.
- [Code style](skills/code-style/SKILL.md): data-only structs, file-level
  functions, clear component ownership, and reuse existing owners/tooling.
- [Zig guard clauses](skills/zig-guard-clause/SKILL.md) and
  [defensive logging](skills/zig-defensive-logging/SKILL.md).
- [Build and smoke test](skills/build-and-smoke-test/SKILL.md): run
  `bash scripts/format.sh`, then `zig build`, then
  `bash scripts/smoke_test.sh`; inspect the actual logs and success sentinel.
  Do not launch the game with custom run/kill logic.
- [Independent review](skills/review-before-handoff/SKILL.md): one fresh-context,
  read-only reviewer and correction pass for substantial or risky changes,
  including the planned music feature phases. Small mechanical and ordinary
  documentation updates use local inspection and relevant checks.

The smoke script now defaults to `agent-temp-files/smoke_test.log` in the current
checkout, with an optional `SMOKE_LOG_PATH` override. This prevents concurrent
worktrees from overwriting a shared `/tmp/game_run.log`. Its game runner and
process cleanup are unchanged. Use this existing script for smoke tests.

Use this worktree's branch for music changes. Avoid resetting, stashing, or
switching the original checkout. Merge/rebase coordination comes after the
user accepts and commits a phase; shared settings/build changes may need
reconciliation then. Do not merge into the other agent's active working tree
as part of music implementation.

Suggested prompt when resuming after listening:

> Read MUSIC_HANDOFF.md. Continue Phase 1 with my listening feedback. Keep the
> implementation uncommitted until I explicitly ask for a commit, and agree
> the next phase before expanding the groove.
