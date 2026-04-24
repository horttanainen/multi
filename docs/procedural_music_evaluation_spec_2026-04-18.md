# Procedural Music Evaluation Spec v2 (2026-04-18)

This spec defines how we score generated instruments against a reference track.
It replaces the older average-only perceptual gate with a stricter, tail-aware and articulation-aware method.

## Goals

- Catch audible failures that can still pass simple averages (for example "rapid synth-key machine-gun guitar").
- Keep scoring fully automatable for optimizer loops.
- Keep outputs machine-readable for CI and runtime manifest decisions.

## Scoring Layers

### 1) Instrument Descriptor Compare (`scripts/music_compare_instruments.py`)

Per stem score (`0-100`) from weighted descriptor similarity.

Descriptor families:

- energy/dynamics: `rms_*`, `dynamic_range`, `crest_factor`
- spectral/timbre: centroid/rolloff/flatness + MFCC stats
- temporal articulation (new in v2):
  - `onset_strength_mean`
  - `onset_ioi_cv`
  - `onset_short_ioi_ratio`
  - `envelope_modulation_rate_hz`
  - `rms_modulation_depth`

Additional fail logic (new in v2):

- tighter mismatch threshold for temporal metrics
- `temporal_articulation_mismatch` if temporal group mismatches
- guitar-specific:
  - `machine_gun_articulation`
  - `modulation_rate_mismatch`

Output:

- `artifacts/music_reports/<run>.instrument_compare.json`
- includes `meta.evaluation_spec_version = 2`

### 2) Perceptual Window Compare (`scripts/music_compare_perceptual.py`)

Windowed descriptor/perceptual match with bidirectional alignment:

- forward: generated window -> best reference window
- reverse: reference window -> best generated window

This reduces single-window cherry-picking.

Aggregate metrics:

- `average_score` (combined forward + reverse)
- `adjusted_average_score` (coverage-adjusted)
- `p20_score` (tail quality gate)
- `p10_score` (diagnostic)
- coverage stats for both directions

Gate (v2):

- pass only if:
  - `adjusted_average_score >= min_score`
  - `p20_score >= min_tail_score`

Defaults:

- `min_score = 70`
- `min_tail_score = min_score - 12` (58 by default)

Output:

- `artifacts/music_reports/<run>.perceptual_compare.json`
- includes `meta.evaluation_spec_version = 2`

### 3) Optimizer Objective (`scripts/music_optimize_americana.py`)

Composite objective uses:

- offline + runtime average stem scores
- offline + runtime drums scores
- offline + runtime guitar scores
- offline + runtime perceptual average + tail

Penalty terms (new in v2):

- low guitar score vs gate
- critical guitar fail reasons (`machine_gun_articulation`, temporal mismatches)
- low perceptual average/tail
- critical perceptual reason histogram hits (`attack_too_sharp`, `modulation_mismatch`, etc.)

This prevents high aggregate scores from ranking candidates that sound obviously wrong.

## Contract Integration

`scripts/music_build_target_contract.py` now stores evaluation info:

- `evaluation.spec_version`
- `evaluation.instrument_compare.min_score`
- `evaluation.perceptual_compare.min_score`
- `evaluation.perceptual_compare.min_tail_score`

The reference pipeline can set these via env:

- `PERCEPTUAL_MIN_SCORE`
- `PERCEPTUAL_MIN_TAIL_SCORE`
- `EVALUATION_SPEC_VERSION`

## Required Run Loop

1. Build/refresh reference contract:

```bash
STEMS_OUTPUT_ROOT=artifacts/stems/run_demucs6 \
STEM_BACKEND=demucs6 \
PERCEPTUAL_MIN_SCORE=70 \
PERCEPTUAL_MIN_TAIL_SCORE=58 \
EVALUATION_SPEC_VERSION=2 \
scripts/music_run_reference_pipeline.sh americana_raga "https://youtu.be/vDygNfFKcPg"
```

2. Run optimization:

```bash
pyenv exec python3 scripts/music_optimize_americana.py \
  --runs 12 \
  --seconds 12 \
  --run-prefix americana_opt_v2 \
  --output artifacts/music_reports/americana_opt_v2.results.json
```

3. Inspect top run artifacts:

- compare: `artifacts/music_reports/<run>.instrument_compare.json`
- perceptual: `artifacts/music_reports/<run>.perceptual_compare.json`
- preset: `artifacts/music_presets/<prefix>_best.procedural_preset.json`
- manifest: `artifacts/music_presets/<prefix>_best.runtime_manifest.json`

4. Fit inverse candidates + emit runtime manifest proposal:

```bash
pyenv exec python3 scripts/music_fit_inverse_instruments.py \
  --style-name americana_raga \
  --target-contract artifacts/music_profiles/americana_raga.target_contract.json \
  --instrument-profile artifacts/music_profiles/americana_raga.instrument_profile.json \
  --target-stems drums,guitar \
  --output artifacts/music_reports/americana_raga.inverse_fit.results.json \
  --runtime-manifest-output artifacts/music_presets/americana_raga.runtime_manifest.json
```

## In-Game Application (New)

To apply optimized procedural parameters in live runtime:

1. Promote best preset file to:
   - `artifacts/music_presets/americana_current_best.procedural_preset.json`
2. Start game with optional explicit preset override:

```bash
MUSIC_PRESET_PATH=artifacts/music_presets/americana_current_best.procedural_preset.json \
zig build run
```

Behavior:

- If `MUSIC_PRESET_PATH` is unset, runtime does not load any preset file.
- Set `MUSIC_PRESET_PATH=off` (or `none`) to disable preset override.
- If `MUSIC_MANIFEST_PATH` is set, runtime loads manifest backend intent per stem.
- Runtime applies preset mix + guitar timbre controls into live Americana procedural synthesis.
- Manifest `inverse` backends now load and play via live inverse synthesis path.
- If inverse preset/asset loading fails for a stem, that stem falls back to procedural.

## External References (comparison methodology)

- ITU-R BS.1534 (MUSHRA): <https://www.itu.int/rec/R-REC-BS.1534/en>
- ITU-R BS.1116: <https://www.itu.int/rec/R-REC-BS.1116/en>
- webMUSHRA: <https://github.com/audiolabs/webMUSHRA>
- ViSQOL: <https://github.com/google/visqol>
- Frechet Audio Distance (FAD): <https://github.com/google-research/google-research/tree/master/frechet_audio_distance>
- museval (BSS Eval tooling): <https://github.com/sigsep/sigsep-mus-eval>
- DTW alignment reference: <https://librosa.org/doc/latest/generated/librosa.sequence.dtw.html>
