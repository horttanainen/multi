# Single Pluck Iteration Workflow

This document defines the working loop for acoustic guitar single-note
iterations. Update this file when the process changes.

## Rule

Do not make blind synth changes. Each round needs an explicit baseline, generated
candidate WAVs, and a scoring report before any candidate is promoted.

## Current Accepted Baseline

- WAV: `artifacts/instrument_renders/target_set_fit_pass1_scorer2_fit_001_first_pluck.wav`
- Report: `artifacts/music_reports/target_set_fit_pass1_scorer2_compare.json`
- Target-set score: `56.3654`
- Parameters:
  `pluck_position=0.1678`, `pluck_brightness=0.8165`,
  `string_mix=1.7309`, `body_mix=1.3536`, `attack_mix=0.8253`,
  `mute=0.114`, `string_decay=0.7765`, `body_gain=1.0442`,
  `body_decay=0.7817`, `body_freq=0.8752`, `pick_noise=0.6683`,
  `attack_gain=0.6903`, `attack_decay=0.5456`,
  `inharmonicity=0.4292`, `high_decay=0.6963`,
  `output_gain=0.9934`.
- Promotion: listener picked `fit_001` by ear, then scorer version 5 ranked it
  first across the accepted target set.
- Runner default candidate parameters now inherit this baseline unless a
  candidate overrides them.

## Pause Point: 2026-05-09

Stop point for the next session:

- We are in Milestone 5, event-level guitar phrase work.
- The active synth direction is now `guitar-faust-pluck`, not
  `guitar-admittance-pluck`.
- Reason: listener feedback says the direct Faust branch has the convincing
  ringing note that the earlier modal/body and split-waveguide branches lacked.
- Working Faust single-pluck audition:
  `artifacts/instrument_renders/target_set_faust_direct_pluck_pass1_audition/by_candidate_03_faust_direct_moredepth.wav`
- Working Faust phrase audition:
  `artifacts/event_phrase_renders/guitar_event_phrase_faust_direct_moredepth_pass1/audition_reference_then_generated.wav`
- Main Faust reports:
  - target-set:
    `artifacts/music_reports/target_set_faust_direct_pluck_pass1_compare.json`
  - phrase:
    `artifacts/music_reports/guitar_event_phrase_faust_direct_moredepth_pass1_phrase_compare.json`
- Current score position:
  - `faust_direct_moredepth` target-set score `45.7017`
  - `faust_direct_moredepth` phrase score `47.5494`
  - phrase score is close to `admittance_moredepth` (`47.7471`)
- Important direction rule: keep the Faust string dry and ringing first. Do not
  reintroduce the previous body bank or bridge-body resonator path until the
  Faust string itself is promoted as the working phrase timbre.
- Next concrete step:
  1. Commit the cleaned `guitar-faust-pluck` implementation and workflow update.
  2. Run a focused Faust-only parameter pass for decay, brightness, simple
     bridge-filter absorption/brightness, and excitation balance.
  3. Listener-review the best Faust single-pluck and phrase auditions against
     `admittance_moredepth` and `blend_more_body`.
  4. Promote Faust as the working phrase timbre if it still wins by ear, even if
     isolated target-set score remains lower.
  5. After Faust is promoted, add a real bridge/coupling milestone before any
     body layer. The current Faust branch has a useful bridge filter, but it
     does not yet have the bridge/admittance/body coupling work from the earlier
     research branch.

## Milestones

These are the tracking milestones for this acoustic guitar pluck work. Keep this
section aligned with the round history below.

- [x] Milestone 1: Single Pluck Baseline
  - Goal: one generated pluck beats the previous baseline by score and by ear.
  - Done when generated WAVs exist, report exists, listener picks a winner, and
    the winner is promoted only after scorer/listener agreement.
  - Status: completed. Accepted baseline is
    `artifacts/instrument_renders/first_pluck_param_sweep2_pos175_body115.wav`
    with score `74.6340`.

- [x] Milestone 2: Parameterized Guitar Probe
  - Goal: expose research-backed guitar controls as candidate parameters so
    rounds use controlled sweeps instead of editing constants.
  - Controls now exposed include `pluck_position`, `pluck_brightness`,
    `string_mix`, `body_mix`, `attack_mix`, `mute`, `string_decay`,
    `body_gain`, `body_decay`, `body_freq`, `pick_noise`, `attack_gain`,
    `attack_decay`, `bridge_coupling`, `inharmonicity`, `high_decay`, and
    `output_gain`.
  - Status: completed for the single-pluck probe.

- [x] Milestone 3: Multi-Pluck Target Set
  - Goal: extract and validate several guitar plucks across pitch and dynamics
    so the score cannot overfit one clip.
  - Done when octave/pitch checks reject bad targets; each target has onset,
    pitch, duration, and confidence; and the scorer ranks candidates across a
    target set instead of one WAV.
  - Status: completed. Listener accepted the target set:
    `artifacts/music_targets/americana_raga/guitar/selected/pluck_target_set.json`.
    `scripts/run_guitar_pluck_round.py --target-set ...` now ranks candidates by
    average score across the selected targets.

- [x] Milestone 4: Real Fitting Loop
  - Goal: use random search, CMA-ES, or differential evolution over exposed
    parameters so scripts produce reproducible presets instead of hand state.
  - Done when the optimizer renders candidates, the scorer ranks them, the best
    preset is reproducible, and the listener confirms improvement.
  - Status: completed. `target_set_fit_pass1` produced listener winner
    `fit_001`; scorer version 5 calibration reranked it first in
    `target_set_fit_pass1_scorer2`, and the maintained baseline defaults now
    inherit those parameters.

- [ ] Milestone 5: Faust Event-Level Guitar
  - Goal: make `guitar-faust-pluck` the working instrument for a convincing
    guitar phrase: ringing note, onset, decay, event timing, velocity, and phrase
    continuity.
  - Status: in progress. The active direction is `guitar-faust-pluck`.
    `guitar-admittance-pluck` and `blend_more_body` are comparison references,
    not the main branch.

- [x] Milestone 5F: Faust Direct Working Branch
  - Goal: replace the failed split-waveguide experiment with a closer Faust
    working string model.
  - Scope: `pluckString`-style low-passed noise excitation, steel-string
    `smooth(0.05)` damping, and the STK/Faust two-zero bridge filter.
  - Done when the branch renders through `music-probe`, scores against the
    target set and phrase window, and listener feedback confirms the missing
    ringing note is present.
  - Status: completed on 2026-05-09. `guitar-faust-pluck` scored `45.7017` on
    the target set and `47.5494` on the phrase. Listener feedback: it sounds
    really good. The failed `guitar-waveguide-split` code path was removed.

- [ ] Milestone 5A: Promote Faust Phrase Timbre
  - Goal: decide whether `guitar-faust-pluck` becomes the working phrase timbre.
  - Done when the listener compares Faust against `admittance_moredepth` and
    `blend_more_body`, confirms the Faust branch by ear, and the selected Faust
    preset/render is documented as the working phrase timbre.
  - Current front-runner:
    `artifacts/event_phrase_renders/guitar_event_phrase_faust_direct_moredepth_pass1/audition_reference_then_generated.wav`

- [ ] Milestone 5B: Faust Parameter Pass
  - Goal: tune only the working Faust string path before adding body modeling.
  - Scope: string decay, bridge-filter absorption/brightness, pluck brightness,
    excitation level, output level, and velocity response.
  - Done when a small Faust-only sweep produces reproducible presets and a
    listener-selected winner that preserves the ringing note.

- [ ] Milestone 5C: Faust Bridge Coupling
  - Goal: give the working Faust string an explicit bridge/coupling stage before
    adding any body layer.
  - Scope: decide the bridge readout/coupling signal, termination behavior, and
    whether to keep the STK/Faust bridge filter alone or combine it with the
    earlier bridge-admittance idea. Do not add body resonators in this milestone.
  - Done when a bridge-coupled Faust variant keeps the ringing note, avoids the
    plastic-barrel/drum transient, and is documented against the dry Faust
    baseline by score and ear.

- [ ] Milestone 5D: Faust Body Handoff
  - Goal: add acoustic depth after the bridge coupling is stable.
  - Scope: optional, low-level bridge-driven body layer or commuted response fed
    from the Faust bridge signal. Do not use the old direct body transient path.
  - Done when a body-enabled Faust variant beats or matches dry/bridge-only
    Faust by ear and does not obscure the string note.

- [ ] Milestone 5E: Better Faust Event Rendering
  - Goal: improve phrase rendering beyond one detected pluck per event using the
    Faust instrument.
  - Scope: note duration, decay overlap, chord interaction, mute/release
    behavior, pitch contours, and dynamic-dependent brightness.

- [ ] Milestone 5G: Multi-Phrase Faust Validation
  - Goal: prevent overfitting the current phrase window.
  - Done when the Faust branch is scored and auditioned across multiple accepted
    phrase snippets, analogous to the completed multi-pluck target set.

- [ ] Milestone 5H: Faust Provenance And License
  - Goal: make the code provenance explicit before broader integration.
  - Done when copied/ported Faust-derived code is documented with source links
  and the appropriate license notice is added if we keep it.

- [ ] Milestone 5I: Performance Details
  - Goal: add guitar-specific performance behavior after the Faust timbre is
  chosen.
  - Scope: slight timing spread, body/sympathetic continuity between notes,
    strum/chord behavior, and more realistic damping between events.

- [ ] Milestone 6: Procedural Faust Integration
  - Goal: move the winning Faust model/preset from probe and audition scripts
    into the actual generated music path.
  - Done when procedural Americana guitar uses the selected Faust model and
    passes the normal render, compare, build, and smoke-test workflow.

Research-backed improvement backlog:

- Faust-informed waveguide result: the independent split waveguide is useful as
  a reference/component idea, but the first implementation is not a current
  timbre candidate. Target-set round
  `target_set_faust_waveguide_probe_pass1` ranked `admittance_moredepth` first
  at `62.0208`; the best split-waveguide variant was
  `waveguide_split_blend_more_body` at `36.3894`. Phrase round
  `guitar_event_phrase_waveguide_split_blend_more_body_pass1` scored `38.9121`,
  below `admittance_moredepth` (`47.7471`), `admittance_bodyclear` (`47.9979`),
  and `blend_more_body` (`48.0871`).
- Faust review correction: round `target_set_faust_waveguide_probe_pass2`
  reduced per-sample travel loss and injected a Faust-style low-passed pluck
  excitation into the waveguide. Best split-waveguide target-set score improved
  to `39.9915` (`waveguide_split_moredepth`), and phrase round
  `guitar_event_phrase_waveguide_split_moredepth_pass2` improved to `41.6391`.
  Still not competitive by scorer, but worth listener review because the failure
  mode is now less dominated by isolated pick clicks.
- Faust ring correction: round `target_set_faust_waveguide_probe_pass3`
  changed the bridge/body drive from near-zero rigid-termination displacement
  toward incident/reflected bridge-wave force, and raised string reflection so
  the pluck leaves a measurable ringing tail. Best split-waveguide target-set
  score improved to `43.5497` (`waveguide_split_bodyclear`). Phrase scores did
  not improve (`waveguide_split_bodyclear` `40.5504`,
  `waveguide_split_moredepth` `39.2757`), so treat this as a listener-review
  timbre branch rather than a scorer winner.
- Direct Faust port branch: added `guitar-faust-pluck`, a closer working copy
  of Faust's useful guitar pieces: `pluckString`-style low-passed noise
  excitation, steel-string `smooth(0.05)` damping, and the STK/Faust two-zero
  bridge filter. This branch intentionally skips the previous body bank because
  Faust's acoustic `guitarBody` is only a pass-through placeholder. Target-set
  round `target_set_faust_direct_pluck_pass1` scored `45.7017` for
  `faust_direct_moredepth`, above the split-waveguide branch (`43.5497`) but
  below `admittance_moredepth` (`62.0208`). Phrase round
  `guitar_event_phrase_faust_direct_moredepth_pass1` scored `47.5494`, close to
  `admittance_moredepth` (`47.7471`). This is the first Faust-derived branch
  with a convincing ringing note by scorer and listener review. The failed
  `guitar-waveguide-split` code path was removed before commit.
- Body coupling correction: route the body mainly from string/bridge-like motion
  instead of adding a separate contact/body hit on every note.
- PDF-backed body rule: Woodhouse starts from string properties plus bridge
  input admittance/admittance matrix; Lee/French integrates a transmission-line
  string with a measured-admittance body at the bridge boundary. In both cases,
  body color comes from frequency-dependent bridge coupling, not an independent
  per-note sound layer.
- Better body model: split low air/top modes from higher body modes, add
  notches/antiresonance, tune decay per mode.
- Better pluck model: pluck position comb effect, finite contact/release time,
  pick angle, separate displacement and velocity excitation.
- Better two-polarization model: actual energy exchange/coupling instead of two
  mixed modal banks.
- Better commuted synthesis: precompute a body-shaped excitation table, then
  feed a cleaner waveguide.
- Better damping: frequency-dependent decay, especially making high partials die
  faster without killing attack.
- Better scorer: add listener-aligned penalties for piercingness, tonal
  flatness, beepy artifacts, and missing body transient.

## Rejected Diagnostic Round

- Round: `first_pluck_diagnostic_contrast1`
- Report: `artifacts/music_reports/first_pluck_diagnostic_contrast1_compare.json`
- Highest scorer:
  `artifacts/instrument_renders/first_pluck_diagnostic_contrast1_muted_body.wav`
- Score: `75.6230`
- Parameters: `mute=1.0`, `string_mix=0.20`, `body_mix=2.80`,
  `attack_mix=2.00`, `body_decay=0.40`, `attack_gain=1.90`, plus the current
  baseline defaults.
- Listener result: reject `muted_body`; it scores highest but sounds like a beep,
  not a metallic guitar string.
- Listener-preferred branches: `metallic_stiff` or current baseline.
- Status: do not promote from this diagnostic round. Use a focused metallic
  string sweep next.

## Focused Metallic Round

- Round: `first_pluck_metallic_focus1`
- Report: `artifacts/music_reports/first_pluck_metallic_focus1_compare.json`
- Highest scorer:
  `artifacts/instrument_renders/first_pluck_param_sweep2_pos175_body115.wav`
- Score: `74.6340`
- Best new metallic scorer:
  `artifacts/instrument_renders/first_pluck_metallic_focus1_metallic_shorter.wav`
- Best new metallic score: `74.2031`
- Listener result: keep the current baseline. `metallic_stiff` and related
  variants are distinctive but do not beat the baseline by ear.
- Status: closed with no promotion.

## Multi-Pluck Target Set

- Manifest: `artifacts/music_targets/americana_raga/guitar/selected/pluck_target_set.json`
- Listener result: accepted as a good target set.
- Targets:
  - `first_pluck`, G4, `80.715s`
  - `pluck_001_target_001`, D2, `354.325s`
  - `pluck_004_target_004`, F#4, `148.065s`
  - `pluck_008_target_008`, E4, `245.705s`
  - `pluck_000_target_000`, F#4, `121.205s`
  - `pluck_002_target_002`, G4, `133.705s`
- Validation round: `target_set_validation1`
- Aggregate report: `artifacts/music_reports/target_set_validation1_compare.json`
- Result: current baseline narrowly beats `metallic_shorter` across the target
  set, average score `67.6516` vs `67.5924`.

## Real Fitting Loop

- Script: `scripts/optimize_guitar_pluck_target_set.py`
- First pass: `target_set_fit_pass1`
- Seed: `20260503`
- Samples: `4` plus baseline
- Candidate manifest:
  `artifacts/music_presets/target_set_fit_pass1_candidates.json`
- Aggregate report: `artifacts/music_reports/target_set_fit_pass1_compare.json`
- Best preset proposal:
  `artifacts/music_presets/target_set_fit_pass1_best_guitar_pluck_params.json`
- Audition pack:
  `artifacts/instrument_renders/target_set_fit_pass1_audition/audition_manifest.json`
- Scored winner: baseline, average score `67.6516`.
- Listener winner: `fit_001`, average score `62.7289`.
- Listener-winner preset:
  `artifacts/music_presets/target_set_fit_pass1_listener_winner_fit_001_guitar_pluck_params.json`
- Scorer calibration pass: `target_set_fit_pass1_scorer2`
- Calibrated report:
  `artifacts/music_reports/target_set_fit_pass1_scorer2_compare.json`
- Calibrated audition pack:
  `artifacts/instrument_renders/target_set_fit_pass1_scorer2_audition/audition_manifest.json`
- Calibrated winner: `fit_001`, average score `56.3654`.
- Result: promote `fit_001` as the maintained baseline after listener/scorer
  agreement.

## Event-Level Guitar

- Script: `scripts/render_guitar_event_phrase.py`
- First pass: `guitar_event_phrase_pass1`
- Reference phrase:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass1/reference_phrase.wav`
- Generated phrase:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass1/generated_phrase.wav`
- Audition phrase:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass1/audition_reference_then_generated.wav`
- Event manifest:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass1/event_phrase_manifest.json`
- Score report:
  `artifacts/music_reports/guitar_event_phrase_pass1_phrase_compare.json`
- Phrase score: `42.5575`
- Detected/rendered events: `8`
- Listener feedback: the first phrase pass had too much separate body knock on
  every note and not enough plucking sharpness.
- Pass 2 comparison pack:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass2_compare/guitar_event_phrase_pass2_compare.wav`
- Pass 2 comparison manifest:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass2_compare/guitar_event_phrase_pass2_compare.json`
- Pass 2 variants:
  - `guitar_event_phrase_pass2_integrated_body`, score `43.4326`
  - `guitar_event_phrase_pass2_sharp_string`, score `43.6971`
  - `guitar_event_phrase_pass2_blended_chord`, score `43.5129`
- Listener feedback: `integrated_body` is better, but the body onset still
  sounds too sharp and drum-like.
- Pass 3 comparison pack:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass3_compare/guitar_event_phrase_pass3_compare.wav`
- Pass 3 comparison manifest:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass3_compare/guitar_event_phrase_pass3_compare.json`
- Pass 3 variants:
  - `guitar_event_phrase_pass3_soft_body_onset`, score `44.5908`
  - `guitar_event_phrase_pass3_less_thump`, score `45.0439`
  - `guitar_event_phrase_pass3_soft_blend`, score `44.9971`
- Result: Milestone 5 loop exists. Pass 3 keeps `integrated_body` as the
  comparison anchor and tests lower attack-body level, lower event velocity,
  less low-body thump, and brighter string/pick compensation.
- Listener feedback: `soft_blend` may be best, but the string is too metallic
  and the phrase lacks the depth of the reference.
- Pass 4 comparison pack:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass4_compare/guitar_event_phrase_pass4_compare.wav`
- Pass 4 comparison manifest:
  `artifacts/event_phrase_renders/guitar_event_phrase_pass4_compare/guitar_event_phrase_pass4_compare.json`
- Pass 4 variants:
  - `guitar_event_phrase_pass4_warm_depth`, score `46.6696`
  - `guitar_event_phrase_pass4_round_depth`, score `44.9035`
  - `guitar_event_phrase_pass4_deep_pick`, score `45.1976`
- Result: Pass 4 keeps the softened body onset, reduces metallic brightness,
  lowers high-partial decay, and adds more sustained body depth.
- Listener feedback: reject this direction. The phrase variants added separate
  sounds around the note instead of fixing the instrument model. The body should
  be incorporated into the chord/string response and should not start like a
  drum or side-hit.
- Pass 4 correction: do not use `warm_depth`, `round_depth`, or `deep_pick` as
  anchors. This was the point where parameter tuning started adding or exposing
  non-guitar transient sounds instead of fixing the model.
- Backtrack decision: keep `guitar-modal-pluck` as the only default probe
  candidate. Park the other algorithms from default rounds. Revisit the
  body-coupling implementation before generating more phrase variants.
- Implementation finding before the correction: `guitar-modal-pluck` injected
  the contact transient directly into both the main body bank and a separate
  attack-body bank. This likely caused the separate body-hit sound.
- Body-coupled correction pass:
  - Code change: removed the separate `attack_body` layer from
    `guitar-modal-pluck`; removed low thump from the contact signal; body input
    is now driven from bridge-force/string-motion instead of direct contact
    injection.
  - Pluck target-set round: `target_set_body_coupled_pass1`
  - Target-set report:
    `artifacts/music_reports/target_set_body_coupled_pass1_compare.json`
  - Target-set score: `56.1290`
  - Pluck audition pack:
    `artifacts/instrument_renders/target_set_body_coupled_pass1_audition/audition_manifest.json`
  - Phrase round: `guitar_event_phrase_body_coupled_pass1`
  - Phrase report:
    `artifacts/music_reports/guitar_event_phrase_body_coupled_pass1_phrase_compare.json`
  - Phrase score: `43.3790`
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_body_coupled_pass1_compare/body_coupled_vs_previous.wav`
  - Comparison cues: cue 1 reference, cue 2 previous `pass4_round_depth`, cue 3
    body-coupled correction.
  - Status: listener review pending. Do not promote until confirmed by ear.
- No-added-noise correction pass:
  - Code change: removed the remaining synthetic contact/release noise path from
    `guitar-modal-pluck`. The maintained path now has no added pick-noise,
    scrape, release click, thump, or attack-body sound; it uses modeled string
    motion and bridge/body response only.
  - Pluck target-set round: `target_set_no_added_noise_pass1`
  - Target-set report:
    `artifacts/music_reports/target_set_no_added_noise_pass1_compare.json`
  - Target-set score: `56.1101`
  - Pluck audition pack:
    `artifacts/instrument_renders/target_set_no_added_noise_pass1_audition/audition_manifest.json`
  - Phrase round: `guitar_event_phrase_no_added_noise_pass1`
  - Phrase report:
    `artifacts/music_reports/guitar_event_phrase_no_added_noise_pass1_phrase_compare.json`
  - Phrase score: `43.3442`
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_no_added_noise_pass1_compare/no_added_noise_vs_soft_blend.wav`
  - Comparison cues: cue 1 reference, cue 2 last acceptable `pass3_soft_blend`,
    cue 3 no-added-noise correction.
  - Listener feedback: rejected. Cue 3 in
    `no_added_noise_vs_soft_blend.wav` is hated by ear.
  - Status: do not promote. The maintained `guitar-modal-pluck` implementation
    was restored to the last accepted baseline state after this rejection.
- Explicit bridge-body candidate pass:
  - Code change: added `guitar-bridge-body-pluck` as a separate probe
    instrument. The accepted `guitar-modal-pluck` baseline remains unchanged.
  - Model difference: the candidate keeps the baseline string/contact direct
    path but drives body color from bridge-force/string-motion instead of direct
    contact injection into body resonators.
  - Pluck target-set round: `target_set_bridge_body_variant_pass1`
  - Target-set report:
    `artifacts/music_reports/target_set_bridge_body_variant_pass1_compare.json`
  - Target-set ranking: baseline `56.3654`, bridge-body `55.6635`.
  - Pluck audition pack:
    `artifacts/instrument_renders/target_set_bridge_body_variant_pass1_audition/audition_manifest.json`
  - Phrase round: `guitar_event_phrase_bridge_body_variant_pass1`
  - Phrase report:
    `artifacts/music_reports/guitar_event_phrase_bridge_body_variant_pass1_phrase_compare.json`
  - Phrase scores: baseline pass1 `42.5575`, bridge-body `44.8019`.
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_bridge_body_variant_pass1_compare/bridge_body_vs_baseline.wav`
  - Comparison cues: cue 1 reference, cue 2 accepted-baseline phrase pass1,
    cue 3 bridge-body candidate.
  - Listener feedback: bridge-body may be better because it lacks the audible
    thumps.
  - Status: leading candidate by ear, but not promoted yet. Preserve the
    no-contact-to-body-resonator property in the next sweep.
- Bridge-body focused sweep 1:
  - Invariant: every new candidate uses `guitar-bridge-body-pluck`, preserving
    no contact/pick transient into body resonators.
  - Goal: tune depth, warmth, and direct attack around the bridge-body candidate
    without returning to separate body thumps.
  - Pluck target-set round: `target_set_bridge_body_sweep1`
  - Target-set report:
    `artifacts/music_reports/target_set_bridge_body_sweep1_compare.json`
  - Target-set ranking:
    - baseline `56.3654`
    - bridge_depth `55.9722`
    - bridge_round `55.9005`
    - bridge_sharp `55.7060`
    - bridge_anchor `55.6635`
    - bridge_warm `55.3305`
  - Pluck audition pack:
    `artifacts/instrument_renders/target_set_bridge_body_sweep1_audition/audition_manifest.json`
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_bridge_body_sweep1_compare/bridge_body_sweep1.wav`
  - Phrase cues:
    - cue 1 reference
    - cue 2 accepted-baseline phrase pass1, score `42.5575`
    - cue 3 bridge_anchor, score `44.8019`
    - cue 4 bridge_depth, score `44.3954`
    - cue 5 bridge_round, score `44.6776`
    - cue 6 bridge_sharp, score `44.4773`
  - Status: listener review pending. Scorer prefers bridge_anchor for phrase
    and baseline for isolated target-set average.
- Bridge-body random search 24 pass:
  - Research basis added before run: web search reinforced bridge
    mobility/admittance as the coupling control, body-induced partials as a mix
    of quasi-harmonic string/body content and short body-mode transients, and
    commuted/body-response modeling as future separate-candidate work.
  - Code change: `scripts/optimize_guitar_pluck_target_set.py` now searches
    `bridge_coupling`, because bridge mobility/coupling is a primary physical
    control in the sources.
  - Instrument: `guitar-bridge-body-pluck`
  - Seed: `2026050317`
  - Samples: `24` plus bridge-body baseline.
  - Target-set report:
    `artifacts/music_reports/target_set_bridge_body_random24_pass1_compare.json`
  - Best isolated target-set candidate: `fit_019`, score `60.2583`, min score
    `42.1317`.
  - Top target-set audition pack:
    `artifacts/instrument_renders/target_set_bridge_body_random24_pass1_audition/audition_manifest.json`
  - Best preset:
    `artifacts/music_presets/target_set_bridge_body_random24_pass1_best_guitar_pluck_params.json`
  - Important result: `fit_019` improves isolated target-set score strongly but
    does not transfer to phrase scoring.
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_bridge_random24_pass1_compare/bridge_random24_phrase_compare.wav`
  - Phrase cues:
    - cue 1 reference
    - cue 2 accepted-baseline phrase pass1, score `42.5575`
    - cue 3 bridge_anchor, score `44.8019`
    - cue 4 random `fit_019`, score `42.6999`
    - cue 5 random `fit_008`, score `45.3245`
    - cue 6 random `fit_020`, score `45.0082`
    - cue 7 random `fit_012`, score `42.3523`
  - Status: listener review pending. Scorer's best phrase candidate is
    `fit_008`; scorer's best isolated-pluck candidate is `fit_019`.
- Admittance pluck implementation pass:
  - Code change: added `guitar-admittance-pluck` as a separate probe
    instrument. The accepted `guitar-modal-pluck` baseline and
    `guitar-bridge-body-pluck` candidate remain available.
  - Research basis: Woodhouse's bridge input-admittance/coupled
    string-body framing and Lee/French's bridge-force/body-admittance result.
    The implementation is still an approximation: it uses admittance-weighted
    modal string partials, two polarization banks, frequency-dependent damping
    near body modes, and a low-passed bridge-force drive into the body bank.
    It does not use a measured admittance table yet.
  - Important correction between pass 1 and pass 2: low air/top resonance
    weighting now compares partial frequency against scaled body-mode centers,
    and body drive is smoothed so body depth is less like an independent hit.
  - Pluck target-set round: `target_set_admittance_pluck_pass2`
  - Target-set report:
    `artifacts/music_reports/target_set_admittance_pluck_pass2_compare.json`
  - Target-set ranking:
    - `admittance_moredepth`: `62.0208`, min `49.6656`
    - `admittance_clear`: `61.6243`, min `55.9368`
    - `admittance_softbridge`: `61.2153`, min `49.7433`
    - `admittance_balanced`: `60.5310`, min `47.6723`
    - accepted baseline: `56.3654`, min `35.0398`
    - bridge-body: `55.6635`, min `41.0273`
  - Best preset:
    `artifacts/music_presets/target_set_admittance_pluck_pass2_moredepth_guitar_pluck_params.json`
  - Pluck audition pack:
    `artifacts/instrument_renders/target_set_admittance_pluck_pass2_audition/audition_manifest.json`
  - Phrase checks:
    - `guitar_event_phrase_admittance_moredepth_pass2`, score `47.7471`
    - `guitar_event_phrase_admittance_clear_pass2`, score `46.0863`
  - Phrase comparison pack:
    `artifacts/event_phrase_renders/guitar_event_phrase_admittance_pass2_compare/admittance_pass2_phrase_compare.wav`
  - Phrase cues:
    - cue 1 reference
    - cue 2 accepted baseline phrase pass1, score `42.5575`
    - cue 3 bridge-body candidate, score `44.8019`
    - cue 4 `admittance_moredepth`, score `47.7471`
    - cue 5 `admittance_clear`, score `46.0863`
  - Status: listener review pending. If cue 4 wins by ear, promote
    `admittance_moredepth` as the new working guitar model/preset.
  - Rejected follow-up: `target_set_admittance_pluck_pass3` tested body-mode
    retuning closer to the raw paper frequencies (`body_freq=0.95` and `1.00`)
    plus darker/woodier variants. None beat `admittance_moredepth`; the best
    pass-3 result remained the same pass-2 settings at `62.0208`.
  - Final moredepth/bodyclear A/B:
    - Phrase comparison pack:
      `artifacts/event_phrase_renders/guitar_event_phrase_admittance_final_ab_compare/admittance_moredepth_bodyclear_final_ab.wav`
    - Phrase cues:
      - cue 1 reference
      - cue 2 accepted baseline phrase pass1, score `42.5575`
      - cue 3 `admittance_moredepth`, score `47.7471`
      - cue 4 `admittance_bodyclear`, score `47.9979`
      - cue 5 `blend_bodyfreq975`, score `47.9262`
      - cue 6 `blend_more_string`, score `47.7881`
      - cue 7 `blend_more_body`, score `48.0871`
    - Listener feedback: cue 7, `blend_more_body`, may be the best by ear.
    - Saved front-runner preset:
      `artifacts/music_presets/admittance_blend_more_body_listener_front_runner_guitar_pluck_params.json`
    - Important scorer disagreement: the phrase scorer and listener preference
      favor cue 7, but the isolated target-set scorer still strongly favors
      `admittance_moredepth`. Treat cue 7 as the current ear front-runner, not a
      fully promoted baseline, until the scoring rule is reconciled or listener
      confirms final promotion.

## Round Loop

1. Pick the current baseline WAV.
2. Choose one narrow change to test.
3. Render every candidate through the music generation entrypoint:

```bash
zig build music-probe -- guitar-modal-pluck --freq 390.2439 --velocity 0.8 --duration 0.22 --out <candidate.wav>
```

4. Score the generated WAVs against the selected reference target:

```bash
pyenv exec python3 scripts/compare_reference_target.py \
  --target artifacts/music_targets/americana_raga/guitar/selected/first_pluck.wav \
  --generated <candidate.wav> \
  --output <report.json>
```

5. Report only the useful review paths:
   - generated candidate WAV paths
   - scoring report path
   - last-round winner path
   - highest-scoring candidate path
6. The listener checks the WAVs by ear.
7. If the listener agrees that the note improved and the highest scorer is best
   by ear, promote that candidate as the new baseline.
8. If the listener likes a lower-scoring file best, adjust the scoring script
   before using the score for promotion.
9. If no candidate sounds better, keep the old baseline and change the synth
   model or candidate set for the next round.

## Done Criteria

A round task is not done until:

- audio files were generated through `music-probe`
- the scorer ran successfully
- paths were reported for generated WAVs, the JSON report, previous winner, and
  the highest-scoring file
- the listener made the promotion decision

## Automation

Use `scripts/run_guitar_pluck_round.py` to render and score a round while keeping
the output concise. With no `--candidate` arguments, it renders only the
maintained `guitar-modal-pluck` candidate and includes the previous winner in the
scoring set. Parked legacy instruments can still be tested with explicit
`--candidate` arguments, but they are no longer part of the default comparison
set. Pass one or more explicit `--candidate` arguments for a narrow A/B round.

Candidate specs can include physical guitar probe parameters:

- `pluck_position`
- `pluck_brightness`
- `string_mix`
- `body_mix`
- `attack_mix`
- `mute`
- `string_decay`
- `body_gain`
- `body_decay`
- `body_freq`
- `pick_noise`
- `attack_gain`
- `attack_decay`
- `bridge_coupling`
- `inharmonicity`
- `high_decay`
- `output_gain`

Example focused sweep:

```bash
pyenv exec python3 scripts/run_guitar_pluck_round.py \
  --round-id first_pluck_param_sweep \
  --candidate name=baseline,instrument=guitar-modal-pluck \
  --candidate name=body_plus,instrument=guitar-modal-pluck,body_gain=1.15 \
  --candidate name=pluck_back,instrument=guitar-modal-pluck,pluck_position=0.170
```

The script should not decide promotion by itself; it only prints the evidence
needed for the listener decision.

For target-set fitting rounds, build an audition pack after scoring so the
listener can compare algorithms without manually opening every generated WAV:

```bash
pyenv exec python3 scripts/build_guitar_pluck_audition_pack.py \
  --report artifacts/music_reports/target_set_fit_pass1_compare.json
```

The pack writes two listening views:

- `by_candidate_*.wav`: one algorithm across all target notes.
- `by_target_*.wav`: reference plus ranked algorithms for one target note.

Each clip is loudness-normalized and preceded by cue beeps. The cue order is
recorded in `audition_manifest.json`.
