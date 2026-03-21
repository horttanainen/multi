// Procedural chill house style — v2 composition engine.
//
// Uses Markov chord progressions, multi-scale arcs, chord-aware bass motion,
// vertical layer activation, and macro key modulation so the groove evolves
// instead of looping a static bar forever.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");

const Envelope = dsp.Envelope;
const LPF = dsp.LPF;
const StereoReverb = dsp.StereoReverb;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;
const panStereo = dsp.panStereo;
const SAMPLE_RATE = dsp.SAMPLE_RATE;

pub const CuePreset = enum(u8) {
    deep_night,
    sunset_drive,
    soft_focus,
    warehouse,
};

pub var bpm: f32 = 120.0;
pub var reverb_mix: f32 = 0.35;
pub var kick_vol: f32 = 0.25;
pub var hihat_vol: f32 = 0.12;
pub var bass_vol: f32 = 0.2;
pub var pad_vol: f32 = 0.06;
pub var stab_chance: f32 = 0.4;
pub var selected_cue: CuePreset = .deep_night;

const HouseReverb = StereoReverb(.{ 1117, 1049, 983, 907 }, .{ 197, 419 });
var reverb: HouseReverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });
var rng: dsp.Rng = dsp.Rng.init(54321);

var engine: composition.CompositionEngine = .{};

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 10 }, .len = 4 }; // i7
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 14 }, .len = 4 }; // IIImaj-ish color
    h.chords[2] = .{ .offsets = .{ 5, 9, 12, 15 }, .len = 4 }; // iv
    h.chords[3] = .{ .offsets = .{ 7, 10, 14, 17 }, .len = 4 }; // v
    h.chords[4] = .{ .offsets = .{ 10, 14, 17, 21 }, .len = 4 }; // VII
    h.num_chords = 5;
    h.transitions[0] = .{ 0.08, 0.24, 0.30, 0.12, 0.26, 0, 0, 0 };
    h.transitions[1] = .{ 0.22, 0.08, 0.28, 0.12, 0.30, 0, 0, 0 };
    h.transitions[2] = .{ 0.26, 0.18, 0.08, 0.22, 0.26, 0, 0, 0 };
    h.transitions[3] = .{ 0.28, 0.12, 0.24, 0.08, 0.28, 0, 0, 0 };
    h.transitions[4] = .{ 0.34, 0.14, 0.20, 0.16, 0.16, 0, 0, 0 };
    return h;
}

const HOUSE_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 4, .shape = .rise_fall },
    .meso = .{ .section_beats = 32, .shape = .rise_fall },
    .macro = .{ .section_beats = 128, .shape = .plateau },
};

var lfo_filter: composition.SlowLfo = .{ .period_beats = 48, .depth = 0.07 };

var drum_target: f32 = 1.0;
var bass_target: f32 = 0.9;
var pad_target: f32 = 0.45;
var stab_target: f32 = 0.25;

var drum_level: f32 = 1.0;
var bass_level: f32 = 0.8;
var pad_level: f32 = 0.2;
var stab_level: f32 = 0.0;

const LAYER_FADE_RATE: f32 = 0.00006;

var kick: instruments.Kick = .{ .base_freq = 48.0, .sweep = 110.0, .volume = 1.2 };
var hat: instruments.HiHat = .{ .volume = 0.7 };
var bass: instruments.SawBass = .{ .drive = 0.42, .sub_mix = 0.48, .volume = 0.72 };
var bass_phrase: composition.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 7,
    .rest_chance = 0.08,
    .min_notes = 4,
    .max_notes = 8,
    .gravity = 3.2,
};

const PadVoice = dsp.Voice(3, 1);
const PAD_COUNT = 3;
var pads: [PAD_COUNT]PadVoice = .{
    .{ .fm_ratio = 1.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1600.0), .pan = -0.55 },
    .{ .fm_ratio = 2.0, .fm_depth = 0.75, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1500.0), .pan = 0.0 },
    .{ .fm_ratio = 3.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1550.0), .pan = 0.55 },
};

const StabVoice = dsp.Voice(2, 1);
var stab_voices: [3]StabVoice = .{
    .{ .unison_spread = 0.004, .pan = -0.3 },
    .{ .unison_spread = 0.004, .pan = 0.0 },
    .{ .unison_spread = 0.004, .pan = 0.3 },
};
var stab_env: Envelope = Envelope.init(0.002, 0.08, 0.0, 0.05);

var step_counter: f32 = 0.0;
var bar_step: u8 = 0;
var beat_number: u32 = 0;
const CHORD_CHANGE_BEATS: f32 = 8.0;

pub fn reset() void {
    rng = dsp.Rng.init(54321);
    engine.reset(.{ .root = 36, .scale_type = .dorian }, initHarmony(), HOUSE_ARCS, CHORD_CHANGE_BEATS, .mixed);
    lfo_filter = .{ .period_beats = 48, .depth = 0.07 };

    drum_target = 1.0;
    bass_target = 0.9;
    pad_target = 0.45;
    stab_target = 0.25;
    drum_level = 1.0;
    bass_level = 0.8;
    pad_level = 0.2;
    stab_level = 0.0;

    kick = .{ .base_freq = 48.0, .sweep = 110.0, .volume = 1.2 };
    hat = .{ .volume = 0.7 };
    bass = .{ .drive = 0.42, .sub_mix = 0.48, .volume = 0.72 };
    bass_phrase = .{
        .anchor = 0,
        .region_low = 0,
        .region_high = 7,
        .rest_chance = 0.08,
        .min_notes = 4,
        .max_notes = 8,
        .gravity = 3.2,
    };
    pads = .{
        .{ .fm_ratio = 1.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1600.0), .pan = -0.55 },
        .{ .fm_ratio = 2.0, .fm_depth = 0.75, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1500.0), .pan = 0.0 },
        .{ .fm_ratio = 3.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = LPF.init(1550.0), .pan = 0.55 },
    };
    stab_voices = .{
        .{ .unison_spread = 0.004, .pan = -0.3 },
        .{ .unison_spread = 0.004, .pan = 0.0 },
        .{ .unison_spread = 0.004, .pan = 0.3 },
    };
    stab_env = Envelope.init(0.002, 0.08, 0.0, 0.05);

    step_counter = 0.0;
    bar_step = 0;
    beat_number = 0;

    reverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm / 4.0;
    for (0..frames) |i| {
        lfo_filter.advanceSample(bpm);
        const tick = engine.advanceSample(&rng, bpm);
        if (tick.chord_changed) {
            advanceChord();
        }
        updateLayerTargets(tick.macro);
        drum_level += (drum_target - drum_level) * LAYER_FADE_RATE;
        bass_level += (bass_target - bass_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        stab_level += (stab_target - stab_level) * LAYER_FADE_RATE;

        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep(tick.meso, tick.micro);
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const kick_s = kick.process() * kick_vol * drum_level;
        left += kick_s;
        right += kick_s;

        const hat_s = hat.process(&rng) * hihat_vol * drum_level;
        left += hat_s * 0.42;
        right += hat_s * 0.62;

        const bass_s = bass.process() * bass_vol * bass_level;
        left += bass_s * 0.9;
        right += bass_s * 0.84;

        for (0..PAD_COUNT) |p| {
            const sample = pads[p].process() * pad_vol * pad_level;
            const stereo = panStereo(sample, pads[p].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const stab_out = processStab();
        left += stab_out[0] * stab_level;
        right += stab_out[1] * stab_level;

        const rev = reverb.process(.{ left, right });
        const wet = reverb_mix + tick.meso * 0.05;
        const dry = 1.0 - wet;
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.92);
        buf[i * 2 + 1] = softClip(right * 0.92);
    }
}

fn advanceChord() void {
    const degrees = engine.harmony.chordScaleDegrees(engine.key.scale_type);
    bass_phrase.setChordTones(degrees.tones[0..degrees.count]);

    const chord = engine.harmony.chords[engine.harmony.current];
    const filter_mod = lfo_filter.modulate();
    for (0..PAD_COUNT) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        const freq = midiToFreq(engine.key.root + offset + 12);
        pads[idx].filter = LPF.init((1100.0 + filter_mod * 900.0) + @as(f32, @floatFromInt(idx)) * 120.0);
        pads[idx].trigger(freq, Envelope.init(0.8, 0.5, 0.72, 2.8));
        stab_voices[idx].freq = midiToFreq(engine.key.root + offset + 12);
    }

    bass.freq = midiToFreq(engine.key.root + chord.offsets[0]);
}

fn advanceStep(meso: f32, micro: f32) void {
    const step = bar_step;
    beat_number += 1;

    if (step % 4 == 0) {
        kick.trigger(1.0);
    } else if ((step == 10 or step == 15) and rng.float() < 0.18 + meso * 0.22) {
        kick.trigger(0.55);
    }

    const hat_chance = if (step % 2 == 1)
        0.92
    else if (step == 14)
        0.85
    else
        0.15 + meso * 0.3;
    if (rng.float() < hat_chance) {
        hat.trigger();
    }

    if (shouldTriggerBass(step)) {
        bass_phrase.rest_chance = 0.06 + (1.0 - meso) * 0.08;
        if (bass_phrase.advance(&rng)) |note_idx| {
            bass.trigger(midiToFreq(engine.key.noteToMidi(note_idx)));
        } else {
            bass.env.trigger();
        }
        bass.setFilter((300.0 + micro * 220.0 + meso * 340.0) * lfo_filter.modulate());
    }

    const stab_trigger = switch (step) {
        3, 11 => true,
        7, 15 => rng.float() < stab_chance * (0.35 + meso * 0.45),
        else => false,
    };
    if (stab_trigger and rng.float() < stab_chance * (0.55 + meso * 0.55)) {
        stab_env = Envelope.init(0.002, 0.05 + micro * 0.06, 0.0, 0.04 + meso * 0.04);
        stab_env.trigger();
    }

    bar_step = (bar_step + 1) % 16;
}

fn shouldTriggerBass(step: u8) bool {
    return switch (step) {
        0, 3, 6, 8, 10, 14 => true,
        else => false,
    };
}

fn updateLayerTargets(macro: f32) void {
    drum_target = 0.9 + macro * 0.1;
    bass_target = 0.65 + macro * 0.35;
    pad_target = 0.18 + macro * 0.82;
    stab_target = if (macro > 0.2) @min((macro - 0.2) * 1.2, 0.85) else 0.0;
}

fn applyCueParams() void {
    switch (selected_cue) {
        .deep_night => {
            engine.key.root = 36;
            engine.key.target_root = 36;
            engine.key.scale_type = .dorian;
            engine.chord_change_beats = 8.0;
            engine.modulation_mode = .mixed;
            lfo_filter = .{ .period_beats = 56, .depth = 0.07 };
            bass_phrase.rest_chance = 0.08;
            bass_phrase.region_low = 0;
            bass_phrase.region_high = 7;
            kick.base_freq = 48.0;
            kick.sweep = 110.0;
            hat.volume = 0.7;
            bass.drive = 0.42;
            stab_chance = std.math.clamp(stab_chance, 0.0, 1.0);
        },
        .sunset_drive => {
            engine.key.root = 38;
            engine.key.target_root = 38;
            engine.key.scale_type = .mixolydian;
            engine.chord_change_beats = 6.0;
            engine.modulation_mode = .fifth;
            lfo_filter = .{ .period_beats = 42, .depth = 0.09 };
            bass_phrase.rest_chance = 0.04;
            bass_phrase.region_low = 1;
            bass_phrase.region_high = 8;
            kick.base_freq = 50.0;
            kick.sweep = 120.0;
            hat.volume = 0.82;
            bass.drive = 0.5;
        },
        .soft_focus => {
            engine.key.root = 34;
            engine.key.target_root = 34;
            engine.key.scale_type = .minor_pentatonic;
            engine.chord_change_beats = 10.0;
            engine.modulation_mode = .fourth;
            lfo_filter = .{ .period_beats = 70, .depth = 0.05 };
            bass_phrase.rest_chance = 0.14;
            bass_phrase.region_low = 0;
            bass_phrase.region_high = 6;
            kick.base_freq = 45.0;
            kick.sweep = 95.0;
            hat.volume = 0.55;
            bass.drive = 0.32;
        },
        .warehouse => {
            engine.key.root = 41;
            engine.key.target_root = 41;
            engine.key.scale_type = .harmonic_minor;
            engine.chord_change_beats = 4.0;
            engine.modulation_mode = .none;
            lfo_filter = .{ .period_beats = 36, .depth = 0.11 };
            bass_phrase.rest_chance = 0.02;
            bass_phrase.region_low = 0;
            bass_phrase.region_high = 9;
            kick.base_freq = 52.0;
            kick.sweep = 132.0;
            hat.volume = 0.92;
            bass.drive = 0.62;
        },
    }
}

fn processStab() [2]f32 {
    const env_val = stab_env.process();
    if (env_val < 0.001) return .{ 0.0, 0.0 };

    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..3) |idx| {
        stab_voices[idx].env = .{
            .state = .sustain,
            .level = env_val,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = env_val,
            .release_rate = 0,
        };
        const sample = stab_voices[idx].process() * 0.08;
        const stereo = panStereo(sample, stab_voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}
