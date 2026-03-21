// Procedural relaxing piano style.
// Sparse slow piano with unison-thickened FM voices, phrase-based melody,
// and arc-driven dynamics. Uses synth engine types for DSP.
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

pub var bpm: f32 = 65.0;
pub var reverb_mix: f32 = 0.65;
pub var note_vol: f32 = 0.12;
pub var rest_chance: f32 = 0.5;
pub var brightness: f32 = 0.5;

// ============================================================
// Reverb
// ============================================================

const PianoReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: PianoReverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

// ============================================================
// Piano voices: 2 unison oscillators with FM for piano timbre
// ============================================================

const PianoVoice = synth.Voice(2, 1);
const VOICE_COUNT = 2;

var voices: [VOICE_COUNT]PianoVoice = .{
    .{ .fm_ratio = 3.0, .fm_depth = 0.5, .fm_env_depth = 1.5, .unison_spread = 0.003, .filter = LPF.init(3000.0), .pan = -0.3 },
    .{ .fm_ratio = 3.0, .fm_depth = 0.5, .fm_env_depth = 1.5, .unison_spread = 0.003, .filter = LPF.init(3000.0), .pan = 0.3 },
};
var voice_beat_counter: [VOICE_COUNT]f32 = .{ 0, 0 };
const voice_beat_len: [VOICE_COUNT]f32 = .{ 2.5, 3.5 };

// ============================================================
// Phrase generators (one per voice for independent melodies)
// ============================================================

var phrases: [VOICE_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 10, .region_low = 5, .region_high = 17, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
    .{ .anchor = 12, .region_low = 5, .region_high = 17, .rest_chance = 0.35, .min_notes = 3, .max_notes = 6 },
};

// ============================================================
// Arc controller for dynamics over ~32 beats
// ============================================================

var arc: synth.ArcController = .{ .section_beats = 32, .shape = .rise_fall };

// ============================================================
// Drone (always-on low hum, no envelope)
// ============================================================

var drone_phase: [2]f32 = .{ 0, 0 };
var drone_freq: f32 = midiToFreq(36);
var drone_lpf: LPF = LPF.init(120.0);

var rng: synth.Rng = synth.Rng.init(77777);

// ============================================================
// Fill buffer
// ============================================================

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        arc.advanceSample(bpm);
        const t = arc.tension();

        var left: f32 = 0;
        var right: f32 = 0;

        // === Piano voices ===
        for (0..VOICE_COUNT) |vi| {
            voice_beat_counter[vi] += 1.0 / spb;
            if (voice_beat_counter[vi] >= voice_beat_len[vi]) {
                voice_beat_counter[vi] -= voice_beat_len[vi];

                // Arc modulates rest chance: more rests at low tension
                phrases[vi].rest_chance = rest_chance * (1.2 - t * 0.4);

                if (phrases[vi].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(scale[note_idx]);
                    // Brighter filter at high tension
                    const cutoff = 1000.0 + brightness * 6000.0 + t * 2000.0;
                    voices[vi].filter = LPF.init(cutoff);
                    voices[vi].fm_depth = 0.5 + brightness * 1.5;
                    voices[vi].pan = (rng.float() - 0.5) * 0.8;
                    // Shorter decay at high tension for more articulation
                    const decay = 1.5 - t * 0.4;
                    voices[vi].trigger(freq, Envelope.init(0.003, decay, 0.0, 1.0));
                }
            }

            const sample = voices[vi].process() * note_vol;
            const stereo = panStereo(sample, voices[vi].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Drone ===
        drone_phase[0] += drone_freq * INV_SR * TAU;
        if (drone_phase[0] > TAU) drone_phase[0] -= TAU;
        drone_phase[1] += drone_freq * 1.002 * INV_SR * TAU;
        if (drone_phase[1] > TAU) drone_phase[1] -= TAU;
        var drone_sample = @sin(drone_phase[0]) + @sin(drone_phase[1]) * 0.5;
        drone_sample = drone_lpf.process(drone_sample);
        drone_sample *= 0.02;
        left += drone_sample;
        right += drone_sample;

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
    rng = synth.Rng.init(77777);
    voices = .{
        .{ .fm_ratio = 3.0, .fm_depth = 0.5, .fm_env_depth = 1.5, .unison_spread = 0.003, .filter = LPF.init(3000.0), .pan = -0.3 },
        .{ .fm_ratio = 3.0, .fm_depth = 0.5, .fm_env_depth = 1.5, .unison_spread = 0.003, .filter = LPF.init(3000.0), .pan = 0.3 },
    };
    voice_beat_counter = .{ 0, 0 };
    phrases = .{
        .{ .anchor = 10, .region_low = 5, .region_high = 17, .rest_chance = 0.3, .min_notes = 3, .max_notes = 6 },
        .{ .anchor = 12, .region_low = 5, .region_high = 17, .rest_chance = 0.35, .min_notes = 3, .max_notes = 6 },
    };
    arc = .{ .section_beats = 32, .shape = .rise_fall };
    drone_phase = .{ 0, 0 };
    drone_freq = midiToFreq(36);
    drone_lpf = LPF.init(120.0);
    reverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });
}
