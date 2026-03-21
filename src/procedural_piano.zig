// Procedural relaxing piano style — v2 composition engine.
//
// Uses chord progression, phrase memory, multi-scale arcs, and key modulation
// so the piano develops motifs over time instead of circling one static loop.
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;
const panStereo = dsp.panStereo;
const SAMPLE_RATE = dsp.SAMPLE_RATE;

pub const CuePreset = enum(u8) {
    solace,
    nocturne,
    daybreak,
    remembrance,
};

pub var bpm: f32 = 65.0;
pub var reverb_mix: f32 = 0.65;
pub var note_vol: f32 = 0.12;
pub var rest_chance: f32 = 0.5;
pub var brightness: f32 = 0.5;
pub var selected_cue: CuePreset = .solace;

const PianoReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: PianoReverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });
var rng: dsp.Rng = dsp.Rng.init(77777);

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 10 }, .len = 4 };
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 14 }, .len = 4 };
    h.chords[2] = .{ .offsets = .{ 5, 8, 12, 15 }, .len = 4 };
    h.chords[3] = .{ .offsets = .{ 8, 12, 15, 19 }, .len = 4 };
    h.chords[4] = .{ .offsets = .{ 10, 14, 17, 21 }, .len = 4 };
    h.num_chords = 5;
    h.transitions[0] = .{ 0.10, 0.22, 0.26, 0.18, 0.24, 0, 0, 0 };
    h.transitions[1] = .{ 0.24, 0.10, 0.22, 0.16, 0.28, 0, 0, 0 };
    h.transitions[2] = .{ 0.26, 0.18, 0.08, 0.24, 0.24, 0, 0, 0 };
    h.transitions[3] = .{ 0.22, 0.14, 0.24, 0.10, 0.30, 0, 0, 0 };
    h.transitions[4] = .{ 0.32, 0.14, 0.18, 0.18, 0.18, 0, 0, 0 };
    return h;
}

const PIANO_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 192, .shape = .plateau },
};
var lfo_reverb: composition.SlowLfo = .{ .period_beats = 140, .depth = 0.05 };

const MELODY_LAYER = 0;
const HARMONY_LAYER = 1;
const DRONE_LAYER = 2;
const PIANO_LAYER_CURVES: [3]composition.LayerCurve = .{
    .{ .offset = 0.65, .slope = 0.35, .max = 1.0 },
    .{ .start = 0.15, .offset = 0.0, .slope = 1.1, .max = 0.7 },
    .{ .offset = 0.18, .slope = 0.45, .max = 1.0 },
};

const LAYER_FADE_RATE: f32 = 0.00004;

const MELODY_VOICE = 0;
const HARMONY_VOICE = 1;
var voices: [2]instruments.PianoVoice = .{
    instruments.PianoVoice.init(-0.28, 0.0),
    instruments.PianoVoice.init(0.28, 1.5),
};
const VOICE_TIMINGS: [2]composition.VoiceTimingSpec = .{
    .{ .base_beats = 2.75, .random_beats = 1.75 },
    .{ .base_beats = 4.5, .random_beats = 2.5 },
};

var melody_phrase: composition.PhraseGenerator = .{
    .anchor = 10,
    .region_low = 7,
    .region_high = 16,
    .rest_chance = 0.48,
    .min_notes = 3,
    .max_notes = 6,
    .gravity = 3.5,
};
var harmony_phrase: composition.PhraseGenerator = .{
    .anchor = 9,
    .region_low = 5,
    .region_high = 13,
    .rest_chance = 0.62,
    .min_notes = 2,
    .max_notes = 5,
    .gravity = 4.0,
};
var phrase_memory: composition.PhraseMemory = .{};

var drone: instruments.SineDrone = instruments.SineDrone.init(midiToFreq(36), 120.0, 1.002, 1.0, 0.5, 0.02);

const CHORD_CHANGE_BEATS: f32 = 12.0;
const PianoCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    chord_change_beats: f32,
    modulation_mode: composition.ModulationMode,
    reverb_lfo: composition.SlowLfo,
    melody_phrase: composition.PhraseConfig,
    harmony_phrase: composition.PhraseConfig,
    drone_filter_hz: f32,
    drone_detune_ratio: f32,
};
const CUE_SPECS: [4]PianoCueSpec = .{
    .{
        .root = 36,
        .scale_type = .minor_pentatonic,
        .chord_change_beats = 12.0,
        .modulation_mode = .mixed,
        .reverb_lfo = .{ .period_beats = 140, .depth = 0.05 },
        .melody_phrase = .{ .rest_chance = 0.48, .region_low = 7, .region_high = 16 },
        .harmony_phrase = .{ .rest_chance = 0.62, .region_low = 5, .region_high = 13 },
        .drone_filter_hz = 120.0,
        .drone_detune_ratio = 1.002,
    },
    .{
        .root = 33,
        .scale_type = .harmonic_minor,
        .chord_change_beats = 16.0,
        .modulation_mode = .fourth,
        .reverb_lfo = .{ .period_beats = 170, .depth = 0.06 },
        .melody_phrase = .{ .rest_chance = 0.58, .region_low = 6, .region_high = 13 },
        .harmony_phrase = .{ .rest_chance = 0.72, .region_low = 4, .region_high = 11 },
        .drone_filter_hz = 100.0,
        .drone_detune_ratio = 1.0014,
    },
    .{
        .root = 38,
        .scale_type = .major_pentatonic,
        .chord_change_beats = 9.0,
        .modulation_mode = .fifth,
        .reverb_lfo = .{ .period_beats = 115, .depth = 0.04 },
        .melody_phrase = .{ .rest_chance = 0.36, .region_low = 9, .region_high = 18 },
        .harmony_phrase = .{ .rest_chance = 0.54, .region_low = 7, .region_high = 14 },
        .drone_filter_hz = 150.0,
        .drone_detune_ratio = 1.0025,
    },
    .{
        .root = 35,
        .scale_type = .dorian,
        .chord_change_beats = 14.0,
        .modulation_mode = .none,
        .reverb_lfo = .{ .period_beats = 155, .depth = 0.07 },
        .melody_phrase = .{ .rest_chance = 0.52, .region_low = 8, .region_high = 15 },
        .harmony_phrase = .{ .rest_chance = 0.66, .region_low = 5, .region_high = 12 },
        .drone_filter_hz = 110.0,
        .drone_detune_ratio = 1.0017,
    },
};
const PianoStyleSpec = composition.StyleSpec(PianoCueSpec, 3, 2);
const STYLE: PianoStyleSpec = .{
    .arcs = PIANO_ARCS,
    .layer_curves = PIANO_LAYER_CURVES,
    .voice_timings = VOICE_TIMINGS,
    .cues = &CUE_SPECS,
};
const PianoRunner = composition.StyleRunner(PianoCueSpec, 3, 2);
var runner: PianoRunner = .{};

pub fn reset() void {
    rng = dsp.Rng.init(77777);
    lfo_reverb = .{ .period_beats = 140, .depth = 0.05 };
    voices = .{
        instruments.PianoVoice.init(-0.28, 0.0),
        instruments.PianoVoice.init(0.28, 1.5),
    };
    melody_phrase = .{
        .anchor = 10,
        .region_low = 7,
        .region_high = 16,
        .rest_chance = 0.48,
        .min_notes = 3,
        .max_notes = 6,
        .gravity = 3.5,
    };
    harmony_phrase = .{
        .anchor = 9,
        .region_low = 5,
        .region_high = 13,
        .rest_chance = 0.62,
        .min_notes = 2,
        .max_notes = 5,
        .gravity = 4.0,
    };
    phrase_memory = .{};
    drone = instruments.SineDrone.init(midiToFreq(36), 120.0, 1.002, 1.0, 0.5, 0.02);
    reverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });
    runner.reset(&rng, &STYLE, .{ .root = 36, .scale_type = .minor_pentatonic }, initHarmony(), CHORD_CHANGE_BEATS, .mixed, .{ 0.9, 0.45, 0.45 }, .{ 0.8, 0.15, 0.25 });
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    for (0..frames) |i| {
        lfo_reverb.advanceSample(bpm);
        const frame = runner.advanceFrame(&rng, &STYLE, bpm, LAYER_FADE_RATE);
        if (frame.tick.chord_changed) {
            advanceChord();
        }

        if (frame.voice_triggers[MELODY_VOICE]) {
            triggerMelodyNote(frame.tick.meso, frame.tick.micro);
        }

        if (frame.voice_triggers[HARMONY_VOICE]) {
            triggerHarmonyNote(frame.tick.meso);
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const melody_sample = voices[MELODY_VOICE].process(&rng, 0.0, brightness * 0.28, 0.0, 0.0) * note_vol * runner.layer_levels[MELODY_LAYER];
        const melody_stereo = panStereo(melody_sample, voices[MELODY_VOICE].pan);
        left += melody_stereo[0];
        right += melody_stereo[1];

        const harmony_sample = voices[HARMONY_VOICE].process(&rng, 0.0, brightness * 0.18, 0.0, 0.0) * note_vol * runner.layer_levels[HARMONY_LAYER] * 0.85;
        const harmony_stereo = panStereo(harmony_sample, voices[HARMONY_VOICE].pan);
        left += harmony_stereo[0];
        right += harmony_stereo[1];

        const drone_sample = drone.process() * runner.layer_levels[DRONE_LAYER];
        left += drone_sample;
        right += drone_sample;

        const wet = reverb_mix * lfo_reverb.modulate();
        const dry = 1.0 - wet;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left);
        buf[i * 2 + 1] = softClip(right);
    }
}

fn advanceChord() void {
    composition.applyChordTonesToPhrases(&runner.engine.harmony, runner.engine.key.scale_type, .{ &melody_phrase, &harmony_phrase });

    const chord = runner.engine.harmony.chords[runner.engine.harmony.current];
    drone.freq = midiToFreq(runner.engine.key.root + chord.offsets[0] - 12);

    composition.sampleVoiceTimings(2, &STYLE.voice_timings, &rng, &runner.voice_beat_len);
}

fn triggerMelodyNote(meso: f32, micro: f32) void {
    const picked = layers.nextPhraseStep(&rng, meso, &melody_phrase, &phrase_memory, .{
        .base_rest_chance = rest_chance,
        .rest_scale = 1.25,
        .meso_scale = 0.35,
        .recall_chance = 0.32,
    }) orelse return;
    triggerVoice(MELODY_VOICE, picked.note, 0.95 + rng.float() * 0.08, meso, micro, true);
}

fn triggerHarmonyNote(meso: f32) void {
    const picked = layers.nextPhraseStep(&rng, meso, &harmony_phrase, null, .{
        .base_rest_chance = rest_chance,
        .rest_offset = 0.15,
        .rest_scale = 1.2,
        .meso_scale = 0.25,
    }) orelse return;
    triggerVoice(HARMONY_VOICE, picked.note, 0.58 + rng.float() * 0.06, meso, 0.0, false);
}

fn triggerVoice(voice_idx: usize, note_idx: u8, velocity: f32, meso: f32, micro: f32, is_melody: bool) void {
    const freq = midiToFreq(runner.engine.key.noteToMidi(note_idx));
    const cutoff = if (is_melody)
        1200.0 + brightness * 3600.0 + meso * 1400.0
    else
        820.0 + brightness * 2200.0 + meso * 900.0;
    const decay = if (is_melody)
        1.4 + (1.0 - micro) * 0.45
    else
        2.1 + (1.0 - meso) * 0.6;
    const release = if (is_melody) 1.1 + meso * 0.5 else 1.8 + meso * 0.8;

    voices[voice_idx].pan = if (is_melody)
        (rng.float() - 0.5) * 0.7
    else
        (rng.float() - 0.5) * 0.35;
    voices[voice_idx].mod_ratio = if (is_melody) 3.0 else 2.4;
    voices[voice_idx].mod_depth = if (is_melody)
        0.5 + brightness * 1.35
    else
        0.3 + brightness * 0.7;
    voices[voice_idx].detune_ratio = 1.0005 + (rng.float() - 0.5) * 0.0015;
    voices[voice_idx].trigger(freq, velocity, cutoff, dsp.Envelope.init(0.003, decay, 0.0, release));
}

fn applyCueParams() void {
    const spec = STYLE.cues[@intFromEnum(selected_cue)];
    runner.engine.key.root = spec.root;
    runner.engine.key.target_root = spec.root;
    runner.engine.key.scale_type = spec.scale_type;
    runner.engine.chord_change_beats = spec.chord_change_beats;
    runner.engine.modulation_mode = spec.modulation_mode;
    lfo_reverb = spec.reverb_lfo;
    composition.applyPhraseConfig(spec.melody_phrase, &melody_phrase);
    composition.applyPhraseConfig(spec.harmony_phrase, &harmony_phrase);
    drone.filter = dsp.LPF.init(spec.drone_filter_hz);
    drone.detune_ratio = spec.drone_detune_ratio;
}
