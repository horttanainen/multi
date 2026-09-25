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

The user's progression request calls for continuous music that changes character
and develops its note/rhythm patterns every 1–3 minutes, with playback continuity
across development relaunches. The current 204.8-second arrangement still restarts
a fixed score; its seeds affect noise rather than composition. This work is deferred
until the current arrangement's lead teases, fades and bass features are settled.

The immediate request is to inspect and plan those transitions. The lead first
enters at 0:25.6 without a multi-bar build. Lead-free gaps already leave the bass
playing, but it has no deliberate foreground mix. The ending has a four-bar fade;
most other layer changes use only 20 ms smoothing. Artist research below refines
Phase 9 into distinct filtered entrances, sparse phrase teases, bass features
with reduced backing, and a decisive return after the existing breakdown. Preserve
the accepted new lead's sustained phrase, +12 pitch/+6 dB balance, and the original
quieter low bass outside feature windows. The user authorized trying this plan;
the implementation and listening comparisons are now prepared. All 47 music
tests, two menu/audio tests and build/smoke pass; independent review found no
actionable issues. The user liked the complete arrangement and explicitly
requested committing the phase. See
[Phase 9](../MUSIC_HANDOFF.md#phase-9-lead-anticipation-fades-and-bass-features).

Additional user direction: remove the wooden/taiko-like character from background
percussion. All hard-techno sounds should suggest machinery, synths or a drum kit.
Phase 7 now replaces the metal bus's shared Atarigane voice with an electronic
accent: a short ring-modulated noise burst or an electronic snare. The user likes
both and prefers Electronic Snare, now the game and probe default. Noise Burst
remains an alternative. The old/new mix and isolated comparisons are ready;
the accepted bass, lead and score remain intact, and taiko keeps its own Atarigane
implementation. All 36 music and two menu tests, seven offline renders and the
prescribed build/smoke checks pass. Independent review found no actionable issues;
the subsequent default-selection change is locally checked, with a full Snare
track preview. The user accepted the result, committed as `d9269e8`. See
[Phase 7](../MUSIC_HANDOFF.md#phase-7-electronic-percussion-replacement).

The user selected the sustained bass voice at +12 semitones and +6 dB as the
replacement game lead. Phase 8 now implements that independent voice with its
original held phrase, legato, filters, drive, mono routing and kick ducking. The
original low bass remains underneath. It follows existing lead entrance/rest
sections; long-term progression remains separate planned work. Older Corrosion
settings also use the newly selected voice in the game. Corrosion stays available
in the probe for comparison.

Two comparisons play Corrosion then the new voice: the sustained bass phrase,
and the original short lead riff. Corrosion retains its original G4 register,
processing and level; the new voice uses the selected G2 register. Backing is
identical. The user rejected lowering Corrosion for the comparison, so the old
lead on its original pattern must now match the accepted recording byte for byte. The first rejected attempt had changed the bass's articulation
and processing; the new default matches the accepted +12/+6 dB bass recording.
All 42 music tests, two menu/audio tests, eleven renders and build/smoke checks
pass. Independent review found no actionable issues. The user accepted the phase and
explicitly authorized its commit. See
[Phase 8](../MUSIC_HANDOFF.md#phase-8-the-bass-synth-in-the-lead-register).

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

## Arrangement research: lead teases, drops and variation

Research requested by the user on 2026-09-25. These are documented practices from
particular artists and a producer's arrangement guide, not a universal techno
formula. Sources were read as written interviews and studio-session reporting;
the linked videos were not independently auditioned or transcribed here.

### What the sources establish

- **Filter movement can carry a simple hook.** Future Music's account of its own
  BEC studio session describes a two-note melody and simple bassline, with
  opening synth cutoff and changing reverb building tension. This provides a
  concrete example of anticipation through changing the presentation of a small
  amount of musical material.
  [BEC studio-session account](https://www.musicradar.com/music-tech/record-everything-all-the-time-and-keep-it-all-8-pro-techno-producers-explain-how-they-create-their-tracks),
  [original artist demonstration](https://www.youtube.com/watch?v=IN74DuZuQxM).
- **Withholding weight can make the return significant.** Aril Brikha describes
  maintaining momentum in “Groove La Chord” by opening/closing the chord filter
  and adding/removing the ride. He also deliberately filtered away the kick's
  sub-frequencies for roughly two or three minutes before revealing them. His
  account also cautions against treating exact bar counts as mandatory: the
  retained performance was not rigidly arranged at regular intervals.
  [Aril Brikha interview](https://www.ableton.com/en/blog/aril-brikha-remaking-groove-la-chord-with-live-and-note/).
- **Movement can happen inside a repeated sequence.** Mathew Jonson discusses
  rhythmic accents, live changes to synth/EQ/volume/mutes, and unsynchronized
  filter modulation that gradually emphasizes different parts of a melody.
  Those are examples of variation at the performance and timbre level; they
  do not by themselves satisfy our user's separate request for new note patterns.
  [Mathew Jonson interview](https://www.ableton.com/en/blog/mathew-jonson-rhythm-melody-and-chaos/).
- **Removing parts is an arrangement method.** Dennis DeSantis proposes starting
  with a dense arrangement and subtracting material to find combinations,
  spacing and section lengths that work. This supports exploring the instruments
  already present before adding further layers.
  [Arranging as a Subtractive Process](https://makingmusic.ableton.com/arranging-as-a-subtractive-process).
- **Industrial intensity still benefits from a controlled low end.** David
  Castellani describes concentrating distortion in upper frequencies and
  high-passing a parallel distortion feed, alongside hands-on effect automation.
  This is useful context for preserving kick/bass clarity; it is not a reason
  to redesign the accepted lead patch during the transition phase.
  [David Castellani interview](https://blog.native-instruments.com/david-castellani/).

### Our application to the current generator

The following choices were inferred from those practices and the user's listening
feedback. They form the accepted Phase 9 implementation; the user liked the
complete updated arrangement and explicitly authorized its commit.

Bring the lead forward using its level, brightness and room in the arrangement.
First let the listener recognize the sustained phrase through a quieter, darker
preview; then reveal its accepted sound. For a different return, play a small
fragment and withhold the rest until the entrance. Keep the remaining notes held,
so teasing does not recreate the short, percussive articulation the user rejected.
Extra reverb is optional and deferred initially: the selected voice currently
has no lead delay, and gain/filter automation can be tested without replacing it.

Give the lower bass its solo by withdrawing the upper lead and easing rumble and
busy percussion while retaining the kick. Both voices share a patch and phrase
an octave apart, so their relative prominence deserves special attention in the
listening comparisons. Restore the original quieter bass balance as the lead
returns; continuous loud doubling would weaken the change of foreground role.

Use the existing breakdown for the largest drop. Build anticipation while kick
and low bass rest, briefly withdraw the lead before the downbeat, then restore
the accepted instruments together. Retain the existing final-beat gap as the
first candidate. A drop can also be a smaller restoration of low end or drums;
the bass handoffs need not each interrupt the groove with a large breakdown.

For later continuous generation, audition three timescales: small tone/accent
movement within phrases; a limited rhythm or note-ending variation every few
phrases; and a larger change of motif, density or foreground role every 1–3
minutes. Preserve memorable parts of a motif between variations. The cadence
and bounded variation rules are our design choices, not artist prescriptions.
Phase 9 first tests the transitions in the current arrangement; its concrete
timing, comparison plan and commit boundary are in
[the handoff](../MUSIC_HANDOFF.md#phase-9-lead-anticipation-fades-and-bass-features).

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
