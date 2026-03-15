const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const StereoReverb = synth.StereoReverb;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

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

const ChoirReverb = StereoReverb(.{ 2039, 1877, 1733, 1601 }, .{ 307, 709 });
var reverb: ChoirReverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
var rng: synth.Rng = synth.Rng.init(0x4300_9000);

const MonkVoice = struct {
    freq: f32 = midiToFreq(48),
    phase: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    env: Envelope = Envelope.init(0.8, 1.8, 0.72, 4.5),
    formant_a: LPF = LPF.init(700.0),
    formant_b: LPF = LPF.init(1200.0),
    pan: f32 = 0.0,
    vowel_mix: f32 = 0.45,
};

const PAD_VOICE_COUNT = 3;
var pad_voices: [PAD_VOICE_COUNT]MonkVoice = .{
    .{ .pan = -0.35, .vowel_mix = 0.35 },
    .{ .pan = 0.0, .vowel_mix = 0.45 },
    .{ .pan = 0.35, .vowel_mix = 0.55 },
};
var chant_voice: MonkVoice = .{ .pan = 0.08, .vowel_mix = 0.5 };

var drone_phase: [2]f32 = .{ 0.0, 0.0 };
var drone_freq: f32 = midiToFreq(36);
var drone_lpf: LPF = LPF.init(180.0);

var breath_lpf: LPF = LPF.init(1200.0);
var shimmer_lpf: LPF = LPF.init(3400.0);

var step_counter: f32 = 0.0;
var chant_step: u8 = 0;
var chord_step: u8 = 0;

const chord_map = [4][4][3]u8{
    .{ .{ 38, 45, 50 }, .{ 41, 48, 53 }, .{ 43, 50, 55 }, .{ 36, 43, 48 } }, // cathedral
    .{ .{ 36, 43, 48 }, .{ 38, 45, 50 }, .{ 41, 48, 53 }, .{ 43, 50, 55 } }, // procession
    .{ .{ 41, 48, 53 }, .{ 38, 45, 50 }, .{ 36, 43, 48 }, .{ 43, 50, 55 } }, // vigil
    .{ .{ 38, 45, 50 }, .{ 43, 50, 55 }, .{ 45, 52, 57 }, .{ 41, 48, 53 } }, // crusade
};

const chant_map = [4][8]u8{
    .{ 62, 64, 65, 67, 65, 64, 62, 60 },
    .{ 60, 62, 64, 65, 67, 65, 64, 62 },
    .{ 65, 64, 62, 60, 62, 64, 65, 67 },
    .{ 67, 69, 67, 65, 64, 65, 67, 69 },
};

pub fn reset() void {
    reverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
    rng = synth.Rng.init(0x4300_9000 + @as(u32, @intFromEnum(selected_cue)) * 23);
    step_counter = 0.0;
    chant_step = 0;
    chord_step = 0;
    pad_voices = .{
        .{ .pan = -0.35, .vowel_mix = 0.35 },
        .{ .pan = 0.0, .vowel_mix = 0.45 },
        .{ .pan = 0.35, .vowel_mix = 0.55 },
    };
    chant_voice = .{ .pan = 0.08, .vowel_mix = 0.5 };
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
    loadCueChord();
    loadCueVowels();
    triggerPadChord();
    triggerChantNote();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm * 0.5;

    for (0..frames) |i| {
        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep();
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const drone = processDrone() * drone_mix * choir_vol;
        left += drone * 0.9;
        right += drone * 0.9;

        for (0..PAD_VOICE_COUNT) |idx| {
            const sample = processVoice(&pad_voices[idx]) * choir_vol * 0.95;
            const stereo = panStereo(sample, pad_voices[idx].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const chant = processVoice(&chant_voice) * choir_vol * chant_mix;
        const chant_stereo = panStereo(chant, chant_voice.pan);
        left += chant_stereo[0];
        right += chant_stereo[1];

        const breath = processBreath();
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
    for (0..PAD_VOICE_COUNT) |idx| {
        pad_voices[idx].freq = midiToFreq(chord[idx]);
    }
    drone_freq = midiToFreq(chord[0] - 12);
}

fn loadCueVowels() void {
    const cue_index = @intFromEnum(selected_cue);
    for (0..PAD_VOICE_COUNT) |idx| {
        const seed = cue_index * 9 + @as(u8, @intCast(idx));
        setVoiceVowel(&pad_voices[idx], @intCast((seed + chord_step) % 4));
    }
    setVoiceVowel(&chant_voice, @intCast((cue_index + chant_step / 4) % 4));
}

fn triggerPadChord() void {
    for (0..PAD_VOICE_COUNT) |idx| {
        pad_voices[idx].env = Envelope.init(1.4, 1.6, 0.76, 5.8);
        pad_voices[idx].env.trigger();
    }
}

fn triggerChantNote() void {
    const cue_notes = chant_map[@intFromEnum(selected_cue)];
    const note_idx = cue_notes[chant_step / 2];
    chant_voice.freq = midiToFreq(note_idx);
    chant_voice.env = Envelope.init(0.18, 0.5, 0.55, 1.6);
    chant_voice.env.trigger();
}

fn setVoiceVowel(voice: *MonkVoice, vowel_idx: u8) void {
    switch (vowel_idx) {
        0 => {
            voice.formant_a = LPF.init(620.0);
            voice.formant_b = LPF.init(1180.0);
            voice.vowel_mix = 0.34;
        },
        1 => {
            voice.formant_a = LPF.init(540.0);
            voice.formant_b = LPF.init(920.0);
            voice.vowel_mix = 0.42;
        },
        2 => {
            voice.formant_a = LPF.init(420.0);
            voice.formant_b = LPF.init(780.0);
            voice.vowel_mix = 0.58;
        },
        else => {
            voice.formant_a = LPF.init(760.0);
            voice.formant_b = LPF.init(1520.0);
            voice.vowel_mix = 0.48;
        },
    }
}

fn processVoice(voice: *MonkVoice) f32 {
    const env = voice.env.process();
    if (env <= 0.0001) return 0.0;

    var sample: f32 = 0.0;
    for (0..voice.phase.len) |idx| {
        const harmonic = @as(f32, @floatFromInt(idx + 1));
        const amp: f32 = switch (idx) {
            0 => 0.62,
            1 => 0.24,
            2 => 0.12,
            else => 0.06,
        };
        voice.phase[idx] += voice.freq * harmonic * INV_SR * TAU;
        if (voice.phase[idx] > TAU) {
            voice.phase[idx] -= TAU;
        }
        sample += @sin(voice.phase[idx]) * amp;
    }

    const formant_a = voice.formant_a.process(sample);
    const formant_b = voice.formant_b.process(sample);
    const filtered = formant_a * (1.0 - voice.vowel_mix) + formant_b * voice.vowel_mix;
    return filtered * env;
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

fn processBreath() f32 {
    if (breathiness <= 0.001) return 0.0;

    const noise = rng.float() * 2.0 - 1.0;
    const base = breath_lpf.process(noise);
    const shimmer = shimmer_lpf.process(noise * 0.35);
    return (base * 0.015 + shimmer * 0.006) * breathiness;
}
