// Procedural monastic choir style — v2 composition engine.
//
// Uses chord progression, multi-scale arcs, chant motif memory, macro key
// movement, and cue-specific timing so the presets diverge both harmonically
// and behaviorally over time.
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

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
var rng: dsp.Rng = dsp.Rng.init(0x4300_9000);

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

var chant_phrase_template: composition.PhraseGenerator = .{
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

var cue_reverb_boost: f32 = 0.0;
var cue_breath_boost: f32 = 0.0;
var cue_chant_recall_chance: f32 = 0.3;
var cue_chant_threshold: f32 = 0.35;
var cue_chord_change_beats: f32 = 16.0;
var cue_chant_beat_len: f32 = 2.0;
var cue_pad_attack: f32 = 1.4;
var cue_pad_release: f32 = 5.8;
var cue_chant_attack: f32 = 0.18;
var cue_chant_release: f32 = 1.6;

pub fn reset() void {
    reverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
    rng = dsp.Rng.init(0x4300_9000 + @as(u32, @intFromEnum(selected_cue)) * 23);
    engine.reset(.{ .root = 38, .scale_type = .natural_minor }, initHarmony(), CHOIR_ARCS, 16.0, .none);
    lfo_reverb = .{ .period_beats = 180, .depth = 0.04 };
    drone_target = 0.9;
    pad_target = 0.75;
    chant_target = 0.2;
    breath_target = 0.35;
    drone_level = 0.8;
    pad_level = 0.5;
    chant_level = 0.0;
    breath_level = 0.25;
    chant_phrase_template = .{
        .anchor = 12,
        .region_low = 9,
        .region_high = 16,
        .rest_chance = 0.18,
        .min_notes = 4,
        .max_notes = 8,
        .gravity = 3.5,
    };
    layers.resetChoirPadLayer(&pad_layer);
    layers.resetChoirChantLayer(&chant_layer, chant_phrase_template);
    layers.resetDroneLayer(&drone_layer, .{
        .freq = dsp.midiToFreq(36),
        .detune_ratio = 1.0016,
        .primary_mix = 0.78,
        .secondary_mix = 0.32,
        .volume = 0.32,
        .filter = dsp.LPF.init(180.0),
    });
    layers.resetBreathLayer(&breath_layer);
    chant_beat_counter = 0.0;
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
    chant_beat_counter = 0.0;
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = dsp.samplesPerBeat(bpm);

    for (0..frames) |i| {
        lfo_reverb.advanceSample(bpm);
        engine.chord_change_beats = cue_chord_change_beats;
        const tick = engine.advanceSample(&rng, bpm);
        if (tick.chord_changed) {
            advanceChord();
        }

        chant_beat_counter += 1.0 / spb;
        if (chant_beat_counter >= cue_chant_beat_len) {
            chant_beat_counter -= cue_chant_beat_len;
            triggerChantNote(tick.meso, tick.micro);
        }

        updateLayerTargets(tick.macro);
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

        const breath_out = layers.mixBreathLayer(&breath_layer, &rng, breathiness, cue_breath_boost, tick.meso, breath_level);
        left += breath_out[0];
        right += breath_out[1];

        const wet = (reverb_mix + cue_reverb_boost) * lfo_reverb.modulate();
        const dry = 1.0 - wet;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.88);
        buf[i * 2 + 1] = softClip(right * 0.88);
    }
}

fn applyCueParams() void {
    switch (selected_cue) {
        .cathedral => {
            engine.key.root = 38;
            engine.key.target_root = 38;
            cue_reverb_boost = 0.08;
            cue_breath_boost = 0.05;
            cue_chant_recall_chance = 0.28;
            cue_chant_threshold = 0.25;
            cue_chord_change_beats = 18.0;
            cue_chant_beat_len = 2.5;
            cue_pad_attack = 2.0;
            cue_pad_release = 7.5;
            cue_chant_attack = 0.22;
            cue_chant_release = 2.1;
            layers.applyChoirChantCue(&chant_layer, .{
                .phrase = .{ .rest_chance = 0.24, .region_low = 9, .region_high = 15 },
                .min_notes = 4,
                .max_notes = 7,
                .recall_chance = cue_chant_recall_chance,
                .attack = cue_chant_attack,
                .release = cue_chant_release,
            });
            layers.applyDroneCue(&drone_layer, 160.0, 1.0012);
        },
        .procession => {
            engine.key.root = 40;
            engine.key.target_root = 40;
            cue_reverb_boost = 0.02;
            cue_breath_boost = 0.0;
            cue_chant_recall_chance = 0.22;
            cue_chant_threshold = 0.12;
            cue_chord_change_beats = 12.0;
            cue_chant_beat_len = 1.5;
            cue_pad_attack = 1.0;
            cue_pad_release = 4.5;
            cue_chant_attack = 0.12;
            cue_chant_release = 1.2;
            layers.applyChoirChantCue(&chant_layer, .{
                .phrase = .{ .rest_chance = 0.14, .region_low = 10, .region_high = 17 },
                .min_notes = 5,
                .max_notes = 8,
                .recall_chance = cue_chant_recall_chance,
                .attack = cue_chant_attack,
                .release = cue_chant_release,
            });
            layers.applyDroneCue(&drone_layer, 220.0, 1.0018);
        },
        .vigil => {
            engine.key.root = 36;
            engine.key.target_root = 36;
            cue_reverb_boost = 0.12;
            cue_breath_boost = 0.12;
            cue_chant_recall_chance = 0.4;
            cue_chant_threshold = 0.5;
            cue_chord_change_beats = 22.0;
            cue_chant_beat_len = 3.5;
            cue_pad_attack = 2.6;
            cue_pad_release = 8.5;
            cue_chant_attack = 0.28;
            cue_chant_release = 2.6;
            layers.applyChoirChantCue(&chant_layer, .{
                .phrase = .{ .rest_chance = 0.36, .region_low = 8, .region_high = 13 },
                .min_notes = 3,
                .max_notes = 5,
                .recall_chance = cue_chant_recall_chance,
                .attack = cue_chant_attack,
                .release = cue_chant_release,
            });
            layers.applyDroneCue(&drone_layer, 130.0, 1.0009);
        },
        .crusade => {
            engine.key.root = 41;
            engine.key.target_root = 41;
            cue_reverb_boost = 0.0;
            cue_breath_boost = -0.05;
            cue_chant_recall_chance = 0.18;
            cue_chant_threshold = 0.08;
            cue_chord_change_beats = 10.0;
            cue_chant_beat_len = 1.0;
            cue_pad_attack = 0.8;
            cue_pad_release = 3.6;
            cue_chant_attack = 0.08;
            cue_chant_release = 0.95;
            layers.applyChoirChantCue(&chant_layer, .{
                .phrase = .{ .rest_chance = 0.08, .region_low = 11, .region_high = 18 },
                .min_notes = 5,
                .max_notes = 9,
                .recall_chance = cue_chant_recall_chance,
                .attack = cue_chant_attack,
                .release = cue_chant_release,
            });
            layers.applyDroneCue(&drone_layer, 240.0, 1.0021);
        },
    }
    engine.key.scale_type = switch (selected_cue) {
        .cathedral => .dorian,
        .procession => .mixolydian,
        .vigil => .harmonic_minor,
        .crusade => .natural_minor,
    };
    engine.modulation_mode = if (selected_cue == .crusade) .fourth else .none;
}

fn advanceChord() void {
    const chord = engine.harmony.chords[engine.harmony.current];
    layers.applyChoirPadChord(&pad_layer, engine.key.root, chord, cue_pad_attack, cue_pad_release, @intFromEnum(selected_cue), engine.harmony.current);
    layers.applyChoirChantChord(&chant_layer, engine.key.root, &engine.harmony, engine.key.scale_type, @intFromEnum(selected_cue));
    layers.applyDroneChord(&drone_layer, engine.key.root, chord, -1);
}

fn triggerChantNote(meso: f32, micro: f32) void {
    layers.maybeTriggerChoirChant(&chant_layer, &rng, &engine.key, chant_level, meso, micro, .{
        .phrase = .{
            .rest_chance = chant_layer.phrase.rest_chance,
            .region_low = chant_layer.phrase.region_low,
            .region_high = chant_layer.phrase.region_high,
        },
        .min_notes = chant_layer.phrase.min_notes,
        .max_notes = chant_layer.phrase.max_notes,
        .recall_chance = cue_chant_recall_chance,
        .attack = cue_chant_attack,
        .release = cue_chant_release,
    });
}

fn updateLayerTargets(macro: f32) void {
    drone_target = 0.65 + macro * 0.35;
    pad_target = 0.3 + macro * 0.7;
    chant_target = if (macro > cue_chant_threshold) @min((macro - cue_chant_threshold) * 1.25, 0.95) else 0.0;
    breath_target = 0.18 + (1.0 - macro) * 0.35;
}
