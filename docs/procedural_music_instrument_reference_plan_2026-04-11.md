# Procedural Music Instrument-Reference Plan (Snapshot 2026-04-11)

This is a preserved copy of the agreed implementation plan so it does not get lost.

Update (2026-04-18): merged continuation plan is in
`docs/procedural_music_instrument_matching_combined_plan_2026-04-18.md`.

## 1. Define target instruments and backend strategy.

- Use drums/bass/vocals/other as reliable base stems.
- Add optional piano/guitar stems when available.
- Default backend: UVR model stack (practical, active user base).
- Keep Demucs support optional; treat 6-stem piano as low-confidence.

## 2. Add a stem extraction script.

- New script: `scripts/music_extract_stems.sh` (or `.py`).
- Input: one reference WAV.
- Output: `artifacts/stems/<track>/<stem>.wav`.
- Backends: `uvr`, `demucs4`, `demucs6`, `spleeter5` (switchable).

## 3. Add stem quality scoring.

- New script: `scripts/music_stem_qc.py`.
- Compute leakage/purity proxies per stem (band overlap, correlation to mix residual, transient density sanity).
- Output confidence JSON per stem.
- Mark low-confidence stems as "assist-only" (not hard targets).

## 4. Build instrument profiling on stems.

- New script: `scripts/music_profile_instruments.py`.
- Extract timbre/rhythm descriptors per instrument: RMS envelope stats, spectral centroid/rolloff/flatness, MFCC stats, onset density, pitch range where relevant.
- Save `docs/<style>.instrument_profile.json`.

## 5. Add generated-vs-reference instrument comparison.

- New script: `scripts/music_compare_instruments.py`.
- Compare generated instrument renders to reference stem descriptors.
- Use weighted distance score per instrument (0-100), with per-metric breakdown and fail reasons.
- Important: compare timbre/distribution, not raw waveform alignment.

## 6. Add embedding-based similarity (phase 2 of M6).

- Optional CLAP embedding similarity per instrument clip for perceptual matching.
- This helps catch "still sounds synthy" cases not captured by simple spectral stats.

## 7. Integrate into workflow + acceptance gates.

- Extend M6 acceptance:
- Each target instrument has a minimum confidence and minimum similarity score.
- `docs/<style>.instrument_report.md` is generated automatically.
- Smoke suite can read pass/fail flags from the report.

## 8. Practical limits to set now.

- Flute and other sparse melodic instruments may require manual clip selection from other stem.
- Keep a manual review pass for first iteration, then automate thresholds from collected runs.

## Sources

- Demucs archived status + maintenance note + 6-stem piano limitation: https://github.com/facebookresearch/demucs
- UVR repo/status and model-stack positioning: https://github.com/Anjok07/ultimatevocalremovergui
- Spleeter 5-stem capability and release age: https://github.com/deezer/spleeter
- Open-Unmix status/models/licensing notes: https://github.com/sigsep/open-unmix-pytorch
- CLAP embeddings (music checkpoints): https://github.com/LAION-AI/CLAP
- Essentia feature extraction API/tutorial: https://essentia.upf.edu/tutorial_extractors_musicextractor.html
- librosa spectral feature definitions: https://librosa.org/doc/0.11.0/generated/librosa.feature.spectral_centroid.html
- museval evaluation tooling context: https://pypi.org/project/museval/

## Current progress snapshot

- Implemented: steps 1-5.
- In progress: step 7 (workflow integration + acceptance gates/report automation).
- Pending: step 6 (embedding similarity) and step 8 threshold hardening from real runs.
