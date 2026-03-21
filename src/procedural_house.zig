// Procedural chill house style — v2 composition engine.
//
// Uses Markov chord progressions, multi-scale arcs, chord-aware bass motion,
// vertical layer activation, and macro key modulation so the groove evolves
// instead of looping a static bar forever.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

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

const DRUM_LAYER = 0;
const BASS_LAYER = 1;
const PAD_LAYER = 2;
const STAB_LAYER = 3;
const KICK_MAIN_MASK: u16 = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12);
const KICK_FILL_MASK: u16 = (1 << 10) | (1 << 15);
const BASS_TRIGGER_MASK: u16 = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 14);
const HOUSE_BASS_LAYER_SPEC: layers.StepBassSpec = .{
    .trigger_mask = BASS_TRIGGER_MASK,
    .base_rest_chance = 0.06,
    .meso_rest_spread = 0.08,
    .filter_base_hz = 300.0,
    .filter_micro_hz = 220.0,
    .filter_meso_hz = 340.0,
};
const HOUSE_LAYER_CURVES: [4]composition.LayerCurve = .{
    .{ .offset = 0.9, .slope = 0.1, .max = 1.0 },
    .{ .offset = 0.65, .slope = 0.35, .max = 1.0 },
    .{ .offset = 0.18, .slope = 0.82, .max = 1.0 },
    .{ .start = 0.2, .offset = 0.0, .slope = 1.2, .max = 0.85 },
};

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

var beat_number: u32 = 0;
const CHORD_CHANGE_BEATS: f32 = 8.0;
const HouseCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    chord_change_beats: f32,
    modulation_mode: composition.ModulationMode,
    lfo_filter: composition.SlowLfo,
    bass_phrase: composition.PhraseConfig,
    kick_base_freq: f32,
    kick_sweep: f32,
    hat_volume: f32,
    bass_drive: f32,
};
const CUE_SPECS: [4]HouseCueSpec = .{
    .{
        .root = 36,
        .scale_type = .dorian,
        .chord_change_beats = 8.0,
        .modulation_mode = .mixed,
        .lfo_filter = .{ .period_beats = 56, .depth = 0.07 },
        .bass_phrase = .{ .rest_chance = 0.08, .region_low = 0, .region_high = 7 },
        .kick_base_freq = 48.0,
        .kick_sweep = 110.0,
        .hat_volume = 0.7,
        .bass_drive = 0.42,
    },
    .{
        .root = 38,
        .scale_type = .mixolydian,
        .chord_change_beats = 6.0,
        .modulation_mode = .fifth,
        .lfo_filter = .{ .period_beats = 42, .depth = 0.09 },
        .bass_phrase = .{ .rest_chance = 0.04, .region_low = 1, .region_high = 8 },
        .kick_base_freq = 50.0,
        .kick_sweep = 120.0,
        .hat_volume = 0.82,
        .bass_drive = 0.5,
    },
    .{
        .root = 34,
        .scale_type = .minor_pentatonic,
        .chord_change_beats = 10.0,
        .modulation_mode = .fourth,
        .lfo_filter = .{ .period_beats = 70, .depth = 0.05 },
        .bass_phrase = .{ .rest_chance = 0.14, .region_low = 0, .region_high = 6 },
        .kick_base_freq = 45.0,
        .kick_sweep = 95.0,
        .hat_volume = 0.55,
        .bass_drive = 0.32,
    },
    .{
        .root = 41,
        .scale_type = .harmonic_minor,
        .chord_change_beats = 4.0,
        .modulation_mode = .none,
        .lfo_filter = .{ .period_beats = 36, .depth = 0.11 },
        .bass_phrase = .{ .rest_chance = 0.02, .region_low = 0, .region_high = 9 },
        .kick_base_freq = 52.0,
        .kick_sweep = 132.0,
        .hat_volume = 0.92,
        .bass_drive = 0.62,
    },
};
const HouseStyleSpec = composition.StyleSpec(HouseCueSpec, 4, 0);
const STYLE: HouseStyleSpec = .{
    .arcs = HOUSE_ARCS,
    .layer_curves = HOUSE_LAYER_CURVES,
    .voice_timings = .{},
    .cues = &CUE_SPECS,
};
const HouseRunner = composition.StepStyleRunner(HouseCueSpec, 4);
var runner: HouseRunner = .{};

pub fn reset() void {
    rng = dsp.Rng.init(54321);
    lfo_filter = .{ .period_beats = 48, .depth = 0.07 };

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
    beat_number = 0;

    reverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });
    runner.reset(&STYLE, .{ .root = 36, .scale_type = .dorian }, initHarmony(), CHORD_CHANGE_BEATS, .mixed, .{ 1.0, 0.9, 0.45, 0.25 }, .{ 1.0, 0.8, 0.2, 0.0 });
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    for (0..frames) |i| {
        lfo_filter.advanceSample(bpm);
        const frame = runner.advanceFrame(&rng, &STYLE, bpm, LAYER_FADE_RATE);
        if (frame.tick.chord_changed) {
            advanceChord();
        }

        if (frame.step) |step| {
            advanceStep(step, frame.tick.meso, frame.tick.micro);
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const kick_s = kick.process() * kick_vol * runner.layer_levels[DRUM_LAYER];
        left += kick_s;
        right += kick_s;

        const hat_s = hat.process(&rng) * hihat_vol * runner.layer_levels[DRUM_LAYER];
        left += hat_s * 0.42;
        right += hat_s * 0.62;

        const bass_s = bass.process() * bass_vol * runner.layer_levels[BASS_LAYER];
        left += bass_s * 0.9;
        right += bass_s * 0.84;

        for (0..PAD_COUNT) |p| {
            const sample = pads[p].process() * pad_vol * runner.layer_levels[PAD_LAYER];
            const stereo = panStereo(sample, pads[p].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const stab_out = processStab();
        left += stab_out[0] * runner.layer_levels[STAB_LAYER];
        right += stab_out[1] * runner.layer_levels[STAB_LAYER];

        const rev = reverb.process(.{ left, right });
        const wet = reverb_mix + frame.tick.meso * 0.05;
        const dry = 1.0 - wet;
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.92);
        buf[i * 2 + 1] = softClip(right * 0.92);
    }
}

fn advanceChord() void {
    composition.applyChordTonesToPhrases(&runner.engine.harmony, runner.engine.key.scale_type, .{ &bass_phrase });

    const chord = runner.engine.harmony.chords[runner.engine.harmony.current];
    var freqs: [PAD_COUNT]f32 = undefined;
    layers.fillChordFrequencies(PAD_COUNT, &freqs, runner.engine.key.root, chord, 1);
    const filter_mod = lfo_filter.modulate();
    for (0..PAD_COUNT) |idx| {
        pads[idx].filter = LPF.init((1100.0 + filter_mod * 900.0) + @as(f32, @floatFromInt(idx)) * 120.0);
        pads[idx].trigger(freqs[idx], Envelope.init(0.8, 0.5, 0.72, 2.8));
        stab_voices[idx].freq = freqs[idx];
    }

    bass.freq = midiToFreq(runner.engine.key.root + chord.offsets[0]);
}

fn advanceStep(step: u8, meso: f32, micro: f32) void {
    beat_number += 1;

    const drum_events = layers.drumStepEvents(step, meso, &rng, .{
        .kick_main_mask = KICK_MAIN_MASK,
        .kick_fill_mask = KICK_FILL_MASK,
        .kick_fill_velocity = 0.55,
        .kick_fill_density = 0.36,
        .hat_onbeat_chance = 0.0,
        .hat_offbeat_chance = 0.0,
    });
    layers.applyDrumStep(drum_events, &kick, null, null);

    const hat_chance = if (step % 2 == 1)
        0.92
    else if (step == 14)
        0.85
    else
        0.15 + meso * 0.3;
    if (rng.float() < hat_chance) {
        hat.trigger();
    }

    layers.triggerStepBass(step, micro, meso, lfo_filter.modulate(), &rng, &runner.engine.key, &bass_phrase, &bass, HOUSE_BASS_LAYER_SPEC);

    const stab_trigger = switch (step) {
        3, 11 => true,
        7, 15 => rng.float() < stab_chance * (0.35 + meso * 0.45),
        else => false,
    };
    if (stab_trigger and rng.float() < stab_chance * (0.55 + meso * 0.55)) {
        stab_env = Envelope.init(0.002, 0.05 + micro * 0.06, 0.0, 0.04 + meso * 0.04);
        stab_env.trigger();
    }
}

fn applyCueParams() void {
    const spec = STYLE.cues[@intFromEnum(selected_cue)];
    runner.engine.key.root = spec.root;
    runner.engine.key.target_root = spec.root;
    runner.engine.key.scale_type = spec.scale_type;
    runner.engine.chord_change_beats = spec.chord_change_beats;
    runner.engine.modulation_mode = spec.modulation_mode;
    lfo_filter = spec.lfo_filter;
    composition.applyPhraseConfig(spec.bass_phrase, &bass_phrase);
    kick.base_freq = spec.kick_base_freq;
    kick.sweep = spec.kick_sweep;
    hat.volume = spec.hat_volume;
    bass.drive = spec.bass_drive;
    stab_chance = std.math.clamp(stab_chance, 0.0, 1.0);
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
