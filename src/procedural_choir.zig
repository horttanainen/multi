// Procedural monk choir style.
// Slow, meditative choral chords with vowel-like formant filtering,
// breathy noise layer, and long reverb. Gregorian chant feel.
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

pub var bpm: f32 = 40.0;
pub var reverb_mix: f32 = 0.72;
pub var choir_vol: f32 = 0.15;
pub var breathiness: f32 = 0.3;

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

// ============================================================
// Formant filter (2 resonant peaks to simulate vowel sounds)
// ============================================================

const Formant = struct {
    // Two bandpass-like filters via resonant LPFs
    lpf1: LPF,
    lpf2: LPF,
    freq1: f32,
    freq2: f32,
    mix: f32, // blend between formants

    fn init(f1: f32, f2: f32, m: f32) Formant {
        return .{
            .lpf1 = LPF.init(f1),
            .lpf2 = LPF.init(f2),
            .freq1 = f1,
            .freq2 = f2,
            .mix = m,
        };
    }

    fn process(self: *Formant, input: f32) f32 {
        // Run input through both filters, blend
        const out1 = self.lpf1.process(input);
        const out2 = self.lpf2.process(input);
        return out1 * (1.0 - self.mix) + out2 * self.mix;
    }
};

// Vowel formant presets: (F1, F2, blend)
// "Ah" (open): F1=730, F2=1090
// "Oh" (round): F1=570, F2=840
// "Oo" (closed): F1=300, F2=870
// "Eh" : F1=660, F2=1720
const vowel_f1 = [4]f32{ 730, 570, 300, 660 };
const vowel_f2 = [4]f32{ 1090, 840, 870, 1720 };

// ============================================================
// Reverb (cathedral-like, very long tail)
// ============================================================

const ChoirReverb = StereoReverb(.{ 2039, 1877, 1733, 1601 }, .{ 307, 709 });
var reverb: ChoirReverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });

// ============================================================
// Choir voices
// ============================================================

const VOICE_COUNT = 4;

var voice_phase: [VOICE_COUNT][3]f32 = .{.{0} ** 3} ** VOICE_COUNT; // 3 harmonics
var voice_freq: [VOICE_COUNT]f32 = .{ midiToFreq(48), midiToFreq(51), midiToFreq(55), midiToFreq(60) };
var voice_env: [VOICE_COUNT]Envelope = .{
    Envelope.init(3.0, 1.0, 0.7, 4.0),
    Envelope.init(3.5, 1.0, 0.65, 4.5),
    Envelope.init(4.0, 1.0, 0.6, 5.0),
    Envelope.init(3.2, 1.0, 0.68, 4.2),
};
var voice_formant: [VOICE_COUNT]Formant = .{
    Formant.init(730, 1090, 0.4),
    Formant.init(570, 840, 0.5),
    Formant.init(730, 1090, 0.4),
    Formant.init(300, 870, 0.6),
};
var voice_note_idx: [VOICE_COUNT]u8 = .{ 5, 6, 8, 10 };
var voice_beat_counter: [VOICE_COUNT]f32 = .{ 0, 0, 0, 0 };
// Very long, prime beat lengths for slow-drifting chords
const voice_beat_len: [VOICE_COUNT]f32 = .{ 19.0, 23.0, 17.0, 13.0 };
var voice_vowel: [VOICE_COUNT]u8 = .{ 0, 1, 0, 2 };

// Breath noise
var breath_lpf: LPF = LPF.init(800.0);

// Global
var global_sample: u64 = 0;
var rng: synth.Rng = synth.Rng.init(33333);

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        var left: f32 = 0;
        var right: f32 = 0;

        // === Choir voices ===
        for (0..VOICE_COUNT) |v| {
            voice_beat_counter[v] += 1.0 / spb;
            if (voice_beat_counter[v] >= voice_beat_len[v]) {
                voice_beat_counter[v] -= voice_beat_len[v];

                // Pick new note — bass voices stay low, tenor/alto go higher
                const ranges = [VOICE_COUNT][2]u8{ .{ 0, 4 }, .{ 5, 9 }, .{ 5, 9 }, .{ 10, 14 } };
                voice_note_idx[v] = rng.nextScaleNote(voice_note_idx[v], ranges[v][0], ranges[v][1]);
                voice_freq[v] = midiToFreq(scale[voice_note_idx[v]]);
                voice_env[v].trigger();

                // Slowly cycle vowels
                voice_vowel[v] = @intCast(rng.next() % 4);
                const vow = voice_vowel[v];
                voice_formant[v] = Formant.init(vowel_f1[vow], vowel_f2[vow], 0.3 + rng.float() * 0.4);
            }

            const env_val = voice_env[v].process();
            if (env_val < 0.001) continue;

            // Additive synthesis: fundamental + 2 harmonics (choir-like spectrum)
            var sample: f32 = 0;
            for (0..3) |h| {
                const hf: f32 = @floatFromInt(h + 1);
                // Choir harmonic rolloff: odd harmonics slightly louder
                const odd_boost: f32 = if (h % 2 == 0) 1.0 else 0.7;
                const harmonic_amp = odd_boost / (hf * hf);
                voice_phase[v][h] += voice_freq[v] * hf * INV_SR * TAU;
                if (voice_phase[v][h] > TAU) voice_phase[v][h] -= TAU;
                sample += @sin(voice_phase[v][h]) * harmonic_amp;
            }

            // Apply formant filter for vowel character
            sample = voice_formant[v].process(sample);
            sample *= env_val * choir_vol;

            // Spread voices across stereo field
            const pan_positions = [VOICE_COUNT]f32{ -0.5, -0.15, 0.15, 0.5 };
            const stereo = panStereo(sample, pan_positions[v]);
            left += stereo[0];
            right += stereo[1];
        }

        // === Breath layer (filtered noise for realism) ===
        if (breathiness > 0.01) {
            const noise = rng.float() * 2.0 - 1.0;
            var breath = breath_lpf.process(noise);
            breath *= breathiness * 0.04;
            left += breath;
            right += breath;
        }

        // === Reverb (cathedral) ===
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
    rng = synth.Rng.init(33333);

    voice_phase = .{.{0} ** 3} ** VOICE_COUNT;
    voice_freq = .{ midiToFreq(48), midiToFreq(51), midiToFreq(55), midiToFreq(60) };
    voice_env = .{
        Envelope.init(3.0, 1.0, 0.7, 4.0),
        Envelope.init(3.5, 1.0, 0.65, 4.5),
        Envelope.init(4.0, 1.0, 0.6, 5.0),
        Envelope.init(3.2, 1.0, 0.68, 4.2),
    };
    voice_formant = .{
        Formant.init(730, 1090, 0.4),
        Formant.init(570, 840, 0.5),
        Formant.init(730, 1090, 0.4),
        Formant.init(300, 870, 0.6),
    };
    voice_note_idx = .{ 5, 6, 8, 10 };
    voice_beat_counter = .{ 0, 0, 0, 0 };
    voice_vowel = .{ 0, 1, 0, 2 };

    breath_lpf = LPF.init(800.0);

    reverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
}
