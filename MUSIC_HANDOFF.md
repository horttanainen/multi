# Procedural hard techno: resume here

Updated 2026-09-25. This folder is the dedicated music worktree.

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
- Phase 1 was accepted and committed as `2ecaf4e` on `codex/hard-techno`.
  The user selected the first (tight) low-end candidate.
- Phase 2 was accepted and committed as `26e70e2`. The user liked Warehouse and
  Machine, leaning toward Warehouse as the best. Warehouse remains the loop default.
- Phase 3 was accepted and committed as `957e54f`.
- Phase 4: the user selected the Corrosion synth lead after the dark industrial
  comparisons. Its shared oscillator also supports the accepted bass voice.
- Phase 5: basic Hard Techno game playback, settings and audio synchronization
  are retained. The added lead/drum editing rows, range bars, groove editor,
  Reset Techno Sound action and temporary lead multipliers have been removed at
  the user's request. Volume, Tempo Scale, Reverb and Loop/Full Track remain.
- Phase 6: the user accepted the sustained legato bass and explicitly requested
  committing it together with the slider rollback (`316ba59`). The commit includes the
  accepted lead dependencies and basic playback integration. Personal changes
  to `settings.json` stay outside the commit.
- The user particularly likes the sustained bass voice and thinks it could also
  work as a lead. They now request bass solos in the upcoming arrangement work:
  let that voice take the foreground while the Corrosion lead rests.
- Lead entrances should build anticipation through a quiet fade-in or a muffled,
  filtered preview before the full lead takes over. Include these teases in the
  upcoming arrangement work alongside bass solos.
- Phase 7 is the current implementation: replace the wooden-sounding background
  accent with electronic percussion. The user likes both candidates and prefers
  Electronic Snare, now the game/probe default. Noise Burst remains an alternative.
  The existing lead, bass and arrangement are preserved. The user accepted the
  selected Snare track and explicitly authorized the percussion commit.
- Progression across 1–3 minute sections and playback continuity across launches
  remain proposed next work. A future
  lead-only editor must use real synthesis parameter names and useful ranges.

The user wants better procedural music and proposed a hard techno generator,
with shared-library improvements where useful. They selected a separate folder
so this work is easy to track while another agent works on other game features.
The completed Phase 3 milestone is a Warehouse-led arrangement with a short
Machine section. Corrosion is the selected synth hook. The sustained bassline is
accepted; progression and the percussion palette are proposed before lead editing.
Workflow skills now distinguish accepting changes from explicitly authorizing
a commit; they also reserve independent review for substantial or risky changes.

Read [the investigation](docs/hard_techno_procedural_music_investigation.md) for
the code findings, measured baseline, technical sources, and full roadmap.
Its copy in the original checkout was left in place; maintain the copy here
for future music work.

## Musical direction

The user explicitly wants dark industrial techno and selected Corrosion after
favoring Machine and Buzz. Sandstorm was their earlier reference for a rough synth
lead. Keep the 150 BPM groove, distorted kick, rolling rumble and restrained
percussion while refining the original repeating lead motif through listening.
Latest palette constraint (2026-09-25): all hard-techno sounds should read as
machines/synths or a drum kit. The user dislikes background hits that sound like
wood clanking or taiko/world percussion. No wooden or acoustic world-percussion
character. Phase 7 replaces the hard-techno metal bus's `instruments.Atarigane`
with a synthesized electronic accent; the shared taiko instrument stays intact.
This was not a percussion change in the earlier sustained-bass iteration.
The user selected the first, tight
kick/rumble candidate: drive 2.3, decay 0.28 seconds, rumble 0.52. In Phase 2,
they liked the first (Warehouse) and last (Machine) grooves, with Warehouse
currently preferred. Keep Machine as a positive alternative; no preference for
Rolling was expressed.

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

## Phase 6: independent bassline before the lead editor

**Outcome and commit boundary:** a separate mono bass synth, an original four-bar
G-minor pattern, arrangement integration, an isolated bass bus and listening
comparisons. This phase does not implement the revised lead editor or add menu
knobs. The user has now accepted the sustained bass and explicitly requested a
commit, including removal of the earlier sound-slider work and retention of the
accepted lead dependencies and basic playback integration.

### Current iteration: sustained bass counterline

The user found the first bassline too much like separate sounds. They want a low
synth voice behind the lead, holding notes and following its own pattern. This
iteration replaces the 48–85 ms plucks with 400–1,000 ms notes at 150 BPM. The
four-bar pattern has ten notes spanning F1–D2, and small gate overlaps maintain
legato pitch changes without restarting the amplitude or filter envelope.

The existing `SynthBass` still combines a saw and same-pitch sine, cascaded
low-pass filters, saturation and DC removal. A 15 ms attack, 82% envelope sustain,
55 ms release and a 650 Hz filter floor keep the tone present after the onset.
Overlapping notes preserve oscillator phase and envelope state. Kick ducking
now retains a quiet bass signal under the kick, with a 20% unducked contribution.
The mono, dry bass remains separate from the lead voice and pattern. Long gates
scale with live tempo changes so their remaining musical duration stays aligned.
The existing oscillator, envelope, filters, saturation, clock and settings paths
own these changes; there is no new synthesizer framework or UI.

The full track has 258 bass triggers: quiet whole-bar G1 roots at bars 8–11,
the full pattern from bar 12, no new bass notes in the breakdown at bars 80–87,
return at bar 88, whole-bar roots at bars 120–123, and no new notes from bar 124.
Bar numbers are zero-based. Short release/filter tails can cross a section edge.
The lead's score and processing are unchanged. `low_end` sums kick, rumble and
bass; all stems share the established headroom gain `1 / (1 + 0.25 * bass_level)`.
At the default 0.65 level this is approximately -1.31 dB. Zero bass level preserves
the old bass-free mix. The listening comparison is matched in loudness.

The game enables bass by default in Hard Techno, including old settings without
this field. The probe defaults to zero for earlier audition compatibility; use
`--bass-level 0.65` for game balance and `--techno-bus bass` for the isolated part.
No new controls have been added. User edits in `settings.json` are preserved.

```bash
python3 agent-tests/hard_techno_audition.py --phase 6 --output-dir agent-temp-files/hard-techno/bassline/sustained/audition --bass-reference agent-temp-files/hard-techno/bassline/audition/with_bass_mix_raw.wav
```

The first comparison cue is the previous short-note bass, the second is the new
sustained bass. The optional reference input must be outside the output directory
and must not alias an existing output file; it is validated before rendering.
Its measurement log is written into the new output directory. Raw stems retain mix gain; solo listening
copies have a separate gain for audibility. The current iteration snapshot is
`agent-temp-files/hard-techno/bassline/sustained/before/`.

Listen to the [short-note versus sustained comparison](agent-temp-files/hard-techno/bassline/sustained/audition/bass_comparison.wav):
one beep is the previous short-note version (0.18 s), two beeps is the new held
version (13.86 s). Both are approximately -18 LUFS. Also available:
[solo sustained bass](agent-temp-files/hard-techno/bassline/sustained/audition/bass_solo_matched.wav),
[full track](agent-temp-files/hard-techno/bassline/sustained/audition/bass_track_matched.wav),
and [entry/return excerpts](agent-temp-files/hard-techno/bassline/sustained/audition/bass_transitions.wav).

Formatting, build and diff checks pass, along with 34 music tests in ReleaseSafe
and two menu/SDL tests in Debug. A focused audio test verifies that the held tone
stays audible late in the note, overlapping pitch changes preserve envelope state,
and release reaches silence. The retrigger continuity check now compares against
an uninterrupted copy of the waveform rather than confusing a pitch-dependent
waveform slope with a click. This was a test correction, not a DSP defect.

All six renders are finite/unclipped. Loop and full-track stems sum within two
PCM LSB, the full track has 258 bass notes and 480 kicks, arranged rests and the
ending are silent after release tails, and the largest section-boundary jump is
0.00159 full scale. Bass-off loop and full track remain byte-identical to the
original Corrosion renders. Maximum-level 25.6-second sweeps across eight lead
choices and both tempo limits peak at 0.83415. The prescribed five-second menu
smoke passed with no warnings, errors, panics or crashes, using isolated Hard
Techno settings. Agent commands did not edit the user's `settings.json`; it changed
during the iteration to Machine/Full Track with the bass field saved. Those latest
settings are preserved. Runtime Full Track continues to use its arranged grooves.

One fresh-context independent review covered the four-file iteration delta. It
found one **P2** in `agent-tests/hard_techno_audition.py`: selecting a reference
inside the output folder could overwrite it before comparison, yielding a
misleading current-versus-current comparison. Fixed by validating the reference
before rendering and rejecting output-directory and file-alias collisions.
Direct-path, symlink and hardlink tests confirm rejection preserves the reference
bytes, and the normal separate-directory audition run succeeds. No actionable
issues were found in the Zig implementation. The reviewer also identified missing
direct coverage of live held-note retiming; a focused test now exercises slowing
and speeding up, sustained tone and release at the arranged rest; it passes. While
adding that test, ReleaseSafe caught a narrow inferred integer in its buffer count;
the count is now explicitly `usize`. No production DSP fix was needed. No recursive
review was run.
See the [validation receipt](agent-temp-files/hard-techno/bassline/sustained/validation.json)
and [audition receipt](agent-temp-files/hard-techno/bassline/sustained/audition/audition.json).
Listening acceptance is complete: the user described the sustained bass as very
good and explicitly requested committing it. The slider rollback and final
validation are recorded below.

### Previous iteration: short offbeat bass

The initial 19-note pattern used brief plucks and a chromatic pickup. Its full
track had 491 bass notes. It passed 32 music tests, two menu/SDL tests, six finite
and unclipped renders, two exact bass-off regressions, and build/smoke checks;
one independent review found no actionable findings. A maximum-level headroom
failure was corrected with the shared linear gain reserve. Human listening then
identified the unwanted percussive articulation, prompting the current iteration.
Earlier source snapshots, audio and receipts remain under
`agent-temp-files/hard-techno/bassline/`; the original
[comparison](agent-temp-files/hard-techno/bassline/audition/bass_comparison.wav)
and [validation receipt](agent-temp-files/hard-techno/bassline/validation.json)
are historical evidence, not validation of the sustained iteration.

### Deferred lead-editor plan

The user's newer progression/relaunch request takes priority over this editor;
see the next-phase proposal below.

1. Expose actual oscillator, sync, modulation, filter, distortion and envelope
   parameters. Keep Corrosion as a starting preset. Prove useful audible ranges
   with soloed parameter sweeps before further UI work.
2. Replace the previous broad controls with a focused lead editor. Remove the
   added drum/groove editing controls; include solo, held-note preview, comparison
   with original Corrosion, reset and persistence. Use real parameter names and
   units, such as pulse width (%), cutoff (Hz), drive (dB) and decay (ms).
3. Add simple automatic modulation with a source, speed, depth and destination.
   Avoid a large routing system. Each phase requires listening and appropriate
   technical validation. Do not begin these phases before the bass handoff and
   user steering.

## Phase 7: electronic percussion replacement

**Outcome and commit boundary:** replace the hard-techno background hit that
resembled wooden/world percussion, with listening alternatives before proceeding
to the evolving arrangement. Reuse the existing instrument/DSP owner, metal bus,
offline probe and audition helper. No new menu controls or arrangement changes.

The previous accent was the same Atarigane voice used by taiko, pitched lower and
played with muted strikes. Hard Techno now uses `ElectronicAccent` with two tones:

- **Noise Burst:** high-pass-filtered noise ring-modulated at 2,350 Hz, with a
  short decay and saturation. The user also likes this alternative; audition it
  through `--metal-voice noise_burst`.
- **Snare:** filtered noise over a brief downward-pitched sine body, then
  saturation. The user preferred this final candidate in the isolated comparison;
  it is now the game and probe default (`--metal-voice snare`).

Both use the existing filters, saturator and independent accent RNG. Retriggers
preserve oscillator/filter state and fade the previous excitation into the next
attack. Processing drains the DSP tail after excitation ends. The old Atarigane
implementation remains available to taiko; Hard Techno no longer calls it.
Older saved settings gain the default snare voice; no personal settings
file was edited. The existing numeric controls and saved voice selection work
through the same config/persistence path, with no sound-editor rows added.

Listen to the [mix comparison](agent-temp-files/hard-techno/phase7/audition/percussion_comparison.wav)
or the [isolated accent comparison](agent-temp-files/hard-techno/phase7/audition/accent_comparison.wav):

| Cue | Sound | Start |
| --- | --- | --- |
| 1 beep | Previous Atarigane accent | 0:00.18 |
| 2 beeps | Noise Burst | 0:13.86 |
| 3 beeps | Snare | 0:27.64 |

Each excerpt lasts 12.8 seconds. The isolated accents are raised independently
for listening; raw stems retain their actual mix gain. The
[Machine groove comparison](agent-temp-files/hard-techno/phase7/audition/machine_comparison.wav)
uses the denser accent pattern: Noise Burst first, Snare second. A
[full Noise Burst track](agent-temp-files/hard-techno/phase7/audition/noise_burst_track_matched.wav)
is also available. The selected
[full Electronic Snare track](agent-temp-files/hard-techno/phase7/selected-snare/audition/snare_track_matched.wav)
uses the same accepted voice as the comparison. All comparisons use constant-gain
loudness matching.

Validation completed:

- 36/36 music tests in ReleaseSafe and 2/2 menu/SDL tests. New coverage checks
  accent retriggers/tails, deterministic rendering across buffer sizes, unchanged
  other voices, both tones at tempo/mix extremes, and old/new settings loading.
- Seven offline renders are finite and unclipped. For both Warehouse candidates,
  old mix minus old accent plus new accent reconstructs the new mix within
  2 PCM16 LSB: the accepted backing, bass and lead remain intact. The full
  205.8-second Noise Burst render preserves section timing and a silent ending.
  The selected Snare full-track render and post-selection checks are recorded in
  [the selection receipt](agent-temp-files/hard-techno/phase7/selected-snare/validation.json).
- Formatting, build and diff checks pass. The prescribed five-second game smoke
  uses an isolated Machine-loop fixture so the new accents sound during startup;
  the sentinel appears without warnings, errors or panics.
- Reference input protection rejects direct, symbolic-link and hardlink output
  collisions without changing the reference bytes. The helper validates both
  phase-7 references before writing comparison logs or renders.
- One fresh-context independent read-only review found no actionable issues in
  the accent DSP, routing, settings, CLI or reference protection. It inspected
  the test/render/smoke evidence without rerunning mutating checks. The user then
  selected Snare and also approved Noise Burst's sound. The small default-selection
  change uses local diff inspection and existing validation; no new reviewer is
  needed. No synthesis parameters or note timing changed.

See the [validation receipt](agent-temp-files/hard-techno/phase7/validation.json)
and [audition receipt](agent-temp-files/hard-techno/phase7/audition/audition.json).
Reproduce with the pre-change references retained in ignored scratch space:

```bash
python3 agent-tests/hard_techno_audition.py --phase 7 --percussion-reference agent-temp-files/hard-techno/phase7/baseline --output-dir agent-temp-files/hard-techno/phase7/audition
```

### Following phase: evolving playback and continuity across launches

Latest user feedback: the music sounds like the same short piece on repeat. They
expect noticeable musical shifts every 1–3 minutes and dislike hearing the same
opening every time they relaunch during development.
They also want anticipation before lead entrances: a fade-in or muffled preview
before the lead takes the foreground. The accepted sustained bass should have
solo sections of its own.

Initial read-only inspection on 2026-09-25 found `settings.json` selecting Hard
Techno, `arrangement: loop`, tempo scale 1 and random seed mode. A later read found
Full Track selected, with Machine stored as the loop groove. The melodic loop is four
bars (6.4 seconds at 150 BPM). Track mode currently runs a fixed 128-bar, 204.8-second
arrangement with entrances, breaks and returns, then the runtime restarts the same
score. Seed changes vary percussion noise, not the bass/lead patterns or initial
bar. There is no playback-position persistence. Agent commands did not edit these
saved settings.

Proposed coherent next phase, before lead knobs:

- Add an ongoing arrangement mode using the existing clock, phrase/section
  ownership and voices. Select substantial new sections on musical boundaries
  every roughly 1–3 minutes, with smaller variations between them. Change motif
  variants, bass movement, groove/layer density and intensity while maintaining
  musical relationships and avoiding immediate repeats. Preserve finite track
  and loop modes for auditions and repeatable tests. Honor the newly specified
  machine/drum-kit sound palette; audition a replacement for the wooden-sounding
  background hit before incorporating it into the evolving arrangement.
- Build anticipation before major lead entrances and returns. Preview the coming
  motif at low gain, with a low-pass filter attenuating its upper frequencies,
  or with sparse fragments; gradually raise the gain and/or filter cutoff before
  revealing the full accepted Corrosion sound on a phrase boundary. Start by
  auditioning 4–16-bar teases, with duration chosen for the surrounding section.
  Vary the approach so each entrance does not repeat the same build. Implement
  this as arrangement automation around the existing voice, preserving its
  accepted full-strength tone and leaving the deferred editor out of scope.
- Give the sustained bass deliberate solo sections. Rest the Corrosion lead,
  reduce competing percussion and rumble where needed, and bring the bass into
  the foreground through arrangement and controlled mix changes. Keep its
  accepted sustained/legato sound; audition longer phrases and melodic variants
  that work as a featured part. A solo can retain the kick and sparse drums:
  the requirement is that the bass carries the musical focus. Include transitions
  from the full mix into a bass solo and from a bass solo through a lead tease
  into the full lead, without forcing that sequence into every section.
- Persist the composition seed, arrangement decisions and musical position
  periodically as well as at normal shutdown. Resume from a nearby phrase
  boundary with a short fade and appropriate voice/effect warm-up, so force-closing
  development runs does not keep returning to the intro. For a fresh state, begin
  in an established musical section instead of always replaying the opening.
- Keep audio-callback work bounded: capture checkpoint data under the existing
  synchronization boundary, write it from the main thread, and validate loaded
  state/version before use. Reuse the settings/filesystem owners where appropriate;
  keep runtime playback state separate from sound-design defaults and reset.
- Validate with long renders and a section/phrase trace, transition/headroom
  checks, deterministic reconstruction from saved state, and real relaunch tests
  using isolated settings. Listening must establish audible development over
  several minutes; randomizing noise alone does not meet this requirement.
  Include focused lead-tease/reveal and bass-solo transitions in the auditions.
  Check smooth gain/filter changes, solo/reveal headroom and preservation of the
  accepted full lead and bass tones. Checkpoint reconstruction must also preserve
  the selected solo/tease stage and its musical progress.

This is recorded planning only. Progression/resume behavior is not implemented
in the sustained-bass iteration. Exact state format, checkpoint frequency and
fresh-start policy should be finalized with the phase implementation plan.

## Phase 4: synth lead auditions

**Outcome and commit boundary:** an original four-bar G-minor riff, lead-tone
comparisons over the selected Warehouse groove, isolated lead/rhythm buses, and lead
entrances within the full arrangement. The user requested this missing musical
layer before proceeding to game integration. Corrosion is the selected lead for
now; this choice does not freeze its sound design.

### Current iteration: dark industrial

The user likes Machine and Buzz better and requests a rougher, darker industrial
sound. This iteration keeps the original riff, groove, note timing and arrangement.
Buzz is the unchanged comparison control; the two new choices build on those
preferred voices.

| Cue | Tone | Start in comparison | Full 16-bar clip |
| --- | --- | --- | --- |
| 1 beep | Buzz: previous version | 0.18 s | [WAV](agent-temp-files/hard-techno/phase4/industrial/buzz_matched.wav) |
| 2 beeps | Iron: darker Machine with octave weight and dense distortion | 13.86 s | [WAV](agent-temp-files/hard-techno/phase4/industrial/iron_matched.wav) |
| 3 beeps | Corrosion: heavier Buzz with inharmonic metallic modulation | 27.64 s | [WAV](agent-temp-files/hard-techno/phase4/industrial/corrosion_matched.wav) |

Listen to [the comparison](agent-temp-files/hard-techno/phase4/industrial/lead_comparison.wav),
[the full Corrosion track](agent-temp-files/hard-techno/phase4/industrial/corrosion_track_matched.wav),
or [entry/return excerpts](agent-temp-files/hard-techno/phase4/industrial/lead_transitions.wav).
The full track introduces the lead at 0:25.6. The user selected Corrosion after
listening. Earlier auditions remain available below. Future iterations can tune
distortion, metallic modulation, octave weight, filtering, envelopes and mix level
within the existing synth. The experimental Phase 5 controls were removed at
the user's request; synthesis parameters are currently code-defined.

Both variants add an octave sine layer before the existing two saturation stages.
Iron uses a fifth-related modulator; Corrosion uses a stronger inharmonic one.
Modulator phases persist through retriggers. Extra filtering after distortion
reduces the bright top end, with all filters continuing through idle tails.
The existing SyncLead, SyncSaw, envelope, filters, antialiased saturation, delay,
sidechain and audition helper own this work; no new synthesis subsystem was added.
No claim is made that the complete nonlinear signal is alias-free.

```bash
python3 agent-tests/hard_techno_audition.py --phase 4 --lead-set industrial
```

This writes to `agent-temp-files/hard-techno/phase4/industrial/`. Direct probe
choices are `--lead iron` and `--lead corrosion`. Earlier lead sets and the
lead-off default are preserved. `--groove machine` remains a percussion choice.

All 25 music tests pass, now covering seven tones: gates/retriggers, idle silence,
DC, zero velocity, additive stems, reset, chunk/seed behavior and maximum mix
controls at both tempo extremes. A scratch sweep over MIDI 36–107 with retriggers
measured voice peaks of 0.8747 (Iron) and 0.8744 (Corrosion).
All 14 audition renders are finite and unclipped; comparison loudness is -18.00,
-18.00 and -18.01 LUFS. The full track retains 579 lead notes, 480 kicks and its
silent ending. Stem sums differ by at most 2 PCM LSB and the largest section
boundary jump is 0.00263 full scale. See the
[audition receipt](agent-temp-files/hard-techno/phase4/industrial/audition.json).

Twelve [regression comparisons](agent-temp-files/hard-techno/phase4/industrial/regression.json)
are byte-identical, including all five previous lead mixes, Buzz's lead stem,
rhythm stems and lead-off loop/full-track mixes. Spectral band measurements show
about 5 dB less relative energy above 6 kHz for the two new tones than Buzz;
this confirms darker filtering but does not establish musical quality.
Formatting, build and diff checks pass. The prescribed smoke test reached its
five-second sentinel without warnings, errors, panics or crashes.
One independent read-only review covered the five-file iteration delta against
the saved baseline. It found no actionable issues, checked phase/filter state,
shared-component reuse and applicable skills, and independently confirmed all
12 regression comparisons. No review-driven corrections were needed. The reviewer
inspected the test/build receipt, render evidence and clean smoke log without
rerunning mutating checks. Corrosion has full-track coverage; Iron has loop and
unit-test coverage. The game smoke initializes ambient music, so these new tones
are validated through the offline probe. The user accepted Corrosion as the
current lead choice. It is retained in the accepted bass/playback commit; the
following sections preserve the earlier lead-audition history.

### Previous iteration: mechanical buzz

The user liked the first lead implementation but requested a rougher tone, then
clarified “more like a machine” and “more buzz”. The riff, groove, timing and
arrangement stay fixed for this iteration. The first clip is the unchanged Razor
control; the two new choices focus on a steady buzz and sharp gated attacks.

| Cue | Tone | Start in comparison | Full 16-bar clip |
| --- | --- | --- | --- |
| 1 beep | Razor: original swept tone | 0.18 s | [WAV](agent-temp-files/hard-techno/phase4/rough/razor_matched.wav) |
| 2 beeps | Machine: nearly fixed sync tone with a pitch-locked saw underneath | 13.86 s | [WAV](agent-temp-files/hard-techno/phase4/rough/machine_matched.wav) |
| 3 beeps | Buzz: narrow pulse and heavier distortion | 27.64 s | [WAV](agent-temp-files/hard-techno/phase4/rough/buzz_matched.wav) |

Listen to [the new comparison](agent-temp-files/hard-techno/phase4/rough/lead_comparison.wav),
the [full Buzz track](agent-temp-files/hard-techno/phase4/rough/buzz_track_matched.wav),
or [its entry/return previews](agent-temp-files/hard-techno/phase4/rough/lead_transitions.wav).
The full track introduces the lead at 0:25.6. Buzz is a provisional full-track
example; no user preference is inferred from its inclusion.

Machine and Buzz add mid emphasis, asymmetric distortion of the gated signal,
a second antialiased saturation stage, and final DC removal. Their attack is
0.9 ms, their release is 9 ms, and their delay return is halved. Buzz forms an
18%-duty pulse from two offset, pitch-locked band-limited saws with a small saw
component retained. Machine keeps a small initial sync movement. Both reuse the
existing oscillator, envelope, filters, saturation and delay components.

Darude describes distortion as the step that gave his early lead its recognizable
character in [this interview](https://www.bandwagon.asia/articles/edm-legend-darude-on-sandstorm-mental-health-and-more).
That informed the direction; this is not an exact recreation of his patch.

```bash
python3 agent-tests/hard_techno_audition.py --phase 4 --lead-set rough
zig build procedural-music-probe -- hard-techno --lead buzz --arrangement track --seed 12345 --out agent-temp-files/hard-techno/buzz_track.wav
```

The rough recipe writes to `agent-temp-files/hard-techno/phase4/rough/` by default,
preserving earlier auditions. `--lead-set original` retains the original three
tones. New probe choices are `--lead machine` and `--lead buzz`; the separate
`--groove machine` still selects the existing percussion pattern.

Current validation: all 25 tests pass. The earlier lead tests now exercise all
five tones, and a new test covers post-distortion DC removal and zero-velocity
silence. Stress checks cover both tempo extremes at maximum controls, additive
stems, gates/retriggers, reset and chunk/seed behavior. A separate sweep across
MIDI notes 36–107 with retriggers measured voice peaks of 0.8373 (Machine) and
0.8259 (Buzz). The first shaping attempts exposed filter overshoot and DC;
output saturation, final DC removal and gain compensation corrected these before
review. Instrument saturation may reach its unit rails internally; the final
mixed output is separately checked for clipping and headroom.

All 14 final loop/track/stem renders are finite and unclipped. The comparison
mixes measure -17.98, -18.00 and -18.00 LUFS. Both new raw mix true peaks are
-4.78 dBTP. Stem summation differs by at most 2 PCM LSB; the full Buzz track
retains 579 notes, 480 kicks and the silent ending. Largest section-boundary
jump is 0.00263 full scale. See the
[audition receipt](agent-temp-files/hard-techno/phase4/rough/audition.json).

All ten comparison controls are byte-identical, including the three original
lead mixes, Razor's isolated lead, rhythm stems and lead-off loop/full-track
renders; see [regression.json](agent-temp-files/hard-techno/phase4/rough/regression.json).
Formatting, build and diff checks pass. The final prescribed smoke run contains
the five-second success sentinel with no warnings, errors, panics or crashes.
One independent read-only review covered the five-file iteration delta against
the saved pre-iteration files, including phase continuity, saturation/DC removal,
gain staging, original-tone compatibility and audition paths. It found no
actionable issues, inspected the final receipts and smoke log, and independently
byte-compared four controls. No review-driven corrections were needed. Musical
acceptance remains for user listening; game integration is still a later phase.

### Original lead audition

The reference is the prominent, recognizable synth hook the user describes in
Darude's Sandstorm. The new notes are an original motif. The three versions use
the same notes, accents and gates so the comparison isolates their timbres:

| Cue | Tone | Start in comparison | Full 16-bar clip |
| --- | --- | --- | --- |
| 1 beep | Razor: bright, strongly swept sync tone | 0.18 s | [WAV](agent-temp-files/hard-techno/phase4/razor_matched.wav) |
| 2 beeps | Hollow: lower sync range and darker filtering | 13.86 s | [WAV](agent-temp-files/hard-techno/phase4/hollow_matched.wav) |
| 3 beeps | Wide: two slightly detuned sync voices | 27.64 s | [WAV](agent-temp-files/hard-techno/phase4/wide_matched.wav) |

Listen to [the comparison](agent-temp-files/hard-techno/phase4/lead_comparison.wav).
There is also a provisional [full Razor track](agent-temp-files/hard-techno/phase4/razor_track_matched.wav)
and [lead-entry / break-return previews](agent-temp-files/hard-techno/phase4/lead_transitions.wav).
Razor is the first example, not a user-selected winner. The full track introduces
the hook at 0:25.6, makes room for the Machine contrast, thins it in the break,
and brings it back at 2:20.8. It retains the finite ending at 3:24.8.

Shared `dsp.SyncSaw` synthesizes the Fourier coefficients of a saw reset by a
master oscillator, omits DC, and limits its harmonic set to 48 partials below
16 kHz. Coefficients interpolate over 1 ms during the sync sweep. This avoids
directly sampling the reset discontinuities; it is not a claim that the complete
modulated and saturated signal has no aliasing. The existing `Voice` has fixed
harmonic weights and does not implement oscillator sync, so it is not reused as
the oscillator. `instruments.SyncLead` reuses the shared envelope, filters and
antialiased cubic saturation. The style reuses its step clock, level smoothing,
kick ducking envelope and delay-line helpers. Notes never consume noise RNG.

For background on oscillator sync and pitch-envelope sweeps, see
[Roland's oscillator explanation](https://articles.roland.com/exploring-the-sh-4d-oscillators/).
The saw-specific coefficients here come from the discontinuities of the
piecewise saw over one master period; this implementation is not a recreation
of a particular commercial synth preset.

Lead-enabled mixes use a static 0.86 headroom gain on all buses, including solos.
The rhythm's balance and synthesis stay the same, and lead-level zero retains
that gain so muting the lead cannot change rhythm loudness. `--lead off` preserves
the original output. Mix comparisons use constant-gain loudness matching.

```bash
python3 agent-tests/hard_techno_audition.py --phase 4
zig build test-music
zig build procedural-music-probe -- hard-techno --lead razor --arrangement track --seed 12345 --out agent-temp-files/hard-techno/lead_track.wav
```

New controls: `--lead off|razor|hollow|wide|machine|buzz|iron|corrosion`, `--lead-level 0..1` (default 0.75),
and `--techno-bus lead`. The compatibility default remains off; pass
`--lead corrosion` for the selected tone. The phase-4 audition command explicitly
enables each candidate. Phases 1–3 of the
recipe remain available. Raw lead stems retain mix gain; see the
[audition receipt](agent-temp-files/hard-techno/phase4/audition.json).

Original audition validation: all 24 tests, formatting and the build passed. The five new tests cover
folded-harmonic suppression versus a naive sync oscillator, gate/retrigger
behavior, reset/chunk/seed determinism, bus summation, full-track lead entry and
ending, and headroom at both tempo extremes. The initial all-controls-maximum
test exposed clipping; adding static headroom resolved it. This was an
implementation finding before independent review.

All 14 loop/full mix/stem renders are finite and unclipped. The three comparison
mixes measure -17.98, -18.00 and -18.00 LUFS after matching; raw true peaks range
from -4.82 to -4.75 dBTP. Both loop and full-track stem sums differ by at most
2 PCM LSB. The full track has 579 lead notes, 480 kicks and exact trailing silence.
Lead-enabled 25.6-second renders took 216–283 ms, and full-track renders took
1.50–1.57 seconds. These are offline render/write times, not audio-callback
deadline measurements. The prescribed smoke run contains the five-second
success sentinel with no warnings, errors, panics or crashes.

All 13 same-build-mode regressions are byte-identical: ten Phase 2 loops/stems,
the previous lead-off full track, and the taiko/guitar baselines. See
[regression.json](agent-temp-files/hard-techno/phase4/regression.json). An initial
legacy comparison used ReleaseFast against Debug baselines; rerendering with
the matching Debug mode resolved those numerical differences without code changes.

One independent read-only review covered all six code/test/helper files and the
applicable skills. It found no actionable issues after inspecting the shared
owners, sync math, timing, static headroom, CLI and automation. It verified the
audition and smoke evidence; the final legacy hash receipt was completed after
its report and sent as follow-up evidence. No review-driven code corrections
were needed. User listening will determine whether the sound, riff and balance
work; no musical-quality verdict is inferred from these technical checks.

## Phase 3: complete arrangement

**Outcome and commit boundary:** a finite 128-bar track, retained loop mode,
section timing diagnostics, focused arrangement tests, and an extended audition
recipe for full tracks and transition previews. The user requested implementation
after the concrete plan, then explicitly requested the completed phase's commit.

The arrangement uses the selected tight low end and the existing voices/effects.
`StepSequencer16` provides the clock; `composition.easeLevels` smooths layer
changes over roughly 20 ms. Section changes preserve synthesis/effect state.
An eight-bar break omits kick triggers, a short clap build leaves one beat of
space before the return, and the final four bars fade to zero. Playback remains
silent after bar 128 until reset. Noise seeds change timbre, while the score and
section timeline stay repeatable.

| Section | Bars (one-based) | Start at 150 BPM | Development |
| --- | --- | --- | --- |
| Intro | 1–8 | 0:00.0 | Tight kick, restrained hats, then rumble |
| Drive | 9–40 | 0:12.8 | Warehouse enters and gradually fills out |
| Contrast | 41–56 | 1:04.0 | Machine percussion with a lighter rumble balance |
| Pressure | 57–80 | 1:29.6 | Warehouse returns, with an eight-bar reduction and fills |
| Breakdown | 81–88 | 2:08.0 | Kick drops out; percussion builds toward the return |
| Return | 89–120 | 2:20.8 | Full Warehouse pulse, then late-phrase accents |
| Outro | 121–128 | 3:12.0 | Layers withdraw; the master fades from 3:18.4 |
| Finished | — | 3:24.8 | Silence |

Listen to [the full track](agent-temp-files/hard-techno/phase3/track_seed_12345_matched.wav)
or [the transition previews](agent-temp-files/hard-techno/phase3/transitions.wav).
The full file includes one second of trailing silence for the ending check.
The preview pack has four excerpts, introduced by one through four beeps:

| Cue | Preview | Start in pack | Duration |
| --- | --- | --- | --- |
| 1 | Main groove entry | 0.18 s | 9.6 s |
| 2 | Machine contrast | 10.66 s | 9.6 s |
| 3 | Break and return | 21.24 s | 22.4 s |
| 4 | Ending | 44.72 s | 10.6 s |

The preview segments retain the full track's constant gain, preserving the
quieter break. Three seeds (12345, 54321, 98765) were rendered and matched to
-18.01 LUFS. Raw true peaks range from -3.60 to -3.32 dBTP. The raw/stem paths,
commands, section frames, loudness measurements and checks are recorded in
[audition.json](agent-temp-files/hard-techno/phase3/audition.json).

```bash
python3 agent-tests/hard_techno_audition.py --phase 3
zig build test-music
zig build procedural-music-probe -- hard-techno --arrangement track --seed 12345 --out agent-temp-files/hard-techno/full_track.wav
```

`--arrangement track` defaults to the full 128 bars at the chosen tempo, plus one
second of silence. Explicit `--duration` supports partial renders. Track mode
uses the fixed Warehouse/Machine form; `--groove` selects patterns in loop mode.
`--arrangement loop` is still the default, preserving earlier audition commands.

Completed validation: all 19 music tests and the build pass. Tests cover exact
section samples, fractional timing across all 128 bars at 139.5 BPM, quiet
break/return energy, boundary continuity, finite/headroom behavior, the silent
ending and subsequent reset, gain smoothing, chunk invariance, and reset-time
configuration snapshots. All seven full-track mix/stem renders are finite and
unclipped. Three seeds have identical section traces and 480 kicks. The primary
track's four stems sum within 3 PCM LSB; measured section-boundary jumps are at
most 0.0031 full scale. Full-track rendering/writing took 1.13–1.17 seconds;
this does not measure the game callback.

All ten Phase 2 loop mixes/stems remain byte-identical after regenerating them
with the updated audition recipe; see
[regression.json](agent-temp-files/hard-techno/phase3/regression.json).
Formatting and diff checks pass. The final prescribed smoke run contains
`info: Ran successfully for 5 seconds` with no warnings, errors, panics or crashes
in [smoke_test.log](agent-temp-files/smoke_test.log).

One independent read-only review covered the four code/test/helper files and
applicable skills. It found no actionable issues and independently verified the
silent endings, exact stereo preview excerpts, loop regression bytes and render
receipts. No review-driven corrections were needed. Documentation was inspected
locally. Musical-quality feedback remains for user listening; game integration
and audio-callback performance checks belong to the proposed next phase.

## Phase 2: percussion groove

**Outcome and commit boundary:** three repeatable 16-bar percussion grooves over
the selected tight kick/rumble, isolated buses, focused shared-instrument fixes,
and an updated listening recipe. Long-form arrangement and game integration
remain the subsequent milestones. The user authorized starting this phase along
with the Phase 1 commit, then separately requested its commit after listening.

The groove choices are `warehouse` (straight offbeat hats), `rolling` (shuffled
sixteenths and ghost claps), and `machine` (sparse hats with metallic answers).
They share the selected low end and use deliberate two/four-bar accents. Noise
streams belong to individual instruments; noise consumption cannot change the
score. Swing delays percussion only, keeping the kick on its original grid.

Shared code extends `HiHat` with velocity, adjustable decay and choking, fixes
`Envelope` release from its current level and zero-sustain completion, and adds
a three-burst electronic clap. Metallic hits reuse the existing modal Atarigane
voice with a shorter stroke. New techno hat frequencies stay below Nyquist.
The old bass/acid proposal remains optional. Listening feedback favors developing
Warehouse as the main groove while retaining Machine as an alternative.

The existing probe now supports `--groove foundation|warehouse|rolling|machine`,
`--percussion 0..1`, and buses `mix`, `kick`, `rumble`, `low_end`, `hats`, `clap`,
`metal`, and `percussion`. `warehouse` is the preferred full-groove default;
`foundation` reproduces Phase 1. Soloing is performed after synthesis.

```bash
python3 agent-tests/hard_techno_audition.py --phase 2
zig build test-music
zig build procedural-music-probe -- hard-techno --groove rolling --duration 25.6 --seed 12345 --out agent-temp-files/hard-techno/rolling.wav
```

The updated audition recipe preserves stereo in both the comparison pack and
the individual clips. It measures loudness, applies constant gain, verifies the
matched level/true peak, and leaves the raw stems at their mix gains.

Listen to [the stereo comparison](agent-temp-files/hard-techno/phase2/compare.wav):

| Cue | Groove | Start | Full 16-bar clip |
| --- | --- | --- | --- |
| 1 beep | Warehouse: straight offbeat hats | 0.18 s | [WAV](agent-temp-files/hard-techno/phase2/warehouse_matched.wav) |
| 2 beeps | Rolling: shuffled sixteenths and ghost claps | 13.86 s | [WAV](agent-temp-files/hard-techno/phase2/rolling_matched.wav) |
| 3 beeps | Machine: sparse hats and metallic answers | 27.64 s | [WAV](agent-temp-files/hard-techno/phase2/machine_matched.wav) |

The clips measure -18.01, -18.01, and -18.00 LUFS after constant-gain matching.
Raw mix true peaks range from -3.87 to -3.49 dBTP. All ten mix/stem renders are
finite and unclipped. Full mixes took 149–159 ms to render/write 25.6 seconds;
this is offline throughput, not a runtime callback measurement. The settings,
commands, timings and raw stem paths are in
[audition.json](agent-temp-files/hard-techno/phase2/audition.json). Start with
the full mixes, then use [percussion](agent-temp-files/hard-techno/phase2/warehouse_percussion_raw.wav),
[hats](agent-temp-files/hard-techno/phase2/warehouse_hats_raw.wav),
[clap](agent-temp-files/hard-techno/phase2/warehouse_clap_raw.wav), or
[metal](agent-temp-files/hard-techno/phase2/warehouse_metal_raw.wav) to inspect
the initial warehouse balance. These stems retain their original mix gain.

Completed validation:

- All 15 tests pass, including early note-off, hat choke, clap retrigger, swing
  timing, full bus summing, chunk/seed behavior, unchanged low end, and
  headroom/DC at extreme settings. Stress testing caught excess clap gain at
  extreme settings; reducing the clap bus gain fixed it before review.
- Formatting, build, and diff checks pass. The smoke log contains the five-second
  success sentinel with no warnings or errors.
- Taiko/guitar 32-second seed-12345 clips and the selected Phase 1 low end remain
  byte-identical to their baselines; see
  [regression.json](agent-temp-files/hard-techno/phase2/regression.json).
- One independent read-only review covered all six code/test/helper files and
  applicable skills. It found no actionable issues and independently verified
  the regression bytes, exact stereo comparison segments, render receipts and
  smoke log. No review-driven code corrections were needed. The envelope fix
  and clap gain adjustment were implementation work before that review.

User listening feedback: “the first one and the last one are really good” and
“Maybe the first one is the best”. Warehouse is the leading choice, with Machine
also positively received. This is a tentative preference, not a request to
change either sound. No synthesis edits or new renders were needed to apply it;
Warehouse was already the default. No musical-quality verdict is inferred from
metrics.

This feedback became the Warehouse-led Phase 3 arrangement described above,
with one Machine contrast section and deliberate phrase-boundary changes.

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
python3 agent-tests/hard_techno_audition.py --phase 1
zig build test-music
zig build procedural-music-probe -- hard-techno --groove foundation --duration 25.6 --seed 12345 --out agent-temp-files/hard-techno/custom.wav
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
  took 75–101 ms at the Phase 1 handoff; this is offline throughput, not a measured game
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

## Phase 5: basic playback retained; sound sliders removed

The user requested removal of the experimental sound sliders when accepting the
sustained bassline. Hard Techno remains available under **Game Menu → Music →
Style: Hard Techno**, with the accepted Corrosion lead and sustained bass.
Volume, Tempo Scale and Reverb use the original numeric menu controls.
**Playback: Loop / Full Track** selects the short loop or arranged 128-bar track.
The added lead/drum rows, range-bar renderer, groove editor, Reset Techno Sound
and four patch-multiplier controls are removed. The Corrosion synth implementation
is restored to its accepted pre-slider form. Older settings containing the removed
`lead_controls` object still load; the unknown fields are ignored.

Hard Techno saves its own tempo (0.35–1.65, with 1 = 150 BPM) so switching or
cancelling style previews preserves other styles' wider tempo range. The saved
loop groove remains usable; Full Track uses its arranged Warehouse/Machine
sections and repeats after its ending. Changing playback mode restarts the score.
Tempo and reverb changes preserve position and smooth the effect taps.
**Reset Changes** restores the complete music-menu snapshot from opening.

The music component retains synchronization for settings, style changes, cue
requests and file-buffer replacement through the audio stream's recursive lock;
SDL holds that same lock during its stream callback. See the
[SDL locking contract](https://wiki.libsdl.org/SDL3/SDL_LockAudioStream).
Fractional delay reads and tempo retiming remain in the shared DSP and generator
owners. These support the existing playback controls and held bass notes.

Stored settings gain a nested `music_hard_techno` config; older files load the
Corrosion and bass defaults. Generator volume remains 0.86 in game. The probe's
`--master-volume` option reproduces SDL output gain; e.g. use
`--lead corrosion --volume 0.86 --master-volume 0.5` for the default menu volume.
Offline tracks remain finite. Startup flags `--music-menu` and
`--music-settings PATH` support isolated testing and normal menu startup.

The original integration review found one **P2** in `src/musicConfigMenu.zig`:
cancelling a Hard Techno style preview could overwrite Ambient's saved tempo
outside the 0.35–1.65 range. The fix retains separate tempo settings. Its tests for
2.0 and 0.2, including close/reload persistence, remain in the simplified menu.

### Accepted bass and slider rollback validation

- Formatting, build and diff checks pass.
- `zig build test-music -Doptimize=ReleaseSafe --summary all`: 33 tests pass.
  The obsolete multiplier-controls test was removed; bass, lead, tempo,
  headroom and shared-DSP checks remain.
- `zig build test-music-menu --summary all`: two tests pass. They cover old
  slider-settings compatibility, basic controls/reset, bass and groove settings
  preservation, playback/style visibility, tempo-preview restoration and actual
  dummy SDL playback with rapid tempo/reverb changes and master mute.
- The 25.6-second Corrosion/bass loop and 205.8-second full track have exactly
  the same decoded PCM as the accepted sustained-bass audition files. Both
  renders are finite and unclipped.
- The prescribed five-second smoke opened the music menu with an isolated
  Hard Techno fixture. It reached the sentinel without warnings, errors or panics.
- See [the rollback receipt](agent-temp-files/hard-techno/slider-rollback/validation.json)
  and logs in the same directory. One fresh-context read-only reviewer found
  no actionable issues in the rollback, shared menu/settings boundaries or audio
  synchronization. It independently confirmed both PCM comparisons and inspected
  validation logs. Manual GUI interaction was not part of that review.

```bash
zig build test-music -Doptimize=ReleaseSafe --summary all
zig build test-music-menu --summary all
zig build
bash scripts/smoke_test.sh --music-settings agent-temp-files/hard-techno/slider-rollback/smoke-settings.json --music-menu
```

## Phase roadmap

| Phase | Deliverable | Main validation |
| --- | --- | --- |
| 2. Complete groove (committed; Warehouse preferred) | Three percussion grooves over the selected tight foundation, hats with choking, clap, sparse metallic percussion, and shared envelope release/idle fixes. Machine is also positively received; a tonal part remains optional. | Matched 16-bar mixes and isolated buses; 15 focused tests, unchanged low-end/legacy renders, build/smoke and independent review completed. |
| 3. Musical development (committed) | 128-bar Warehouse-led arrangement with one Machine contrast section, phrase-aligned builds, break, fills, return and ending; existing step clock and layer smoothing. | Three full-track seeds and transition previews; 19 tests; section alignment, continuity, ending, reset, bus summing, loop regressions, build/smoke and independent review completed. |
| 4. Synth hook (accepted with bass commit) | Original-riff lead comparisons, reusable sync oscillator/instrument, isolated lead bus, and phrase-aligned track entrances. Corrosion is selected for now and can be tuned later. | Matched mixes, full Corrosion track, stem sums, 25 tests, 12 control regressions and build/smoke completed; independent review found no actionable issues. |
| 5. Basic playback (retained; sound sliders removed) | Hard Techno playback, synchronization, settings/reset and repeating runtime track; original numeric controls and Loop/Full Track. | Two menu/SDL tests, exact loop/full-track audio regressions, build and isolated smoke pass; the original P2 tempo-preview fix remains covered. |
| 6. Independent bassline (sustained iteration accepted) | Separate mono saw/sine bass with held legato notes, four-bar counterline, arrangement, defaults/persistence, bass stem and short-note/sustained comparison. Progression/resume is proposed next, before the lead editor. | 34 music and two menu/SDL tests, six finite/unclipped renders, two exact bass-off regressions, extended headroom sweep and build/smoke pass. Review found one P2 reference-overwrite issue, fixed; live-tempo regression passes in both directions. |

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

Suggested prompt when resuming:

> Read MUSIC_HANDOFF.md. The sustained bass is accepted and the experimental
> music-menu sound sliders have been removed. Corrosion and basic Hard Techno
> playback are retained. Phase 7 has Noise Burst and Snare replacements for the
> wooden-sounding background accent. The user prefers Snare (now the default)
> and also likes Noise Burst. The user accepted this phase and requested its commit.
> Progression over 1–3 minute sections and playback resume
> across game launches are proposed next, ahead of any revised lead editor.
> Include quiet or filtered lead teases before full entrances and featured solos
> for the accepted sustained bass, with the lead resting to give it space.
> All sounds must fit machinery/synths or a drum kit, with no wooden percussion.
> Present the next phase plan before implementing it.
