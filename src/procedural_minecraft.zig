// Procedural Minecraft-style ambient piano.
// Short cue-based fragments with long gaps, a soft harmonic bed,
// degraded piano timbre, and slow resonance tails.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const scale = dsp.pentatonic_scale;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;
const panStereo = dsp.panStereo;
const SAMPLE_RATE = dsp.SAMPLE_RATE;

// ============================================================
// Tweakable parameters (written by musicConfigMenu)
// ============================================================

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 65.0;
pub var reverb_mix: f32 = 0.65;
pub var note_vol: f32 = 0.12;
pub var rest_chance: f32 = 0.5;
pub var brightness: f32 = 0.5;
pub var bed_mix: f32 = 0.8;
pub var cloud_mix: f32 = 0.7;
pub var harmony_mix: f32 = 0.55;
pub var bell_amount: f32 = 0.45;
pub var hammer_mix: f32 = 0.25;
pub var cue_gap: f32 = 28.0;
pub var cue_length: f32 = 32.0;
pub var cue_density: f32 = 0.45;
pub var wow: f32 = 0.2;
pub var blur: f32 = 0.4;
pub var attack_softness: f32 = 0.35;

fn samplesPerBeat() f32 {
    return SAMPLE_RATE * 60.0 / (BASE_BPM * bpm);
}

// ============================================================
// Reverb
// ============================================================

const PianoReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: PianoReverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

// ============================================================
// Cue state
// ============================================================

const CueState = enum {
    idle,
    playing_cue,
    tail_decay,
};

const TextureProfile = enum {
    dry_fragile,
    washed_distant,
    warm_blurred,
    thin_lonely,
};

pub const CuePreset = enum(u8) {
    washed_open,
    warm_suspended,
    bright_air,
    lonely_sparse,
    combat,
};

pub var selected_cue: CuePreset = .washed_open;

var cue_state: CueState = .idle;
var cue_samples_remaining: u64 = 0;
var idle_samples_remaining: u64 = 0;
var tail_samples_remaining: u64 = 0;
var cue_density_current: f32 = 0.45;
var scene_presence: f32 = 0.0;
var scene_presence_target: f32 = 0.0;
var texture_profile: TextureProfile = .washed_distant;
var texture_bed_mul: f32 = 1.0;
var texture_cloud_mul: f32 = 1.0;
var texture_harmony_mul: f32 = 1.0;
var texture_bell_mul: f32 = 1.0;
var texture_hammer_mul: f32 = 1.0;
var texture_wow_mul: f32 = 1.0;
var texture_blur_mul: f32 = 1.0;
var texture_attack_mul: f32 = 1.0;

// ============================================================
// Harmonic regions and phrase state
// ============================================================

const VOICE_COUNT = 2;
const PHRASE_MAX_LEN = 5;
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
var beat_counter: f32 = 0;
var beat_number: u32 = 0;

var motif_notes: [PHRASE_MAX_LEN]u8 = .{0} ** PHRASE_MAX_LEN;
var motif_rests: [PHRASE_MAX_LEN]bool = .{false} ** PHRASE_MAX_LEN;
var motif_len: u8 = 0;
var phrase_notes: [VOICE_COUNT][PHRASE_MAX_LEN]u8 = .{.{0} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
var phrase_rests: [VOICE_COUNT][PHRASE_MAX_LEN]bool = .{.{false} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
var phrase_len: [VOICE_COUNT]u8 = .{ 0, 0 };
var phrase_pos: [VOICE_COUNT]u8 = .{ 0, 0 };

// ============================================================
// Piano voices
// ============================================================

var voices: [VOICE_COUNT]instruments.PianoVoice = .{
    instruments.PianoVoice.init(-0.18, 0.0),
    instruments.PianoVoice.init(0.22, 1.5),
};
var voice_note_idx: [VOICE_COUNT]u8 = .{ 10, 12 };
var voice_beat_counter: [VOICE_COUNT]f32 = .{ 0, 0 };
const voice_beat_len: [VOICE_COUNT]f32 = .{ 2.5, 3.75 };

// ============================================================
// Resonance, bed, and drone
// ============================================================

var texture_layer: layers.MinecraftTextureLayer = .{};

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
var rng: dsp.Rng = dsp.Rng.init(77777);

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = samplesPerBeat();

    for (0..frames) |i| {
        global_sample += 1;
        updateScenePresence();
        updateBeatState(spb);

        var left: f32 = 0;
        var right: f32 = 0;

        for (0..VOICE_COUNT) |voice_idx| {
            voice_beat_counter[voice_idx] += 1.0 / spb;
            const beat_len = voiceBeatLength(voice_idx);
            if (voice_beat_counter[voice_idx] >= beat_len) {
                voice_beat_counter[voice_idx] -= beat_len;
                advanceVoice(voice_idx);
            }
        }

        for (0..VOICE_COUNT) |voice_idx| {
            const wow_amount = effectiveWow();
            const blur_amount = effectiveBlur();
            const bell_tone = std.math.clamp(bell_amount * texture_bell_mul * (1.0 - blur_amount * 0.45), 0.0, 1.0);
            const voice_gain = if (voice_idx == MOTIF_VOICE) 1.0 else std.math.clamp(harmony_mix * texture_harmony_mul, 0.0, 1.0);
            const hammer_level = hammer_mix * texture_hammer_mul * (0.2 + brightness * 0.22) * (1.0 - effectiveAttackSoftness() * 0.45);
            var sample = voices[voice_idx].process(&rng, wow_amount, bell_tone, effectiveAttackSoftness(), hammer_level) * note_vol * voice_gain;
            sample *= 0.88;

            const stereo = panStereo(sample, voices[voice_idx].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const texture_out = layers.mixMinecraftTextureLayer(
            &texture_layer,
            scene_presence,
            region_root_class,
            brightness,
            bed_mix,
            cloud_mix,
            effectiveWow(),
            effectiveBlur(),
            texture_bed_mul,
            texture_cloud_mul,
            drone_dropout_beats,
        );
        left += texture_out[0];
        right += texture_out[1];

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
    rng = dsp.Rng.init(77777);

    cue_state = .idle;
    cue_samples_remaining = 0;
    idle_samples_remaining = 0;
    tail_samples_remaining = 0;
    cue_density_current = cue_density;
    scene_presence = 0.0;
    scene_presence_target = 0.0;
    texture_profile = .washed_distant;
    texture_bed_mul = 1.0;
    texture_cloud_mul = 1.0;
    texture_harmony_mul = 1.0;
    texture_bell_mul = 1.0;
    texture_hammer_mul = 1.0;
    texture_wow_mul = 1.0;
    texture_blur_mul = 1.0;
    texture_attack_mul = 1.0;

    current_region = .open;
    region_root_class = 0;
    beat_counter = 0;
    beat_number = 0;

    motif_notes = .{0} ** PHRASE_MAX_LEN;
    motif_rests = .{false} ** PHRASE_MAX_LEN;
    motif_len = 0;
    phrase_notes = .{.{0} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
    phrase_rests = .{.{false} ** PHRASE_MAX_LEN} ** VOICE_COUNT;
    phrase_len = .{ 0, 0 };
    phrase_pos = .{ 0, 0 };

    voices = .{
        instruments.PianoVoice.init(-0.18, 0.0),
        instruments.PianoVoice.init(0.22, 1.5),
    };
    voice_note_idx = .{ 10, 12 };
    voice_beat_counter = .{ 0, 0 };

    layers.resetMinecraftTextureLayer(&texture_layer);

    bloom_notes_remaining = 0;
    repeat_figure_notes_remaining = 0;
    repeat_note_idx = 12;
    drone_dropout_beats = 0;

    reverb = PianoReverb.init(.{ 0.90, 0.91, 0.92, 0.89 });

    startCue();
}

pub fn triggerCue() void {
    startCue();
}

fn updateScenePresence() void {
    scene_presence += (scene_presence_target - scene_presence) * 0.00045;
}

fn startCue() void {
    cue_state = .playing_cue;
    cue_samples_remaining = 0;
    idle_samples_remaining = 0;
    tail_samples_remaining = 0;
    scene_presence_target = 1.0;

    applySelectedCue();
    cue_density_current = std.math.clamp(cue_density * textureDensityMultiplier(), 0.12, 0.95);
    updateRegionTuning();
    rebuildMotif();

    beat_counter = 0;
    beat_number = 0;
    bloom_notes_remaining = 0;
    repeat_figure_notes_remaining = 0;
    drone_dropout_beats = 0;
    voice_beat_counter[MOTIF_VOICE] = 0;
    voice_beat_counter[HARMONY_VOICE] = voiceBeatLength(HARMONY_VOICE) * 0.45;

    advanceVoice(MOTIF_VOICE);
}

fn applySelectedCue() void {
    switch (selected_cue) {
        .washed_open => {
            current_region = .open;
            texture_profile = .washed_distant;
            region_root_class = 0;
            texture_bed_mul = 1.25;
            texture_cloud_mul = 1.35;
            texture_harmony_mul = 0.72;
            texture_bell_mul = 0.62;
            texture_hammer_mul = 0.48;
            texture_wow_mul = 1.0;
            texture_blur_mul = 1.22;
            texture_attack_mul = 1.15;
        },
        .warm_suspended => {
            current_region = .suspended;
            texture_profile = .warm_blurred;
            region_root_class = 1;
            texture_bed_mul = 1.08;
            texture_cloud_mul = 1.18;
            texture_harmony_mul = 0.85;
            texture_bell_mul = 0.52;
            texture_hammer_mul = 0.55;
            texture_wow_mul = 0.78;
            texture_blur_mul = 1.35;
            texture_attack_mul = 1.25;
        },
        .bright_air => {
            current_region = .bright;
            texture_profile = .dry_fragile;
            region_root_class = 2;
            texture_bed_mul = 0.7;
            texture_cloud_mul = 0.95;
            texture_harmony_mul = 0.66;
            texture_bell_mul = 0.74;
            texture_hammer_mul = 0.58;
            texture_wow_mul = 0.92;
            texture_blur_mul = 0.82;
            texture_attack_mul = 0.92;
        },
        .lonely_sparse => {
            current_region = .sparse;
            texture_profile = .thin_lonely;
            region_root_class = 0;
            texture_bed_mul = 0.42;
            texture_cloud_mul = 0.82;
            texture_harmony_mul = 0.55;
            texture_bell_mul = 0.88;
            texture_hammer_mul = 0.46;
            texture_wow_mul = 1.18;
            texture_blur_mul = 0.92;
            texture_attack_mul = 1.0;
        },
        .combat => {
            current_region = .bright;
            texture_profile = .dry_fragile;
            region_root_class = 3;
            texture_bed_mul = 0.62;
            texture_cloud_mul = 0.78;
            texture_harmony_mul = 0.82;
            texture_bell_mul = 0.82;
            texture_hammer_mul = 0.78;
            texture_wow_mul = 0.62;
            texture_blur_mul = 0.58;
            texture_attack_mul = 0.7;
        },
    }
}

fn textureDensityMultiplier() f32 {
    return switch (texture_profile) {
        .dry_fragile => 0.9,
        .washed_distant => 0.68,
        .warm_blurred => 0.78,
        .thin_lonely => 0.58,
    };
}

fn effectiveWow() f32 {
    return std.math.clamp(wow * texture_wow_mul, 0.0, 1.0);
}

fn effectiveBlur() f32 {
    return std.math.clamp(blur * texture_blur_mul, 0.0, 1.0);
}

fn effectiveAttackSoftness() f32 {
    return std.math.clamp(attack_softness * texture_attack_mul, 0.0, 1.0);
}

fn voiceBeatLength(voice_idx: usize) f32 {
    const density_scale = 1.85 - cue_density_current * 0.95;
    const harmony_scale: f32 = if (voice_idx == HARMONY_VOICE) 1.18 else 1.0;
    return voice_beat_len[voice_idx] * density_scale * harmony_scale;
}

fn updateBeatState(spb: f32) void {
    beat_counter += 1.0 / spb;
    if (beat_counter < 1.0) return;

    beat_counter -= 1.0;
    beat_number += 1;

    if (drone_dropout_beats > 0) {
        drone_dropout_beats -= 1.0;
        if (drone_dropout_beats < 0) {
            drone_dropout_beats = 0;
        }
    }

    if (beat_number % 24 == 0) {
        scheduleRareEvents();
    }
}

fn scheduleRareEvents() void {
    if (bloom_notes_remaining == 0 and rng.float() < 0.08) {
        bloom_notes_remaining = 2;
    }

    if (repeat_figure_notes_remaining == 0 and rng.float() < 0.07) {
        repeat_figure_notes_remaining = 3;
        repeat_note_idx = chooseRegionNote(1, 10, 14);
    }

    if (drone_dropout_beats <= 0 and rng.float() < 0.06) {
        drone_dropout_beats = 4.0;
    }
}

fn updateRegionTuning() void {
    layers.applyMinecraftRegionTuning(&texture_layer, region_root_class, switch (current_region) {
        .open => .open,
        .suspended => .suspended,
        .bright => .bright,
        .sparse => .sparse,
    });
}

fn rebuildMotif() void {
    buildMotif();
    deriveHarmonyPhrase();
    phrase_pos = .{ 0, 0 };

    voices[MOTIF_VOICE].pan = -0.1 - rng.float() * 0.08;
    voices[HARMONY_VOICE].pan = 0.1 + rng.float() * 0.1;
    voices[MOTIF_VOICE].detune_ratio = 0.9995 + rng.float() * 0.001;
    voices[HARMONY_VOICE].detune_ratio = 1.0002 + rng.float() * 0.0009;

    const blur_amount = effectiveBlur();
    voices[MOTIF_VOICE].mod_ratio = 2.5 + brightness * 0.25 + bell_amount * 0.15 - blur_amount * 0.18;
    voices[HARMONY_VOICE].mod_ratio = 2.3 + brightness * 0.22 + bell_amount * 0.12 - blur_amount * 0.14;
    voices[MOTIF_VOICE].mod_depth = 0.45 + brightness * 0.28 + bell_amount * 0.2 - blur_amount * 0.18;
    voices[HARMONY_VOICE].mod_depth = 0.28 + brightness * 0.18 + bell_amount * 0.14 - blur_amount * 0.12;
}

fn buildMotif() void {
    const bounds = regionBounds(MOTIF_VOICE);
    const low = bounds[0];
    const high = bounds[1];

    var new_len: u8 = 3 + @as(u8, @intCast(rng.next() % 2));
    if (cue_density_current > 0.7 and rng.float() < 0.4) {
        new_len += 1;
    }
    if (current_region == .sparse and new_len > 3) {
        new_len = 3;
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

        const should_repeat = repeat_figure_notes_remaining > 0 and step_idx < 2;
        if (should_repeat) {
            cursor = repeat_note_idx;
        } else if (step_idx == 0 and bloomNotesAllowedForVoice(MOTIF_VOICE)) {
            cursor = chooseBloomNote(low, high);
        } else if (step_idx == 0) {
            cursor = chooseRegionNote(@intCast(MOTIF_VOICE), low, high);
        } else if (rng.float() < 0.45) {
            cursor = motif_notes[step_idx - 1];
        } else {
            cursor = choosePhraseMotion(cursor, low, high);
        }

        motif_notes[step_idx] = cursor;

        var rest_bias = rest_chance + regionRestBias() + (1.0 - cue_density_current) * 0.28;
        if (step_idx == 0) {
            rest_bias -= 0.3;
        }
        if (should_repeat) {
            rest_bias -= 0.22;
        }
        if (bloomNotesAllowedForVoice(MOTIF_VOICE)) {
            rest_bias -= 0.12;
        }

        const should_rest = rng.float() < std.math.clamp(rest_bias, 0.05, 0.92);
        motif_rests[step_idx] = should_rest;
        if (!should_rest) {
            has_note = true;
        }
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
        if (note_idx < low) {
            note_idx = low;
        }
        phrase_notes[HARMONY_VOICE][step_idx] = note_idx;

        var should_rest = motif_rests[step_idx];
        if (!should_rest) {
            const base_rest_chance: f32 = switch (current_region) {
                .open => 0.7,
                .suspended => 0.72,
                .bright => 0.58,
                .sparse => 0.88,
            };
            should_rest = rng.float() < std.math.clamp(base_rest_chance + (1.0 - cue_density_current) * 0.1, 0.0, 0.95);
        }
        phrase_rests[HARMONY_VOICE][step_idx] = should_rest;
        if (!should_rest) {
            has_note = true;
        }
    }

    if (has_note) return;

    for (0..motif_len) |step_idx| {
        if (motif_rests[step_idx]) continue;
        phrase_rests[HARMONY_VOICE][step_idx] = false;
        return;
    }
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
    var should_rest = phrase_rests[voice_idx][safe_idx];
    if (!should_rest) {
        const density_gate = if (voice_idx == MOTIF_VOICE)
            cue_density_current
        else
            cue_density_current * 0.72;
        should_rest = rng.float() > density_gate;
    }

    if (should_rest) {
        voices[voice_idx].active = false;
    } else {
        triggerVoiceNote(voice_idx, phrase_notes[voice_idx][safe_idx]);
        voices[voice_idx].active = true;
    }

    phrase_pos[voice_idx] += 1;
    if (phrase_pos[voice_idx] < phrase_len[voice_idx]) return;
    phrase_pos[voice_idx] = 0;
}

fn triggerVoiceNote(voice_idx: usize, note_idx: u8) void {
    voice_note_idx[voice_idx] = note_idx;
    const freq = midiToFreq(scale[note_idx]);
    const velocity = if (voice_idx == MOTIF_VOICE)
        0.9 + rng.float() * 0.1
    else
        0.48 + rng.float() * 0.08;

    const note_height = @as(f32, @floatFromInt(note_idx - 5)) / 12.0;
    const blur_amount = effectiveBlur();
    const attack_amount = effectiveAttackSoftness();
    const cutoff = if (voice_idx == MOTIF_VOICE)
        650.0 + brightness * 2800.0 + note_height * 550.0 - blur_amount * 850.0
    else
        520.0 + brightness * 1700.0 + note_height * 280.0 - blur_amount * 620.0;

    const attack_s = if (voice_idx == MOTIF_VOICE)
        0.003 + attack_amount * 0.05
    else
        0.006 + attack_amount * 0.065;
    const decay_s = if (voice_idx == MOTIF_VOICE)
        1.6 + blur_amount * 0.9
    else
        1.9 + blur_amount * 1.1;
    const release_s = if (voice_idx == MOTIF_VOICE)
        1.5 + blur_amount * 1.6
    else
        1.8 + blur_amount * 1.9;
    voices[voice_idx].trigger(freq, velocity, @max(cutoff, 140.0), dsp.Envelope.init(attack_s, decay_s, 0.0, release_s));

    layers.exciteMinecraftTextureLayer(&texture_layer, note_idx, region_root_class);

    if (bloomNotesAllowedForVoice(voice_idx) and bloom_notes_remaining > 0) {
        bloom_notes_remaining -= 1;
    }
    if (repeat_figure_notes_remaining > 0 and voice_idx == MOTIF_VOICE) {
        repeat_figure_notes_remaining -= 1;
    }
}

fn scenePresenceForTexture() f32 {
    return std.math.clamp(scene_presence + 0.05, 0.0, 1.05);
}

fn regionBounds(voice_idx: usize) [2]u8 {
    if (voice_idx == MOTIF_VOICE) {
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
        .suspended => 0.04,
        .bright => -0.12,
        .sparse => 0.18,
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

    if (r < 0.32) {
        delta = 1;
    } else if (r < 0.64) {
        delta = -1;
    } else if (r < 0.82) {
        delta = 0;
    } else if (r < 0.9) {
        delta = 2;
    } else if (r < 0.96) {
        delta = -2;
    } else {
        delta = if (rng.float() < 0.5) 3 else -3;
    }

    const moved = @as(i16, current) + delta;
    var next_note: u8 = @intCast(std.math.clamp(moved, @as(i16, low), @as(i16, high)));

    if (current_region == .bright and rng.float() < 0.25) {
        next_note = @min(next_note + 1, high);
    }
    if (current_region == .sparse and rng.float() < 0.35) {
        next_note = current;
    }

    return next_note;
}

fn chooseBloomNote(low: u8, high: u8) u8 {
    const bloom_low = @max(low, @as(u8, 14));
    const bloom_high = @max(bloom_low, high);
    return @min(bloom_low + @as(u8, @intCast(rng.next() % 3)), bloom_high);
}

fn bloomNotesAllowedForVoice(voice_idx: usize) bool {
    return bloom_notes_remaining > 0 and voice_idx == MOTIF_VOICE;
}
