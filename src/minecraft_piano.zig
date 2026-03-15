// Procedural relaxing piano style.
// Sparse Minecraft-like piano with phrase memory, harmonic regions,
// processed piano timbre, and slow rare-event evolution.
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

pub var bpm: f32 = 65.0;
pub var reverb_mix: f32 = 0.65;
pub var note_vol: f32 = 0.12;
pub var rest_chance: f32 = 0.5;
pub var brightness: f32 = 0.5;
pub var bed_mix: f32 = 0.8;
pub var cloud_mix: f32 = 0.7;
pub var harmony_mix: f32 = 0.55;
pub var bell_amount: f32 = 0.45;
pub var hammer_mix: f32 = 0.25;

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

// ============================================================
// Reverb (long ambient tail)
// ============================================================

const PianoReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: PianoReverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

// ============================================================
// Harmonic regions and phrase state
// ============================================================

const VOICE_COUNT = 2;
const PHRASE_MAX_LEN = 5;
const RESONANCE_COUNT = 3;
const BED_PARTIALS = 4;
const MOTIF_VOICE: usize = 0;
const HARMONY_VOICE: usize = 1;

const HarmonicRegion = enum {
    open,
    suspended,
    bright,
    sparse,
};

var current_region: HarmonicRegion = .open;
var region_root_class: u8 = 0;
var region_beat_progress: f32 = 0;
var region_target_beats: f32 = 40;

var beat_counter: f32 = 0;
var beat_number: u32 = 0;

var motif_notes: [PHRASE_MAX_LEN]u8 = .{0} ** PHRASE_MAX_LEN;
var motif_rests: [PHRASE_MAX_LEN]bool = .{false} ** PHRASE_MAX_LEN;
var motif_len: u8 = 0;
var motif_loop_count: u8 = 0;
var motif_loop_target: u8 = 6;

var phrase_notes: [VOICE_COUNT][PHRASE_MAX_LEN]u8 = .{.{0} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
var phrase_rests: [VOICE_COUNT][PHRASE_MAX_LEN]bool = .{.{false} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
var phrase_len: [VOICE_COUNT]u8 = .{ 0, 0 };
var phrase_pos: [VOICE_COUNT]u8 = .{ 0, 0 };

// ============================================================
// Piano voices
// ============================================================

var voice_carrier_phase: [VOICE_COUNT]f32 = .{0} ** VOICE_COUNT;
var voice_detune_phase: [VOICE_COUNT]f32 = .{0} ** VOICE_COUNT;
var voice_mod_phase: [VOICE_COUNT]f32 = .{0} ** VOICE_COUNT;
var voice_freq: [VOICE_COUNT]f32 = .{ midiToFreq(60), midiToFreq(67) };
var voice_detune: [VOICE_COUNT]f32 = .{ 1.001, 0.999 };
var voice_mod_ratio: [VOICE_COUNT]f32 = .{ 3.1, 2.8 };
var voice_mod_depth: [VOICE_COUNT]f32 = .{ 1.0, 0.9 };
var voice_velocity: [VOICE_COUNT]f32 = .{ 1.0, 1.0 };
var voice_pan: [VOICE_COUNT]f32 = .{ -0.18, 0.22 };
var voice_flutter_phase: [VOICE_COUNT]f32 = .{ 0.0, 1.5 };
var voice_hammer_age: [VOICE_COUNT]u32 = .{ 999999, 999999 };
var voice_active: [VOICE_COUNT]bool = .{ false, false };
var voice_note_idx: [VOICE_COUNT]u8 = .{ 10, 12 };
var voice_beat_counter: [VOICE_COUNT]f32 = .{ 0, 0 };
var voice_env: [VOICE_COUNT]Envelope = .{
    Envelope.init(0.002, 1.8, 0.0, 1.5),
    Envelope.init(0.002, 2.1, 0.0, 1.8),
};
var voice_lpf: [VOICE_COUNT]LPF = .{ LPF.init(2800.0), LPF.init(2500.0) };
const voice_beat_len: [VOICE_COUNT]f32 = .{ 2.5, 3.75 };

// ============================================================
// Resonance and drone
// ============================================================

var resonance_phase: [RESONANCE_COUNT]f32 = .{0} ** RESONANCE_COUNT;
var resonance_freq: [RESONANCE_COUNT]f32 = .{ midiToFreq(36), midiToFreq(43), midiToFreq(48) };
var resonance_energy: [RESONANCE_COUNT]f32 = .{ 0.0, 0.0, 0.0 };
var cloud_phase: [RESONANCE_COUNT][2]f32 = .{.{0} ** 2} ** RESONANCE_COUNT;
var cloud_freq: [RESONANCE_COUNT]f32 = .{ midiToFreq(48), midiToFreq(55), midiToFreq(60) };
var cloud_energy: [RESONANCE_COUNT]f32 = .{ 0.0, 0.0, 0.0 };

var bed_phase: [BED_PARTIALS][3]f32 = .{.{0} ** 3} ** BED_PARTIALS;
var bed_freq: [BED_PARTIALS]f32 = .{
    midiToFreq(36),
    midiToFreq(43),
    midiToFreq(48),
    midiToFreq(55),
};
var bed_target_gain: [BED_PARTIALS]f32 = .{ 0.012, 0.010, 0.008, 0.006 };
var bed_gain: [BED_PARTIALS]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

var drone_phase: f32 = 0;
var drone_detune_phase: f32 = 0;
var drone_freq: f32 = midiToFreq(36);
var drone_lpf: LPF = LPF.init(120.0);

// ============================================================
// Rare events
// ============================================================

var bloom_notes_remaining: u8 = 0;
var repeat_figure_notes_remaining: u8 = 0;
var repeat_note_idx: u8 = 12;
var drone_dropout_beats: f32 = 0;

// ============================================================
// Global
// ============================================================

var global_sample: u64 = 0;
var rng: synth.Rng = synth.Rng.init(77777);

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        updateBeatState(spb);

        var left: f32 = 0;
        var right: f32 = 0;

        for (0..VOICE_COUNT) |voice_idx| {
            voice_beat_counter[voice_idx] += 1.0 / spb;
            if (voice_beat_counter[voice_idx] >= voice_beat_len[voice_idx]) {
                voice_beat_counter[voice_idx] -= voice_beat_len[voice_idx];
                advanceVoice(voice_idx);
            }

            const env_val = voice_env[voice_idx].process();
            if (!voice_active[voice_idx] and env_val < 0.001) continue;

            voice_flutter_phase[voice_idx] += (0.00006 + @as(f32, @floatFromInt(voice_idx)) * 0.00001) * TAU;
            if (voice_flutter_phase[voice_idx] > TAU) voice_flutter_phase[voice_idx] -= TAU;
            const flutter = @sin(voice_flutter_phase[voice_idx]) * (0.0006 + brightness * 0.0012);

            const carrier_freq = voice_freq[voice_idx] * (1.0 + flutter);
            const mod_freq = carrier_freq * voice_mod_ratio[voice_idx];
            voice_mod_phase[voice_idx] += mod_freq * INV_SR * TAU;
            if (voice_mod_phase[voice_idx] > TAU) voice_mod_phase[voice_idx] -= TAU;

            const fm_amount = 0.2 + bell_amount * 1.3;
            const mod_signal = @sin(voice_mod_phase[voice_idx]) * voice_mod_depth[voice_idx] * env_val * fm_amount;

            voice_carrier_phase[voice_idx] += carrier_freq * INV_SR * TAU;
            if (voice_carrier_phase[voice_idx] > TAU) voice_carrier_phase[voice_idx] -= TAU;

            voice_detune_phase[voice_idx] += carrier_freq * voice_detune[voice_idx] * INV_SR * TAU;
            if (voice_detune_phase[voice_idx] > TAU) voice_detune_phase[voice_idx] -= TAU;

            var body = @sin(voice_carrier_phase[voice_idx] + mod_signal);
            body += @sin(voice_detune_phase[voice_idx] + mod_signal * 0.65) * 0.42;
            body += @sin(voice_carrier_phase[voice_idx] * 0.5) * 0.12;
            body += @sin(voice_carrier_phase[voice_idx] * 2.0 + mod_signal * 0.35) * (0.03 + bell_amount * 0.17);
            body = voice_lpf[voice_idx].process(body);

            var hammer: f32 = 0;
            if (voice_hammer_age[voice_idx] < 4096) {
                const age: f32 = @floatFromInt(voice_hammer_age[voice_idx]);
                const decay = @exp(-age * 0.0045);
                hammer = ((rng.float() * 2.0 - 1.0) * 0.7 + @sin(voice_carrier_phase[voice_idx] * 6.0) * 0.3) * decay;
                voice_hammer_age[voice_idx] += 1;
            }

            const voice_gain = if (voice_idx == MOTIF_VOICE) 1.0 else harmony_mix;
            var sample = (body + hammer * hammer_mix * (0.25 + brightness * 0.25)) * env_val * note_vol * voice_velocity[voice_idx] * voice_gain;
            sample *= 0.9;

            const stereo = panStereo(sample, voice_pan[voice_idx]);
            left += stereo[0];
            right += stereo[1];
        }

        const bed = processAmbientBed();
        left += bed[0];
        right += bed[1];

        const resonance = processResonance();
        left += resonance * 0.65;
        right += resonance * 0.85;

        if (drone_dropout_beats <= 0) {
            drone_phase += drone_freq * INV_SR * TAU;
            if (drone_phase > TAU) drone_phase -= TAU;
            drone_detune_phase += drone_freq * 1.0014 * INV_SR * TAU;
            if (drone_detune_phase > TAU) drone_detune_phase -= TAU;
            var drone_sample = @sin(drone_phase) + @sin(drone_detune_phase) * 0.45;
            drone_sample = drone_lpf.process(drone_sample);
            drone_sample *= 0.018;
            left += drone_sample;
            right += drone_sample;
        }

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

    current_region = .open;
    region_root_class = 0;
    region_beat_progress = 0;
    region_target_beats = 40;
    beat_counter = 0;
    beat_number = 0;

    motif_notes = .{0} ** PHRASE_MAX_LEN;
    motif_rests = .{false} ** PHRASE_MAX_LEN;
    motif_len = 0;
    motif_loop_count = 0;
    motif_loop_target = 6;
    phrase_notes = .{.{0} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
    phrase_rests = .{.{false} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
    phrase_len = .{ 0, 0 };
    phrase_pos = .{ 0, 0 };

    voice_carrier_phase = .{0} ** VOICE_COUNT;
    voice_detune_phase = .{0} ** VOICE_COUNT;
    voice_mod_phase = .{0} ** VOICE_COUNT;
    voice_freq = .{ midiToFreq(60), midiToFreq(67) };
    voice_detune = .{ 1.001, 0.999 };
    voice_mod_ratio = .{ 3.1, 2.8 };
    voice_mod_depth = .{ 1.0, 0.9 };
    voice_velocity = .{ 1.0, 1.0 };
    voice_pan = .{ -0.18, 0.22 };
    voice_flutter_phase = .{ 0.0, 1.5 };
    voice_hammer_age = .{ 999999, 999999 };
    voice_active = .{ false, false };
    voice_note_idx = .{ 10, 12 };
    voice_beat_counter = .{ 0, 0 };
    voice_env = .{
        Envelope.init(0.002, 1.8, 0.0, 1.5),
        Envelope.init(0.002, 2.1, 0.0, 1.8),
    };
    voice_lpf = .{ LPF.init(2800.0), LPF.init(2500.0) };

    resonance_phase = .{0} ** RESONANCE_COUNT;
    resonance_energy = .{ 0.0, 0.0, 0.0 };
    cloud_phase = .{.{0} ** 2} ** RESONANCE_COUNT;
    cloud_energy = .{ 0.0, 0.0, 0.0 };
    bed_phase = .{.{0} ** 3} ** BED_PARTIALS;
    bed_gain = .{ 0.0, 0.0, 0.0, 0.0 };

    drone_phase = 0;
    drone_detune_phase = 0;
    drone_freq = midiToFreq(36);
    drone_lpf = LPF.init(120.0);

    bloom_notes_remaining = 0;
    repeat_figure_notes_remaining = 0;
    repeat_note_idx = 12;
    drone_dropout_beats = 0;

    reverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

    updateRegionTuning();
    rebuildMotif();
}

fn updateBeatState(spb: f32) void {
    beat_counter += 1.0 / spb;
    if (beat_counter < 1.0) return;

    beat_counter -= 1.0;
    beat_number += 1;
    region_beat_progress += 1.0;

    if (drone_dropout_beats > 0) {
        drone_dropout_beats -= 1.0;
        if (drone_dropout_beats < 0) drone_dropout_beats = 0;
    }

    if (region_beat_progress >= region_target_beats) {
        chooseNextRegion();
    }

    if (beat_number % 16 == 0) {
        scheduleRareEvents();
    }
}

fn scheduleRareEvents() void {
    if (bloom_notes_remaining == 0 and rng.float() < 0.12) {
        bloom_notes_remaining = 3;
    }

    if (repeat_figure_notes_remaining == 0 and rng.float() < 0.10) {
        repeat_figure_notes_remaining = 4;
        repeat_note_idx = chooseRegionNote(1, 10, 14);
    }

    if (drone_dropout_beats <= 0 and rng.float() < 0.08) {
        drone_dropout_beats = 4.0;
    }
}

fn chooseNextRegion() void {
    const current_tag = @intFromEnum(current_region);
    var next_tag: u8 = @intCast(rng.next() % 4);
    if (next_tag == current_tag) {
        next_tag = @intCast((next_tag + 1) % 4);
    }

    current_region = @enumFromInt(next_tag);

    const direction: i8 = if (rng.float() < 0.55) 1 else -1;
    const moved_root: i16 = @as(i16, region_root_class) + direction;
    region_root_class = @intCast(std.math.clamp(moved_root, 0, 4));

    region_beat_progress = 0;
    region_target_beats = 28.0 + rng.float() * 36.0;

    updateRegionTuning();
    rebuildMotif();
}

fn updateRegionTuning() void {
    const low_root = region_root_class;
    const low_fifth = @min(low_root + 3, 4);
    const mid_root = @min(low_root + 5, 9);
    const high_root = @min(low_root + 10, 14);

    resonance_freq[0] = midiToFreq(scale[low_root]);
    resonance_freq[1] = midiToFreq(scale[low_fifth]);
    resonance_freq[2] = midiToFreq(scale[mid_root]);
    cloud_freq[0] = midiToFreq(scale[mid_root]);
    cloud_freq[1] = midiToFreq(scale[@min(low_root + 8, 14)]);
    cloud_freq[2] = midiToFreq(scale[high_root]);

    drone_freq = midiToFreq(scale[low_root]);
    if (current_region == .bright) {
        drone_freq = midiToFreq(scale[@min(low_root + 1, 4)]);
    }
    if (current_region == .suspended) {
        resonance_freq[2] = midiToFreq(scale[@min(high_root, 14)]);
        cloud_freq[1] = midiToFreq(scale[@min(low_root + 6, 14)]);
    }

    bed_freq[0] = midiToFreq(scale[low_root]);
    bed_freq[1] = midiToFreq(scale[low_fifth]);
    bed_freq[2] = midiToFreq(scale[mid_root]);
    bed_freq[3] = midiToFreq(scale[high_root]);

    bed_target_gain = switch (current_region) {
        .open => .{ 0.014, 0.011, 0.008, 0.005 },
        .suspended => .{ 0.013, 0.010, 0.009, 0.006 },
        .bright => .{ 0.011, 0.010, 0.010, 0.008 },
        .sparse => .{ 0.009, 0.007, 0.005, 0.003 },
    };
}

fn rebuildMotif() void {
    buildMotif();
    deriveHarmonyPhrase();
    phrase_pos = .{ 0, 0 };
    motif_loop_count = 0;
    motif_loop_target = 5 + @as(u8, @intCast(rng.next() % 4));

    voice_pan[MOTIF_VOICE] = -0.12 - rng.float() * 0.10;
    voice_pan[HARMONY_VOICE] = 0.12 + rng.float() * 0.12;
    voice_detune[MOTIF_VOICE] = 0.9995 + rng.float() * 0.0012;
    voice_detune[HARMONY_VOICE] = 1.0004 + rng.float() * 0.0010;
    voice_mod_ratio[MOTIF_VOICE] = 2.95 + brightness * 0.35;
    voice_mod_ratio[HARMONY_VOICE] = 2.65 + brightness * 0.30;
    voice_mod_depth[MOTIF_VOICE] = 0.82 + brightness * 0.55;
    voice_mod_depth[HARMONY_VOICE] = 0.60 + brightness * 0.35;
}

fn buildMotif() void {
    const bounds = regionBounds(MOTIF_VOICE);
    const low = bounds[0];
    const high = bounds[1];

    var new_len: u8 = 3 + @as(u8, @intCast(rng.next() % 3));
    if (current_region == .sparse and new_len > 4) {
        new_len = 4;
    }

    motif_len = new_len;
    phrase_len[MOTIF_VOICE] = new_len;
    phrase_len[HARMONY_VOICE] = new_len;

    var cursor = chooseRegionNote(@intCast(MOTIF_VOICE), low, high);
    var has_note = false;

    for (0..PHRASE_MAX_LEN) |step_idx| {
        if (step_idx >= new_len) {
            motif_notes[step_idx] = cursor;
            motif_rests[step_idx] = true;
            continue;
        }

        const should_repeat = repeat_figure_notes_remaining > 0 and step_idx < 3;
        if (should_repeat) {
            cursor = repeat_note_idx;
        } else if (step_idx == 0 and bloomNotesAllowedForVoice(MOTIF_VOICE)) {
            cursor = chooseBloomNote(low, high);
        } else if (step_idx == 0) {
            cursor = chooseRegionNote(@intCast(MOTIF_VOICE), low, high);
        } else {
            cursor = choosePhraseMotion(cursor, low, high);
        }

        motif_notes[step_idx] = cursor;

        var rest_bias = rest_chance + regionRestBias() + 0.05;
        if (bloomNotesAllowedForVoice(MOTIF_VOICE)) rest_bias -= 0.18;
        if (should_repeat) rest_bias -= 0.25;
        if (step_idx == 0) rest_bias -= 0.25;

        const should_rest = rng.float() < std.math.clamp(rest_bias, 0.05, 0.9);
        motif_rests[step_idx] = should_rest;
        if (!should_rest) has_note = true;
    }

    if (!has_note) {
        motif_rests[0] = false;
        motif_notes[0] = chooseRegionNote(@intCast(MOTIF_VOICE), low, high);
    }

    for (0..PHRASE_MAX_LEN) |step_idx| {
        phrase_notes[MOTIF_VOICE][step_idx] = motif_notes[step_idx];
        phrase_rests[MOTIF_VOICE][step_idx] = motif_rests[step_idx];
    }
}

fn deriveHarmonyPhrase() void {
    const bounds = regionBounds(HARMONY_VOICE);
    const low = bounds[0];
    const high = bounds[1];
    var has_note = false;

    for (0..PHRASE_MAX_LEN) |step_idx| {
        if (step_idx >= motif_len) {
            phrase_notes[HARMONY_VOICE][step_idx] = chooseRegionNote(@intCast(HARMONY_VOICE), low, high);
            phrase_rests[HARMONY_VOICE][step_idx] = true;
            continue;
        }

        const base = motif_notes[step_idx];
        const offset: u8 = switch (current_region) {
            .open => 2,
            .suspended => 1,
            .bright => 2,
            .sparse => 0,
        };
        var note_idx = @min(base + offset, high);
        if (note_idx < low) note_idx = low;
        phrase_notes[HARMONY_VOICE][step_idx] = note_idx;

        var should_rest = motif_rests[step_idx];
        if (!should_rest) {
            const harmony_rest_chance: f32 = switch (current_region) {
                .open => 0.62,
                .suspended => 0.60,
                .bright => 0.45,
                .sparse => 0.82,
            };
            should_rest = rng.float() < harmony_rest_chance;
        }
        phrase_rests[HARMONY_VOICE][step_idx] = should_rest;
        if (!should_rest) has_note = true;
    }

    if (has_note) return;

    for (0..motif_len) |step_idx| {
        if (motif_rests[step_idx]) continue;
        phrase_rests[HARMONY_VOICE][step_idx] = false;
        return;
    }
}

fn mutateMotif() void {
    if (motif_len == 0) {
        std.log.warn("mutateMotif: motif had zero-length phrase, rebuilding", .{});
        rebuildMotif();
        return;
    }

    const bounds = regionBounds(MOTIF_VOICE);
    const low = bounds[0];
    const high = bounds[1];
    const idx: usize = @intCast(rng.next() % motif_len);

    if (rng.float() < 0.28) {
        motif_rests[idx] = !motif_rests[idx];
        var has_note = false;
        for (0..motif_len) |step_idx| {
            if (motif_rests[step_idx]) continue;
            has_note = true;
            break;
        }
        if (!has_note) motif_rests[0] = false;
    } else {
        motif_notes[idx] = choosePhraseMotion(motif_notes[idx], low, high);
        motif_rests[idx] = false;
    }

    for (0..PHRASE_MAX_LEN) |step_idx| {
        phrase_notes[MOTIF_VOICE][step_idx] = motif_notes[step_idx];
        phrase_rests[MOTIF_VOICE][step_idx] = motif_rests[step_idx];
    }
    deriveHarmonyPhrase();
}

fn advanceVoice(voice_idx: usize) void {
    if (phrase_len[voice_idx] == 0) {
        std.log.warn("advanceVoice: voice {d} had zero-length phrase, rebuilding", .{voice_idx});
        rebuildMotif();
    }

    const step_idx = phrase_pos[voice_idx];
    if (step_idx >= phrase_len[voice_idx]) {
        std.log.warn("advanceVoice: voice {d} phrase position {d} exceeded phrase length {d}", .{ voice_idx, step_idx, phrase_len[voice_idx] });
        phrase_pos[voice_idx] = 0;
    }

    const safe_idx = phrase_pos[voice_idx];
    if (phrase_rests[voice_idx][safe_idx]) {
        voice_active[voice_idx] = false;
    } else {
        triggerVoiceNote(voice_idx, phrase_notes[voice_idx][safe_idx]);
        voice_active[voice_idx] = true;
    }

    phrase_pos[voice_idx] += 1;
    if (phrase_pos[voice_idx] < phrase_len[voice_idx]) return;

    phrase_pos[voice_idx] = 0;
    if (voice_idx != MOTIF_VOICE) return;

    motif_loop_count += 1;
    if (motif_loop_count < motif_loop_target) return;

    if (rng.float() < 0.72) {
        mutateMotif();
    } else {
        rebuildMotif();
    }
    motif_loop_count = 0;
}

fn triggerVoiceNote(voice_idx: usize, note_idx: u8) void {
    voice_note_idx[voice_idx] = note_idx;
    voice_freq[voice_idx] = midiToFreq(scale[note_idx]);
    voice_velocity[voice_idx] = if (voice_idx == MOTIF_VOICE)
        0.92 + rng.float() * 0.12
    else
        0.54 + rng.float() * 0.08;

    const note_height = @as(f32, @floatFromInt(note_idx - 5)) / 12.0;
    const cutoff = if (voice_idx == MOTIF_VOICE)
        900.0 + brightness * 5200.0 + note_height * 900.0
    else
        650.0 + brightness * 2400.0 + note_height * 450.0;
    voice_lpf[voice_idx] = LPF.init(cutoff);
    voice_env[voice_idx].trigger();
    voice_hammer_age[voice_idx] = 0;

    exciteResonance(note_idx);

    if (bloomNotesAllowedForVoice(voice_idx) and bloom_notes_remaining > 0) {
        bloom_notes_remaining -= 1;
    }
    if (repeat_figure_notes_remaining > 0 and voice_idx == MOTIF_VOICE) {
        repeat_figure_notes_remaining -= 1;
    }
}

fn processResonance() f32 {
    var sample: f32 = 0;

    for (0..RESONANCE_COUNT) |idx| {
        resonance_phase[idx] += resonance_freq[idx] * INV_SR * TAU;
        if (resonance_phase[idx] > TAU) resonance_phase[idx] -= TAU;

        resonance_energy[idx] *= 0.99991;
        sample += @sin(resonance_phase[idx]) * resonance_energy[idx];

        cloud_phase[idx][0] += cloud_freq[idx] * INV_SR * TAU;
        if (cloud_phase[idx][0] > TAU) cloud_phase[idx][0] -= TAU;
        cloud_phase[idx][1] += cloud_freq[idx] * 0.501 * INV_SR * TAU;
        if (cloud_phase[idx][1] > TAU) cloud_phase[idx][1] -= TAU;

        cloud_energy[idx] *= 0.999985;
        sample += (@sin(cloud_phase[idx][0]) * 0.7 + @sin(cloud_phase[idx][1]) * 0.3) * cloud_energy[idx];
    }

    return sample * ((0.012 + brightness * 0.006) + cloud_mix * 0.012);
}

fn exciteResonance(note_idx: u8) void {
    for (0..RESONANCE_COUNT) |idx| {
        const class_match = note_idx % 5 == region_root_class or note_idx % 5 == (region_root_class + idx) % 5;
        const boost: f32 = if (class_match) 0.012 else 0.005;
        resonance_energy[idx] = std.math.clamp(resonance_energy[idx] + boost, 0.0, 0.08);
        const cloud_boost: f32 = if (class_match) 0.010 else 0.003;
        cloud_energy[idx] = std.math.clamp(cloud_energy[idx] + cloud_boost, 0.0, 0.06);
    }
}

fn processAmbientBed() [2]f32 {
    var left: f32 = 0;
    var right: f32 = 0;

    for (0..BED_PARTIALS) |idx| {
        bed_gain[idx] += (bed_target_gain[idx] - bed_gain[idx]) * 0.00025;

        const base_freq = bed_freq[idx];
        var sample: f32 = 0;
        for (0..3) |osc_idx| {
            const detune = 1.0 + (@as(f32, @floatFromInt(osc_idx)) - 1.0) * 0.0018;
            bed_phase[idx][osc_idx] += base_freq * detune * INV_SR * TAU;
            if (bed_phase[idx][osc_idx] > TAU) bed_phase[idx][osc_idx] -= TAU;
            const amp: f32 = if (osc_idx == 1) 0.55 else 0.225;
            sample += @sin(bed_phase[idx][osc_idx]) * amp;
        }

        sample *= bed_gain[idx] * bed_mix;
        const pan: f32 = switch (idx) {
            0 => -0.35,
            1 => 0.35,
            2 => -0.12,
            else => 0.12,
        };
        const stereo = panStereo(sample, pan);
        left += stereo[0];
        right += stereo[1];
    }

    return .{ left, right };
}

fn regionBounds(voice_idx: usize) [2]u8 {
    if (voice_idx == 0) {
        return switch (current_region) {
            .open => .{ 5, 11 },
            .suspended => .{ 6, 12 },
            .bright => .{ 8, 13 },
            .sparse => .{ 5, 10 },
        };
    }

    return switch (current_region) {
        .open => .{ 10, 15 },
        .suspended => .{ 11, 16 },
        .bright => .{ 13, 18 },
        .sparse => .{ 10, 14 },
    };
}

fn regionRestBias() f32 {
    return switch (current_region) {
        .open => -0.05,
        .suspended => 0.02,
        .bright => -0.18,
        .sparse => 0.16,
    };
}

fn chooseRegionNote(voice_octave_offset: u8, low: u8, high: u8) u8 {
    const base = region_root_class + voice_octave_offset * 5;
    const clamped = std.math.clamp(@as(i16, base), @as(i16, low), @as(i16, high));
    const note_idx: u8 = @intCast(clamped);

    if (current_region == .suspended and rng.float() < 0.45) {
        return @min(note_idx + 1, high);
    }

    if (current_region == .bright and rng.float() < 0.5) {
        return @min(note_idx + 2, high);
    }

    return note_idx;
}

fn choosePhraseMotion(current: u8, low: u8, high: u8) u8 {
    const r = rng.float();
    var delta: i8 = 0;

    if (r < 0.28) {
        delta = 1;
    } else if (r < 0.56) {
        delta = -1;
    } else if (r < 0.76) {
        delta = 0;
    } else if (r < 0.88) {
        delta = 2;
    } else if (r < 0.96) {
        delta = -2;
    } else {
        delta = if (rng.float() < 0.5) 3 else -3;
    }

    const moved = @as(i16, current) + delta;
    var next_note: u8 = @intCast(std.math.clamp(moved, @as(i16, low), @as(i16, high)));

    if (current_region == .bright and rng.float() < 0.35) {
        next_note = @min(next_note + 1, high);
    }
    if (current_region == .sparse and rng.float() < 0.3) {
        next_note = chooseRegionNote(1, low, high);
    }

    return next_note;
}

fn chooseBloomNote(low: u8, high: u8) u8 {
    const bloom_low = @max(low, @as(u8, 14));
    const bloom_high = @max(bloom_low, high);
    return @min(bloom_low + @as(u8, @intCast(rng.next() % 3)), bloom_high);
}

fn bloomNotesAllowedForVoice(voice_idx: usize) bool {
    return bloom_notes_remaining > 0 and voice_idx == 1;
}
