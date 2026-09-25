# Hard techno procedural music investigation

Investigated 2026-09-24 against commit `657ac10` and the existing working tree.
This document records the preimplementation findings and proposed roadmap.
Phases 1 and 2 are committed with the user's selected tight low end and preferred
Warehouse groove; Machine was also positively received. Phase 3 adds a complete
128-bar Warehouse-led arrangement with a Machine contrast section. Validation
and independent review are complete; Phase 3 is committed as `957e54f`.
The user then requested the missing recognizable synth lead. Phase 4 adds lead
auditions before game integration, which becomes Phase 5. The current iteration
follows the user's preference for Machine/Buzz and request for darker, rougher
industrial techno. The user selected Corrosion for now, with further tone tuning
possible later. Basic Hard Techno game integration is retained, including saved
settings, playback selection and audio-thread synchronization. The experimental
lead/drum sliders, range bars and temporary lead multipliers were removed at the
user's request when accepting the sustained bass. The original style-preview
tempo-loss fix and its regression coverage remain. See
[MUSIC_HANDOFF.md](../MUSIC_HANDOFF.md#phase-4-synth-lead-auditions)
for the full track, transition previews, results and current status.

The user subsequently clarified that only the lead should be editable, that the
current sliders have too little audible effect, and that controls must name real
audio parameters. That editor revision is deferred: the user requested
an independent bassline first, then accepted its sustained iteration. Phase 6 adds a saw/sine bass voice with a bass bus,
game defaults and before/after auditions. The user found the first short-note
pattern too percussive, so the current iteration uses sustained legato notes and
an independent four-bar counterline behind the lead. See
[the current phase](../MUSIC_HANDOFF.md#phase-6-independent-bassline-before-the-lead-editor).
The sustained iteration passes 34 music tests, two menu tests, six finite/unclipped
renders, bass-off regression comparisons and build/smoke checks. Independent
review found a P2 comparison-reference overwrite hazard, now fixed with collision
checks; the additional live-tempo regression passes in both directions. The user
accepted the sustained bass and explicitly requested committing it with the
slider rollback. Final rollback validation passes 33 music tests (the obsolete
controls test was removed), two menu/SDL tests and build/smoke; both the loop
and full track remain byte-identical to the accepted sustained-bass renders.

The user's latest request raises progression and repeated openings: their saved
configuration initially selected the 6.4-second loop (later changed to Full Track), and the existing 204.8-second track
restarts a fixed score. Random seeds affect noise, not the composition or start.
The next proposed phase is an ongoing arrangement with shifts every 1–3 minutes
and periodic playback checkpoints to resume across development relaunches. This
is recorded planning; no progression or resume changes are included in the bass
iteration. See the corresponding next-phase proposal in MUSIC_HANDOFF.md.

Additional user direction: remove the wooden/taiko-like character from background
percussion. All hard-techno sounds should suggest machinery, synths or a drum kit.
The current metal bus uses the shared Atarigane voice; isolate and audition that
part as the first candidate for replacement or redesign. This requirement is
recorded for the next sound iteration; percussion is unchanged in the bass work.

The user has explicitly made earlier music-generation guidance optional because
the previous approach gave poor results. Treat this document's musical and
synthesis recommendations as hypotheses, and prioritize listening results when
choosing the next approach.

Hard techno is a promising direction for this engine. Its instruments can be
designed directly with synthesis, and a strong repeating groove gives us a small,
audible first milestone. The main work is sound design, low-frequency mixing,
and deliberate musical structure. Adding more independent random choices will
not establish those qualities.

The working artistic assumption is dark, driving techno at 150 BPM, with a
distorted kick, rolling rumble, sparse percussion, and a restrained acid motif.
That is a proposed starting point, not a user-selected reference or a definition
of the genre.

## Baseline implementation

| Component | What we can reuse | What techno needs |
| --- | --- | --- |
| `src/music/dsp.zig` | 48 kHz synthesis, envelopes, noise, filters, delays, reverb, panning | Controlled saturation, ducking, smoothed parameters, resonant filtering, alias-suppressed saw/pulse oscillators |
| `src/music/instruments.zig` | Shared instrument ownership; noise/metal hi-hat and modal percussion building blocks | A purpose-built electronic kick, open/closed hats with choking, clap, monophonic bass/acid voice |
| `src/music/composition.zig` | Sample-driven 16-step sequencing, scale helpers, arcs, layer fades | Explicit bar/phrase boundaries and an optional arrangement policy that preserves repeating motifs |
| `src/music/entropy.zig` | Reproducible seed configuration and namespace mixing | Separate composition and instrument-noise streams within the new style |
| `src/music/cue_morph.zig` | Gradual cue parameter transitions | Schedule structural changes on phrase boundaries |
| `src/procedural_music_probe.zig` | Offline rendering through the same `fillBuffer` functions used in the game | Techno rendering, isolated buses, consistent master gain, actionable render statistics |
| `src/music.zig`, `src/settings.zig`, `src/musicConfigMenu.zig` | Playback, persisted settings, existing menu | One additional style and a few meaningful controls |

The current styles are ambient, choir, African drums, taiko, and Americana
guitar. There is no techno style. The offline style probe currently supports
only guitar and taiko.

The April reference-matching status document is historical. Several renderers,
inverse-backend paths, and optimization scripts it describes are absent from
the current source tree. Its scores cannot establish current audio quality.

## Findings from the current code

1. **The composition policy needs a techno-specific option.**
   `compositionSectionStateChooseSectionBeats` samples continuous section lengths;
   the engine also varies chord cadence and discourages repeated sections.
   Taiko deliberately adds tempo drift. Those are intentional choices for the
   existing styles, but techno should keep a stable pulse and change layers on
   deliberate 8/16/32-bar boundaries. Reuse the step clock and helpers without
   requiring the new style to use the entire harmony/novelty director.

2. **The shared DSP does not yet provide the needed electronic sound chain.**
   Its general low/high-pass filters are one-pole, without resonance controls.
   `softClip` is a static cubic waveshaper with a small-signal gain of 1.5 and
   saturation at +/-1; it is not a dynamics limiter. Simply driving the master
   into it cannot separately preserve kick attack, shape rumble, and control
   bass masking. Use separate kick and rumble buses, with the rumble ducked by
   each kick, before a conservatively gained final mix.

3. **There is a latent shared envelope release bug.**
   `envelopeInit` and `envelopeRetrigger` compute release rate from the sustain
   level. With sustain zero, releasing during attack or decay leaves a positive
   level subtracting zero forever. A completed zero-sustain decay also stays in
   the `sustain` state instead of becoming idle. The inspected current styles
   largely use decay-driven percussion, so this is not evidence of the cause of
   the user's present sound complaint. It must be resolved before reusing this
   envelope for gated bass notes and hat choking. Preserve current decay shapes
   and verify both early release and terminal idle behavior.

4. **Some existing synthesis would need aliasing care if reused.**
   The shared hi-hat generates a partial at `6200 * 4.35 = 26970 Hz`, above the
   24 kHz Nyquist limit, which folds to 21.03 kHz. That observation alone does
   not prove an audible problem. New pitched oscillators and heavy distortion
   should nevertheless have an explicit alias-reduction design, rather than
   accumulating uncontrolled high-frequency components.

5. **Sound generation and composition randomness are coupled in taiko.**
   Its `rng` feeds both the composition runner and sample-level percussion
   noise. Changing an instrument's noise consumption can therefore change later
   musical decisions for the same seed. Give the new style separate streams so
   timbre comparisons hold the score constant. Do not silently reseed all old
   styles as part of this addition.

6. **The audition controls are inconsistent.**
   In the style probe, `--volume` changes guitar's internal output level, but
   changes only taiko's `drum_mix`, leaving shime and kane audible. The game has
   a separate SDL stream gain. Introduce a consistent post-mix audition gain,
   retain explicit instrument/bus controls, and compare sound candidates at
   matched playback loudness. RMS measurements alone are not perceived loudness.

7. **Runtime parameter ownership needs attention during integration.**
   The settings/menu code writes style globals and can reset a style while
   `musicCallback` consumes those states. No matching audio-stream lock is
   visible in those paths. Establish a synchronized settings handoff or use the
   stream's documented synchronization when adding the new controls. This is a
   code-inspection concern; a race was not reproduced in this investigation.

## Render evidence

Existing probe, seed `12345`, default probe settings, 32-second renders:

| Style/cue | RMS, PCM dBFS | Sample peak, PCM dBFS | Full-scale PCM samples |
| --- | ---: | ---: | ---: |
| Taiko / matsuri | -22.277 | -3.451 | 0 |
| Guitar / open-road | -31.902 | -19.159 | 0 |

Both render commands built and completed without non-finite-sample warnings.
The approximately 9.6 dB RMS difference is specific to these excerpts and probe
settings. It does not measure aesthetic quality or prove clipping elsewhere is
absent. These are code and signal measurements; no subjective listening verdict
is claimed.

A separate four-second taiko render with `--volume 0` produced RMS `0.01514`
and peak `0.41039`, confirming that the documented volume control is not a
master mute.

```sh
zig build procedural-music-probe -- taiko --duration 32 --seed 12345 --taiko-bus-stats --out /private/tmp/multi-music-investigation-taiko.wav
zig build procedural-music-probe -- americana-guitar --duration 32 --seed 12345 --out /private/tmp/multi-music-investigation-guitar.wav
zig build procedural-music-probe -- taiko --duration 4 --seed 12345 --volume 0 --out /private/tmp/multi-music-investigation-taiko-volume-zero.wav
```

PCM measurements were computed from the resulting WAV samples; taiko was also
checked with FFmpeg `astats`. An initial output path under `/tmp` failed with
`NotDir` in the probe's `createDirPath`; using the real `/private/tmp` directory
succeeded. This path issue is separate from synthesis quality.

## Proposed sound and shared-library changes

Start with the low end: a repeatable kick with independently shaped pitch drop,
attack, body, and decay. Keep its fundamental centered and make drive adjustable
with output compensation. Feed a separate copy into the existing delay/reverb
building blocks, filter and saturate that return, then duck it on each kick.
Rumble release should follow the beat length and recover between kicks. Treat
rumble as the initial bass part; add another low bass voice only if listening
shows a musical need.

Add complementary hats, a short clap, and occasional metallic percussion. Hat
accents can vary slightly; kick placement and strength should remain dependable.
Generate a short motif once and repeat it, with occasional accent, slide, or
one-note changes at phrase boundaries. Larger changes come from filtering,
layer entrances, and brief breaks.

The repeated beat and layered arrangement follow established techno production
practice; the specific dark sound and tempo here are design choices.
[Native Instruments' production guide](https://blog.native-instruments.com/how-to-make-techno/)
describes the four-on-the-floor/offbeat-hat foundation and developing loops into
sections. [Ableton's kick overview](https://www.ableton.com/en/blog/drop-it-kick-electronic-music/)
is a useful reference for separating attack/body behavior and distortion.

Extend shared modules only as a working sound needs them:

- In `dsp.zig`, add a smoothed gain/parameter primitive, a kick-triggered ducking
  envelope, and a controlled saturation path. Reuse its HPF for DC removal and
  its delay/reverb storage. Evaluate 2x or 4x processing around nonlinear stages
  with proper up/downsampling filters and delay alignment. Existing filters
  assume 48 kHz, so oversampled processing needs explicit rate-aware coefficients.
- For bass/acid, add a resonant state-variable filter based on
  [Cytomic's published formulation](https://www.cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf)
  and a PolyBLEP saw/pulse oscillator; the
  [Faust oscillator documentation](https://faustlibraries.grame.fr/libs/oscillators/#polyblep-based-oscillators)
  provides a useful implementation reference. This would be an acid-like voice,
  not a claim of accurate TB-303 circuit emulation.
- Keep electronic instruments in `instruments.zig`; give
  `procedural_hard_techno.zig` ownership of their instances, score, and bus routing.
  Keep data structs and file-level functions consistent with repository style.
- Extend `composition.zig` with opt-in step/bar information as needed. Its
  current sequencer emits step zero after one sixteenth-note interval; define
  immediate-start behavior explicitly for the new style without shifting old
  styles' timing. Use the existing clock rather than a second tempo scheduler.
- Extend the existing probe with bus isolation and timing/level reporting.
  Isolating a bus must not change the generated score or disable effect inputs
  needed to hear that bus, particularly kick-fed rumble.

Nonlinear processing creates additional bandwidth, so oscillator antialiasing
alone does not solve distortion aliasing. The
[DAFx waveshaping paper](https://www.dafx.de/paper-archive/2016/dafxpapers/20-DAFx-16_paper_41-PN.pdf)
and [Faust's antialiased nonlinearities](https://faustlibraries.grame.fr/libs/aanl/)
describe approaches to assess if simple oversampling is insufficient. Choose
the simplest implementation that meets listening and CPU requirements.

## Proposed commit-sized phases

Each phase ends with independent code review, applicable checks, and user
listening/review. Changes remain uncommitted until accepted and the user
explicitly asks to commit; the next phase's scope is agreed before starting it.

| Phase | Reviewable outcome and scope | Validation and listening |
| --- | --- | --- |
| 1. Kick and rumble proof | Add the new style to the offline probe with a fixed 150 BPM kick/rumble pattern; add only the needed shared kick, saturation, smoothing, ducking, and timing support. Reuse filters, delay/reverb, entropy, and WAV output. | Export kick, rumble, and combined excerpts plus a few drive/decay candidates with matched playback levels. Verify a stable pulse, finite samples, output headroom, rumble recovery, and render time. Listen for weight, attack, and an enjoyable repeated low-end groove. |
| 2. Complete groove | Add hats with choking, clap, sparse metallic percussion, and a restrained bass/acid motif. Add the shared resonant filter/oscillator and fix the envelope lifecycle when these voices need them. Separate score/noise RNG streams. | Render a repeatable 16-bar groove and isolated buses. Test early note-off, hat choke, filter extremes, seed reproducibility, and score independence from timbre settings. Listen for a coherent groove and room around the kick. |
| 3. Musical development | Add explicit phrase-boundary arrangement, recurring motifs, fills, breaks, and controlled returns. Reuse cue morphing and step counters; keep genre-specific decisions in the style. | Render at least three minutes for several seeds. Check transition alignment and continuity; audition whole passages for repetition, tension, and satisfying returns. |
| 4. Game integration | Wire the style into playback, settings, and the existing menu; add a small set of cue/drive/rumble controls, consistent probe master gain, and safe live-setting application. | Build and five-second smoke test, switch styles, adjust controls, save/reload, and compare runtime with offline output. Measure callback workload under gameplay and check old style renders for unintended changes. |

All code phases use `bash scripts/format.sh`, `zig build`, and
`bash scripts/smoke_test.sh` as required by the repository. Focused tests should
cover DSP and timing boundaries, including rendering the same score with
different buffer chunk sizes. For live playback, measure time per buffer in an
optimized build against its audio duration, leaving substantial headroom.

Acceptance should combine technical checks with listening. Track peak/DC,
non-finite samples, low-frequency balance, event timing, and performance; use
matched-level A/B clips to judge the actual sound. A louder or more spectrally
similar result is not by itself a better musical result.

Recommended next phase: the kick/rumble proof. It lets the user judge the core
sound before committing to the rest of the generator. No implementation changes
were made during this investigation; the independent implementation review and
game smoke test therefore have not run.
