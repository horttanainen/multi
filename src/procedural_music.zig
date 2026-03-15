// Procedural ambient music style.
// Uses pentatonic scale, Eno-style incommensurable loops,
// FM synthesis, one-pole filtering, and comb reverb.
// All DSP primitives imported from synth.zig.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
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

pub var bpm: f32 = 72.0;
pub var reverb_mix: f32 = 0.6;
pub var drone_vol: f32 = 0.15;
pub var pad_vol: f32 = 0.08;
pub var melody_vol: f32 = 0.06;
pub var arp_vol: f32 = 0.025;

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

// ============================================================
// Reverb (long tail for ambient)
// ============================================================

const AmbientReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: AmbientReverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });

// ============================================================
// Voices
// ============================================================

const DRONE_COUNT = 2;
const PAD_COUNT = 3;
const MELODY_COUNT = 2;
const ARP_COUNT = 3;

// Drone: low sustained notes, very slow envelopes
var drone_phase: [DRONE_COUNT]f32 = .{0} ** DRONE_COUNT;
var drone_freq: [DRONE_COUNT]f32 = .{ midiToFreq(36), midiToFreq(43) };
var drone_detune: [DRONE_COUNT]f32 = .{ 0, 0 };
var drone_env: [DRONE_COUNT]Envelope = .{
    Envelope.init(3.0, 0.5, 0.8, 4.0),
    Envelope.init(4.0, 0.5, 0.7, 5.0),
};
var drone_lpf: [DRONE_COUNT]LPF = .{ LPF.init(200.0), LPF.init(180.0) };
var drone_beat_counter: [DRONE_COUNT]f32 = .{ 0, 0 };
const drone_beat_len: [DRONE_COUNT]f32 = .{ 13.0, 17.0 };
var drone_note_idx: [DRONE_COUNT]u8 = .{ 0, 3 };

// Pad: mid-range, additive synthesis
var pad_phase: [PAD_COUNT][4]f32 = .{.{0} ** 4} ** PAD_COUNT;
var pad_freq: [PAD_COUNT]f32 = .{ midiToFreq(48), midiToFreq(51), midiToFreq(55) };
var pad_env: [PAD_COUNT]Envelope = .{
    Envelope.init(1.5, 0.3, 0.6, 2.5),
    Envelope.init(2.0, 0.3, 0.5, 3.0),
    Envelope.init(1.8, 0.3, 0.55, 2.8),
};
var pad_lpf: [PAD_COUNT]LPF = .{ LPF.init(800.0), LPF.init(700.0), LPF.init(750.0) };
var pad_beat_counter: [PAD_COUNT]f32 = .{ 0, 0, 0 };
const pad_beat_len: [PAD_COUNT]f32 = .{ 7.0, 11.0, 9.0 };
var pad_note_idx: [PAD_COUNT]u8 = .{ 5, 6, 8 };

// Melody: FM bell tones
var mel_carrier_phase: [MELODY_COUNT]f32 = .{0} ** MELODY_COUNT;
var mel_mod_phase: [MELODY_COUNT]f32 = .{0} ** MELODY_COUNT;
var mel_freq: [MELODY_COUNT]f32 = .{ midiToFreq(60), midiToFreq(63) };
var mel_env: [MELODY_COUNT]Envelope = .{
    Envelope.init(0.01, 0.8, 0.0, 0.3),
    Envelope.init(0.01, 1.2, 0.0, 0.4),
};
var mel_beat_counter: [MELODY_COUNT]f32 = .{ 0, 0 };
const mel_beat_len: [MELODY_COUNT]f32 = .{ 2.0, 3.0 };
var mel_note_idx: [MELODY_COUNT]u8 = .{ 10, 12 };
var mel_rest: [MELODY_COUNT]bool = .{ false, false };

// Arp: fast high notes, quiet
var arp_phase: [ARP_COUNT]f32 = .{0} ** ARP_COUNT;
var arp_freq: [ARP_COUNT]f32 = .{ midiToFreq(72), midiToFreq(75), midiToFreq(77) };
var arp_env: [ARP_COUNT]Envelope = .{
    Envelope.init(0.005, 0.15, 0.0, 0.2),
    Envelope.init(0.005, 0.2, 0.0, 0.25),
    Envelope.init(0.005, 0.18, 0.0, 0.22),
};
var arp_beat_counter: [ARP_COUNT]f32 = .{ 0, 0, 0 };
const arp_beat_len: [ARP_COUNT]f32 = .{ 0.75, 1.25, 1.0 };
var arp_note_idx: [ARP_COUNT]u8 = .{ 15, 16, 17 };

// Global
var global_sample: u64 = 0;
var rng: synth.Rng = synth.Rng.init(12345);

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        var left: f32 = 0;
        var right: f32 = 0;

        // === Drone layer ===
        for (0..DRONE_COUNT) |d| {
            drone_beat_counter[d] += 1.0 / spb;
            if (drone_beat_counter[d] >= drone_beat_len[d]) {
                drone_beat_counter[d] -= drone_beat_len[d];
                drone_note_idx[d] = rng.nextScaleNote(drone_note_idx[d], 0, 4);
                drone_freq[d] = midiToFreq(scale[drone_note_idx[d]]);
                drone_detune[d] = 1.0 + (rng.float() - 0.5) * 0.004;
                drone_env[d].trigger();
            }

            drone_phase[d] += drone_freq[d] * INV_SR * TAU;
            if (drone_phase[d] > TAU) drone_phase[d] -= TAU;
            const s1 = @sin(drone_phase[d]);
            const s2 = @sin(drone_phase[d] * drone_detune[d]);
            var sample = (s1 + s2) * 0.5;
            sample = drone_lpf[d].process(sample);
            sample *= drone_env[d].process() * drone_vol;

            const pan: f32 = if (d == 0) -0.3 else 0.3;
            const stereo = panStereo(sample, pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Pad layer ===
        for (0..PAD_COUNT) |p| {
            pad_beat_counter[p] += 1.0 / spb;
            if (pad_beat_counter[p] >= pad_beat_len[p]) {
                pad_beat_counter[p] -= pad_beat_len[p];
                pad_note_idx[p] = rng.nextScaleNote(pad_note_idx[p], 5, 9);
                pad_freq[p] = midiToFreq(scale[pad_note_idx[p]]);
                pad_env[p].trigger();
            }

            var sample: f32 = 0;
            for (0..4) |h| {
                const hf: f32 = @floatFromInt(h + 1);
                const harmonic_amp = 1.0 / (hf * hf);
                pad_phase[p][h] += pad_freq[p] * hf * INV_SR * TAU;
                if (pad_phase[p][h] > TAU) pad_phase[p][h] -= TAU;
                sample += @sin(pad_phase[p][h]) * harmonic_amp;
            }
            sample = pad_lpf[p].process(sample);
            sample *= pad_env[p].process() * pad_vol;

            const pan_positions = [PAD_COUNT]f32{ -0.4, 0.0, 0.4 };
            const stereo = panStereo(sample, pan_positions[p]);
            left += stereo[0];
            right += stereo[1];
        }

        // === Melody layer (FM bell tones) ===
        for (0..MELODY_COUNT) |m| {
            mel_beat_counter[m] += 1.0 / spb;
            if (mel_beat_counter[m] >= mel_beat_len[m]) {
                mel_beat_counter[m] -= mel_beat_len[m];
                mel_rest[m] = rng.float() < 0.3;
                if (!mel_rest[m]) {
                    mel_note_idx[m] = rng.nextScaleNote(mel_note_idx[m], 10, 14);
                    mel_freq[m] = midiToFreq(scale[mel_note_idx[m]]);
                    mel_env[m].trigger();
                }
            }

            if (!mel_rest[m]) {
                const mod_freq = mel_freq[m] * 2.0;
                mel_mod_phase[m] += mod_freq * INV_SR * TAU;
                if (mel_mod_phase[m] > TAU) mel_mod_phase[m] -= TAU;

                const env_val = mel_env[m].process();
                const mod_depth = 1.5 * env_val;
                const mod_signal = mod_depth * @sin(mel_mod_phase[m]);

                mel_carrier_phase[m] += mel_freq[m] * INV_SR * TAU;
                if (mel_carrier_phase[m] > TAU) mel_carrier_phase[m] -= TAU;

                const sample = @sin(mel_carrier_phase[m] + mod_signal) * env_val * melody_vol;
                const pan: f32 = if (m == 0) -0.5 else 0.5;
                const stereo = panStereo(sample, pan);
                left += stereo[0];
                right += stereo[1];
            } else {
                _ = mel_env[m].process();
            }
        }

        // === Arp layer ===
        for (0..ARP_COUNT) |a| {
            arp_beat_counter[a] += 1.0 / spb;
            if (arp_beat_counter[a] >= arp_beat_len[a]) {
                arp_beat_counter[a] -= arp_beat_len[a];
                arp_note_idx[a] = rng.nextScaleNote(arp_note_idx[a], 15, 19);
                arp_freq[a] = midiToFreq(scale[arp_note_idx[a]]);
                arp_env[a].trigger();
            }

            arp_phase[a] += arp_freq[a] * INV_SR * TAU;
            if (arp_phase[a] > TAU) arp_phase[a] -= TAU;

            const sample = @sin(arp_phase[a]) * arp_env[a].process() * arp_vol;
            const pan_pos = [ARP_COUNT]f32{ -0.7, 0.0, 0.7 };
            const stereo = panStereo(sample, pan_pos[a]);
            left += stereo[0];
            right += stereo[1];
        }

        // === Reverb ===
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
    rng = synth.Rng.init(12345);

    drone_phase = .{0} ** DRONE_COUNT;
    drone_freq = .{ midiToFreq(36), midiToFreq(43) };
    drone_detune = .{ 0, 0 };
    drone_env = .{ Envelope.init(3.0, 0.5, 0.8, 4.0), Envelope.init(4.0, 0.5, 0.7, 5.0) };
    drone_lpf = .{ LPF.init(200.0), LPF.init(180.0) };
    drone_beat_counter = .{ 0, 0 };
    drone_note_idx = .{ 0, 3 };

    pad_phase = .{.{0} ** 4} ** PAD_COUNT;
    pad_freq = .{ midiToFreq(48), midiToFreq(51), midiToFreq(55) };
    pad_env = .{ Envelope.init(1.5, 0.3, 0.6, 2.5), Envelope.init(2.0, 0.3, 0.5, 3.0), Envelope.init(1.8, 0.3, 0.55, 2.8) };
    pad_lpf = .{ LPF.init(800.0), LPF.init(700.0), LPF.init(750.0) };
    pad_beat_counter = .{ 0, 0, 0 };
    pad_note_idx = .{ 5, 6, 8 };

    mel_carrier_phase = .{0} ** MELODY_COUNT;
    mel_mod_phase = .{0} ** MELODY_COUNT;
    mel_freq = .{ midiToFreq(60), midiToFreq(63) };
    mel_env = .{ Envelope.init(0.01, 0.8, 0.0, 0.3), Envelope.init(0.01, 1.2, 0.0, 0.4) };
    mel_beat_counter = .{ 0, 0 };
    mel_note_idx = .{ 10, 12 };
    mel_rest = .{ false, false };

    arp_phase = .{0} ** ARP_COUNT;
    arp_freq = .{ midiToFreq(72), midiToFreq(75), midiToFreq(77) };
    arp_env = .{ Envelope.init(0.005, 0.15, 0.0, 0.2), Envelope.init(0.005, 0.2, 0.0, 0.25), Envelope.init(0.005, 0.18, 0.0, 0.22) };
    arp_beat_counter = .{ 0, 0, 0 };
    arp_note_idx = .{ 15, 16, 17 };

    reverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });
}
