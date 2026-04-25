// Procedural ambient music style — v2 composition engine.
//
// Uses Markov chord progressions, multi-scale arcs, phrase memory
// with motif development, chord-tone gravity, key modulation,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter sets ("flavors"): dawn, twilight, space, forest.
const dsp = @import("music/dsp.zig");
const std = @import("std");
const composition = @import("music/composition.zig");
const cue_morph = @import("music/cue_morph.zig");
const entropy = @import("music/entropy.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

// ============================================================
// Tweakable parameters (written by musicConfigMenu / settings)
// ============================================================

pub const CuePreset = enum(u8) {
    dawn,
    twilight,
    space,
    forest,
};

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 72.0;
pub var reverb_mix: f32 = 0.6;
pub var drone_vol: f32 = 0.15;
pub var pad_vol: f32 = 0.08;
pub var melody_vol: f32 = 0.04;
pub var arp_vol: f32 = 0.015;
pub var selected_cue: CuePreset = .dawn;

// ============================================================
// Reverb
// ============================================================

const AmbientReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: AmbientReverb = dsp.stereoReverbInit(.{1759, 1693, 1623, 1548}, .{245, 605}, .{ 0.87, 0.88, 0.89, 0.86 });

// ============================================================
// Composition engine & harmony
// ============================================================

var engine: composition.CompositionEngine = .{};

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    // Ambient chords: i, III, iv, VI, VII, v
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 0 }, .len = 3 }; // i
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 0 }, .len = 3 }; // III
    h.chords[2] = .{ .offsets = .{ 5, 8, 0, 0 }, .len = 3 }; // iv
    h.chords[3] = .{ .offsets = .{ 8, 0, 3, 0 }, .len = 3 }; // VI
    h.chords[4] = .{ .offsets = .{ 10, 2, 5, 0 }, .len = 3 }; // VII
    h.chords[5] = .{ .offsets = .{ 7, 10, 2, 0 }, .len = 3 }; // v
    h.num_chords = 6;
    //                  i     III    iv    VI    VII    v
    h.transitions[0] = .{ 0.1, 0.25, 0.25, 0.2, 0.1, 0.1, 0, 0 };
    h.transitions[1] = .{ 0.2, 0.1, 0.3, 0.2, 0.1, 0.1, 0, 0 };
    h.transitions[2] = .{ 0.3, 0.15, 0.05, 0.25, 0.15, 0.1, 0, 0 };
    h.transitions[3] = .{ 0.2, 0.2, 0.2, 0.1, 0.2, 0.1, 0, 0 };
    h.transitions[4] = .{ 0.35, 0.15, 0.1, 0.2, 0.05, 0.15, 0, 0 };
    h.transitions[5] = .{ 0.25, 0.2, 0.2, 0.15, 0.1, 0.1, 0, 0 };
    return h;
}

const AMBIENT_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};

// ============================================================
// Slow LFOs for organic movement
// ============================================================

var lfo_filter: composition.SlowLfo = .{ .period_beats = 90, .depth = 0.08 };
var lfo_reverb: composition.SlowLfo = .{ .period_beats = 150, .depth = 0.04 };

// ============================================================
// Layer volumes (for vertical activation)
// ============================================================

var drone_target: f32 = 1.0;
var pad_target: f32 = 1.0;
var melody_target: f32 = 0.5;
var arp_target: f32 = 0.0;

var drone_level: f32 = 1.0;
var pad_level: f32 = 0.3;
var melody_level: f32 = 0.0;
var arp_level: f32 = 0.0;

const LAYER_FADE_RATE: f32 = 0.00003;

var drone_layer: layers.AmbientDroneLayer = .{};
var pad_layer: layers.AmbientPadLayer = .{};
var melody_layer: layers.AmbientMelodyLayer = .{};
var arp_layer: layers.AmbientArpLayer = .{};

// ============================================================
// RNG
// ============================================================

var rng: dsp.Rng = dsp.rngInit(12345);

// ============================================================
// Cue specs (static data describing each flavor)
// ============================================================

const AmbientCueSpec = struct {
    scale_type: composition.ScaleType,
    chord_change_beats: f32,
    reverb_boost: f32,
    melody_thresh: f32,
    arp_thresh: f32,
    drone_filter_base: f32,
    drone_filter_range: f32,
    pad_filter_base: f32,
    pad_filter_range: f32,
    melody_recall_chance: f32,
    drone_env_attack: f32,
    drone_env_release: f32,
    pad_env_attack: f32,
    pad_env_release: f32,
    melody_env_attack: f32,
    melody_env_decay: f32,
    melody_env_release: f32,
    arp_env_decay: f32,
    arp_env_release: f32,
    drone_beat_len: [2]f32,
    pad_beat_len: [3]f32,
    melody_beat_len: [2]f32,
    arp_beat_len: [3]f32,
    lfo_filter: composition.SlowLfo,
    lfo_reverb: composition.SlowLfo,
    melody_phrase: composition.PhraseConfig,
    melody_min_notes: u8,
    melody_max_notes: u8,
    arp_phrase: composition.PhraseConfig,
    arp_min_notes: u8,
    arp_max_notes: u8,
};

const CUE_SPECS: [4]AmbientCueSpec = .{
    // dawn — Warm, rising, major-leaning, bright filters, gentle melody
    .{
        .scale_type = .major_pentatonic,
        .chord_change_beats = 14.0,
        .reverb_boost = 0.05,
        .melody_thresh = 0.25,
        .arp_thresh = 0.55,
        .drone_filter_base = 200.0,
        .drone_filter_range = 120.0,
        .pad_filter_base = 600.0,
        .pad_filter_range = 600.0,
        .melody_recall_chance = 0.35,
        .drone_env_attack = 3.5,
        .drone_env_release = 4.0,
        .pad_env_attack = 1.5,
        .pad_env_release = 3.0,
        .melody_env_attack = 0.08,
        .melody_env_decay = 2.5,
        .melody_env_release = 3.0,
        .arp_env_decay = 1.8,
        .arp_env_release = 2.5,
        .drone_beat_len = .{ 21.5, 27.75 },
        .pad_beat_len = .{ 11.25, 15.5, 19.75 },
        .melody_beat_len = .{ 7.5, 10.25 },
        .arp_beat_len = .{ 3.25, 4.75, 4.0 },
        .lfo_filter = .{ .period_beats = 80, .depth = 0.10 },
        .lfo_reverb = .{ .period_beats = 130, .depth = 0.05 },
        .melody_phrase = .{ .rest_chance = 0.45, .region_low = 8, .region_high = 15 },
        .melody_min_notes = 3,
        .melody_max_notes = 7,
        .arp_phrase = .{ .rest_chance = 0.4, .region_low = 13, .region_high = 18 },
        .arp_min_notes = 3,
        .arp_max_notes = 7,
    },
    // twilight — Dark, descending, minor, very filtered, sparse
    .{
        .scale_type = .natural_minor,
        .chord_change_beats = 20.0,
        .reverb_boost = 0.1,
        .melody_thresh = 0.45,
        .arp_thresh = 0.75,
        .drone_filter_base = 120.0,
        .drone_filter_range = 50.0,
        .pad_filter_base = 350.0,
        .pad_filter_range = 300.0,
        .melody_recall_chance = 0.4,
        .drone_env_attack = 5.0,
        .drone_env_release = 6.0,
        .pad_env_attack = 3.0,
        .pad_env_release = 4.5,
        .melody_env_attack = 0.2,
        .melody_env_decay = 3.0,
        .melody_env_release = 3.5,
        .arp_env_decay = 2.0,
        .arp_env_release = 3.0,
        .drone_beat_len = .{ 27.5, 33.75 },
        .pad_beat_len = .{ 17.25, 21.5, 25.75 },
        .melody_beat_len = .{ 11.5, 15.25 },
        .arp_beat_len = .{ 5.75, 7.25, 6.5 },
        .lfo_filter = .{ .period_beats = 120, .depth = 0.06 },
        .lfo_reverb = .{ .period_beats = 180, .depth = 0.05 },
        .melody_phrase = .{ .rest_chance = 0.65, .region_low = 7, .region_high = 12 },
        .melody_min_notes = 3,
        .melody_max_notes = 7,
        .arp_phrase = .{ .rest_chance = 0.6, .region_low = 11, .region_high = 15 },
        .arp_min_notes = 3,
        .arp_max_notes = 7,
    },
    // space — Very sparse, wide stereo, huge reverb, glacial pace
    .{
        .scale_type = .minor_pentatonic,
        .chord_change_beats = 24.0,
        .reverb_boost = 0.2,
        .melody_thresh = 0.4,
        .arp_thresh = 0.5,
        .drone_filter_base = 140.0,
        .drone_filter_range = 60.0,
        .pad_filter_base = 400.0,
        .pad_filter_range = 400.0,
        .melody_recall_chance = 0.5,
        .drone_env_attack = 6.0,
        .drone_env_release = 8.0,
        .pad_env_attack = 4.0,
        .pad_env_release = 5.0,
        .melody_env_attack = 0.3,
        .melody_env_decay = 4.0,
        .melody_env_release = 4.0,
        .arp_env_decay = 2.5,
        .arp_env_release = 3.5,
        .drone_beat_len = .{ 31.5, 37.75 },
        .pad_beat_len = .{ 19.25, 23.5, 29.75 },
        .melody_beat_len = .{ 13.5, 17.25 },
        .arp_beat_len = .{ 4.75, 6.25, 5.5 },
        .lfo_filter = .{ .period_beats = 150, .depth = 0.05 },
        .lfo_reverb = .{ .period_beats = 200, .depth = 0.06 },
        .melody_phrase = .{ .rest_chance = 0.6, .region_low = 9, .region_high = 16 },
        .melody_min_notes = 3,
        .melody_max_notes = 7,
        .arp_phrase = .{ .rest_chance = 0.45, .region_low = 14, .region_high = 19 },
        .arp_min_notes = 3,
        .arp_max_notes = 7,
    },
    // forest — Earthy, mid-register, moderate pace, bird-like melody ornaments
    .{
        .scale_type = .dorian,
        .chord_change_beats = 12.0,
        .reverb_boost = 0.0,
        .melody_thresh = 0.2,
        .arp_thresh = 0.4,
        .drone_filter_base = 180.0,
        .drone_filter_range = 100.0,
        .pad_filter_base = 550.0,
        .pad_filter_range = 450.0,
        .melody_recall_chance = 0.3,
        .drone_env_attack = 3.0,
        .drone_env_release = 4.0,
        .pad_env_attack = 1.5,
        .pad_env_release = 2.5,
        .melody_env_attack = 0.05,
        .melody_env_decay = 1.5,
        .melody_env_release = 2.0,
        .arp_env_decay = 0.8,
        .arp_env_release = 1.2,
        .drone_beat_len = .{ 19.5, 25.75 },
        .pad_beat_len = .{ 11.25, 14.5, 18.75 },
        .melody_beat_len = .{ 6.5, 9.25 },
        .arp_beat_len = .{ 2.75, 4.25, 3.5 },
        .lfo_filter = .{ .period_beats = 70, .depth = 0.09 },
        .lfo_reverb = .{ .period_beats = 110, .depth = 0.03 },
        .melody_phrase = .{ .rest_chance = 0.4, .region_low = 8, .region_high = 15 },
        .melody_min_notes = 3,
        .melody_max_notes = 6,
        .arp_phrase = .{ .rest_chance = 0.35, .region_low = 13, .region_high = 19 },
        .arp_min_notes = 3,
        .arp_max_notes = 6,
    },
};

const AmbientCueMorph = cue_morph.CueMorph(CuePreset);
var cue_state: AmbientCueMorph = .{
    .from = .dawn,
    .to = .dawn,
    .progress = 1.0,
    .morph_beats = 24.0,
};

const AmbientRuntimeCue = struct {
    reverb_boost: f32,
    melody_thresh: f32,
    arp_thresh: f32,
    drone_filter_base: f32,
    drone_filter_range: f32,
    pad_filter_base: f32,
    pad_filter_range: f32,
    melody_recall_chance: f32,
    drone_env_attack: f32,
    drone_env_release: f32,
    pad_env_attack: f32,
    pad_env_release: f32,
    melody_env_attack: f32,
    melody_env_decay: f32,
    melody_env_release: f32,
    arp_env_decay: f32,
    arp_env_release: f32,
    drone_beat_len: [2]f32,
    pad_beat_len: [3]f32,
    melody_beat_len: [2]f32,
    arp_beat_len: [3]f32,
    lfo_filter_period: f32,
    lfo_filter_depth: f32,
    lfo_reverb_period: f32,
    lfo_reverb_depth: f32,
    melody_rest_chance: f32,
    arp_rest_chance: f32,
};

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn blendedRuntimeCue() AmbientRuntimeCue {
    const from = CUE_SPECS[@intFromEnum(cue_state.from)];
    const to = CUE_SPECS[@intFromEnum(cue_state.to)];
    const t = cue_state.progress;

    var cue: AmbientRuntimeCue = undefined;
    cue.reverb_boost = lerpF32(from.reverb_boost, to.reverb_boost, t);
    cue.melody_thresh = lerpF32(from.melody_thresh, to.melody_thresh, t);
    cue.arp_thresh = lerpF32(from.arp_thresh, to.arp_thresh, t);
    cue.drone_filter_base = lerpF32(from.drone_filter_base, to.drone_filter_base, t);
    cue.drone_filter_range = lerpF32(from.drone_filter_range, to.drone_filter_range, t);
    cue.pad_filter_base = lerpF32(from.pad_filter_base, to.pad_filter_base, t);
    cue.pad_filter_range = lerpF32(from.pad_filter_range, to.pad_filter_range, t);
    cue.melody_recall_chance = lerpF32(from.melody_recall_chance, to.melody_recall_chance, t);
    cue.drone_env_attack = lerpF32(from.drone_env_attack, to.drone_env_attack, t);
    cue.drone_env_release = lerpF32(from.drone_env_release, to.drone_env_release, t);
    cue.pad_env_attack = lerpF32(from.pad_env_attack, to.pad_env_attack, t);
    cue.pad_env_release = lerpF32(from.pad_env_release, to.pad_env_release, t);
    cue.melody_env_attack = lerpF32(from.melody_env_attack, to.melody_env_attack, t);
    cue.melody_env_decay = lerpF32(from.melody_env_decay, to.melody_env_decay, t);
    cue.melody_env_release = lerpF32(from.melody_env_release, to.melody_env_release, t);
    cue.arp_env_decay = lerpF32(from.arp_env_decay, to.arp_env_decay, t);
    cue.arp_env_release = lerpF32(from.arp_env_release, to.arp_env_release, t);
    cue.lfo_filter_period = lerpF32(from.lfo_filter.period_beats, to.lfo_filter.period_beats, t);
    cue.lfo_filter_depth = lerpF32(from.lfo_filter.depth, to.lfo_filter.depth, t);
    cue.lfo_reverb_period = lerpF32(from.lfo_reverb.period_beats, to.lfo_reverb.period_beats, t);
    cue.lfo_reverb_depth = lerpF32(from.lfo_reverb.depth, to.lfo_reverb.depth, t);
    cue.melody_rest_chance = lerpF32(from.melody_phrase.rest_chance, to.melody_phrase.rest_chance, t);
    cue.arp_rest_chance = lerpF32(from.arp_phrase.rest_chance, to.arp_phrase.rest_chance, t);

    inline for (0..2) |i| {
        cue.drone_beat_len[i] = lerpF32(from.drone_beat_len[i], to.drone_beat_len[i], t);
        cue.melody_beat_len[i] = lerpF32(from.melody_beat_len[i], to.melody_beat_len[i], t);
    }
    inline for (0..3) |i| {
        cue.pad_beat_len[i] = lerpF32(from.pad_beat_len[i], to.pad_beat_len[i], t);
        cue.arp_beat_len[i] = lerpF32(from.arp_beat_len[i], to.arp_beat_len[i], t);
    }
    return cue;
}

// ============================================================
// Public API
// ============================================================

pub fn triggerCue() void {
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const eff_bpm = BASE_BPM * bpm;
    const spb = dsp.samplesPerBeat(eff_bpm);

    for (0..frames) |i| {
        cue_morph.advance(CuePreset, &cue_state, spb);
        const cue = blendedRuntimeCue();
        lfo_filter.period_beats = cue.lfo_filter_period;
        lfo_filter.depth = cue.lfo_filter_depth;
        lfo_reverb.period_beats = cue.lfo_reverb_period;
        lfo_reverb.depth = cue.lfo_reverb_depth;
        composition.slowLfoAdvanceSample(&lfo_filter, eff_bpm);
        composition.slowLfoAdvanceSample(&lfo_reverb, eff_bpm);
        const director_intensity = composition.compositionEngineLongFormIntensity(&engine);
        const director_cadence = composition.compositionEngineLongFormCadenceSpread(&engine);
        const director_mod = composition.compositionEngineLongFormModulationDrive(&engine);
        const cadence_warp = std.math.clamp(1.0 + (director_cadence - 0.16) * 0.34 + composition.slowLfoValue(&lfo_filter) * 0.55, 0.72, 1.35);
        inline for (0..2) |j| {
            drone_layer.beat_len[j] = cue.drone_beat_len[j] * cadence_warp;
            melody_layer.beat_len[j] = cue.melody_beat_len[j] * cadence_warp;
        }
        inline for (0..3) |j| {
            pad_layer.beat_len[j] = cue.pad_beat_len[j] * cadence_warp;
            arp_layer.beat_len[j] = cue.arp_beat_len[j] * cadence_warp;
        }
        for (0..layers.AmbientMelodyLayer.COUNT) |m| {
            melody_layer.phrases[m].rest_chance = cue.melody_rest_chance;
        }
        for (0..layers.AmbientArpLayer.COUNT) |a| {
            arp_layer.phrases[a].rest_chance = cue.arp_rest_chance;
        }
        const tick = composition.compositionEngineAdvanceSample(&engine, &rng, eff_bpm);

        if (tick.chord_changed) {
            advanceChord();
        }

        // === Vertical layer activation ===
        const melody_thresh = std.math.clamp(cue.melody_thresh + (0.5 - director_intensity) * 0.18, 0.05, 0.94);
        const arp_thresh = std.math.clamp(cue.arp_thresh + (0.42 - director_intensity) * 0.22 + director_mod * 0.08, 0.08, 0.97);
        drone_target = std.math.clamp(0.76 + tick.macro * 0.21 + (1.0 - director_intensity) * 0.08, 0.0, 1.0);
        pad_target = std.math.clamp(0.18 + tick.macro * 0.79 + director_mod * 0.05, 0.0, 1.0);
        melody_target = if (tick.macro > melody_thresh) std.math.clamp((tick.macro - melody_thresh) * (1.0 + director_intensity * 0.45), 0.0, 0.88) else 0.0;
        arp_target = if (tick.macro > arp_thresh) std.math.clamp((tick.macro - arp_thresh) * (1.05 + director_cadence * 0.7), 0.0, 0.7) else 0.0;

        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        melody_level += (melody_target - melody_level) * LAYER_FADE_RATE;
        arp_level += (arp_target - arp_level) * LAYER_FADE_RATE;

        var left: f32 = 0;
        var right: f32 = 0;

        layers.advanceAmbientDroneLayer(&drone_layer, &rng, &engine.key, spb, tick.meso, cue.drone_filter_base, cue.drone_filter_range, composition.slowLfoModulate(&lfo_filter), cue.drone_env_attack, cue.drone_env_release);
        layers.advanceAmbientPadLayer(&pad_layer, &engine.key, spb, tick.meso, cue.pad_filter_base, cue.pad_filter_range, composition.slowLfoModulate(&lfo_filter), cue.pad_env_attack, cue.pad_env_release);
        const melody_recall = std.math.clamp(cue.melody_recall_chance * (0.95 - director_cadence * 0.45) + (1.0 - director_intensity) * 0.08, 0.04, 0.86);
        layers.advanceAmbientMelodyLayer(&melody_layer, &rng, &engine.key, spb, tick.meso, tick.micro, melody_recall, cue.melody_env_attack, cue.melody_env_decay, cue.melody_env_release);
        layers.advanceAmbientArpLayer(&arp_layer, &rng, &engine.key, spb, tick.meso, tick.micro, cue.arp_env_decay, cue.arp_env_release);

        const drone_out = layers.mixAmbientDroneLayer(&drone_layer, drone_vol * drone_level);
        left += drone_out[0];
        right += drone_out[1];

        const pad_out = layers.mixAmbientPadLayer(&pad_layer, pad_vol * pad_level);
        left += pad_out[0];
        right += pad_out[1];

        const melody_out = layers.mixAmbientMelodyLayer(&melody_layer, melody_vol * melody_level);
        left += melody_out[0];
        right += melody_out[1];

        const arp_out = layers.mixAmbientArpLayer(&arp_layer, arp_vol * arp_level);
        left += arp_out[0];
        right += arp_out[1];

        // === Reverb ===
        const rev_mix = std.math.clamp((reverb_mix + cue.reverb_boost + director_mod * 0.05) * composition.slowLfoModulate(&lfo_reverb), 0.0, 0.98);
        const dry = 1.0 - rev_mix;
        const rev = dsp.stereoReverbProcess(.{1759, 1693, 1623, 1548}, .{245, 605}, &reverb, .{ left, right });
        left = left * dry + rev[0] * rev_mix;
        right = right * dry + rev[1] * rev_mix;

        buf[i * 2] = softClip(left);
        buf[i * 2 + 1] = softClip(right);
    }
}

// ============================================================
// Cue parameter application
// ============================================================

fn applyCueParams() void {
    cue_morph.setTarget(CuePreset, &cue_state, selected_cue);
    const spec = CUE_SPECS[@intFromEnum(cue_state.to)];
    engine.key.scale_type = spec.scale_type;
    composition.compositionEngineSetChordChangeBeats(&engine, spec.chord_change_beats);
    for (0..layers.AmbientMelodyLayer.COUNT) |m| {
        melody_layer.phrases[m].region_low = spec.melody_phrase.region_low;
        melody_layer.phrases[m].region_high = spec.melody_phrase.region_high;
        melody_layer.phrases[m].min_notes = spec.melody_min_notes;
        melody_layer.phrases[m].max_notes = spec.melody_max_notes;
    }
    for (0..layers.AmbientArpLayer.COUNT) |a| {
        arp_layer.phrases[a].region_low = spec.arp_phrase.region_low;
        arp_layer.phrases[a].region_high = spec.arp_phrase.region_high;
        arp_layer.phrases[a].min_notes = spec.arp_min_notes;
        arp_layer.phrases[a].max_notes = spec.arp_max_notes;
    }
}

// ============================================================
// Chord & note triggering
// ============================================================

fn advanceChord() void {
    const chord = engine.harmony.chords[engine.harmony.current];
    layers.applyAmbientMelodyChord(&melody_layer, &engine.harmony, engine.key.scale_type);
    layers.applyAmbientArpChord(&arp_layer, &engine.harmony, engine.key.scale_type);
    layers.applyAmbientPadChord(&pad_layer, engine.key.root, engine.key.scale_type, chord);
}

// ============================================================
// Reset
// ============================================================

pub fn reset() void {
    rng = dsp.rngInit(entropy.nextSeed(0xA6B1_0001, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    composition.compositionEngineReset(&engine, .{ .root = 36, .scale_type = .minor_pentatonic }, initHarmony(), AMBIENT_ARCS, 16.0, .mixed);
    lfo_filter = .{ .period_beats = 90, .depth = 0.08 };
    lfo_reverb = .{ .period_beats = 150, .depth = 0.04 };
    layers.resetAmbientDroneLayer(&drone_layer);
    layers.resetAmbientPadLayer(&pad_layer);
    layers.resetAmbientMelodyLayer(&melody_layer);
    layers.resetAmbientArpLayer(&arp_layer);

    drone_target = 1.0;
    pad_target = 1.0;
    melody_target = 0.5;
    arp_target = 0.0;
    drone_level = 1.0;
    pad_level = 0.3;
    melody_level = 0.0;
    arp_level = 0.0;

    reverb = dsp.stereoReverbInit(.{1759, 1693, 1623, 1548}, .{245, 605}, .{ 0.87, 0.88, 0.89, 0.86 });
    applyCueParams();
    advanceChord();
}
