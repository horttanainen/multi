// Procedural monastic choir style.
// Thick unison voices (3 detuned × 4 harmonics) with formant filtering,
// phrase-based chant melody, and arc-driven dynamics for swells.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const StereoReverb = synth.StereoReverb;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const scale = synth.pentatonic_scale;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

// ============================================================
// Tweakable parameters (written by musicConfigMenu)
// ============================================================

pub const CuePreset = enum(u8) {
    cathedral,
    procession,
    vigil,
    crusade,
};

pub var bpm: f32 = 44.0;
pub var reverb_mix: f32 = 0.72;
pub var choir_vol: f32 = 0.15;
pub var breathiness: f32 = 0.3;
pub var drone_mix: f32 = 0.55;
pub var chant_mix: f32 = 0.58;
pub var selected_cue: CuePreset = .cathedral;

// ============================================================
// Reverb (long cathedral tail)
// ============================================================

const ChoirReverb = StereoReverb(.{ 2039, 1877, 1733, 1601 }, .{ 307, 709 });
var reverb: ChoirReverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
var rng: synth.Rng = synth.Rng.init(0x4300_9000);

// ============================================================
// Choir voice: 3 unison × 4 harmonics with formant filters
// ============================================================

const ChoirVoice = synth.Voice(3, 4);

const ChoirPart = struct {
    voice: ChoirVoice = .{},
    formant_a: LPF = LPF.init(700.0),
    formant_b: LPF = LPF.init(1200.0),
    pan: f32 = 0.0,
    vowel_mix: f32 = 0.45,
};

const PAD_COUNT = 3;
var pad_parts: [PAD_COUNT]ChoirPart = .{
    .{ .voice = .{ .unison_spread = 0.006 }, .pan = -0.35, .vowel_mix = 0.35 },
    .{ .voice = .{ .unison_spread = 0.006 }, .pan = 0.0, .vowel_mix = 0.45 },
    .{ .voice = .{ .unison_spread = 0.006 }, .pan = 0.35, .vowel_mix = 0.55 },
};
var chant_part: ChoirPart = .{ .voice = .{ .unison_spread = 0.004 }, .pan = 0.08, .vowel_mix = 0.5 };

// ============================================================
// Phrase generator for chant melody (replaces fixed chant_map)
// ============================================================

var chant_phrase: synth.PhraseGenerator = .{
    .anchor = 12,
    .region_low = 10,
    .region_high = 16,
    .rest_chance = 0.15,
    .min_notes = 4,
    .max_notes = 8,
};

// ============================================================
// Arc controller for dynamics (slow cathedral swells)
// ============================================================

var arc: synth.ArcController = .{ .section_beats = 64, .shape = .rise_fall };

// ============================================================
// Drone & breath (raw oscillators, no Voice type needed)
// ============================================================

var drone_phase: [2]f32 = .{ 0.0, 0.0 };
var drone_freq: f32 = midiToFreq(36);
var drone_lpf: LPF = LPF.init(180.0);

var breath_lpf: LPF = LPF.init(1200.0);
var shimmer_lpf: LPF = LPF.init(3400.0);

// ============================================================
// Sequencer state
// ============================================================

var step_counter: f32 = 0.0;
var chant_step: u8 = 0;
var chord_step: u8 = 0;

const chord_map = [4][4][3]u8{
    .{ .{ 38, 45, 50 }, .{ 41, 48, 53 }, .{ 43, 50, 55 }, .{ 36, 43, 48 } }, // cathedral
    .{ .{ 36, 43, 48 }, .{ 38, 45, 50 }, .{ 41, 48, 53 }, .{ 43, 50, 55 } }, // procession
    .{ .{ 41, 48, 53 }, .{ 38, 45, 50 }, .{ 36, 43, 48 }, .{ 43, 50, 55 } }, // vigil
    .{ .{ 38, 45, 50 }, .{ 43, 50, 55 }, .{ 45, 52, 57 }, .{ 41, 48, 53 } }, // crusade
};

// ============================================================
// Public API
// ============================================================

pub fn reset() void {
    reverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
    rng = synth.Rng.init(0x4300_9000 + @as(u32, @intFromEnum(selected_cue)) * 23);
    step_counter = 0.0;
    chant_step = 0;
    chord_step = 0;
    pad_parts = .{
        .{ .voice = .{ .unison_spread = 0.006 }, .pan = -0.35, .vowel_mix = 0.35 },
        .{ .voice = .{ .unison_spread = 0.006 }, .pan = 0.0, .vowel_mix = 0.45 },
        .{ .voice = .{ .unison_spread = 0.006 }, .pan = 0.35, .vowel_mix = 0.55 },
    };
    chant_part = .{ .voice = .{ .unison_spread = 0.004 }, .pan = 0.08, .vowel_mix = 0.5 };
    chant_phrase = .{
        .anchor = 12,
        .region_low = 10,
        .region_high = 16,
        .rest_chance = 0.15,
        .min_notes = 4,
        .max_notes = 8,
    };
    arc = .{ .section_beats = 64, .shape = .rise_fall };
    drone_phase = .{ 0.0, 0.0 };
    drone_freq = midiToFreq(36);
    drone_lpf = LPF.init(180.0);
    breath_lpf = LPF.init(1200.0);
    shimmer_lpf = LPF.init(3400.0);
    triggerCue();
}

pub fn triggerCue() void {
    chord_step = 0;
    chant_step = 0;
    chant_phrase.anchor = 10 + @as(u8, @intFromEnum(selected_cue));
    loadCueChord();
    loadCueVowels();
    triggerPadChord();
    triggerChantNote();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm * 0.5;

    for (0..frames) |i| {
        arc.advanceSample(bpm);
        const t = arc.tension();

        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep();
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        // Drone: arc swells volume slightly
        const drone_vol = drone_mix * (0.85 + t * 0.15);
        const drone = processDrone() * drone_vol * choir_vol;
        left += drone * 0.9;
        right += drone * 0.9;

        // Pad voices: arc swells for crescendo/decrescendo
        const pad_vol = 0.95 * (0.8 + t * 0.2);
        for (0..PAD_COUNT) |idx| {
            const sample = processChoirPart(&pad_parts[idx]) * choir_vol * pad_vol;
            const stereo = panStereo(sample, pad_parts[idx].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // Chant melody
        const chant = processChoirPart(&chant_part) * choir_vol * chant_mix;
        const chant_stereo = panStereo(chant, chant_part.pan);
        left += chant_stereo[0];
        right += chant_stereo[1];

        // Breath: more present at low tension (fills silence)
        const breath = processBreath(t);
        left += breath;
        right += breath;

        const rev = reverb.process(.{ left, right });
        const dry = 1.0 - reverb_mix;
        left = left * dry + rev[0] * reverb_mix;
        right = right * dry + rev[1] * reverb_mix;

        buf[i * 2] = softClip(left * 0.88);
        buf[i * 2 + 1] = softClip(right * 0.88);
    }
}

// ============================================================
// Sequencer
// ============================================================

fn advanceStep() void {
    const step = chant_step;
    if (step % 4 == 0) {
        triggerChantNote();
    }
    if (step % 8 == 0) {
        loadCueChord();
        loadCueVowels();
        triggerPadChord();
    }

    chant_step = (chant_step + 1) % 16;
    if (chant_step != 0) return;

    chord_step = @intCast((chord_step + 1) % chord_map[@intFromEnum(selected_cue)].len);
}

fn loadCueChord() void {
    const chord = chord_map[@intFromEnum(selected_cue)][chord_step];
    for (0..PAD_COUNT) |idx| {
        pad_parts[idx].voice.freq = midiToFreq(chord[idx]);
    }
    drone_freq = midiToFreq(chord[0] - 12);
}

fn loadCueVowels() void {
    const cue_index = @intFromEnum(selected_cue);
    for (0..PAD_COUNT) |idx| {
        const seed = cue_index * 9 + @as(u8, @intCast(idx));
        setPartVowel(&pad_parts[idx], @intCast((seed + chord_step) % 4));
    }
    setPartVowel(&chant_part, @intCast((cue_index + chant_step / 4) % 4));
}

fn triggerPadChord() void {
    for (0..PAD_COUNT) |idx| {
        const freq = pad_parts[idx].voice.freq;
        pad_parts[idx].voice.trigger(freq, Envelope.init(1.4, 1.6, 0.76, 5.8));
    }
}

fn triggerChantNote() void {
    if (chant_phrase.advance(&rng)) |note_idx| {
        const freq = midiToFreq(scale[note_idx]);
        chant_part.voice.trigger(freq, Envelope.init(0.18, 0.5, 0.55, 1.6));
    }
}

// ============================================================
// Formant vowels
// ============================================================

fn setPartVowel(part: *ChoirPart, vowel_idx: u8) void {
    switch (vowel_idx) {
        0 => { // ah
            part.formant_a = LPF.init(620.0);
            part.formant_b = LPF.init(1180.0);
            part.vowel_mix = 0.34;
        },
        1 => { // oh
            part.formant_a = LPF.init(540.0);
            part.formant_b = LPF.init(920.0);
            part.vowel_mix = 0.42;
        },
        2 => { // oo
            part.formant_a = LPF.init(420.0);
            part.formant_b = LPF.init(780.0);
            part.vowel_mix = 0.58;
        },
        else => { // eh
            part.formant_a = LPF.init(760.0);
            part.formant_b = LPF.init(1520.0);
            part.vowel_mix = 0.48;
        },
    }
}

// ============================================================
// DSP processing
// ============================================================

fn processChoirPart(part: *ChoirPart) f32 {
    const raw = part.voice.processRaw();
    if (raw.env_val <= 0.0001) return 0;

    const fa = part.formant_a.process(raw.osc);
    const fb = part.formant_b.process(raw.osc);
    const filtered = fa * (1.0 - part.vowel_mix) + fb * part.vowel_mix;
    return filtered * raw.env_val;
}

fn processDrone() f32 {
    drone_phase[0] += drone_freq * INV_SR * TAU;
    if (drone_phase[0] > TAU) drone_phase[0] -= TAU;
    drone_phase[1] += drone_freq * 1.0016 * INV_SR * TAU;
    if (drone_phase[1] > TAU) drone_phase[1] -= TAU;

    var sample = @sin(drone_phase[0]) * 0.78 + @sin(drone_phase[1]) * 0.32;
    sample = drone_lpf.process(sample);
    return sample * 0.32;
}

fn processBreath(t: f32) f32 {
    if (breathiness <= 0.001) return 0.0;

    // More breath at low tension (fills silence between swells)
    const breath_mod = breathiness * (1.1 - t * 0.3);
    const noise = rng.float() * 2.0 - 1.0;
    const base = breath_lpf.process(noise);
    const shimmer = shimmer_lpf.process(noise * 0.35);
    return (base * 0.015 + shimmer * 0.006) * breath_mod;
}
