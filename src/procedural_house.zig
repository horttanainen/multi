// Procedural chill house music style.
// ~120 BPM with synthesized kick, hi-hats, bouncy bass, and Vangelis-style pads.
// All DSP primitives imported from synth.zig.
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

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

// ============================================================
// Reverb (shorter/tighter for house)
// ============================================================

const HouseReverb = StereoReverb(.{ 1117, 1049, 983, 907 }, .{ 197, 419 });
var reverb: HouseReverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });

// ============================================================
// PRNG
// ============================================================

var rng: synth.Rng = synth.Rng.init(54321);

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
// Bass: bouncy pentatonic with thick low end
// ============================================================

var bass_phase: f32 = 0;
var bass_freq: f32 = midiToFreq(36);
var bass_env: Envelope = Envelope.init(0.005, 0.15, 0.6, 0.1);
var bass_lpf: LPF = LPF.init(400.0);
var bass_note_idx: u8 = 0;
var bass_beat_counter: f32 = 0;
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
// Pad: Vangelis-style FM with slow filter sweep
// ============================================================

const PAD_COUNT = 3;
var pad_carrier_phase: [PAD_COUNT]f32 = .{0} ** PAD_COUNT;
var pad_mod_phase: [PAD_COUNT]f32 = .{0} ** PAD_COUNT;
var pad_freq: [PAD_COUNT]f32 = .{ midiToFreq(60), midiToFreq(63), midiToFreq(67) };
var pad_env: [PAD_COUNT]Envelope = .{
    Envelope.init(2.0, 0.5, 0.7, 3.0),
    Envelope.init(2.5, 0.5, 0.6, 3.5),
    Envelope.init(2.2, 0.5, 0.65, 3.2),
};
var pad_lpf: [PAD_COUNT]LPF = .{ LPF.init(2000.0), LPF.init(1800.0), LPF.init(1900.0) };
var pad_beat_counter: [PAD_COUNT]f32 = .{ 0, 0, 0 };
const pad_beat_len: [PAD_COUNT]f32 = .{ 16.0, 12.0, 14.0 };
var pad_note_idx: [PAD_COUNT]u8 = .{ 10, 11, 13 };

fn processPad(idx: usize) [2]f32 {
    const freq = pad_freq[idx];
    const mod_ratios = [PAD_COUNT]f32{ 1.0, 2.0, 3.0 };
    const mod_freq = freq * mod_ratios[idx];

    pad_mod_phase[idx] += mod_freq * INV_SR * TAU;
    if (pad_mod_phase[idx] > TAU) pad_mod_phase[idx] -= TAU;

    const env_val = pad_env[idx].process();
    const mod_depth = 0.8 + env_val * 0.5;
    const mod_signal = mod_depth * @sin(pad_mod_phase[idx]);

    pad_carrier_phase[idx] += freq * INV_SR * TAU;
    if (pad_carrier_phase[idx] > TAU) pad_carrier_phase[idx] -= TAU;

    var s = @sin(pad_carrier_phase[idx] + mod_signal);
    s += @sin(pad_carrier_phase[idx] * 0.5) * 0.3;
    s = pad_lpf[idx].process(s);
    s *= env_val * pad_vol;

    const pan_positions = [PAD_COUNT]f32{ -0.6, 0.0, 0.6 };
    return panStereo(s, pan_positions[idx]);
}

// ============================================================
// Stab: short chord hits for rhythmic interest
// ============================================================

var stab_phase: [3]f32 = .{0} ** 3;
var stab_freq: [3]f32 = .{ midiToFreq(60), midiToFreq(63), midiToFreq(67) };
var stab_env: Envelope = Envelope.init(0.002, 0.08, 0.0, 0.05);

fn triggerStab() void {
    const root_idx = rng.nextScaleNote(10, 10, 14);
    stab_freq[0] = midiToFreq(scale[root_idx]);
    const second = @min(root_idx + 2, 14);
    stab_freq[1] = midiToFreq(scale[second]);
    const third = @min(root_idx + 4, 19);
    stab_freq[2] = midiToFreq(scale[third]);
    stab_env.trigger();
}

fn processStab() [2]f32 {
    const env_val = stab_env.process();
    if (env_val < 0.001) return .{ 0, 0 };

    var l: f32 = 0;
    var r: f32 = 0;
    for (0..3) |v| {
        stab_phase[v] += stab_freq[v] * INV_SR * TAU;
        if (stab_phase[v] > TAU) stab_phase[v] -= TAU;
        var s = @sin(stab_phase[v]);
        s += @sin(stab_phase[v] * 2.0) * 0.3;
        s *= env_val * 0.04;
        const pans = [3]f32{ -0.3, 0.0, 0.3 };
        const stereo = panStereo(s, pans[v]);
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
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        beat_counter += 1.0 / spb;

        // New beat
        if (beat_counter >= 1.0) {
            beat_counter -= 1.0;
            beat_number += 1;
            pattern_step = @intCast(beat_number % 16);

            // Kick: four-on-the-floor
            triggerKick();

            // Bass: pattern-driven
            if (bass_pattern[bass_pattern_idx]) {
                bass_note_idx = rng.nextScaleNote(bass_note_idx, 0, 4);
                bass_freq = midiToFreq(scale[bass_note_idx]);
                bass_env.trigger();
            }
            bass_pattern_idx = (bass_pattern_idx + 1) % 8;

            // Pads: long evolving chords
            for (0..PAD_COUNT) |p| {
                pad_beat_counter[p] += 1.0;
                if (pad_beat_counter[p] >= pad_beat_len[p]) {
                    pad_beat_counter[p] = 0;
                    pad_note_idx[p] = rng.nextScaleNote(pad_note_idx[p], 10, 14);
                    pad_freq[p] = midiToFreq(scale[pad_note_idx[p]]);
                    pad_env[p].trigger();
                }
            }

            // Stab: every 4 beats, 40% probability
            if (beat_number % 4 == 0 and rng.float() < stab_chance) {
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

        // Kick (center)
        const kick = processKick();
        left += kick;
        right += kick;

        // Hi-hat (slightly right)
        const hat = processHihat();
        left += hat * 0.4;
        right += hat * 0.6;

        // Bass (center)
        const bass = processBass();
        left += bass;
        right += bass;

        // Pads (stereo)
        for (0..PAD_COUNT) |p| {
            const pad_out = processPad(p);
            left += pad_out[0];
            right += pad_out[1];
        }

        // Stab (stereo)
        const stab_out = processStab();
        left += stab_out[0];
        right += stab_out[1];

        // Reverb
        const dry = 1.0 - reverb_mix;
        const wet = reverb_mix;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        left = softClip(left);
        right = softClip(right);

        buf[i * 2] = left;
        buf[i * 2 + 1] = right;
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
    bass_note_idx = 0;
    bass_beat_counter = 0;
    bass_pattern_idx = 0;

    pad_carrier_phase = .{0} ** PAD_COUNT;
    pad_mod_phase = .{0} ** PAD_COUNT;
    pad_freq = .{ midiToFreq(60), midiToFreq(63), midiToFreq(67) };
    pad_env = .{ Envelope.init(2.0, 0.5, 0.7, 3.0), Envelope.init(2.5, 0.5, 0.6, 3.5), Envelope.init(2.2, 0.5, 0.65, 3.2) };
    pad_lpf = .{ LPF.init(2000.0), LPF.init(1800.0), LPF.init(1900.0) };
    pad_beat_counter = .{ 0, 0, 0 };
    pad_note_idx = .{ 10, 11, 13 };

    stab_phase = .{0} ** 3;
    stab_freq = .{ midiToFreq(60), midiToFreq(63), midiToFreq(67) };
    stab_env = Envelope.init(0.002, 0.08, 0.0, 0.05);

    reverb = HouseReverb.init(.{ 0.80, 0.81, 0.82, 0.79 });
}
