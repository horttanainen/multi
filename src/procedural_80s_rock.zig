// Procedural 80s rock style.
// Drums, saw bass, detuned power chords, unison lead, cue-driven sequencer.
// Uses synth engine Voice types for thickness; drums stay hand-rolled.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const HPF = synth.HPF;
const StereoReverb = synth.StereoReverb;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

// ============================================================
// Tweakable parameters
// ============================================================

pub const CuePreset = enum(u8) {
    arena,
    night_drive,
    power_ballad,
    combat,
};

pub var bpm: f32 = 112.0;
pub var reverb_mix: f32 = 0.35;
pub var lead_mix: f32 = 0.5;
pub var drive: f32 = 0.55;
pub var drum_mix: f32 = 0.8;
pub var bass_mix: f32 = 0.7;
pub var gate: f32 = 0.45;
pub var selected_cue: CuePreset = .arena;

// ============================================================
// Reverb
// ============================================================

const RockReverb = StereoReverb(.{ 1327, 1451, 1559, 1613 }, .{ 181, 487 });
var reverb: RockReverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
var rng: synth.Rng = synth.Rng.init(0x80F0);

// ============================================================
// Chord & lead maps per cue
// ============================================================

const chord_map = [4][4][3]u8{
    .{ .{ 40, 47, 52 }, .{ 43, 50, 55 }, .{ 45, 52, 57 }, .{ 38, 45, 50 } }, // arena
    .{ .{ 45, 52, 57 }, .{ 40, 47, 52 }, .{ 43, 50, 55 }, .{ 47, 54, 59 } }, // night drive
    .{ .{ 38, 45, 50 }, .{ 43, 50, 55 }, .{ 40, 47, 52 }, .{ 45, 52, 57 } }, // power ballad
    .{ .{ 40, 47, 52 }, .{ 41, 48, 53 }, .{ 43, 50, 55 }, .{ 45, 52, 57 } }, // combat
};

const lead_map = [4][8]u8{
    .{ 64, 67, 69, 71, 72, 71, 69, 67 },
    .{ 69, 71, 72, 74, 76, 74, 72, 71 },
    .{ 60, 64, 67, 69, 72, 69, 67, 64 },
    .{ 64, 67, 71, 72, 74, 72, 71, 67 },
};

// ============================================================
// Sequencer state
// ============================================================

var step_counter: f32 = 0.0;
var bar_step: u8 = 0;
var current_chord_idx: u8 = 0;
var lead_step_idx: u8 = 0;

// ============================================================
// Arc controller for section dynamics
// ============================================================

var arc: synth.ArcController = .{ .section_beats = 32, .shape = .rise_fall };

// ============================================================
// Drums (hand-rolled, too specialized for Voice type)
// ============================================================

var kick_phase: f32 = 0.0;
var kick_pitch_env: f32 = 0.0;
var kick_env: Envelope = Envelope.init(0.001, 0.16, 0.0, 0.1);

var snare_phase: f32 = 0.0;
var snare_env: Envelope = Envelope.init(0.001, 0.12, 0.0, 0.06);
var snare_noise_lpf: LPF = LPF.init(3400.0);
var snare_body_lpf: LPF = LPF.init(2200.0);

var hat_env: Envelope = Envelope.init(0.001, 0.03, 0.0, 0.02);
var hat_hpf: HPF = HPF.init(6000.0);

// ============================================================
// Bass: saw + sub (no unison needed for mono bass)
// ============================================================

var bass_phase: f32 = 0.0;
var bass_sub_phase: f32 = 0.0;
var bass_freq: f32 = midiToFreq(40);
var bass_env: Envelope = Envelope.init(0.002, 0.18, 0.0, 0.08);
var bass_lpf: LPF = LPF.init(800.0);

// ============================================================
// Chords: 3 voices × Voice(2, 1) for detuned power chords
// ============================================================

const ChordVoice = synth.Voice(2, 1);
var chord_voices: [3]ChordVoice = .{
    .{ .unison_spread = 0.006, .pan = -0.22 },
    .{ .unison_spread = 0.006, .pan = 0.0 },
    .{ .unison_spread = 0.006, .pan = 0.22 },
};
var chord_env: Envelope = Envelope.init(0.004, 0.36, 0.0, 0.14);

// ============================================================
// Lead: Voice(3, 1) for thick synth lead
// ============================================================

const LeadVoice = synth.Voice(3, 1);
var lead_voice: LeadVoice = .{
    .unison_spread = 0.005,
    .filter = LPF.init(2200.0),
};

// ============================================================
// Public API
// ============================================================

pub fn reset() void {
    step_counter = 0.0;
    bar_step = 0;
    current_chord_idx = 0;
    lead_step_idx = 0;

    kick_phase = 0.0;
    kick_pitch_env = 0.0;
    kick_env = Envelope.init(0.001, 0.16, 0.0, 0.1);

    snare_phase = 0.0;
    snare_env = Envelope.init(0.001, 0.12, 0.0, 0.06);
    snare_noise_lpf = LPF.init(3400.0);
    snare_body_lpf = LPF.init(2200.0);

    hat_env = Envelope.init(0.001, 0.03, 0.0, 0.02);
    hat_hpf = HPF.init(6000.0);

    bass_phase = 0.0;
    bass_sub_phase = 0.0;
    bass_freq = midiToFreq(40);
    bass_env = Envelope.init(0.002, 0.18, 0.0, 0.08);
    bass_lpf = LPF.init(800.0);

    chord_voices = .{
        .{ .unison_spread = 0.006, .pan = -0.22 },
        .{ .unison_spread = 0.006, .pan = 0.0 },
        .{ .unison_spread = 0.006, .pan = 0.22 },
    };
    chord_env = Envelope.init(0.004, 0.36, 0.0, 0.14);

    lead_voice = .{ .unison_spread = 0.005, .filter = LPF.init(2200.0) };

    arc = .{ .section_beats = 32, .shape = .rise_fall };
    reverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
    rng = synth.Rng.init(@as(u32, 0x80F0_0000) + @as(u32, @intFromEnum(selected_cue)) * 17);
    triggerCue();
}

pub fn triggerCue() void {
    current_chord_idx = 0;
    bar_step = 0;
    lead_step_idx = 0;
    loadChordForCurrentCue();
    bass_freq = midiToFreq(chord_map[@intFromEnum(selected_cue)][0][0]);
    lead_voice.freq = midiToFreq(lead_map[@intFromEnum(selected_cue)][0]);
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm / 4.0;

    for (0..frames) |i| {
        arc.advanceSample(bpm);
        const t = arc.tension();

        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep(t);
        }

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const drum_level = drum_mix;
        const kick = processKick() * drum_level;
        left += kick * 0.85;
        right += kick * 0.85;

        const snare = processSnare() * drum_level;
        left += snare * 0.72;
        right += snare * 0.72;

        const hat = processHat() * drum_level;
        left += hat * 0.42;
        right += hat * 0.52;

        const bass = processBass() * bass_mix;
        left += bass * 0.85;
        right += bass * 0.8;

        const chords = processChords(t);
        left += chords[0];
        right += chords[1];

        const lead = processLead(t) * lead_mix;
        const lead_stereo = panStereo(lead, 0.08);
        left += lead_stereo[0];
        right += lead_stereo[1];

        const rev = reverb.process(.{ left, right });
        const dry = 1.0 - reverb_mix;
        left = left * dry + rev[0] * reverb_mix;
        right = right * dry + rev[1] * reverb_mix;

        buf[i * 2] = softClip(left * 0.82);
        buf[i * 2 + 1] = softClip(right * 0.82);
    }
}

// ============================================================
// Sequencer
// ============================================================

fn advanceStep(t: f32) void {
    const step = bar_step;

    if (step == 0 or step == 8) {
        kick_env.trigger();
        kick_pitch_env = 1.0;
    }
    if (cueKickPattern(step)) {
        kick_env.trigger();
        kick_pitch_env = 0.8;
    }

    if (step == 4 or step == 12) {
        snare_env.trigger();
    }

    if (step % 2 == 0 or cueHatPattern(step)) {
        hat_env.trigger();
    }

    if (step % 2 == 0) {
        bass_env.trigger();
        bass_freq = midiToFreq(chord_map[@intFromEnum(selected_cue)][current_chord_idx][0]);
        bass_lpf = LPF.init(380.0 + drive * 900.0);
    }

    if (step % 4 == 0) {
        chord_env = Envelope.init(0.004, 0.18 + gate * 0.45, 0.0, 0.1 + gate * 0.18);
        chord_env.trigger();
        loadChordForCurrentCue();
    }

    if (cueLeadPattern(step)) {
        // Arc modulates lead envelope and filter
        const env_decay = 0.14 + (1.0 - gate) * 0.2 + t * 0.1;
        lead_voice.env = Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08);
        lead_voice.env.trigger();
        lead_voice.freq = midiToFreq(lead_map[@intFromEnum(selected_cue)][lead_step_idx]);
        lead_voice.filter = LPF.init(1200.0 + drive * 2800.0 + t * 1000.0);
        lead_step_idx = @intCast((lead_step_idx + 1) % lead_map[@intFromEnum(selected_cue)].len);
    }

    bar_step = (bar_step + 1) % 16;
    if (bar_step != 0) return;

    current_chord_idx = @intCast((current_chord_idx + 1) % chord_map[@intFromEnum(selected_cue)].len);
}

fn cueKickPattern(step: u8) bool {
    return switch (selected_cue) {
        .arena => step == 10,
        .night_drive => step == 6 or step == 14,
        .power_ballad => step == 11,
        .combat => step == 6 or step == 10 or step == 14,
    };
}

fn cueHatPattern(step: u8) bool {
    return switch (selected_cue) {
        .arena => false,
        .night_drive => step % 2 == 1,
        .power_ballad => step == 14,
        .combat => step % 2 == 1,
    };
}

fn cueLeadPattern(step: u8) bool {
    return switch (selected_cue) {
        .arena => step == 2 or step == 6 or step == 10 or step == 14,
        .night_drive => step == 3 or step == 7 or step == 11 or step == 15,
        .power_ballad => step == 4 or step == 12,
        .combat => step == 1 or step == 5 or step == 9 or step == 13,
    };
}

fn loadChordForCurrentCue() void {
    const chord = chord_map[@intFromEnum(selected_cue)][current_chord_idx];
    for (0..3) |idx| {
        chord_voices[idx].freq = midiToFreq(chord[idx]);
    }
}

// ============================================================
// DSP processing
// ============================================================

fn processKick() f32 {
    const env = kick_env.process();
    if (env <= 0.0001) return 0.0;

    kick_pitch_env *= 0.993;
    const freq = 44.0 + kick_pitch_env * 90.0;
    kick_phase += freq * INV_SR * TAU;
    if (kick_phase > TAU) kick_phase -= TAU;
    return @sin(kick_phase) * env * 1.5;
}

fn processSnare() f32 {
    const env = snare_env.process();
    if (env <= 0.0001) return 0.0;

    snare_phase += 190.0 * INV_SR * TAU;
    if (snare_phase > TAU) snare_phase -= TAU;
    const noise = snare_noise_lpf.process(rng.float() * 2.0 - 1.0);
    const tone = snare_body_lpf.process(@sin(snare_phase));
    return (noise * 0.78 + tone * 0.35) * env;
}

fn processHat() f32 {
    const env = hat_env.process();
    if (env <= 0.0001) return 0.0;
    const noise = hat_hpf.process(rng.float() * 2.0 - 1.0);
    return noise * env * 0.45;
}

fn processBass() f32 {
    const env = bass_env.process();
    if (env <= 0.0001) return 0.0;

    bass_phase += bass_freq * INV_SR * TAU;
    if (bass_phase > TAU) bass_phase -= TAU;
    bass_sub_phase += bass_freq * 0.5 * INV_SR * TAU;
    if (bass_sub_phase > TAU) bass_sub_phase -= TAU;

    const saw = bass_phase / std.math.pi - 1.0;
    const sub = @sin(bass_sub_phase);
    var sample = saw * (0.6 + drive * 0.35) + sub * 0.4;
    sample = bass_lpf.process(sample);
    sample *= 1.0 + drive * 0.45;
    return sample * env * 0.55;
}

fn processChords(t: f32) [2]f32 {
    const env = chord_env.process();
    if (env <= 0.0001) return .{ 0.0, 0.0 };

    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..3) |idx| {
        // Use Voice's process for unison-detuned chord tones
        // But we share one envelope across all chord voices
        chord_voices[idx].env = .{
            .state = .sustain,
            .level = env,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = env,
            .release_rate = 0,
        };

        const raw = chord_voices[idx].processRaw();
        if (raw.env_val <= 0.0001) continue;

        // Square-ish waveshaping for gritty power chord tone
        var wave = raw.osc;
        wave *= 1.0 + drive * 0.6 + t * 0.2;
        if (wave > 0.85) wave = 0.85;
        if (wave < -0.85) wave = -0.85;
        wave *= raw.env_val * (0.18 + drive * 0.22);

        const stereo = panStereo(wave, chord_voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

fn processLead(t: f32) f32 {
    // Lead uses Voice(3,1) with its own envelope
    const raw = lead_voice.processRaw();
    if (raw.env_val <= 0.0001) return 0.0;

    // Add harmonics manually for richer lead tone
    var wave = raw.osc;
    wave += @sin(lead_voice.phases[0] * 2.0) * 0.18; // octave harmonic
    wave = lead_voice.filter.process(wave);
    wave *= 1.0 + drive * 0.35 + t * 0.15;
    return wave * raw.env_val * 0.4;
}
