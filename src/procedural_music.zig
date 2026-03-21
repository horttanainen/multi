// Procedural ambient music style.
// Uses pentatonic scale, Eno-style incommensurable loops,
// unison-thickened voices, phrase-based melody, and arc dynamics.
// All DSP primitives imported from synth.zig engine.
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

// ============================================================
// Reverb (long tail for ambient)
// ============================================================

const AmbientReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: AmbientReverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });

// ============================================================
// Voice types
// ============================================================

const DroneVoice = synth.Voice(2, 1); // 2 unison, no harmonics (warm sub)
const PadVoice = synth.Voice(3, 4); // 3 unison × 4 harmonics (lush)
const MelodyVoice = synth.Voice(2, 1); // 2 unison, FM bell tones
const ArpVoice = synth.Voice(1, 1); // mono, simple sine plinks

// ============================================================
// Drone layer: low sustained notes, incommensurable loops
// ============================================================

const DRONE_COUNT = 2;
var drones: [DRONE_COUNT]DroneVoice = .{
    .{ .unison_spread = 0.003, .filter = LPF.init(200.0), .pan = -0.3 },
    .{ .unison_spread = 0.003, .filter = LPF.init(180.0), .pan = 0.3 },
};
var drone_beat_counter: [DRONE_COUNT]f32 = .{ 0, 0 };
const drone_beat_len: [DRONE_COUNT]f32 = .{ 13.0, 17.0 };
var drone_phrases: [DRONE_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    .{ .anchor = 3, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
};

// ============================================================
// Pad layer: mid-range, thick additive harmonics
// ============================================================

const PAD_COUNT = 3;
var pads: [PAD_COUNT]PadVoice = .{
    .{ .unison_spread = 0.005, .filter = LPF.init(800.0), .pan = -0.4 },
    .{ .unison_spread = 0.005, .filter = LPF.init(700.0), .pan = 0.0 },
    .{ .unison_spread = 0.005, .filter = LPF.init(750.0), .pan = 0.4 },
};
var pad_beat_counter: [PAD_COUNT]f32 = .{ 0, 0, 0 };
const pad_beat_len: [PAD_COUNT]f32 = .{ 7.0, 11.0, 9.0 };
var pad_phrases: [PAD_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 5, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
    .{ .anchor = 6, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
    .{ .anchor = 8, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
};

// ============================================================
// Melody layer: FM bell tones
// ============================================================

const MELODY_COUNT = 2;
var melodies: [MELODY_COUNT]MelodyVoice = .{
    .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = -0.5 },
    .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = 0.5 },
};
var mel_beat_counter: [MELODY_COUNT]f32 = .{ 0, 0 };
const mel_beat_len: [MELODY_COUNT]f32 = .{ 2.0, 3.0 };
var mel_phrases: [MELODY_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 10, .region_low = 10, .region_high = 14, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
    .{ .anchor = 12, .region_low = 10, .region_high = 14, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
};

// ============================================================
// Arp layer: fast high plinks
// ============================================================

const ARP_COUNT = 3;
var arps: [ARP_COUNT]ArpVoice = .{
    .{ .pan = -0.7 },
    .{ .pan = 0.0 },
    .{ .pan = 0.7 },
};
var arp_beat_counter: [ARP_COUNT]f32 = .{ 0, 0, 0 };
const arp_beat_len: [ARP_COUNT]f32 = .{ 0.75, 1.25, 1.0 };
var arp_phrases: [ARP_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 15, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
    .{ .anchor = 16, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
    .{ .anchor = 17, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
};

// ============================================================
// Arc controller for dynamics
// ============================================================

var arc: synth.ArcController = .{ .section_beats = 48, .shape = .rise_fall };

// ============================================================
// Global state
// ============================================================

var global_sample: u64 = 0;
var rng: synth.Rng = synth.Rng.init(12345);

// ============================================================
// Fill buffer
// ============================================================

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        global_sample += 1;
        arc.advanceSample(bpm);
        const t = arc.tension();

        var left: f32 = 0;
        var right: f32 = 0;

        // === Drone layer ===
        for (0..DRONE_COUNT) |d| {
            drone_beat_counter[d] += 1.0 / spb;
            if (drone_beat_counter[d] >= drone_beat_len[d]) {
                drone_beat_counter[d] -= drone_beat_len[d];
                if (drone_phrases[d].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(scale[note_idx]);
                    drones[d].filter = LPF.init(160.0 + t * 80.0);
                    drones[d].trigger(freq, Envelope.init(3.0, 0.5, 0.8, 4.0));
                }
            }

            const sample = drones[d].process() * drone_vol;
            const stereo = panStereo(sample, drones[d].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Pad layer ===
        for (0..PAD_COUNT) |p| {
            pad_beat_counter[p] += 1.0 / spb;
            if (pad_beat_counter[p] >= pad_beat_len[p]) {
                pad_beat_counter[p] -= pad_beat_len[p];
                if (pad_phrases[p].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(scale[note_idx]);
                    // Arc opens filter at high tension
                    pads[p].filter = LPF.init(500.0 + t * 500.0);
                    pads[p].trigger(freq, Envelope.init(1.5, 0.3, 0.6, 2.5));
                }
            }

            const sample = pads[p].process() * pad_vol;
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
                // Arc modulates melody rest chance: more notes at high tension
                mel_phrases[m].rest_chance = 0.3 * (1.3 - t * 0.6);
                if (mel_phrases[m].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(scale[note_idx]);
                    melodies[m].trigger(freq, Envelope.init(0.01, 0.8, 0.0, 0.3));
                }
            }

            const sample = melodies[m].process() * melody_vol;
            const stereo = panStereo(sample, melodies[m].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Arp layer ===
        for (0..ARP_COUNT) |a| {
            arp_beat_counter[a] += 1.0 / spb;
            if (arp_beat_counter[a] >= arp_beat_len[a]) {
                arp_beat_counter[a] -= arp_beat_len[a];
                // Arp becomes more active at high tension
                arp_phrases[a].rest_chance = 0.2 * (1.4 - t * 0.8);
                if (arp_phrases[a].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(scale[note_idx]);
                    arps[a].trigger(freq, Envelope.init(0.005, 0.15, 0.0, 0.2));
                }
            }

            const sample = arps[a].process() * arp_vol;
            const stereo = panStereo(sample, arps[a].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Reverb ===
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
    rng = synth.Rng.init(12345);

    drones = .{
        .{ .unison_spread = 0.003, .filter = LPF.init(200.0), .pan = -0.3 },
        .{ .unison_spread = 0.003, .filter = LPF.init(180.0), .pan = 0.3 },
    };
    drone_beat_counter = .{ 0, 0 };
    drone_phrases = .{
        .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
        .{ .anchor = 3, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    };

    pads = .{
        .{ .unison_spread = 0.005, .filter = LPF.init(800.0), .pan = -0.4 },
        .{ .unison_spread = 0.005, .filter = LPF.init(700.0), .pan = 0.0 },
        .{ .unison_spread = 0.005, .filter = LPF.init(750.0), .pan = 0.4 },
    };
    pad_beat_counter = .{ 0, 0, 0 };
    pad_phrases = .{
        .{ .anchor = 5, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
        .{ .anchor = 6, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
        .{ .anchor = 8, .region_low = 5, .region_high = 9, .rest_chance = 0.1, .min_notes = 3, .max_notes = 5 },
    };

    melodies = .{
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = -0.5 },
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = 0.5 },
    };
    mel_beat_counter = .{ 0, 0 };
    mel_phrases = .{
        .{ .anchor = 10, .region_low = 10, .region_high = 14, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
        .{ .anchor = 12, .region_low = 10, .region_high = 14, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
    };

    arps = .{
        .{ .pan = -0.7 },
        .{ .pan = 0.0 },
        .{ .pan = 0.7 },
    };
    arp_beat_counter = .{ 0, 0, 0 };
    arp_phrases = .{
        .{ .anchor = 15, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
        .{ .anchor = 16, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
        .{ .anchor = 17, .region_low = 15, .region_high = 19, .rest_chance = 0.2, .min_notes = 4, .max_notes = 8 },
    };

    arc = .{ .section_beats = 48, .shape = .rise_fall };
    reverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });
}
