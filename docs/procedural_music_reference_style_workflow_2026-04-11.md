## Reference Audio -> Procedural Style Workflow (2026-04-11)

Update (2026-04-18): combined continuation plan (including inverse synthesis track)
is in `docs/procedural_music_instrument_matching_combined_plan_2026-04-18.md`.

### Goal

Bootstrap a new procedural style from a real reference track's genre/feel with a repeatable pipeline.

### Quick One-Command Path

Run the full pipeline (download-if-missing, stems, QC, instrument profile, global profile, target contract, inverse-fit manifest proposal):

```bash
scripts/music_run_reference_pipeline.sh <new_style_name> <youtube_url_if_needed>
```

It resolves the reference filename from `yt-dlp` title + slug (same rule as `fetch_reference_wav.sh`), and skips download if that file already exists.

Inverse stage controls (enabled by default):

```bash
RUN_INVERSE_FIT=1 \
INVERSE_TARGET_STEMS=drums,guitar \
scripts/music_run_reference_pipeline.sh <new_style_name> <youtube_url_if_needed>
```

Optional comparison + gate outputs in the same run:

```bash
GENERATED_STEMS_DIR=artifacts/generated/my_style \
MIN_INSTRUMENT_SCORE=65 \
REQUIRE_COMPARISON=1 \
FAIL_ON_GATES=1 \
scripts/music_run_reference_pipeline.sh <new_style_name> <youtube_url_if_needed>
```

### Step 1: Extract Canonical Stems

Run:

```bash
scripts/music_extract_stems.py /path/to/reference.wav --backend <uvr|demucs4|demucs6|spleeter5> --output-root artifacts/stems
```

Notes:

- default backend is `uvr`
- `uvr` requires either:
  - `--uvr-cmd '<command with {input} and {output} placeholders>'`
  - or `--uvr-stems-dir /path/to/pre_extracted_uvr_stems`
- output is normalized WAV stems at:
  - `artifacts/stems/<track_slug>/<stem>.wav`
  - with `stems_manifest.json`

### Step 2: Stem Quality Scoring (confidence + assist-only)

Run:

```bash
scripts/music_stem_qc.py /path/to/reference.wav --stems-dir artifacts/stems/<track_slug>
```

Output:

- `artifacts/stems/<track_slug>/stem_qc.json`
- per-stem confidence + mode:
  - `hard_target`
  - `assist_only`
- global reconstruction/leakage proxy stats

### Step 3: Build Instrument Profile from Stems

Run:

```bash
scripts/music_profile_instruments.py --stems-dir artifacts/stems/<track_slug> --style-name <new_style_name> --output artifacts/music_profiles/<new_style_name>.instrument_profile.json
```

Output includes per-stem descriptors:

- envelope/rhythm:
  - `rms_mean`, `rms_std`, `dynamic_range`, `onset_density_per_second`
- timbre/spectral:
  - `spectral_centroid_*`, `spectral_rolloff_*`, `spectral_flatness_*`, `crest_factor`
- pitch proxy:
  - `pitch_hz` (`min/max/median/count`) where detectable
- cepstral:
  - `mfcc_mean`, `mfcc_std`

### Step 4: Extract Global Profile from WAV (style seed)

Run:

```bash
scripts/music_profile_from_wav.py /path/to/reference.wav --style-name <new_style_name> --output artifacts/music_profiles/<new_style_name>.profile.json
```

Output includes:

- `raw_metrics`:
  - `bpm_estimate`
  - `pulse_confidence`
  - `onset_density_per_second`
  - `rms_mean`, `rms_std`
  - `zcr_mean`
  - `crest_factor`
  - `dynamic_range`
- `suggested_style_params`:
  - `base_bpm`
  - `energy`
  - `lead_density`
  - `ghost_density`
  - `fill_chance`
  - `break_chance`
  - `tempo_drift`

### Step 5: Map Profiles -> Style Module

Use `suggested_style_params` as seed values when creating a new `src/procedural_<new_style_name>.zig` module:

- map `base_bpm` directly
- map `energy` to cue-level intensity multipliers
- map `lead_density`/`ghost_density` to lead phrase rhythm density
- map `fill_chance`/`break_chance` to cycle-level variation events
- map `tempo_drift` to macro arc tempo modulation

Use `artifacts/music_profiles/<new_style_name>.instrument_profile.json` to tune instrument-layer parameters:

- guitar/piano/lead filter cutoffs and brightness
- envelope timings (`attack/decay/release`)
- density and articulation behavior per layer

### Step 6: Wire + Validate

- Add style enum/wiring in settings/music UI.
- Add probe snapshots for the style in `src/music_probe.zig`.
- Run:

```bash
bash scripts/music_smoke_test.sh
```

Target:

- pass baseline checks
- pass M2 variation checks (`m2_theme_variation:PASS`)

### Step 7: Instrument Report + Gates

Run:

```bash
scripts/music_instrument_report.py \
  --instrument-profile artifacts/music_profiles/<new_style_name>.instrument_profile.json \
  --qc artifacts/stems/<track_slug>/stem_qc.json \
  --comparison artifacts/music_reports/<new_style_name>.instrument_compare.json \
  --output-md artifacts/music_reports/<new_style_name>.instrument_report.md \
  --output-json artifacts/music_reports/<new_style_name>.instrument_gate.json
```

This generates:

- machine-readable gate file (`instrument_gate.json`) for CI/smoke checks
- human-readable summary (`instrument_report.md`) with per-stem reasons

### Step 8: Generator-vs-Reference A/B Loop (Americana)

Use the dedicated script to render deterministic generated stems and score them:

```bash
scripts/music_render_americana_stems.sh <run_name> [seconds] [cue] [seed]
```

Example:

```bash
scripts/music_render_americana_stems.sh americana_raga_a3 20 0 1337
```

Outputs:

- generated stems: `artifacts/generated_stems/<run_name>/`
  - `mix.wav`, `drums.wav`, `guitar.wav`, `other.wav`
- comparison report: `artifacts/music_reports/<run_name>.instrument_compare.json`
- gate/report: `artifacts/music_reports/<run_name>.instrument_gate.json`, `artifacts/music_reports/<run_name>.instrument_report.md`

Notes:

- default comparison target stems are `drums,guitar` for current americana iteration
- override target via `TARGET_STEMS=...`
- strict CI-like failure can be enabled via `FAIL_ON_GATES=1`

### Step 9: Perceptual Guitar A/B (Windowed)

Run perceptual windowed compare (guitar vs reference guitar stem):

```bash
pyenv exec python3 scripts/music_compare_perceptual.py \
  --reference-wav artifacts/stems/<track_slug>/guitar.wav \
  --generated-wav artifacts/generated_stems/<run_name>/guitar.wav \
  --style-name <run_name> \
  --min-score 70 \
  --min-tail-score 58 \
  --output artifacts/music_reports/<run_name>.perceptual_compare.json
```

Export worst-window A/B clips:

```bash
pyenv exec python3 scripts/music_export_ab_clips.py \
  --comparison artifacts/music_reports/<run_name>.perceptual_compare.json \
  --reference-wav artifacts/stems/<track_slug>/guitar.wav \
  --generated-wav artifacts/generated_stems/<run_name>/guitar.wav \
  --output-dir artifacts/ab_clips/<run_name>
```

Integrated shortcut:

- `scripts/music_render_americana_stems.sh` now runs perceptual compare by default (`PERCEPTUAL_COMPARE=1`)
- auto-resolves reference guitar from `artifacts/music_profiles/americana_raga.instrument_profile.json` (`meta.stems_dir/guitar.wav`)
- exports A/B clips by default (`PERCEPTUAL_AB_EXPORT=1`)
- for v2 scoring you can set `PERCEPTUAL_MIN_TAIL_SCORE` (default behavior is `PERCEPTUAL_MIN_SCORE-12`)

Live runtime usage:

- optimized presets can be applied at startup with:
  - `MUSIC_PRESET_PATH=artifacts/music_presets/americana_current_best.procedural_preset.json zig build run`
- runtime backend intent can be loaded from manifest with:
  - `MUSIC_MANIFEST_PATH=artifacts/music_presets/americana_raga.runtime_manifest.json zig build run`
- fast startup validation without env-prefixes:
  - `bash scripts/smoke_test.sh --no-build --music-preset-path <preset.json>`
  - `bash scripts/smoke_test.sh --no-build --music-manifest-path <manifest.json>`

### Current Status

- Implemented tooling:
  - `scripts/music_extract_stems.py`
  - `scripts/music_stem_qc.py`
  - `scripts/music_profile_instruments.py`
  - `scripts/music_profile_from_wav.py`
  - `scripts/music_compare_instruments.py`
  - `scripts/music_instrument_report.py`
  - `scripts/music_render_americana_stems.sh`
- Smoke suite includes M2 checks and is green for current four styles.
- `americana_raga` style module is wired into runtime/settings/menu/probe.
- Iteration updates:
  - fixed cue-reset bug where Americana guitar cue params were not applied on reset
  - added render-time guitar timbre controls (gain/drive/cabinet) and optimizer support
  - added drum timbre controls (`drum_transient_scale`, `drum_body_scale`, `drum_noise_scale`) across runtime/render/optimizer/menu
  - added inverse fit stage (`scripts/music_fit_inverse_instruments.py`) with preset + asset emission and runtime manifest output
  - added runtime manifest loading in `settings.zig` with live inverse backend support and fallback on load failure
  - updated comparison scoring to skip drum pitch checks and use linear RMS scales
  - latest tuned reference run: `artifacts/music_reports/americana_raga_a16_tuned.instrument_compare.json` (`guitar` now passes, `drums` still below threshold)
- Next required input: drum timbre/rhythm tuning pass to bring `drums` similarity above threshold and make full gate pass.
