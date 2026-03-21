// Procedural relaxing piano style — v2 composition engine.
//
// Uses chord progression, phrase memory, multi-scale arcs, and key modulation
// so the piano develops motifs over time instead of circling one static loop.
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");

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

var engine: composition.CompositionEngine = .{};

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

var melody_target: f32 = 0.9;
var harmony_target: f32 = 0.45;
var drone_target: f32 = 0.45;

var melody_level: f32 = 0.8;
var harmony_level: f32 = 0.15;
var drone_level: f32 = 0.25;

const LAYER_FADE_RATE: f32 = 0.00004;

const MELODY_VOICE = 0;
const HARMONY_VOICE = 1;
var voices: [2]instruments.PianoVoice = .{
    instruments.PianoVoice.init(-0.28, 0.0),
    instruments.PianoVoice.init(0.28, 1.5),
};
var voice_beat_counter: [2]f32 = .{ 0.0, 0.0 };
var voice_beat_len: [2]f32 = .{ 3.25, 5.5 };

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

pub fn reset() void {
    rng = dsp.Rng.init(77777);
    engine.reset(.{ .root = 36, .scale_type = .minor_pentatonic }, initHarmony(), PIANO_ARCS, CHORD_CHANGE_BEATS, .mixed);
    lfo_reverb = .{ .period_beats = 140, .depth = 0.05 };
    melody_target = 0.9;
    harmony_target = 0.45;
    drone_target = 0.45;
    melody_level = 0.8;
    harmony_level = 0.15;
    drone_level = 0.25;
    voices = .{
        instruments.PianoVoice.init(-0.28, 0.0),
        instruments.PianoVoice.init(0.28, 1.5),
    };
    voice_beat_counter = .{ 0.0, 0.0 };
    voice_beat_len = .{ 3.25, 5.5 };
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
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = dsp.samplesPerBeat(bpm);

    for (0..frames) |i| {
        lfo_reverb.advanceSample(bpm);
        const tick = engine.advanceSample(&rng, bpm);
        if (tick.chord_changed) {
            advanceChord();
        }
        updateLayerTargets(tick.macro);
        melody_level += (melody_target - melody_level) * LAYER_FADE_RATE;
        harmony_level += (harmony_target - harmony_level) * LAYER_FADE_RATE;
        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;

        voice_beat_counter[MELODY_VOICE] += 1.0 / spb;
        if (voice_beat_counter[MELODY_VOICE] >= voice_beat_len[MELODY_VOICE]) {
            voice_beat_counter[MELODY_VOICE] -= voice_beat_len[MELODY_VOICE];
            triggerMelodyNote(tick.meso, tick.micro);
        }

        voice_beat_counter[HARMONY_VOICE] += 1.0 / spb;
        if (voice_beat_counter[HARMONY_VOICE] >= voice_beat_len[HARMONY_VOICE]) {
            voice_beat_counter[HARMONY_VOICE] -= voice_beat_len[HARMONY_VOICE];
            triggerHarmonyNote(tick.meso);
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const melody_sample = voices[MELODY_VOICE].process(&rng, 0.0, brightness * 0.28, 0.0, 0.0) * note_vol * melody_level;
        const melody_stereo = panStereo(melody_sample, voices[MELODY_VOICE].pan);
        left += melody_stereo[0];
        right += melody_stereo[1];

        const harmony_sample = voices[HARMONY_VOICE].process(&rng, 0.0, brightness * 0.18, 0.0, 0.0) * note_vol * harmony_level * 0.85;
        const harmony_stereo = panStereo(harmony_sample, voices[HARMONY_VOICE].pan);
        left += harmony_stereo[0];
        right += harmony_stereo[1];

        const drone_sample = drone.process() * drone_level;
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
    const degrees = engine.harmony.chordScaleDegrees(engine.key.scale_type);
    melody_phrase.setChordTones(degrees.tones[0..degrees.count]);
    harmony_phrase.setChordTones(degrees.tones[0..degrees.count]);

    const chord = engine.harmony.chords[engine.harmony.current];
    drone.freq = midiToFreq(engine.key.root + chord.offsets[0] - 12);

    voice_beat_len[MELODY_VOICE] = 2.75 + rng.float() * 1.75;
    voice_beat_len[HARMONY_VOICE] = 4.5 + rng.float() * 2.5;
}

fn triggerMelodyNote(meso: f32, micro: f32) void {
    melody_phrase.rest_chance = rest_chance * (1.25 - meso * 0.35);

    if (phrase_memory.count > 0 and rng.float() < 0.32) {
        var varied_notes: [composition.PhraseGenerator.MAX_LEN]u8 = undefined;
        if (phrase_memory.recallVaried(&rng, &varied_notes, melody_phrase.region_low, melody_phrase.region_high)) |varied_len| {
            if (varied_len > 0 and varied_notes[0] != 0xFF) {
                triggerVoice(MELODY_VOICE, varied_notes[0], 0.95 + rng.float() * 0.08, meso, micro, true);
                return;
            }
        }
    }

    if (melody_phrase.advance(&rng)) |note_idx| {
        triggerVoice(MELODY_VOICE, note_idx, 0.95 + rng.float() * 0.08, meso, micro, true);
        if (melody_phrase.pos == 0 and melody_phrase.len > 0) {
            phrase_memory.store(&melody_phrase.notes, melody_phrase.len);
        }
    }
}

fn triggerHarmonyNote(meso: f32) void {
    harmony_phrase.rest_chance = (rest_chance + 0.15) * (1.2 - meso * 0.25);
    if (harmony_phrase.advance(&rng)) |note_idx| {
        triggerVoice(HARMONY_VOICE, note_idx, 0.58 + rng.float() * 0.06, meso, 0.0, false);
    }
}

fn triggerVoice(voice_idx: usize, note_idx: u8, velocity: f32, meso: f32, micro: f32, is_melody: bool) void {
    const freq = midiToFreq(engine.key.noteToMidi(note_idx));
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

fn updateLayerTargets(macro: f32) void {
    melody_target = 0.65 + macro * 0.35;
    harmony_target = if (macro > 0.15) @min((macro - 0.15) * 1.1, 0.7) else 0.0;
    drone_target = 0.18 + macro * 0.45;
}

fn applyCueParams() void {
    switch (selected_cue) {
        .solace => {
            engine.key.root = 36;
            engine.key.target_root = 36;
            engine.key.scale_type = .minor_pentatonic;
            engine.chord_change_beats = 12.0;
            engine.modulation_mode = .mixed;
            lfo_reverb = .{ .period_beats = 140, .depth = 0.05 };
            melody_phrase.rest_chance = 0.48;
            melody_phrase.region_low = 7;
            melody_phrase.region_high = 16;
            harmony_phrase.rest_chance = 0.62;
            harmony_phrase.region_low = 5;
            harmony_phrase.region_high = 13;
            drone.filter = dsp.LPF.init(120.0);
            drone.detune_ratio = 1.002;
        },
        .nocturne => {
            engine.key.root = 33;
            engine.key.target_root = 33;
            engine.key.scale_type = .harmonic_minor;
            engine.chord_change_beats = 16.0;
            engine.modulation_mode = .fourth;
            lfo_reverb = .{ .period_beats = 170, .depth = 0.06 };
            melody_phrase.rest_chance = 0.58;
            melody_phrase.region_low = 6;
            melody_phrase.region_high = 13;
            harmony_phrase.rest_chance = 0.72;
            harmony_phrase.region_low = 4;
            harmony_phrase.region_high = 11;
            drone.filter = dsp.LPF.init(100.0);
            drone.detune_ratio = 1.0014;
        },
        .daybreak => {
            engine.key.root = 38;
            engine.key.target_root = 38;
            engine.key.scale_type = .major_pentatonic;
            engine.chord_change_beats = 9.0;
            engine.modulation_mode = .fifth;
            lfo_reverb = .{ .period_beats = 115, .depth = 0.04 };
            melody_phrase.rest_chance = 0.36;
            melody_phrase.region_low = 9;
            melody_phrase.region_high = 18;
            harmony_phrase.rest_chance = 0.54;
            harmony_phrase.region_low = 7;
            harmony_phrase.region_high = 14;
            drone.filter = dsp.LPF.init(150.0);
            drone.detune_ratio = 1.0025;
        },
        .remembrance => {
            engine.key.root = 35;
            engine.key.target_root = 35;
            engine.key.scale_type = .dorian;
            engine.chord_change_beats = 14.0;
            engine.modulation_mode = .none;
            lfo_reverb = .{ .period_beats = 155, .depth = 0.07 };
            melody_phrase.rest_chance = 0.52;
            melody_phrase.region_low = 8;
            melody_phrase.region_high = 15;
            harmony_phrase.rest_chance = 0.66;
            harmony_phrase.region_low = 5;
            harmony_phrase.region_high = 12;
            drone.filter = dsp.LPF.init(110.0);
            drone.detune_ratio = 1.0017;
        },
    }
}
