// Procedural chill house music style.
// ~120 BPM with synthesized kick, hi-hats, phrase-based bass,
// unison FM pads, and stab chords. Uses synth engine types.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const HPF = synth.HPF;
const StereoReverb = synth.StereoReverb;
const scale = synth.pentatonic_scale;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

// ============================================================
// Tweakable parameters (written by musicConfigMenu)
// ============================================================

pub var bpm: f32 = 120.0;
pub var reverb_mix: f32 = 0.35;
pub var kick_vol: f32 = 0.25;
pub var hihat_vol: f32 = 0.12;
pub var bass_vol: f32 = 0.2;
pub var pad_vol: f32 = 0.06;
pub var stab_chance: f32 = 0.4;

// ============================================================
// Reverb (shorter/tighter for house)
// ============================================================

const HouseReverb = StereoReverb(.{ 1117, 1049, 983, 907 }, .{ 197, 419 });
var reverb: HouseReverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });

var rng: synth.Rng = synth.Rng.init(54321);

// ============================================================
// Arc controller for dynamics
// ============================================================

var arc: synth.ArcController = .{ .section_beats = 32, .shape = .rise_fall };

// ============================================================
// Kick drum: sine sweep 150Hz → 50Hz with fast decay
// ============================================================

var kick_phase: f32 = 0;
var kick_env: f32 = 0;
var kick_freq: f32 = 50;
var kick_sample_count: f32 = 0;

fn triggerKick() void {
    kick_env = 1.0;
    kick_freq = 150.0;
    kick_phase = 0;
    kick_sample_count = 0;
}

fn processKick() f32 {
    if (kick_env < 0.001) return 0;

    kick_freq = 50.0 + 100.0 * @exp(-kick_sample_count * 0.00015);
    kick_phase += kick_freq * INV_SR * TAU;
    if (kick_phase > TAU) kick_phase -= TAU;

    kick_env *= 0.9997;
    kick_sample_count += 1;

    var s = @sin(kick_phase) * kick_env;
    s *= 1.5;
    if (s > 1.0) s = 1.0;
    if (s < -1.0) s = -1.0;

    return s * kick_vol;
}

// ============================================================
// Hi-hat: filtered noise burst
// ============================================================

var hihat_env: f32 = 0;
var hihat_hpf: HPF = HPF.init(7000.0);
var hihat_lpf: LPF = LPF.init(12000.0);
var hihat_open: bool = false;

fn triggerHihat(open: bool) void {
    hihat_env = 1.0;
    hihat_open = open;
}

fn processHihat() f32 {
    if (hihat_env < 0.001) return 0;

    const decay: f32 = if (hihat_open) 0.99985 else 0.9993;
    hihat_env *= decay;

    const noise = (rng.float() * 2.0 - 1.0);
    var s = hihat_hpf.process(noise);
    s = hihat_lpf.process(s);

    return s * hihat_env * hihat_vol;
}

// ============================================================
// Bass: bouncy pentatonic with thick low end (phrase-driven)
// ============================================================

var bass_phase: f32 = 0;
var bass_freq: f32 = midiToFreq(36);
var bass_env: Envelope = Envelope.init(0.005, 0.15, 0.6, 0.1);
var bass_lpf: LPF = LPF.init(400.0);
var bass_phrase: synth.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 4,
    .rest_chance = 0.15,
    .min_notes = 4,
    .max_notes = 8,
};
const bass_pattern = [8]bool{ true, false, false, true, true, false, true, false };
var bass_pattern_idx: u8 = 0;

fn processBass() f32 {
    bass_phase += bass_freq * INV_SR * TAU;
    if (bass_phase > TAU) bass_phase -= TAU;

    var s = @sin(bass_phase) * 0.7;
    s += @sin(bass_phase * 3.0) * 0.15;
    s += @sin(bass_phase * 5.0) * 0.05;

    s = bass_lpf.process(s);
    s *= bass_env.process() * bass_vol;
    return s;
}

// ============================================================
// Pad: FM with unison for lush Vangelis-style pads
// ============================================================

const PadVoice = synth.Voice(3, 1);
const PAD_COUNT = 3;

var pads: [PAD_COUNT]PadVoice = .{
    .{ .fm_ratio = 1.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(2000.0), .pan = -0.6 },
    .{ .fm_ratio = 2.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(1800.0), .pan = 0.0 },
    .{ .fm_ratio = 3.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(1900.0), .pan = 0.6 },
};
var pad_beat_counter: [PAD_COUNT]f32 = .{ 0, 0, 0 };
const pad_beat_len: [PAD_COUNT]f32 = .{ 16.0, 12.0, 14.0 };
var pad_phrases: [PAD_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 10, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    .{ .anchor = 11, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    .{ .anchor = 13, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
};

// ============================================================
// Stab: short chord hits
// ============================================================

const StabVoice = synth.Voice(2, 1);
var stab_voices: [3]StabVoice = .{
    .{ .unison_spread = 0.004, .pan = -0.3 },
    .{ .unison_spread = 0.004, .pan = 0.0 },
    .{ .unison_spread = 0.004, .pan = 0.3 },
};
var stab_env: Envelope = Envelope.init(0.002, 0.08, 0.0, 0.05);

fn triggerStab() void {
    const root_idx = rng.nextScaleNote(10, 10, 14);
    const second = @min(root_idx + 2, 14);
    const third = @min(root_idx + 4, 19);
    const freqs = [3]f32{ midiToFreq(scale[root_idx]), midiToFreq(scale[second]), midiToFreq(scale[third]) };
    for (0..3) |v| {
        stab_voices[v].freq = freqs[v];
    }
    stab_env = Envelope.init(0.002, 0.08, 0.0, 0.05);
    stab_env.trigger();
}

fn processStab() [2]f32 {
    const env_val = stab_env.process();
    if (env_val < 0.001) return .{ 0, 0 };

    var l: f32 = 0;
    var r: f32 = 0;
    for (0..3) |v| {
        // Use Voice oscillators but shared stab envelope
        stab_voices[v].env = .{
            .state = .sustain,
            .level = env_val,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = env_val,
            .release_rate = 0,
        };
        const sample = stab_voices[v].process() * 0.04;
        const stereo = panStereo(sample, stab_voices[v].pan);
        l += stereo[0];
        r += stereo[1];
    }
    return .{ l, r };
}

// ============================================================
// Global state & sequencer
// ============================================================

var global_sample: u64 = 0;
var beat_counter: f32 = 0;
var beat_number: u32 = 0;
var pattern_step: u8 = 0;
var hihat_scheduled: bool = false;

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        global_sample += 1;
        arc.advanceSample(bpm);
        const t = arc.tension();

        beat_counter += 1.0 / spb;

        // New beat
        if (beat_counter >= 1.0) {
            beat_counter -= 1.0;
            beat_number += 1;
            pattern_step = @intCast(beat_number % 16);

            // Kick: four-on-the-floor
            triggerKick();

            // Bass: pattern-driven with phrase generation
            if (bass_pattern[bass_pattern_idx]) {
                if (bass_phrase.advance(&rng)) |note_idx| {
                    bass_freq = midiToFreq(scale[note_idx]);
                    bass_env.trigger();
                }
            }
            bass_pattern_idx = (bass_pattern_idx + 1) % 8;

            // Pads: long evolving chords
            for (0..PAD_COUNT) |p| {
                pad_beat_counter[p] += 1.0;
                if (pad_beat_counter[p] >= pad_beat_len[p]) {
                    pad_beat_counter[p] = 0;
                    if (pad_phrases[p].advance(&rng)) |note_idx| {
                        const freq = midiToFreq(scale[note_idx]);
                        // Arc opens pad filter at high tension
                        pads[p].filter = LPF.init(1200.0 + t * 1200.0);
                        pads[p].trigger(freq, Envelope.init(2.0, 0.5, 0.7, 3.0));
                    }
                }
            }

            // Stab: every 4 beats, probability modulated by arc
            if (beat_number % 4 == 0 and rng.float() < stab_chance * (0.7 + t * 0.6)) {
                triggerStab();
            }

            hihat_scheduled = false;
        }

        // Offbeat hi-hat (at half-beat)
        if (!hihat_scheduled and beat_counter >= 0.5) {
            hihat_scheduled = true;
            const open = (pattern_step == 2 or pattern_step == 6 or pattern_step == 10 or pattern_step == 14);
            triggerHihat(open);
        }

        // ---- Mix ----
        var left: f32 = 0;
        var right: f32 = 0;

        const kick = processKick();
        left += kick;
        right += kick;

        const hat = processHihat();
        left += hat * 0.4;
        right += hat * 0.6;

        const bass = processBass();
        left += bass;
        right += bass;

        for (0..PAD_COUNT) |p| {
            const sample = pads[p].process() * pad_vol;
            const stereo = panStereo(sample, pads[p].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const stab_out = processStab();
        left += stab_out[0];
        right += stab_out[1];

        // Reverb
        const dry = 1.0 - reverb_mix;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * reverb_mix;
        right = right * dry + rev[1] * reverb_mix;

        buf[i * 2] = softClip(left);
        buf[i * 2 + 1] = softClip(right);
    }
}

pub fn reset() void {
    global_sample = 0;
    rng = synth.Rng.init(54321);
    beat_counter = 0;
    beat_number = 0;
    pattern_step = 0;
    hihat_scheduled = false;

    kick_phase = 0;
    kick_env = 0;
    kick_freq = 50;
    kick_sample_count = 0;

    hihat_env = 0;
    hihat_hpf = HPF.init(7000.0);
    hihat_lpf = LPF.init(12000.0);
    hihat_open = false;

    bass_phase = 0;
    bass_freq = midiToFreq(36);
    bass_env = Envelope.init(0.005, 0.15, 0.6, 0.1);
    bass_lpf = LPF.init(400.0);
    bass_phrase = .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.15, .min_notes = 4, .max_notes = 8 };
    bass_pattern_idx = 0;

    pads = .{
        .{ .fm_ratio = 1.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(2000.0), .pan = -0.6 },
        .{ .fm_ratio = 2.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(1800.0), .pan = 0.0 },
        .{ .fm_ratio = 3.0, .fm_depth = 0.8, .fm_env_depth = 0.5, .unison_spread = 0.005, .filter = LPF.init(1900.0), .pan = 0.6 },
    };
    pad_beat_counter = .{ 0, 0, 0 };
    pad_phrases = .{
        .{ .anchor = 10, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
        .{ .anchor = 11, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
        .{ .anchor = 13, .region_low = 10, .region_high = 14, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    };

    stab_voices = .{
        .{ .unison_spread = 0.004, .pan = -0.3 },
        .{ .unison_spread = 0.004, .pan = 0.0 },
        .{ .unison_spread = 0.004, .pan = 0.3 },
    };
    stab_env = Envelope.init(0.002, 0.08, 0.0, 0.05);

    arc = .{ .section_beats = 32, .shape = .rise_fall };
    reverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });
}
