# Procedural Music Reference Replication Status (2026-04-24)

This document summarizes the current repository state for the effort to take a
YouTube/reference track, analyze its instruments, and reproduce the result as
procedural music using synthetic instruments defined in code.

## Executive Summary

The pipeline is broad but not yet successful.

- The repository has an end-to-end reference preparation workflow: download WAV,
  extract stems, score stem quality, profile stems, build a target contract, run
  procedural tuning, generate A/B comparison reports, and optionally emit an
  inverse-backend runtime manifest.
- The current promoted Americana preset does not pass its own gates. Current best
  scores are roughly:
  - drums: `30.96 / 65`
  - guitar: `50.40 / 65`
  - guitar perceptual adjusted score: `51.26 / 70`
  - guitar perceptual p20 tail score: `46.31 / 58`
- The latest isolated guitar-target experiment also fails:
  - adjusted score: `52.24 / 70`
  - p20 score: `59.82 / 58`
  - melody score: `32.75 / 52`
- The system does not really parse a track into a musical transcription yet. It
  extracts coarse stems and descriptors, then tunes existing procedural knobs
  against descriptor/perceptual similarity.
- The inverse synthesis path exists, but its current `84-85` scores are heuristic
  fit-confidence scores, not validated generated-audio similarity scores.
- Both offline Americana rendering and headless runtime capture currently force
  procedural backends, so the normal evaluation loop cannot validate inverse
  playback.
- A plain `zig build` currently fails in this environment before project
  compilation with unresolved macOS system symbols. That needs separate
  toolchain/environment cleanup before reliable smoke testing.

## Current Artifacts

Main reference track:

- `references/Peter_Walker_-_White_Wind.wav`
- style name: `americana_raga`
- duration: about `460.07s`
- reference profile: `artifacts/music_profiles/americana_raga.profile.json`
- instrument profile: `artifacts/music_profiles/americana_raga.instrument_profile.json`
- target contract: `artifacts/music_profiles/americana_raga.target_contract.json`
- current promoted procedural preset:
  `artifacts/music_presets/americana_current_best.procedural_preset.json`
- current promoted runtime manifest:
  `artifacts/music_presets/americana_current_best.runtime_manifest.json`

The current best preset was generated from:

- run prefix: `americana_opt_acoustic_pass6`
- best run: `americana_opt_acoustic_pass6_00`
- results file: `artifacts/music_reports/americana_opt_acoustic_pass6.results.json`
- generated stems: `artifacts/generated_stems/americana_opt_acoustic_pass6_00/`
- runtime capture: `artifacts/runtime_capture/americana_opt_acoustic_pass6_00_runtime/`

Latest side experiment:

- isolated guitar target extraction:
  `artifacts/music_targets/guitar/guitar/targets_manifest.json`
- isolated guitar target optimization:
  `artifacts/music_reports/guitarra_target_fit_pass1.results.json`
- best target parameters:
  `artifacts/music_presets/guitarra_target_fit_pass1.params.json`

## Current Process

### 1. Fetch Reference WAV

`scripts/fetch_reference_wav.sh <youtube_url>` downloads audio with `yt-dlp` and
normalizes it with `ffmpeg` to mono, 48 kHz, PCM16 WAV.

The full reference pipeline can also resolve the YouTube title and skip download
if the expected WAV already exists.

### 2. Run Reference Pipeline

Primary command:

```bash
scripts/music_run_reference_pipeline.sh <style_name> <youtube_url>
```

Important stages:

- `scripts/music_extract_stems.py`
- `scripts/music_stem_qc.py`
- `scripts/music_profile_instruments.py`
- `scripts/music_profile_from_wav.py`
- `scripts/music_build_target_contract.py`
- `scripts/music_fit_inverse_instruments.py`
- `scripts/music_instrument_report.py`

The pipeline creates:

- normalized stems under `artifacts/stems/<track_slug>/`
- stem QC JSON
- global style profile JSON
- instrument profile JSON
- unified target contract JSON
- inverse preset proposals
- runtime manifest proposal
- optional generated-vs-reference reports

### 3. Fit Procedural Americana Parameters

`scripts/music_optimize_americana.py` does random-search tuning over existing
Americana knobs. For each candidate it:

- renders deterministic offline stems with `scripts/music_render_americana_stems.sh`
- compares drums/guitar descriptor scores
- runs guitar perceptual comparison
- captures headless runtime stems with `scripts/music_capture_runtime_stems.sh`
- compares runtime stems
- ranks by a weighted objective with penalties for guitar/perceptual failures
- writes best procedural preset and manifest skeleton

The current random-search space tunes mix, reverb, guitar tone, and drum tone.
It does not tune the actual note transcription, phrase grammar, drum event
layout, or arrangement structure.

### 4. Evaluate Generated Stems

Instrument descriptor comparison:

```bash
pyenv exec python3 scripts/music_compare_instruments.py \
  --reference-profile artifacts/music_profiles/americana_raga.instrument_profile.json \
  --generated-stems-dir artifacts/generated_stems/<run_name> \
  --target-stems drums,guitar \
  --min-score 65 \
  --output artifacts/music_reports/<run_name>.instrument_compare.json
```

Guitar perceptual comparison:

```bash
pyenv exec python3 scripts/music_compare_perceptual.py \
  --reference-wav artifacts/stems/peter_walker_white_wind/guitar.wav \
  --generated-wav artifacts/generated_stems/<run_name>/guitar.wav \
  --style-name <run_name> \
  --min-score 70 \
  --min-tail-score 58 \
  --output artifacts/music_reports/<run_name>.perceptual_compare.json
```

### 5. Runtime Application

The live game can load:

- `MUSIC_PRESET_PATH=<procedural_preset.json>`
- `MUSIC_MANIFEST_PATH=<runtime_manifest.json>`

The settings loader can apply procedural Americana controls and can load inverse
presets for drums/guitar from a manifest.

However, the normal offline and headless evaluation path currently does not
exercise inverse backends:

- `src/music_render_americana_wav.zig` sets drums/guitar backends to procedural.
- `src/music_capture_runtime_wav.zig` sets drums/guitar backends to procedural.

## Current Scores

### Current Promoted Best: `americana_current_best`

Source run:

- `americana_opt_acoustic_pass6_00`

Instrument gate:

| Stem | Score | Threshold | Status |
| --- | ---: | ---: | --- |
| drums | `30.9575` | `65.0` | fail |
| guitar | `50.4012` | `65.0` | fail |
| average | `40.6793` | n/a | fail |

Guitar perceptual gate:

| Metric | Score | Threshold | Status |
| --- | ---: | ---: | --- |
| adjusted average | `51.2627` | `70.0` | fail |
| p20 tail | `46.3064` | `58.0` | fail |
| melody | `45.6446` | `52.0` | fail |

Frequent failure reasons:

- `machine_gun_articulation`
- `temporal_articulation_mismatch`
- `melody_range_mismatch`
- `melody_voicing_mismatch`
- `melody_missing_phrases`
- `melody_extra_voicing`
- `attack_too_sharp`
- `body_mismatch`
- `dynamic_mismatch`
- `too_quiet`

### Inverse Fit Proposal

`artifacts/music_presets/americana_raga.runtime_manifest.json` selects inverse
backends for drums and guitar:

| Stem | Inverse Fit Score | Selected Backend |
| --- | ---: | --- |
| drums | `84.981686` | inverse |
| guitar | `82.383427` | inverse |

These scores are not comparable to the descriptor/perceptual scores above. They
come from `scripts/music_fit_inverse_instruments.py`, which scores based on stem
QC confidence, metric coverage, articulation, and dynamics. It does not render
the inverse model and compare the resulting audio to the reference stem.

### Isolated Guitar Target Experiment

Latest run:

- `guitarra_target_fit_pass1`
- target: `target_00_midi067_133.717s_134.379s.wav`

Best result:

| Metric | Score | Threshold | Status |
| --- | ---: | ---: | --- |
| adjusted average | `52.2403` | `70.0` | fail |
| p20 tail | `59.8199` | `58.0` | pass |
| melody | `32.75` | `52.0` | fail |

The isolated-target path is a useful direction, but it also exposes a pitch
analysis problem. The selected target is named/estimated as MIDI `67`
(`~392 Hz`), while its descriptor-level pitch median is about `95 Hz` with only
`8` pitch samples. This suggests the current pitch extraction is not reliable
enough to drive transcription or target selection without additional checks.

## Problems Explaining Poor Results

### 1. The System Is Descriptor Matching, Not Track Parsing

The current system does not parse:

- note events
- drum hits
- chord progression from the track
- section boundaries
- per-instrument performance gestures
- exact instrument identities beyond coarse stem names

It mostly compares aggregate descriptors and tries to tune a hand-authored
procedural style. That can imitate a broad texture, but it cannot yet replicate a
specific track's instrumentation and performance.

### 2. Current Best Is Promoted Despite Failing Gates

`americana_current_best.*` points to a failing candidate. The promotion process
should not update "current best" unless required gates pass or the file name
clearly marks it as "least bad so far."

### 3. Target Contract and Optimizer Targets Disagree

The target contract lists required stems as:

- `drums`
- `bass`
- `vocals`
- `other`

The Americana optimization loop mostly compares:

- `drums`
- `guitar`

So the pipeline's declared requirements and the optimization/evaluation target
are not aligned. Guitar is optional in the contract but treated as a hard target
in the Americana comparison loop.

### 4. Drum Model Is Far From the Reference Stem

The current best drum render is much louder and dynamically different than the
reference drum stem:

- reference `rms_mean`: `0.007856`
- generated `rms_mean`: `0.129289`
- reference `dynamic_range`: `0.045841`
- generated `dynamic_range`: `0.55536`
- reference `crest_factor`: `72.55`
- generated `crest_factor`: `7.15`
- reference `spectral_centroid_mean_hz`: `5803.46`
- generated `spectral_centroid_mean_hz`: `2700.83`

This looks like a mismatch between a sparse/noisy separated percussion stem and
a full procedural drum kit. Mix tuning alone is unlikely to fix this.

### 5. Guitar Model Cannot Match Melody/Articulation

The current best guitar has:

- reference pitch span: `1351.76 Hz`
- generated pitch span: `28.72 Hz`
- reference voiced count: `1527`
- generated voiced count: `45`
- reference short-IOI ratio: `0.310`
- generated short-IOI ratio: `0.638`

That explains the repeated `machine_gun_articulation`,
`melody_range_mismatch`, and `melody_voicing_mismatch` failures. The issue is
not just tone. The generated phrase content and event articulation are wrong.

### 6. Pitch Extraction Is Too Fragile

The analysis code uses lightweight autocorrelation pitch estimation. It is
dependency-free and fast, but current artifacts show octave/voicing instability.
This directly harms:

- target extraction
- melody evaluation
- pitch-span gates
- isolated guitar optimization

The latest guitar target manifest is a concrete example: the target rank uses
one pitch estimate, while the descriptor pitch stats disagree strongly.

### 7. Optimizer Search Space Is Too Small

`scripts/music_optimize_americana.py` tunes a small set of continuous controls:

- mix levels
- reverb
- guitar gain/filter/drive
- drum transient/body/noise scales
- cue selection

It cannot solve missing melody phrases, wrong note ranges, wrong rhythms, wrong
drum pattern grammar, or wrong instrument model topology. The optimizer is being
asked to fix structural problems with timbre/mix knobs.

### 8. Inverse Path Is Not Truthfully Evaluated Yet

The inverse path can emit presets and the game settings loader can read them.
But the normal comparison loop cannot render inverse stems, and the inverse fit
score is not a generated-audio score.

The next useful inverse milestone is not "raise inverse fit score"; it is:

1. render inverse drums/guitar to WAV,
2. compare those WAVs against the same reference stems,
3. choose procedural vs inverse from actual descriptor/perceptual scores,
4. capture manifest-backed runtime audio and compare that too.

### 9. Reference Stem Quality Is Only Moderately Trustworthy

QC marks drums, bass, vocals, other, and guitar as hard targets, but guitar
confidence is only `0.688` and other is `0.675`. Separated stems can include
bleed and artifacts. The "drums" stem in this reference appears especially
problematic because the descriptor target is very sparse/high-crest while the
procedural generator produces a conventional drum kit.

### 10. Global Beat Estimate Is Weak

The global reference profile reports:

- BPM estimate: `137.1951`
- pulse confidence: `0.0005`

That pulse confidence is effectively saying "do not trust this beat estimate."
Any process that maps this directly into composition timing should treat it as a
hint, not ground truth.

### 11. Build Verification Is Currently Blocked

On 2026-04-24, `zig build` was attempted both normally and outside the sandbox.
Both runs failed before source-level compilation with unresolved macOS system
symbols such as:

- `__availability_version_check`
- `_abort`
- `_clock_gettime`
- `_dispatch_queue_create`
- `_waitpid`

Environment details:

- Zig: `0.15.2`
- OS: Darwin `25.3.0` arm64
- SDK path: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
- Apple clang: `21.0.0`

This looks like a Zig/toolchain/platform link issue, not a procedural music
logic failure, but it blocks reliable build/smoke verification.

## What Is Missing

Highest-impact missing pieces:

- A real transcription layer: note events, drum hits, sections, tempo map, and
  instrument activity over time.
- A validated inverse render path: inverse presets need to produce WAVs and be
  scored like procedural renders.
- Manifest-backed headless capture: runtime capture should be able to load
  `MUSIC_PRESET_PATH` and `MUSIC_MANIFEST_PATH`, including inverse backends.
- A promotion gate: do not write `americana_current_best.*` unless gates pass,
  or explicitly name it `least_bad`.
- Better guitar analysis: robust pitch tracking, octave correction, voicing
  confidence, and target selection that rejects low-voicing clips.
- Better guitar synthesis controls: pluck duration, decay, fret/body resonances,
  strum vs picked modes, repeated-note humanization, damping/muting, and note
  sequence control.
- Better drum target modeling: decide whether the target is a drum kit, shaker,
  sparse percussion, or separation artifact before fitting a conventional kit.
- Objective alignment: choose whether the goal is exact track replication or
  style imitation. The current metrics mix both goals.
- Human listening gate: metrics are useful for iteration, but promotion should
  require a short A/B listening note because several failures are perceptual.
- Build/toolchain cleanup so the code path can be verified after every change.

## Recommended Next Process

1. Fix build verification first.
   - The current repository cannot be reliably validated with `zig build`.
   - Do not trust further audio changes until build/smoke is green.

2. Freeze `americana_current_best` as "failing baseline."
   - Keep its reports as the baseline.
   - Rename future promotions or add metadata so failing candidates are not
     confused with passing ones.

3. Make inverse evaluation real.
   - Add inverse-capable render/capture paths.
   - Render drums/guitar from `americana_raga.runtime_manifest.json`.
   - Compare those renders against the same `drums.wav` and `guitar.wav`.

4. Stop optimizing full-track guitar before pitch extraction is fixed.
   - Add octave-consistency checks.
   - Reject guitar targets with very low voiced ratio or contradictory median
     pitch.
   - Validate target MIDI against descriptor-level pitch before running
     optimization.

5. Add event-level targets.
   - For guitar: target note sequence, rough onset times, durations, and pitch
     contour.
   - For drums/percussion: target onset classes and spectral bands.
   - Use aggregate descriptors only as secondary checks.

6. Expand synthesis only after target data is trustworthy.
   - Current knobs cannot fix missing melody and wrong articulation.
   - Add controllable performance parameters before more random-search tuning.

7. Re-run the full loop only when the above is in place.
   - Reference pipeline.
   - Procedural render.
   - Inverse render.
   - Runtime manifest capture.
   - Descriptor/perceptual comparison.
   - Human A/B note.
   - Promotion only if the candidate actually clears the chosen gates.
