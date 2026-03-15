// Procedural relaxing piano style.
// Sparse slow piano with simple overlapping voices and long reverb.
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

pub var bpm: f32 = 65.0;
pub var reverb_mix: f32 = 0.65;
pub var note_vol: f32 = 0.12;
pub var rest_chance: f32 = 0.5;
pub var brightness: f32 = 0.5;

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

const PianoReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: PianoReverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

const VOICE_COUNT = 2;

var voice_carrier_phase: [VOICE_COUNT]f32 = .{0} ** VOICE_COUNT;
var voice_mod_phase: [VOICE_COUNT]f32 = .{0} ** VOICE_COUNT;
var voice_freq: [VOICE_COUNT]f32 = .{ midiToFreq(60), midiToFreq(63) };
var voice_env: [VOICE_COUNT]Envelope = .{
    Envelope.init(0.003, 1.5, 0.0, 1.0),
    Envelope.init(0.003, 1.8, 0.0, 1.2),
};
var voice_lpf: [VOICE_COUNT]LPF = .{ LPF.init(3000.0), LPF.init(3000.0) };
var voice_pan: [VOICE_COUNT]f32 = .{ -0.3, 0.3 };
var voice_note_idx: [VOICE_COUNT]u8 = .{ 10, 12 };
var voice_active: [VOICE_COUNT]bool = .{ false, false };
var voice_beat_counter: [VOICE_COUNT]f32 = .{ 0, 0 };
const voice_beat_len: [VOICE_COUNT]f32 = .{ 2.5, 3.5 };

var drone_phase: f32 = 0;
var drone_freq: f32 = midiToFreq(36);
var drone_lpf: LPF = LPF.init(120.0);

var global_sample: u64 = 0;
var rng: synth.Rng = synth.Rng.init(77777);

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        var left: f32 = 0;
        var right: f32 = 0;

        for (0..VOICE_COUNT) |voice_idx| {
            voice_beat_counter[voice_idx] += 1.0 / spb;
            if (voice_beat_counter[voice_idx] >= voice_beat_len[voice_idx]) {
                voice_beat_counter[voice_idx] -= voice_beat_len[voice_idx];

                if (rng.float() < rest_chance) {
                    voice_active[voice_idx] = false;
                } else {
                    voice_active[voice_idx] = true;
                    voice_note_idx[voice_idx] = rng.nextScaleNote(voice_note_idx[voice_idx], 5, 17);
                    voice_freq[voice_idx] = midiToFreq(scale[voice_note_idx[voice_idx]]);
                    voice_env[voice_idx].trigger();
                    voice_pan[voice_idx] = (rng.float() - 0.5) * 0.8;
                    const cutoff = 1000.0 + brightness * 6000.0;
                    voice_lpf[voice_idx] = LPF.init(cutoff);
                }
            }

            const env_val = voice_env[voice_idx].process();
            if (!voice_active[voice_idx] and env_val < 0.001) continue;

            const mod_freq = voice_freq[voice_idx] * 3.0;
            voice_mod_phase[voice_idx] += mod_freq * INV_SR * TAU;
            if (voice_mod_phase[voice_idx] > TAU) voice_mod_phase[voice_idx] -= TAU;

            const mod_depth = (0.5 + brightness * 1.5) * env_val;
            const mod_signal = mod_depth * @sin(voice_mod_phase[voice_idx]);

            voice_carrier_phase[voice_idx] += voice_freq[voice_idx] * INV_SR * TAU;
            if (voice_carrier_phase[voice_idx] > TAU) voice_carrier_phase[voice_idx] -= TAU;

            var sample = @sin(voice_carrier_phase[voice_idx] + mod_signal);
            sample = voice_lpf[voice_idx].process(sample);
            sample *= env_val * note_vol;

            const stereo = panStereo(sample, voice_pan[voice_idx]);
            left += stereo[0];
            right += stereo[1];
        }

        drone_phase += drone_freq * INV_SR * TAU;
        if (drone_phase > TAU) drone_phase -= TAU;
        var drone_sample = @sin(drone_phase) + @sin(drone_phase * 1.002) * 0.5;
        drone_sample = drone_lpf.process(drone_sample);
        drone_sample *= 0.02;
        left += drone_sample;
        right += drone_sample;

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
    rng = synth.Rng.init(77777);

    voice_carrier_phase = .{0} ** VOICE_COUNT;
    voice_mod_phase = .{0} ** VOICE_COUNT;
    voice_freq = .{ midiToFreq(60), midiToFreq(63) };
    voice_env = .{
        Envelope.init(0.003, 1.5, 0.0, 1.0),
        Envelope.init(0.003, 1.8, 0.0, 1.2),
    };
    voice_lpf = .{ LPF.init(3000.0), LPF.init(3000.0) };
    voice_pan = .{ -0.3, 0.3 };
    voice_note_idx = .{ 10, 12 };
    voice_active = .{ false, false };
    voice_beat_counter = .{ 0, 0 };

    drone_phase = 0;
    drone_freq = midiToFreq(36);
    drone_lpf = LPF.init(120.0);

    reverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });
}
