# Procedural Music Pivot Plan: Isolated Notes and Inverse Fitting (2026-04-25)

## Decision

Use isolated-note and isolated-hit inverse fitting as the main path forward.
Do not continue treating full-track descriptor optimization as the primary path.

Keep the useful parts of the current work:

- reference WAV fetching
- stem extraction
- stem quality checks
- instrument profiling
- render-to-WAV helpers
- comparison reports
- A/B clip export
- runtime preset/manifest loading concepts

Freeze the current Americana pipeline as a failing baseline, then rebuild the
quality path around note/hit-level targets.

## Why Pivot

The current pipeline is broad but structurally underpowered:

- It does not transcribe note events, drum hits, tempo maps, sections, or
  articulations.
- It mostly compares aggregate descriptors and perceptual windows.
- The optimizer only controls mix/timbre knobs, so it cannot repair wrong
  melody, wrong rhythm, wrong note range, or missing performance gestures.
- The inverse backend has heuristic fit scores, but it is not yet validated by
  rendering audio and scoring that audio against reference stems.

Trying to "fix" the existing full-track loop first is likely to spend time on
surface tuning while the core representation remains wrong.

## Main Approach

The new direction is:

1. Start from isolated instrument stems.
2. Extract high-confidence single notes, chords, or drum/percussion hits.
3. Use those clips as concrete audio targets.
4. Fit deliberately constrained synthetic instrument models to those targets.
5. Build event-level transcription and sequencing separately.
6. Reconstruct full procedural music from fitted instruments plus event data.

Important constraint: do not solve for a completely unknown arbitrary function.
That is too unconstrained and unlikely to produce a stable real-time instrument.
Instead, solve an inverse problem over explicit synth topologies.

Examples:

- guitar: pluck exciter, string/waveguide, body resonators, cabinet filtering,
  damping, pick noise, saturation, stereo body response
- drums: transient exciter, tuned body resonator, noise component, decay envelope,
  transient/body/noise balance
- pads/other: oscillator bank, envelope, filter, modulation, saturation/reverb

## Short-Term Goal

Create a reliable single-instrument fitting loop:

```text
reference stem -> high-confidence clips -> target manifest
target clip -> synth render candidate -> loss score
optimizer -> best synth params -> validated target report
```

Acceptance for this phase:

- The fitted synth can match at least one isolated target clip audibly better
  than the current full-track procedural render.
- The score is produced from rendered audio, not from heuristic fit confidence.
- The target manifest rejects low-confidence/contradictory pitch clips.
- The result is reproducible from source and committed scripts, not hand state.

## Proposed Pipeline

### 1. Stem Preparation

Reuse existing stem extraction and QC.

Inputs:

- reference WAV
- separated stems
- stem QC

Outputs:

- accepted stems for target extraction
- confidence metadata

Do not assume every stem is trustworthy. Stem bleed and separation artifacts must
be carried forward as confidence metadata.

### 2. Target Extraction

For each candidate instrument stem:

- detect onsets
- segment candidate notes/hits
- estimate pitch where relevant
- compute envelope and spectral descriptors
- reject clips with low voiced ratio, unstable pitch, contradictory octave
  estimates, severe bleed, or insufficient duration
- cluster targets by pitch/articulation/dynamics

Outputs:

- target WAV clips
- target manifest JSON
- target confidence and rejection reasons

Immediate improvement needed:

- add octave-consistency checks
- compare target-level pitch estimate against descriptor-level pitch estimate
- reject target clips when those estimates disagree strongly

### 3. Synth Topology Definition

Define a small parameterized model per instrument class.

Do not expose hundreds of arbitrary knobs at first. Prefer compact topologies
with physically meaningful controls.

Example guitar parameters:

- midi note or base frequency
- pluck strength
- pluck brightness
- string damping
- body resonance frequencies/gains/decays
- pick noise level
- cabinet high-pass/low-pass
- saturation amount
- stereo width
- release/mute behavior

### Acoustic Guitar Research Basis

Use these references when iterating on the single-pluck acoustic guitar model:

- `docs/references/acoustic_guitar_synthesis/j.apacoust.2015.04.006.pdf`
  - Circuit/transmission-line classical guitar model.
  - Key implementation idea: treat the string as a plucked transmission-line
    model and shape it through a guitar body response rather than expecting the
    string model alone to sound realistic.
- Woodhouse, "On the synthesis of guitar plucks"
  - Local file: `docs/references/acoustic_guitar_synthesis/Guitar_I.pdf`
  - Key implementation idea: realistic plucks depend on coupled string/body
    transient behavior and correct string damping.
- Columbia DSP project, "Synthesizing a Guitar Using Physical Modeling
  Techniques"
  - URL: `https://www.ee.columbia.edu/~ronw/dsp/`
  - Key implementation idea: a simple digital waveguide produces a plucked
    string-like sound but still sounds artificial without filtering/body
    modeling.

Practical rule for this project: do not assume `WaveguideString` is the
instrument. First test raw string behavior, then compare it with a modal/body
response approach against the selected target pluck. Keep each layer audible and
reversible.

Example drum parameters:

- transient amount
- transient decay
- body frequency
- body decay
- noise amount
- noise color
- envelope shape
- saturation

### 4. Render Candidate Audio

For each candidate parameter set:

- render a short WAV with the same duration as the target
- loudness-normalize only where appropriate
- preserve raw output for diagnostics
- compute descriptors and perceptual loss

This must use the same scoring path that later evaluates full procedural stems.

### 5. Loss Function

Use a weighted loss designed for short clips:

- multi-resolution spectral distance
- RMS/envelope distance
- onset/attack distance
- decay/tail distance
- MFCC/spectral-shape distance
- pitch center and pitch contour distance where relevant
- voicing ratio and voiced-frame coverage
- loudness/dynamic range checks

Avoid relying only on aggregate full-track statistics.

### 6. Optimizer

Start with robust black-box optimizers:

- CMA-ES
- differential evolution
- random search for smoke baselines
- Bayesian optimization only when candidate renders become expensive

Later, consider differentiable DSP only after the synth topology and loss are
stable.

### 7. Promote Fitted Instrument Presets

A fitted instrument preset can be promoted only if:

- it is generated from a committed script/config
- it renders deterministically
- it beats the previous baseline on the target report
- it passes a short human A/B check

Do not promote "current best" files that fail gates unless the filename clearly
says `least_bad` or `baseline_fail`.

### 8. Event-Level Reconstruction

After instrument timbre works, add transcription:

- note onset
- pitch or pitch contour
- duration
- velocity/loudness
- articulation class
- drum/percussion hit class
- section/tempo map

Only then should full-track reconstruction become the main objective again.

## What To Keep From Current Work

Keep:

- `scripts/fetch_reference_wav.sh`
- stem extraction and QC scripts
- profile/target-contract scripts
- WAV render helpers
- instrument/perceptual comparison scripts
- A/B clip exporter
- runtime preset/manifest loading scaffolding
- existing status/evaluation docs

Keep as baseline, not as success:

- Americana procedural renderer
- current best Americana preset and reports
- existing failed optimization artifacts, if needed outside git

Do not keep generated caches or bulky outputs in source control:

- `.zig-cache/`
- `.zig-global-cache/`
- Python `__pycache__/`
- generated `artifacts/`
- downloaded `references/` WAV files

## Immediate Cleanup Goal

Before starting new work:

1. Commit source/docs/scripts that are useful enough to preserve.
2. Keep generated artifacts out of git unless a small fixture is explicitly
   needed.
3. Record that the current audio quality is poor and why.
4. Record that the next development direction is isolated-note inverse fitting.
5. Leave the working tree clean or nearly clean.

## First Task Tomorrow

Implement a small target-validation pass for guitar clips:

- read `targets_manifest.json`
- recompute pitch stats per target
- reject contradictory MIDI/pitch estimates
- reject low voiced-ratio clips
- emit a cleaned target manifest

Then run the isolated guitar optimization only on accepted targets.
