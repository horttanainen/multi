// Procedural monastic choir style — v2 composition engine.
//
// Uses chord progression, multi-scale arcs, chant motif memory, macro key
// movement, and cue-specific timing so the presets diverge both harmonically
// and behaviorally over time.
const dsp = @import("music/dsp.zig");
const std = @import("std");
const composition = @import("music/composition.zig");
const cue_morph = @import("music/cue_morph.zig");
const entropy = @import("music/entropy.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

pub const CuePreset = enum(u8) {
    cathedral,
    procession,
    vigil,
    crusade,
};

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 44.0;
pub var reverb_mix: f32 = 0.72;
pub var choir_vol: f32 = 0.15;
pub var breathiness: f32 = 0.3;
pub var drone_mix: f32 = 0.55;
pub var chant_mix: f32 = 0.58;
pub var selected_cue: CuePreset = .cathedral;

const ChoirReverb = StereoReverb(.{ 2039, 1877, 1733, 1601 }, .{ 307, 709 });
var reverb: ChoirReverb = dsp.stereoReverbInit(.{2039, 1877, 1733, 1601}, .{307, 709}, .{ 0.93, 0.94, 0.93, 0.92 });
var rng: dsp.Rng = dsp.rngInit(0x4300_9000);

var engine: composition.CompositionEngine = .{};

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 10 }, .len = 4 };
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 15 }, .len = 4 };
    h.chords[2] = .{ .offsets = .{ 5, 8, 12, 15 }, .len = 4 };
    h.chords[3] = .{ .offsets = .{ 7, 10, 14, 17 }, .len = 4 };
    h.chords[4] = .{ .offsets = .{ 10, 14, 17, 22 }, .len = 4 };
    h.num_chords = 5;
    h.transitions[0] = .{ 0.10, 0.18, 0.28, 0.16, 0.28, 0, 0, 0 };
    h.transitions[1] = .{ 0.26, 0.10, 0.24, 0.10, 0.30, 0, 0, 0 };
    h.transitions[2] = .{ 0.28, 0.14, 0.10, 0.22, 0.26, 0, 0, 0 };
    h.transitions[3] = .{ 0.24, 0.14, 0.20, 0.10, 0.32, 0, 0, 0 };
    h.transitions[4] = .{ 0.34, 0.12, 0.18, 0.14, 0.22, 0, 0, 0 };
    return h;
}

const CHOIR_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 16, .shape = .rise_fall },
    .meso = .{ .section_beats = 64, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};
var lfo_reverb: composition.SlowLfo = .{ .period_beats = 180, .depth = 0.04 };

var drone_target: f32 = 0.9;
var pad_target: f32 = 0.75;
var chant_target: f32 = 0.2;
var breath_target: f32 = 0.35;

var drone_level: f32 = 0.8;
var pad_level: f32 = 0.5;
var chant_level: f32 = 0.0;
var breath_level: f32 = 0.25;

const LAYER_FADE_RATE: f32 = 0.000025;

const CHANT_PHRASE_TEMPLATE: composition.PhraseGenerator = .{
    .anchor = 12,
    .region_low = 9,
    .region_high = 16,
    .rest_chance = 0.18,
    .min_notes = 4,
    .max_notes = 8,
    .gravity = 3.5,
};
var pad_layer: layers.ChoirPadLayer = .{};
var chant_layer: layers.ChoirChantLayer = .{};
var drone_layer: layers.DroneLayer = .{};
var breath_layer: layers.BreathLayer = .{};

var chant_beat_counter: f32 = 0.0;

// ============================================================
// Cue specs (static data describing each flavor)
// ============================================================

const ChoirCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    modulation_mode: composition.ModulationMode,
    chord_change_beats: f32,
    chant_beat_len: f32,
    reverb_boost: f32,
    breath_boost: f32,
    chant_threshold: f32,
    pad_attack: f32,
    pad_release: f32,
    chant_rest_chance: f32,
    chant_region_low: u8,
    chant_region_high: u8,
    chant_min_notes: u8,
    chant_max_notes: u8,
    chant_recall_chance: f32,
    chant_attack: f32,
    chant_release: f32,
    drone_filter_hz: f32,
    drone_detune_ratio: f32,
};

const CUE_SPECS: [4]ChoirCueSpec = .{
    // cathedral
    .{
        .root = 38,
        .scale_type = .dorian,
        .modulation_mode = .none,
        .chord_change_beats = 18.0,
        .chant_beat_len = 2.5,
        .reverb_boost = 0.08,
        .breath_boost = 0.05,
        .chant_threshold = 0.25,
        .pad_attack = 2.0,
        .pad_release = 7.5,
        .chant_rest_chance = 0.24,
        .chant_region_low = 9,
        .chant_region_high = 15,
        .chant_min_notes = 4,
        .chant_max_notes = 7,
        .chant_recall_chance = 0.28,
        .chant_attack = 0.22,
        .chant_release = 2.1,
        .drone_filter_hz = 160.0,
        .drone_detune_ratio = 1.0012,
    },
    // procession
    .{
        .root = 40,
        .scale_type = .mixolydian,
        .modulation_mode = .none,
        .chord_change_beats = 12.0,
        .chant_beat_len = 1.5,
        .reverb_boost = 0.02,
        .breath_boost = 0.0,
        .chant_threshold = 0.12,
        .pad_attack = 1.0,
        .pad_release = 4.5,
        .chant_rest_chance = 0.14,
        .chant_region_low = 10,
        .chant_region_high = 17,
        .chant_min_notes = 5,
        .chant_max_notes = 8,
        .chant_recall_chance = 0.22,
        .chant_attack = 0.12,
        .chant_release = 1.2,
        .drone_filter_hz = 220.0,
        .drone_detune_ratio = 1.0018,
    },
    // vigil
    .{
        .root = 36,
        .scale_type = .harmonic_minor,
        .modulation_mode = .none,
        .chord_change_beats = 22.0,
        .chant_beat_len = 3.5,
        .reverb_boost = 0.12,
        .breath_boost = 0.12,
        .chant_threshold = 0.5,
        .pad_attack = 2.6,
        .pad_release = 8.5,
        .chant_rest_chance = 0.36,
        .chant_region_low = 8,
        .chant_region_high = 13,
        .chant_min_notes = 3,
        .chant_max_notes = 5,
        .chant_recall_chance = 0.4,
        .chant_attack = 0.28,
        .chant_release = 2.6,
        .drone_filter_hz = 130.0,
        .drone_detune_ratio = 1.0009,
    },
    // crusade
    .{
        .root = 41,
        .scale_type = .natural_minor,
        .modulation_mode = .fourth,
        .chord_change_beats = 10.0,
        .chant_beat_len = 1.0,
        .reverb_boost = 0.0,
        .breath_boost = -0.05,
        .chant_threshold = 0.08,
        .pad_attack = 0.8,
        .pad_release = 3.6,
        .chant_rest_chance = 0.08,
        .chant_region_low = 11,
        .chant_region_high = 18,
        .chant_min_notes = 5,
        .chant_max_notes = 9,
        .chant_recall_chance = 0.18,
        .chant_attack = 0.08,
        .chant_release = 0.95,
        .drone_filter_hz = 240.0,
        .drone_detune_ratio = 1.0021,
    },
};

const ChoirCueMorph = cue_morph.CueMorph(CuePreset);
var cue_state: ChoirCueMorph = .{
    .from = .cathedral,
    .to = .cathedral,
    .progress = 1.0,
    .morph_beats = 24.0,
};

const ChoirRuntimeCue = struct {
    chant_beat_len: f32,
    reverb_boost: f32,
    breath_boost: f32,
    chant_threshold: f32,
    pad_attack: f32,
    pad_release: f32,
    chant_rest_chance: f32,
    chant_recall_chance: f32,
    chant_attack: f32,
    chant_release: f32,
    drone_filter_hz: f32,
    drone_detune_ratio: f32,
};

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn blendedRuntimeCue() ChoirRuntimeCue {
    const from = CUE_SPECS[@intFromEnum(cue_state.from)];
    const to = CUE_SPECS[@intFromEnum(cue_state.to)];
    const t = cue_state.progress;
    return .{
        .chant_beat_len = lerpF32(from.chant_beat_len, to.chant_beat_len, t),
        .reverb_boost = lerpF32(from.reverb_boost, to.reverb_boost, t),
        .breath_boost = lerpF32(from.breath_boost, to.breath_boost, t),
        .chant_threshold = lerpF32(from.chant_threshold, to.chant_threshold, t),
        .pad_attack = lerpF32(from.pad_attack, to.pad_attack, t),
        .pad_release = lerpF32(from.pad_release, to.pad_release, t),
        .chant_rest_chance = lerpF32(from.chant_rest_chance, to.chant_rest_chance, t),
        .chant_recall_chance = lerpF32(from.chant_recall_chance, to.chant_recall_chance, t),
        .chant_attack = lerpF32(from.chant_attack, to.chant_attack, t),
        .chant_release = lerpF32(from.chant_release, to.chant_release, t),
        .drone_filter_hz = lerpF32(from.drone_filter_hz, to.drone_filter_hz, t),
        .drone_detune_ratio = lerpF32(from.drone_detune_ratio, to.drone_detune_ratio, t),
    };
}

pub fn reset() void {
    reverb = dsp.stereoReverbInit(.{2039, 1877, 1733, 1601}, .{307, 709}, .{ 0.93, 0.94, 0.93, 0.92 });
    rng = dsp.rngInit(entropy.nextSeed(0x4300_9000, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    composition.compositionEngineReset(&engine, .{ .root = 38, .scale_type = .natural_minor }, initHarmony(), CHOIR_ARCS, 16.0, .none);
    lfo_reverb = .{ .period_beats = 180, .depth = 0.04 };
    drone_target = 0.9;
    pad_target = 0.75;
    chant_target = 0.2;
    breath_target = 0.35;
    drone_level = 0.8;
    pad_level = 0.5;
    chant_level = 0.0;
    breath_level = 0.25;
    layers.resetChoirPadLayer(&pad_layer);
    layers.resetChoirChantLayer(&chant_layer, CHANT_PHRASE_TEMPLATE);
    layers.resetDroneLayer(&drone_layer, .{
        .freq = dsp.midiToFreq(36),
        .detune_ratio = 1.0016,
        .primary_mix = 0.78,
        .secondary_mix = 0.32,
        .volume = 0.32,
        .filter = dsp.lpfInit(180.0),
    });
    layers.resetBreathLayer(&breath_layer);
    chant_beat_counter = 0.0;
    applyCueParams();
    const cue = blendedRuntimeCue();
    advanceChord(&cue);
}

pub fn triggerCue() void {
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const eff_bpm = BASE_BPM * bpm;
    const spb = dsp.samplesPerBeat(eff_bpm);

    for (0..frames) |i| {
        cue_morph.advance(CuePreset, &cue_state, spb);
        const cue = blendedRuntimeCue();
        layers.applyDroneCue(&drone_layer, cue.drone_filter_hz, cue.drone_detune_ratio);
        composition.slowLfoAdvanceSample(&lfo_reverb, eff_bpm);
        const tick = composition.compositionEngineAdvanceSample(&engine, &rng, eff_bpm);
        const director_intensity = composition.compositionEngineLongFormIntensity(&engine);
        const director_cadence = composition.compositionEngineLongFormCadenceSpread(&engine);
        const director_mod = composition.compositionEngineLongFormModulationDrive(&engine);
        if (tick.chord_changed) {
            advanceChord(&cue);
        }

        chant_beat_counter += 1.0 / spb;
        const chant_beat_len = std.math.clamp(cue.chant_beat_len * (1.0 + (director_cadence - 0.16) * 0.45 + composition.slowLfoValue(&lfo_reverb) * 0.7), 0.6, 6.0);
        if (chant_beat_counter >= chant_beat_len) {
            chant_beat_counter -= chant_beat_len;
            triggerChantNote(tick.meso, tick.micro, &cue, director_intensity, director_cadence);
        }

        const chant_threshold = std.math.clamp(cue.chant_threshold + (0.5 - director_intensity) * 0.14 - director_mod * 0.06, 0.04, 0.92);
        updateLayerTargets(tick.macro, chant_threshold, director_intensity, director_mod);
        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        chant_level += (chant_target - chant_level) * LAYER_FADE_RATE;
        breath_level += (breath_target - breath_level) * LAYER_FADE_RATE;

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const drone_out = layers.mixDroneLayer(&drone_layer, drone_mix * choir_vol * drone_level * 0.9);
        left += drone_out[0];
        right += drone_out[1];

        const pad_out = layers.mixChoirPadLayer(&pad_layer, choir_vol * pad_level);
        left += pad_out[0];
        right += pad_out[1];

        const chant_out = layers.mixChoirChantLayer(&chant_layer, choir_vol * chant_level, chant_mix);
        left += chant_out[0];
        right += chant_out[1];

        const breath_out = layers.mixBreathLayer(&breath_layer, &rng, breathiness, cue.breath_boost, tick.meso, breath_level);
        left += breath_out[0];
        right += breath_out[1];

        const wet = std.math.clamp((reverb_mix + cue.reverb_boost + director_mod * 0.05) * composition.slowLfoModulate(&lfo_reverb), 0.0, 0.99);
        const dry = 1.0 - wet;
        const rev = dsp.stereoReverbProcess(.{2039, 1877, 1733, 1601}, .{307, 709}, &reverb, .{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.88);
        buf[i * 2 + 1] = softClip(right * 0.88);
    }
}

fn applyCueParams() void {
    cue_morph.setTarget(CuePreset, &cue_state, selected_cue);
    const spec = CUE_SPECS[@intFromEnum(cue_state.to)];
    engine.key.root = spec.root;
    engine.key.target_root = spec.root;
    engine.key.scale_type = spec.scale_type;
    engine.modulation_mode = spec.modulation_mode;
    composition.compositionEngineSetChordChangeBeats(&engine, spec.chord_change_beats);
    layers.applyChoirChantCue(&chant_layer, .{
        .phrase = .{ .rest_chance = chant_layer.phrase.rest_chance, .region_low = spec.chant_region_low, .region_high = spec.chant_region_high },
        .min_notes = spec.chant_min_notes,
        .max_notes = spec.chant_max_notes,
        .recall_chance = 0.0,
        .attack = 0.1,
        .release = 0.1,
    });
}

fn advanceChord(cue: *const ChoirRuntimeCue) void {
    const chord = engine.harmony.chords[engine.harmony.current];
    const cue_id = @intFromEnum(cue_state.to);
    layers.applyChoirPadChord(&pad_layer, engine.key.root, chord, cue.pad_attack, cue.pad_release, cue_id, engine.harmony.current);
    layers.applyChoirChantChord(&chant_layer, engine.key.root, &engine.harmony, engine.key.scale_type, cue_id);
    layers.applyDroneChord(&drone_layer, engine.key.root, chord, -1);
}

fn triggerChantNote(meso: f32, micro: f32, cue: *const ChoirRuntimeCue, director_intensity: f32, director_cadence: f32) void {
    const target_spec = CUE_SPECS[@intFromEnum(cue_state.to)];
    const recall = std.math.clamp(cue.chant_recall_chance * (0.96 - director_cadence * 0.5) + (1.0 - director_intensity) * 0.08, 0.04, 0.86);
    const rest = std.math.clamp(cue.chant_rest_chance + director_cadence * 0.08 - director_intensity * 0.05, 0.03, 0.78);
    layers.maybeTriggerChoirChant(&chant_layer, &rng, &engine.key, chant_level, meso, micro, .{
        .phrase = .{ .rest_chance = rest, .region_low = target_spec.chant_region_low, .region_high = target_spec.chant_region_high },
        .min_notes = target_spec.chant_min_notes,
        .max_notes = target_spec.chant_max_notes,
        .recall_chance = recall,
        .attack = cue.chant_attack,
        .release = cue.chant_release,
    });
}

fn updateLayerTargets(macro: f32, chant_threshold: f32, director_intensity: f32, director_mod: f32) void {
    drone_target = std.math.clamp(0.62 + macro * 0.35 + (1.0 - director_intensity) * 0.1, 0.0, 1.0);
    pad_target = std.math.clamp(0.26 + macro * 0.72 + director_mod * 0.05, 0.0, 1.0);
    chant_target = if (macro > chant_threshold) std.math.clamp((macro - chant_threshold) * (1.22 + director_intensity * 0.35), 0.0, 1.0) else 0.0;
    breath_target = std.math.clamp(0.16 + (1.0 - macro) * 0.35 + director_mod * 0.06, 0.0, 1.0);
}
