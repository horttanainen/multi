# Procedural Music Instrument Matching Combined Plan (2026-04-18)

This document merges:

1. Original research-backed reference pipeline plan from `docs/procedural_music_instrument_reference_plan_2026-04-11.md`.
2. Practical workflow/status from `docs/procedural_music_reference_style_workflow_2026-04-11.md`.
3. Expanded integration plan to carry results into live music generation, including the inverse synthesis track.
4. Evaluation conversion details in `docs/procedural_music_evaluation_spec_2026-04-18.md`.

Use this as the durable handoff file for continuing work after context loss.

## Current Ground Truth (Repo Snapshot)

- Reference pipeline exists and runs end-to-end:
  - `scripts/music_run_reference_pipeline.sh`
  - `scripts/music_extract_stems.py`
  - `scripts/music_stem_qc.py`
  - `scripts/music_profile_instruments.py`
  - `scripts/music_profile_from_wav.py`
  - `scripts/music_compare_instruments.py`
  - `scripts/music_instrument_report.py`
- Americana A/B fitting loop exists:
  - `scripts/music_render_americana_stems.sh`
  - `scripts/music_optimize_americana.py`
  - `scripts/music_compare_perceptual.py`
- Headless runtime capture (no game launch) now exists:
  - `src/music_capture_runtime_wav.zig`
  - `scripts/music_capture_runtime_stems.sh`
  - `zig build music-capture-runtime-wav -- <out.wav> <style> <seconds> <cue> <seed> <layer>`
  - Captures style/layer WAVs directly from runtime procedural modules for rapid A/B iteration.
- Live runtime now applies optimized Americana controls from settings:
  - Mixes + cue + advanced guitar timbre are wired in `src/settings.zig`.
  - Drum timbre controls (`transient/body/noise`) are wired for runtime and optimizer loops.
- Latest known tuning status: guitar similarity can pass in tuned runs; drums are still the main blocker.
- Evaluation spec v2 now defined (tail-aware + articulation-aware); see `docs/procedural_music_evaluation_spec_2026-04-18.md`.

### 2026-04-18 Implementation Update

- Runtime startup now supports both:
  - `MUSIC_PRESET_PATH` (procedural preset override; default off when unset)
  - `MUSIC_MANIFEST_PATH` (runtime manifest override; default off when unset)
- Runtime manifest parsing is implemented with safe fallback:
  - `inverse` backend now runs via live inverse synthesis path when preset/assets load.
  - per-stem fallback to `procedural` is used only if inverse preset/asset loading fails.
- Live inverse playback backend is implemented in `src/procedural_americana_raga.zig` for `drums` and `guitar`.
- Americana runtime parameter parity now includes drum timbre controls:
  - `drum_transient_scale`, `drum_body_scale`, `drum_noise_scale`
  - wired through settings, live apply path, menu controls, offline render, runtime capture, and optimizer.
- Inverse fit stage is implemented:
  - `scripts/music_fit_inverse_instruments.py`
  - emits `artifacts/music_presets/<style>.<stem>.inverse_preset.json`
  - emits assets under `artifacts/inverse/<style>/<stem>/`
  - emits/updates runtime manifest proposal.
- Reference pipeline now runs inverse-fit stage by default (`RUN_INVERSE_FIT=1`).
- Smoke test supports non-env-override flags:
  - `--music-preset-path`
  - `--music-manifest-path`
  - `--no-build` for fast repeat runs

## Preserved Original Research Results

These are the original sources collected for the reference pipeline direction.

- Demucs archived status + maintenance note + 6-stem piano limitation: <https://github.com/facebookresearch/demucs>
- UVR repo/status and model-stack positioning: <https://github.com/Anjok07/ultimatevocalremovergui>
- Spleeter 5-stem capability and release age: <https://github.com/deezer/spleeter>
- Open-Unmix status/models/licensing notes: <https://github.com/sigsep/open-unmix-pytorch>
- CLAP embeddings (music checkpoints): <https://github.com/LAION-AI/CLAP>
- Essentia feature extraction API/tutorial: <https://essentia.upf.edu/tutorial_extractors_musicextractor.html>
- librosa spectral feature definitions: <https://librosa.org/doc/0.11.0/generated/librosa.feature.spectral_centroid.html>
- museval evaluation tooling context: <https://pypi.org/project/museval/>

Operational takeaways already adopted:

- Treat stem quality as confidence-weighted, not binary truth.
- Compare generated audio using descriptor/perceptual similarity, not waveform alignment.
- Keep optional perceptual scoring (CLAP-capable) for "sounds synthy" failures.

## Combined Strategy (Two Tracks, One Contract)

Do not choose between procedural fitting and inverse synthesis up front.
Run both tracks against one common target contract and pick per-stem winner.

1. Build a shared target contract from pipeline outputs.
2. Track A: Fit existing procedural synthesis parameters.
3. Track B: Fit inverse/synthetic instrument models from stems.
4. Runtime manifest selects backend per stem (`procedural` or `inverse`) with fallback to procedural.

## New Artifacts To Add

### 1) Target Contract

`artifacts/music_profiles/<style>.target_contract.json`

Purpose: normalize all analysis outputs into one machine-readable target for optimizers and runtime selection.

Proposed fields:

- `meta`: style name, generated time, source paths.
- `reference`: `wav`, `stems_dir`, `qc_path`, `profile_path`, `instrument_profile_path`.
- `global_targets`: copied from `<style>.profile.json` (`raw_metrics`, `suggested_style_params`).
- `stems`: per-stem metrics from `<style>.instrument_profile.json` plus QC mode/confidence and computed stem weight.
- `gates`: `min_score`, `min_confidence`, `required_stems`.

### 2) Procedural Preset

`artifacts/music_presets/<style>.procedural_preset.json`

Purpose: persist procedural runtime parameters selected by optimizer.

- `meta`: source contract + optimizer run metadata.
- `global`: bpm scale, reverb, cue defaults.
- `americana`: mix controls + guitar timbre controls + drum timbre controls.
- `scores`: per-stem and aggregate scores used for selection.

### 3) Inverse Presets + Assets

- `artifacts/music_presets/<style>.<stem>.inverse_preset.json`
- `artifacts/inverse/<style>/<stem>/...`

Purpose: store fitted synthetic/inverse model per stem.

### 4) Runtime Manifest

`artifacts/music_presets/<style>.runtime_manifest.json`

Purpose: final backend choice per stem.

- `stems.<stem>.backend`: `procedural` or `inverse`
- `stems.<stem>.preset_path`
- `stems.<stem>.score`
- `fallback_policy`: use procedural when inverse load/asset validation fails.

## Detailed Execution Plan

### Phase 0: Stabilize Inputs

1. Run the reference pipeline for target style (example already used):
   - `STEMS_OUTPUT_ROOT=artifacts/stems/run_demucs6 STEM_BACKEND=demucs6 scripts/music_run_reference_pipeline.sh americana_raga "https://youtu.be/vDygNfFKcPg"`
2. Confirm outputs exist:
   - `artifacts/music_profiles/<style>.profile.json`
   - `artifacts/music_profiles/<style>.instrument_profile.json`
   - `artifacts/stems/<track>/stem_qc.json`
3. Build and store `artifacts/music_profiles/<style>.target_contract.json`.

### Phase 1: Track A (Procedural Fit) Integration

1. Extend live settings persistence/application for missing Americana parameters:
   - `src/settings.zig`
2. (Optional UI exposure) Add selected new knobs in:
   - `src/musicConfigMenu.zig`
3. Add/expand tunable drum timbre controls in:
   - `src/procedural_americana_raga.zig`
4. Thread controls into instrument/layer behavior as needed:
   - `src/music/layers.zig`
   - `src/music/instruments.zig`
5. Upgrade optimizer to consume `target_contract` and emit `procedural_preset`:
   - extend `scripts/music_optimize_americana.py`
6. Keep objective as weighted compare + perceptual, with stem weights from QC confidence.

### Phase 2: Track B (Inverse Synthesis) Implementation

1. Add inverse fit stage script (new):
   - `scripts/music_fit_inverse_instruments.py`
2. Start with stems: `guitar`, `drums`.
3. Per stem, fit compact real-time model components:
   - exciter/transient profile
   - spectral envelope/body filter model
   - nonlinear saturation/cabinet coloration proxy
4. Emit:
   - `artifacts/music_presets/<style>.<stem>.inverse_preset.json`
   - assets under `artifacts/inverse/<style>/<stem>/`

### Phase 3: Runtime Backend Selection

1. Add runtime loader/selector that reads `runtime_manifest`.
2. Route per-stem generation backend:
   - procedural path or inverse path.
3. Guarantee fallback to procedural on inverse failures/missing assets.

### Phase 4: Unified Evaluation and Gates

1. Adopt evaluation spec v2 (`docs/procedural_music_evaluation_spec_2026-04-18.md`) as baseline.
2. Keep compare/gate reports, but enforce:
   - descriptor + temporal articulation gates
   - bidirectional perceptual matching
   - perceptual tail gate (`p20`)
3. Add branch-aware summary:
   - procedural scores
   - inverse scores
   - chosen backend per stem
4. Final pass condition:
   - required stems pass threshold, using selected backend.

### Phase 5: In-Game Instrument Quality Productization

These steps move "better scores" into actual in-game sound quality.

1. Runtime parameter parity (procedural path):
   - Persist and apply all optimized Americana guitar timbre controls in live runtime (`settings.zig` -> `procedural_americana_raga`).
2. Preset ingestion in game startup:
   - Read `artifacts/music_presets/*.procedural_preset.json` and apply to live settings.
   - Support explicit override path via env for fast A/B runs.
3. Manifest-driven backend selection:
   - Load `runtime_manifest` in game startup.
   - Select per-stem backend (`procedural` or `inverse`) with procedural fallback.
4. Drum quality push:
   - Add explicit drum timbre controls (transient/body/noise) exposed to optimizer and runtime.
5. Listen-first gate before promotion:
   - Require both metric pass and human A/B approval before writing `americana_current_best.*`.
6. Safe rollout:
   - Keep default disable/rollback switch for preset/manifest loading.
   - Log applied preset/manifest path + resolved backend per stem.

## Iteration and Testing Loop (Run Between Every Change)

Use this loop after each parameter/code edit so regressions are caught immediately.

1. Choose a run label:
```bash
RUN_ID=americana_iter_$(date +%Y%m%d_%H%M%S)
```

2. Render the current offline candidate stems (optimizer/offline branch):
```bash
scripts/music_render_americana_stems.sh "$RUN_ID" 20 0 1337
```

3. Capture runtime stems from the headless runtime endpoint (no game window):
```bash
scripts/music_capture_runtime_stems.sh americana_raga "${RUN_ID}_runtime" 20 0 1337
```

3b. (In-game parity check) run game/probe with preset override and capture same cue/seed:
```bash
MUSIC_PRESET_PATH=artifacts/music_presets/americana_current_best.procedural_preset.json \
zig build run
```

4. Compare runtime-captured stems to reference instrument profile:
```bash
pyenv exec python3 scripts/music_compare_instruments.py \
  --reference-profile artifacts/music_profiles/americana_raga.instrument_profile.json \
  --generated-stems-dir artifacts/runtime_capture/${RUN_ID}_runtime \
  --target-stems drums,guitar \
  --min-score 65 \
  --output artifacts/music_reports/${RUN_ID}_runtime.instrument_compare.json
```

5. Run perceptual compare for guitar (reference stem vs runtime guitar):
```bash
REF_GUITAR="$(pyenv exec python3 -c 'import json,os; p=json.load(open("artifacts/music_profiles/americana_raga.instrument_profile.json",encoding="utf-8")); print(os.path.join(p.get("meta",{}).get("stems_dir",""),"guitar.wav"))')"
pyenv exec python3 scripts/music_compare_perceptual.py \
  --reference-wav "$REF_GUITAR" \
  --generated-wav "artifacts/runtime_capture/${RUN_ID}_runtime/guitar.wav" \
  --style-name "${RUN_ID}_runtime" \
  --min-score 70 \
  --output "artifacts/music_reports/${RUN_ID}_runtime.perceptual_compare.json"
```

6. (Optional but recommended) Parity check runtime capture vs offline render for same run:
```bash
pyenv exec python3 scripts/music_compare_perceptual.py \
  --reference-wav "artifacts/generated_stems/${RUN_ID}/guitar.wav" \
  --generated-wav "artifacts/runtime_capture/${RUN_ID}_runtime/guitar.wav" \
  --style-name "${RUN_ID}_offline_vs_runtime" \
  --output "artifacts/music_reports/${RUN_ID}_offline_vs_runtime.perceptual_compare.json"
```

7. Gate decision before next edit:
   - If `guitar` improves and `drums` does not regress, keep change and continue.
   - If either required stem regresses, revert/tune before moving to the next phase.
   - Save run outputs under `artifacts/` and keep `docs/` for plan/design documents.

8. Every N iterations (recommended N=3), run project safety checks:
```bash
zig build
bash scripts/smoke_test.sh
```

Notes:

- This loop explicitly compares three targets:
  - reference track stems,
  - offline generated stems,
  - headless runtime stems (closest proxy to in-game procedural output without launching game).
- If full in-game mix-bus capture (music + SFX + final mixer) is needed later, add a dedicated bus-recorder path in `src/audio.zig` as a separate task.

## Immediate Prioritized Worklist

1. Wire advanced Americana params into live settings/runtime.
2. Add startup preset ingestion from `procedural_preset` (env override; default is off unless env is set).
3. Integrate headless runtime capture into optimizer loop outputs (auto-produce runtime compare JSONs per run).
4. Add first drum timbre control surface in `procedural_americana_raga`.
5. Add `runtime_manifest` loader and backend fallback logic in game runtime.
6. Add minimal inverse fitting prototype for guitar stem only.
7. Add backend-aware final summary report (`procedural` vs `inverse` per stem).

## Resume Commands (Next Session)

1. Rebuild reference artifacts:
```bash
STEMS_OUTPUT_ROOT=artifacts/stems/run_demucs6 \
STEM_BACKEND=demucs6 \
scripts/music_run_reference_pipeline.sh americana_raga "https://youtu.be/vDygNfFKcPg"
```

2. Run Americana procedural optimization loop:
```bash
pyenv exec python3 scripts/music_optimize_americana.py \
  --runs 12 \
  --seconds 12 \
  --run-prefix americana_opt_next \
  --output artifacts/music_reports/americana_opt_results_next.json
```

3. Validate generated stems + perceptual pass on best candidate:
```bash
scripts/music_render_americana_stems.sh americana_raga_next 20 0 1337
```

4. Validate runtime capture for the same candidate without launching game:
```bash
scripts/music_capture_runtime_stems.sh americana_raga americana_raga_next_runtime 20 0 1337
```

5. Compare runtime guitar against reference guitar perceptually:
```bash
REF_GUITAR="$(pyenv exec python3 -c 'import json,os; p=json.load(open("artifacts/music_profiles/americana_raga.instrument_profile.json",encoding="utf-8")); print(os.path.join(p.get("meta",{}).get("stems_dir",""),"guitar.wav"))')"
pyenv exec python3 scripts/music_compare_perceptual.py \
  --reference-wav "$REF_GUITAR" \
  --generated-wav artifacts/runtime_capture/americana_raga_next_runtime/guitar.wav \
  --style-name americana_raga_next_runtime \
  --output artifacts/music_reports/americana_raga_next_runtime.perceptual_compare.json
```

## Definition of Done

- One command path produces reference analysis + target contract.
- Procedural preset is auto-generated and applied in live runtime.
- Inverse preset path exists for at least one stem (guitar/drums) and plays in runtime.
- Runtime manifest selects backend per stem based on measured score.
- Gate/report output clearly shows chosen backend and pass/fail rationale.
