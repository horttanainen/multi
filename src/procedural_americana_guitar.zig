const std = @import("std");
const composition = @import("music/composition.zig");
const cue_morph = @import("music/cue_morph.zig");
const dsp = @import("music/dsp.zig");
const entropy = @import("music/entropy.zig");
const human_performance = @import("music/human_performance.zig");
const instruments = @import("music/instruments.zig");
const pattern_history = @import("music/pattern_history.zig");

const softClip = dsp.softClip;

pub var bpm: f32 = 1.0;
pub var reverb_mix: f32 = 0.06;
pub var guitar_vol: f32 = 0.86;
pub var selected_cue: CuePreset = .open_road;
pub var selected_instrument: InstrumentFlavor = .guitar;

const BASE_VELOCITY: f32 = 0.62;
const NOTE_TAIL_SECONDS: f32 = 0.745;
const NOTE_TAIL_SAMPLES: u32 = @intFromFloat(NOTE_TAIL_SECONDS * dsp.SAMPLE_RATE);
const BANJO_NOTE_TAIL_SECONDS: f32 = 0.38;
const BANJO_NOTE_TAIL_SAMPLES: u32 = @intFromFloat(BANJO_NOTE_TAIL_SECONDS * dsp.SAMPLE_RATE);
const ELECTRIC_NOTE_TAIL_SECONDS: f32 = 1.1;
const ELECTRIC_NOTE_TAIL_SAMPLES: u32 = @intFromFloat(ELECTRIC_NOTE_TAIL_SECONDS * dsp.SAMPLE_RATE);
const VOICE_COUNT = 12;
const PENDING_COUNT = 12;
const STRING_COUNT = 6;
const MAX_PATTERN_EVENTS = 12;
const MAX_MOTIF_EVENTS = 5;
const MUTED_FRET: i8 = -1;
const ROOT_D2: u8 = 38;
const CHORD_CHANGE_BEATS: f32 = 16.0;
const GESTURE_HISTORY_SIZE: usize = 10;
const GUITAR_REVERB_SEND_SCALE: f32 = 0.44;
const GUITAR_REVERB_MAX_WET: f32 = 0.62;
const GUITAR_REVERB_RETURN_GAIN: f32 = 2.4;
const GUITAR_REVERB_DRY_DUCK: f32 = 0.35;

const OPEN_STRING_MIDI: [STRING_COUNT]u8 = .{ 38, 45, 50, 55, 59, 64 };
const BANJO_STRING_MIDI: [STRING_COUNT]u8 = .{ 50, 55, 59, 62, 67, 74 };
const ELECTRIC_STRING_MIDI: [STRING_COUNT]u8 = .{ 40, 45, 50, 55, 59, 64 };
const STRING_PAN: [STRING_COUNT]f32 = .{ -0.12, -0.08, -0.03, 0.04, 0.09, 0.14 };

const GuitarReverb = dsp.StereoReverb(.{ 1301, 1511, 1741, 1999 }, .{ 353, 941 });

pub const InstrumentFlavor = enum(u8) {
    guitar,
    banjo,
    electric,
};

pub const CuePreset = enum(u8) {
    open_road,
    low_drone,
    rolling_travis,
    high_lonesome,
};

const ChordId = enum(u8) {
    d5,
    dsus2,
    g_over_d,
    a7sus4_over_d,
    cadd9_over_d,
};

const PatternId = enum(u8) {
    sparse_alternation,
    travis,
    slow_arpeggio,
    drone_brush,
};

const MotifId = enum(u8) {
    low_answer,
    held_top,
    high_answer,
    rest_space,
};

const EvolutionKind = enum(u8) {
    motif,
    pattern,
    density,
};

const ChordShape = struct {
    id: ChordId,
    frets: [STRING_COUNT]i8,
};

const StringEvent = struct {
    step: u8 = 0,
    string: u8 = 0,
    fret_offset: i8 = 0,
    velocity_scale: f32 = 1.0,
    delay: f32 = 0.0,
};

const PickingPattern = struct {
    id: PatternId,
    min_bars: u8,
    events: [MAX_PATTERN_EVENTS]StringEvent,
    len: u8,
};

const TrebleMotif = struct {
    id: MotifId,
    events: [MAX_MOTIF_EVENTS]StringEvent,
    len: u8,
};

const GuitarVoice = struct {
    synth: instruments.GuitarFaustPluck = .{},
    pan: f32 = 0.0,
    active: bool = false,
    flavor: InstrumentFlavor = .guitar,
};

const PendingNote = struct {
    active: bool = false,
    delay: f32 = 0.0,
    frequency_hz: f32 = 0.0,
    velocity: f32 = 0.0,
    pan: f32 = 0.0,
    params: instruments.GuitarParams = .{},
    flavor: InstrumentFlavor = .guitar,
};

const GuitarCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    base_bpm: f32,
    chord_change_beats: f32,
    low_anchor_mask: u16,
    variation_mask: u16,
    chord_bars: u8,
    evolution_bars: u8,
    fill_chance: f32,
    energy: f32,
    reverb_boost: f32,
    tempo_drift: f32,
    initial_pattern: PatternId,
    initial_motif: MotifId,
    initial_fill_density: f32,
    progression_start: u8,
};

const CHORD_SHAPES: [5]ChordShape = .{
    .{ .id = .d5, .frets = .{ 0, 0, 0, 2, 3, 0 } },
    .{ .id = .dsus2, .frets = .{ 0, 0, 0, 2, 3, 0 } },
    .{ .id = .g_over_d, .frets = .{ 0, 2, 0, 0, 3, 3 } },
    .{ .id = .a7sus4_over_d, .frets = .{ 0, 0, 2, 2, 3, 0 } },
    .{ .id = .cadd9_over_d, .frets = .{ 0, 3, 2, 0, 3, 3 } },
};

const BANJO_PARAMS: instruments.GuitarParams = .{
    .pluck_position = 0.105,
    .pluck_brightness = 0.8,
    .string_mix_scale = 1.85,
    .body_mix_scale = 0.62,
    .attack_mix_scale = 1.15,
    .mute_amount = 0.78,
    .string_decay_scale = 0.34,
    .body_gain_scale = 0.5,
    .body_decay_scale = 0.48,
    .body_freq_scale = 1.18,
    .pick_noise_scale = 1.24,
    .attack_gain_scale = 1.34,
    .attack_decay_scale = 0.42,
    .bridge_coupling_scale = 1.5,
    .inharmonicity_scale = 0.88,
    .high_decay_scale = 1.02,
    .output_gain_scale = 0.92,
};

const ELECTRIC_PARAMS: instruments.GuitarParams = .{
    .pluck_position = 0.18,
    .pluck_brightness = 0.62,
    .string_mix_scale = 1.55,
    .body_mix_scale = 0.34,
    .attack_mix_scale = 0.42,
    .mute_amount = 0.045,
    .string_decay_scale = 1.58,
    .body_gain_scale = 0.36,
    .body_decay_scale = 0.86,
    .body_freq_scale = 1.08,
    .pick_noise_scale = 0.46,
    .attack_gain_scale = 0.56,
    .attack_decay_scale = 0.72,
    .bridge_coupling_scale = 0.95,
    .inharmonicity_scale = 0.38,
    .high_decay_scale = 0.72,
    .output_gain_scale = 0.9,
};

const PROGRESSIONS: [4][8]ChordId = .{
    .{ .d5, .dsus2, .g_over_d, .d5, .cadd9_over_d, .g_over_d, .a7sus4_over_d, .d5 },
    .{ .d5, .d5, .g_over_d, .d5, .d5, .cadd9_over_d, .g_over_d, .d5 },
    .{ .d5, .g_over_d, .a7sus4_over_d, .d5, .cadd9_over_d, .g_over_d, .a7sus4_over_d, .d5 },
    .{ .d5, .cadd9_over_d, .g_over_d, .d5, .a7sus4_over_d, .g_over_d, .dsus2, .d5 },
};

const PATTERNS: [4]PickingPattern = .{
    .{
        .id = .sparse_alternation,
        .min_bars = 4,
        .len = 6,
        .events = .{
            .{ .step = 0, .string = 0, .velocity_scale = 1.08 },
            .{ .step = 3, .string = 3, .velocity_scale = 0.83, .delay = 1.0 },
            .{ .step = 5, .string = 4, .velocity_scale = 0.78, .delay = 2.0 },
            .{ .step = 8, .string = 1, .velocity_scale = 0.96 },
            .{ .step = 11, .string = 2, .velocity_scale = 0.78, .delay = 1.0 },
            .{ .step = 13, .string = 4, .velocity_scale = 0.74, .delay = 2.0 },
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
        },
    },
    .{
        .id = .travis,
        .min_bars = 4,
        .len = 8,
        .events = .{
            .{ .step = 0, .string = 0, .velocity_scale = 1.05 },
            .{ .step = 2, .string = 3, .velocity_scale = 0.7, .delay = 1.0 },
            .{ .step = 4, .string = 1, .velocity_scale = 0.9 },
            .{ .step = 6, .string = 4, .velocity_scale = 0.68, .delay = 2.0 },
            .{ .step = 8, .string = 0, .velocity_scale = 0.98 },
            .{ .step = 10, .string = 3, .velocity_scale = 0.72, .delay = 1.0 },
            .{ .step = 12, .string = 2, .velocity_scale = 0.9 },
            .{ .step = 14, .string = 4, .velocity_scale = 0.68, .delay = 2.0 },
            .{},
            .{},
            .{},
            .{},
        },
    },
    .{
        .id = .slow_arpeggio,
        .min_bars = 4,
        .len = 7,
        .events = .{
            .{ .step = 0, .string = 0, .velocity_scale = 1.06 },
            .{ .step = 2, .string = 2, .velocity_scale = 0.74, .delay = 1.0 },
            .{ .step = 5, .string = 3, .velocity_scale = 0.72, .delay = 2.0 },
            .{ .step = 7, .string = 4, .velocity_scale = 0.7, .delay = 3.0 },
            .{ .step = 10, .string = 5, .velocity_scale = 0.68, .delay = 4.0 },
            .{ .step = 12, .string = 1, .velocity_scale = 0.9 },
            .{ .step = 14, .string = 4, .velocity_scale = 0.68, .delay = 2.0 },
            .{},
            .{},
            .{},
            .{},
            .{},
        },
    },
    .{
        .id = .drone_brush,
        .min_bars = 4,
        .len = 10,
        .events = .{
            .{ .step = 0, .string = 0, .velocity_scale = 1.1 },
            .{ .step = 4, .string = 2, .velocity_scale = 0.78 },
            .{ .step = 6, .string = 3, .velocity_scale = 0.66, .delay = 1.0 },
            .{ .step = 8, .string = 0, .velocity_scale = 1.0 },
            .{ .step = 10, .string = 2, .velocity_scale = 0.58, .delay = 0.0 },
            .{ .step = 10, .string = 3, .velocity_scale = 0.54, .delay = 2.0 },
            .{ .step = 10, .string = 4, .velocity_scale = 0.5, .delay = 4.0 },
            .{ .step = 12, .string = 1, .velocity_scale = 0.85 },
            .{ .step = 14, .string = 3, .velocity_scale = 0.62, .delay = 1.0 },
            .{ .step = 15, .string = 4, .velocity_scale = 0.56, .delay = 2.0 },
            .{},
            .{},
        },
    },
};

const MOTIFS: [4]TrebleMotif = .{
    .{
        .id = .low_answer,
        .len = 3,
        .events = .{
            .{ .step = 9, .string = 2, .velocity_scale = 0.68, .delay = 1.0 },
            .{ .step = 11, .string = 3, .velocity_scale = 0.62, .delay = 2.0 },
            .{ .step = 14, .string = 1, .velocity_scale = 0.72 },
            .{},
            .{},
        },
    },
    .{
        .id = .held_top,
        .len = 2,
        .events = .{
            .{ .step = 7, .string = 4, .velocity_scale = 0.6, .delay = 2.0 },
            .{ .step = 14, .string = 4, .velocity_scale = 0.58, .delay = 1.0 },
            .{},
            .{},
            .{},
        },
    },
    .{
        .id = .high_answer,
        .len = 4,
        .events = .{
            .{ .step = 5, .string = 5, .velocity_scale = 0.56, .delay = 3.0 },
            .{ .step = 9, .string = 4, .velocity_scale = 0.62, .delay = 2.0 },
            .{ .step = 11, .string = 5, .fret_offset = -2, .velocity_scale = 0.56, .delay = 4.0 },
            .{ .step = 14, .string = 4, .velocity_scale = 0.58, .delay = 1.0 },
            .{},
        },
    },
    .{
        .id = .rest_space,
        .len = 1,
        .events = .{
            .{ .step = 13, .string = 2, .velocity_scale = 0.48, .delay = 1.0 },
            .{},
            .{},
            .{},
            .{},
        },
    },
};

const GUITAR_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 40, .shape = .rise_fall },
    .macro = .{ .section_beats = 192, .shape = .plateau },
};

const GUITAR_LAYER_CURVES: [1]composition.LayerCurve = .{
    .{ .start = 0.0, .offset = 1.0, .slope = 0.0, .max = 1.0 },
};

const CUE_SPECS: [4]GuitarCueSpec = .{
    // open_road: balanced baseline.
    .{
        .root = ROOT_D2,
        .scale_type = .mixolydian,
        .base_bpm = 92.0,
        .chord_change_beats = CHORD_CHANGE_BEATS,
        .low_anchor_mask = (1 << 0) | (1 << 8),
        .variation_mask = (1 << 3) | (1 << 5) | (1 << 6) | (1 << 9) | (1 << 11) | (1 << 13) | (1 << 14) | (1 << 15),
        .chord_bars = 4,
        .evolution_bars = 2,
        .fill_chance = 0.18,
        .energy = 0.64,
        .reverb_boost = 0.0,
        .tempo_drift = 0.018,
        .initial_pattern = .sparse_alternation,
        .initial_motif = .low_answer,
        .initial_fill_density = 0.12,
        .progression_start = 0,
    },
    // low_drone: slower, more open low-string repetition.
    .{
        .root = ROOT_D2,
        .scale_type = .mixolydian,
        .base_bpm = 78.0,
        .chord_change_beats = 24.0,
        .low_anchor_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .variation_mask = (1 << 5) | (1 << 7) | (1 << 11) | (1 << 13),
        .chord_bars = 6,
        .evolution_bars = 3,
        .fill_chance = 0.08,
        .energy = 0.52,
        .reverb_boost = 0.025,
        .tempo_drift = 0.006,
        .initial_pattern = .drone_brush,
        .initial_motif = .rest_space,
        .initial_fill_density = 0.06,
        .progression_start = 0,
    },
    // rolling_travis: stronger pulse and more right-hand motion.
    .{
        .root = ROOT_D2,
        .scale_type = .mixolydian,
        .base_bpm = 108.0,
        .chord_change_beats = 12.0,
        .low_anchor_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .variation_mask = 0xFFFF,
        .chord_bars = 2,
        .evolution_bars = 2,
        .fill_chance = 0.28,
        .energy = 0.78,
        .reverb_boost = 0.0,
        .tempo_drift = 0.03,
        .initial_pattern = .travis,
        .initial_motif = .held_top,
        .initial_fill_density = 0.2,
        .progression_start = 2,
    },
    // high_lonesome: more treble answers and extra air.
    .{
        .root = ROOT_D2,
        .scale_type = .mixolydian,
        .base_bpm = 86.0,
        .chord_change_beats = 18.0,
        .low_anchor_mask = (1 << 0) | (1 << 8),
        .variation_mask = (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11) | (1 << 14) | (1 << 15),
        .chord_bars = 4,
        .evolution_bars = 2,
        .fill_chance = 0.22,
        .energy = 0.58,
        .reverb_boost = 0.04,
        .tempo_drift = 0.012,
        .initial_pattern = .slow_arpeggio,
        .initial_motif = .high_answer,
        .initial_fill_density = 0.14,
        .progression_start = 4,
    },
};

const GuitarStyleSpec = composition.StyleSpec(GuitarCueSpec, 1, 0);
const STYLE: GuitarStyleSpec = .{
    .arcs = GUITAR_ARCS,
    .layer_curves = GUITAR_LAYER_CURVES,
    .voice_timings = .{},
    .cues = &CUE_SPECS,
};
const GuitarRunner = composition.StepStyleRunner(GuitarCueSpec, 1);
const AmericanaGuitarCueMorph = cue_morph.CueMorph(CuePreset);
const GuitarPerformer = human_performance.Performer(16, STRING_COUNT);

var rng: dsp.Rng = dsp.rngInit(0xA6A1_6A01);
var runner: GuitarRunner = .{};
var voices: [VOICE_COUNT]GuitarVoice = [_]GuitarVoice{.{}} ** VOICE_COUNT;
var pending: [PENDING_COUNT]PendingNote = [_]PendingNote{.{}} ** PENDING_COUNT;
var reverb: GuitarReverb = dsp.stereoReverbInit(.{ 1301, 1511, 1741, 1999 }, .{ 353, 941 }, .{ 0.78, 0.80, 0.77, 0.79 });
var lfo_space: composition.SlowLfo = .{ .period_beats = 96, .depth = 0.025 };
var gesture_history: pattern_history.PatternHistory = .{ .capacity = GESTURE_HISTORY_SIZE };
var cue_state: AmericanaGuitarCueMorph = .{ .from = .open_road, .to = .open_road, .progress = 1.0, .morph_beats = 16.0 };
var structural_cue: CuePreset = .open_road;
var current_progression_idx: usize = 0;
var current_pattern_idx: usize = 0;
var current_motif_idx: usize = 0;
var current_fill_density: f32 = 0.12;
var bar_count: u32 = 0;
var bars_since_chord: u8 = 0;
var bars_since_evolution: u8 = 0;
var bars_on_pattern: u8 = 0;
var evolution_turn: u8 = 0;
var performer: GuitarPerformer = .{};

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn blendedCueSpec() GuitarCueSpec {
    const from = CUE_SPECS[@intFromEnum(cue_state.from)];
    const to = CUE_SPECS[@intFromEnum(cue_state.to)];
    const t = cue_state.progress;
    var spec = CUE_SPECS[@intFromEnum(structural_cue)];
    spec.base_bpm = lerpF32(from.base_bpm, to.base_bpm, t);
    spec.fill_chance = lerpF32(from.fill_chance, to.fill_chance, t);
    spec.energy = lerpF32(from.energy, to.energy, t);
    spec.reverb_boost = lerpF32(from.reverb_boost, to.reverb_boost, t);
    spec.tempo_drift = lerpF32(from.tempo_drift, to.tempo_drift, t);
    spec.initial_fill_density = lerpF32(from.initial_fill_density, to.initial_fill_density, t);
    return spec;
}

fn applyStructuralCueState(spec: GuitarCueSpec) void {
    const progression = PROGRESSIONS[@intFromEnum(structural_cue)];
    if (progression.len == 0) {
        std.log.warn("procedural_americana_guitar.applyStructuralCueState: empty progression for cue={}", .{structural_cue});
        current_progression_idx = 0;
    } else {
        current_progression_idx = @min(@as(usize, @intCast(spec.progression_start)), progression.len - 1);
    }

    current_pattern_idx = @intCast(@intFromEnum(spec.initial_pattern));
    current_motif_idx = @intCast(@intFromEnum(spec.initial_motif));
    current_fill_density = spec.initial_fill_density;
}

fn maybeAdvanceStructuralCue() void {
    if (structural_cue == cue_state.to) return;
    if (cue_state.progress < 0.35) return;

    structural_cue = cue_state.to;
    const target = CUE_SPECS[@intFromEnum(structural_cue)];
    runner.engine.key.scale_type = target.scale_type;
    composition.compositionEngineSetChordChangeBeats(&runner.engine, target.chord_change_beats);
    composition.keyStateModulateTo(&runner.engine.key, target.root);
    applyStructuralCueState(target);
    bars_since_chord = 0;
    bars_since_evolution = 0;
    bars_on_pattern = 0;
    evolution_turn = 0;
    rememberCurrentGesture();
}

fn applyCueParams() void {
    const prev_to = cue_state.to;
    cue_morph.setTarget(CuePreset, &cue_state, selected_cue);
    if (cue_state.to == prev_to and cue_state.progress >= 1.0) return;

    const target = CUE_SPECS[@intFromEnum(cue_state.to)];
    composition.compositionEngineSetChordChangeBeats(&runner.engine, target.chord_change_beats);
    composition.keyStateModulateTo(&runner.engine.key, target.root);
}

fn resetHumanTiming() void {
    human_performance.reset(16, STRING_COUNT, &performer, &rng, performerProfile());
}

fn advanceHumanTiming(meso: f32) void {
    human_performance.advanceClock(16, STRING_COUNT, &performer, &rng, performerProfile(), meso);
}

fn performerProfile() human_performance.PerformerProfile {
    return switch (selected_instrument) {
        .guitar => human_performance.ACOUSTIC_GUITAR_PROFILE,
        .banjo => human_performance.BANJO_PROFILE,
    };
}

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 4, 7, 10 }, .len = 4 };
    h.chords[1] = .{ .offsets = .{ 0, 5, 9, 12 }, .len = 4 };
    h.chords[2] = .{ .offsets = .{ 0, 7, 9, 14 }, .len = 4 };
    h.chords[3] = .{ .offsets = .{ 0, 2, 7, 10 }, .len = 4 };
    h.num_chords = 4;
    h.transitions[0] = .{ 0.36, 0.24, 0.26, 0.14, 0, 0, 0, 0 };
    h.transitions[1] = .{ 0.32, 0.18, 0.3, 0.2, 0, 0, 0, 0 };
    h.transitions[2] = .{ 0.4, 0.18, 0.2, 0.22, 0, 0, 0, 0 };
    h.transitions[3] = .{ 0.46, 0.18, 0.24, 0.12, 0, 0, 0, 0 };
    return h;
}

pub fn reset() void {
    const spec = CUE_SPECS[@intFromEnum(selected_cue)];
    rng = dsp.rngInit(entropy.nextSeed(0xA6A1_6A01, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    structural_cue = selected_cue;
    composition.stepStyleRunnerReset(
        GuitarCueSpec,
        1,
        &runner,
        &STYLE,
        .{ .root = spec.root, .scale_type = spec.scale_type },
        initHarmony(),
        spec.chord_change_beats,
        .none,
        .{1.0},
        .{1.0},
    );
    voices = [_]GuitarVoice{.{}} ** VOICE_COUNT;
    pending = [_]PendingNote{.{}} ** PENDING_COUNT;
    reverb = dsp.stereoReverbInit(.{ 1301, 1511, 1741, 1999 }, .{ 353, 941 }, .{ 0.78, 0.80, 0.77, 0.79 });
    lfo_space = .{ .period_beats = 96, .depth = 0.025 };
    pattern_history.clear(&gesture_history);
    resetHumanTiming();
    applyStructuralCueState(spec);
    bar_count = 0;
    bars_since_chord = 0;
    bars_since_evolution = 0;
    bars_on_pattern = 0;
    evolution_turn = 0;
    rememberCurrentGesture();
}

pub fn triggerCue() void {
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const nominal_bpm = @max(CUE_SPECS[@intFromEnum(cue_state.to)].base_bpm * tempoScale(), 1.0);
    const cue_spb = dsp.samplesPerBeat(nominal_bpm);

    for (0..frames) |frame_idx| {
        cue_morph.advance(CuePreset, &cue_state, cue_spb);
        const spec = blendedCueSpec();
        const macro_t = composition.arcControllerTension(&runner.engine.arcs.macro);
        const effective_bpm = spec.base_bpm * tempoScale() * (1.0 + macro_t * spec.tempo_drift);
        composition.slowLfoAdvanceSample(&lfo_space, effective_bpm);
        const frame = composition.stepStyleRunnerAdvanceFrame(GuitarCueSpec, 1, &runner, &rng, &STYLE, effective_bpm, 0.00004);

        if (frame.step) |step| {
            advanceStep(step, frame.tick.meso, frame.tick.micro, &spec);
        }

        processPendingNotes();

        var stereo = processVoices();
        const room = dsp.stereoReverbProcess(.{ 1301, 1511, 1741, 1999 }, .{ 353, 941 }, &reverb, stereo);
        const wet = guitarReverbWet(spec.reverb_boost) * composition.slowLfoModulate(&lfo_space);
        stereo[0] = stereo[0] * (1.0 - wet * GUITAR_REVERB_DRY_DUCK) + room[0] * wet * GUITAR_REVERB_RETURN_GAIN;
        stereo[1] = stereo[1] * (1.0 - wet * GUITAR_REVERB_DRY_DUCK) + room[1] * wet * GUITAR_REVERB_RETURN_GAIN;

        const out_idx = frame_idx * 2;
        buf[out_idx] = softClip(stereo[0] * guitar_vol * runner.layer_levels[0]);
        buf[out_idx + 1] = softClip(stereo[1] * guitar_vol * runner.layer_levels[0]);
    }
}

fn advanceStep(step: u8, meso: f32, micro: f32, spec: *const GuitarCueSpec) void {
    if (step >= 16) {
        std.log.warn("procedural_americana_guitar.advanceStep: invalid step={d}", .{step});
        return;
    }

    triggerPatternStep(step, meso, micro, spec);
    triggerMotifStep(step, meso, spec);
    maybeTriggerFillStep(step, meso, spec);

    if (step != 15) return;
    advanceBar(meso, spec);
}

fn triggerPatternStep(step: u8, meso: f32, micro: f32, spec: *const GuitarCueSpec) void {
    _ = micro;
    const pattern = &PATTERNS[current_pattern_idx];
    var idx: usize = 0;
    while (idx < @as(usize, pattern.len)) : (idx += 1) {
        const event = pattern.events[idx];
        if (event.step != step) continue;
        const is_anchor = composition.stepActive(spec.low_anchor_mask, step) and event.string <= 1;
        scheduleStringEvent(event, meso, spec, is_anchor);
    }
}

fn triggerMotifStep(step: u8, meso: f32, spec: *const GuitarCueSpec) void {
    const motif = &MOTIFS[current_motif_idx];
    var idx: usize = 0;
    while (idx < @as(usize, motif.len)) : (idx += 1) {
        const event = motif.events[idx];
        if (event.step != step) continue;
        scheduleStringEvent(event, meso, spec, false);
    }
}

fn maybeTriggerFillStep(step: u8, meso: f32, spec: *const GuitarCueSpec) void {
    if (!composition.stepActive(spec.variation_mask, step)) return;
    if (dsp.rngFloat(&rng) >= current_fill_density * spec.fill_chance * (0.35 + meso * 0.65)) return;
    const event = fillEventForStep(step);
    scheduleStringEvent(event, meso, spec, false);
}

fn fillEventForStep(step: u8) StringEvent {
    if (step < 4) return .{ .step = step, .string = 3, .velocity_scale = 0.52, .delay = 1.0 };
    if (step < 8) return .{ .step = step, .string = 4, .velocity_scale = 0.5, .delay = 2.0 };
    if (step < 12) return .{ .step = step, .string = 2, .velocity_scale = 0.58, .delay = 1.0 };
    if (current_motif_idx == @intFromEnum(MotifId.high_answer)) {
        return .{ .step = step, .string = 5, .fret_offset = -2, .velocity_scale = 0.48, .delay = 3.0 };
    }
    return .{ .step = step, .string = 4, .velocity_scale = 0.5, .delay = 1.0 };
}

fn advanceBar(meso: f32, spec: *const GuitarCueSpec) void {
    barCountAdvance();
    advanceHumanTiming(meso);
    maybeAdvanceStructuralCue();
    bars_since_chord +|= 1;
    bars_since_evolution +|= 1;
    bars_on_pattern +|= 1;

    if (bars_since_evolution >= spec.evolution_bars) {
        advanceSecondaryEvolution(meso);
        bars_since_evolution = 0;
        rememberCurrentGesture();
    }

    if (bars_since_chord < spec.chord_bars) return;
    bars_since_chord = 0;
    advanceChord();
    rememberCurrentGesture();
}

fn barCountAdvance() void {
    if (bar_count == std.math.maxInt(u32)) return;
    bar_count += 1;
}

fn advanceSecondaryEvolution(meso: f32) void {
    const kind: EvolutionKind = @enumFromInt(evolution_turn % 3);
    evolution_turn +%= 1;
    switch (kind) {
        .motif => advanceMotif(meso),
        .pattern => advancePattern(meso),
        .density => advanceDensity(meso),
    }
}

fn advanceChord() void {
    current_progression_idx = (current_progression_idx + 1) % PROGRESSIONS[@intFromEnum(structural_cue)].len;
}

fn advanceMotif(meso: f32) void {
    const skip_high = meso < 0.25 and current_motif_idx == @intFromEnum(MotifId.held_top);
    if (skip_high) {
        current_motif_idx = @intFromEnum(MotifId.low_answer);
        return;
    }
    current_motif_idx = (current_motif_idx + 1) % MOTIFS.len;
}

fn advancePattern(meso: f32) void {
    const pattern = &PATTERNS[current_pattern_idx];
    if (bars_on_pattern < pattern.min_bars) {
        advanceMotif(meso);
        return;
    }

    current_pattern_idx = chooseNextPattern(meso);
    bars_on_pattern = 0;
}

fn chooseNextPattern(meso: f32) usize {
    const preferred = if (meso < 0.28)
        @intFromEnum(PatternId.sparse_alternation)
    else if (meso < 0.58)
        @intFromEnum(PatternId.slow_arpeggio)
    else if (dsp.rngFloat(&rng) < 0.54)
        @intFromEnum(PatternId.travis)
    else
        @intFromEnum(PatternId.drone_brush);

    if (preferred != current_pattern_idx) return preferred;
    return (current_pattern_idx + 1 + randomIndex(PATTERNS.len - 1)) % PATTERNS.len;
}

fn advanceDensity(meso: f32) void {
    current_fill_density = std.math.clamp(0.08 + meso * 0.22 + randomRange(-0.035, 0.035), 0.04, 0.34);
}

fn rememberCurrentGesture() void {
    var hash: u32 = 2166136261;
    hash = (hash ^ @as(u32, @intFromEnum(structural_cue))) *% 16777619;
    hash = (hash ^ @as(u32, @intFromEnum(currentChordId()))) *% 16777619;
    hash = (hash ^ @as(u32, @intFromEnum(PATTERNS[current_pattern_idx].id))) *% 16777619;
    hash = (hash ^ @as(u32, @intFromEnum(MOTIFS[current_motif_idx].id))) *% 16777619;
    hash = (hash ^ @as(u32, @intFromFloat(current_fill_density * 100.0))) *% 16777619;

    if (!pattern_history.seenRecently(&gesture_history, hash)) {
        pattern_history.remember(&gesture_history, hash);
        return;
    }

    current_motif_idx = (current_motif_idx + 1) % MOTIFS.len;
    const nudged_hash = (hash ^ @as(u32, @intFromEnum(MOTIFS[current_motif_idx].id))) *% 16777619;
    pattern_history.remember(&gesture_history, nudged_hash);
}

fn scheduleStringEvent(event: StringEvent, meso: f32, spec: *const GuitarCueSpec, is_anchor: bool) void {
    if (event.string >= STRING_COUNT) {
        std.log.warn("procedural_americana_guitar.scheduleStringEvent: invalid string={d}", .{event.string});
        return;
    }

    const string_idx: usize = @intCast(event.string);
    const shape = currentChordShape();
    const fret = shape.frets[string_idx];
    if (fret == MUTED_FRET) return;

    const fret_raw = @as(i16, fret) + @as(i16, event.fret_offset);
    const fret_clamped: u8 = @intCast(std.math.clamp(fret_raw, @as(i16, 0), @as(i16, 14)));
    const midi = openStringMidi(string_idx) + fret_clamped;
    const freq = dsp.midiToFreq(midi) * centsRatio(humanPitchCents(is_anchor, string_idx));
    const velocity = stringEventVelocity(event, meso, spec, is_anchor);
    const pan = std.math.clamp(STRING_PAN[string_idx] + randomRange(-0.035, 0.035), -0.34, 0.34);
    scheduleNote(freq, velocity, pan, scheduledGuitarParams(is_anchor), selected_instrument, event.delay + randomRange(0.0, 1.2) + humanTimingDelaySamples(is_anchor, event.step, string_idx));
}

fn currentChordShape() ChordShape {
    const chord_id = currentChordId();
    return CHORD_SHAPES[@intFromEnum(chord_id)];
}

fn currentChordId() ChordId {
    const progression = PROGRESSIONS[@intFromEnum(structural_cue)];
    return progression[current_progression_idx % progression.len];
}

fn stringEventVelocity(event: StringEvent, meso: f32, spec: *const GuitarCueSpec, is_anchor: bool) f32 {
    const anchor_bias: f32 = if (is_anchor) 0.06 else 0.0;
    const energy_bias = (spec.energy - 0.5) * 0.07 + meso * 0.025;
    const instrument_bias: f32 = switch (selected_instrument) {
        .guitar => 0.0,
        .banjo => -0.035,
    };
    return std.math.clamp(BASE_VELOCITY * event.velocity_scale + anchor_bias + energy_bias + instrument_bias + randomRange(-0.02, 0.02), 0.34, 0.78);
}

fn scheduledGuitarParams(is_anchor: bool) instruments.GuitarParams {
    var params = baseInstrumentParams();
    switch (selected_instrument) {
        .guitar => randomizeGuitarParams(&params, is_anchor),
        .banjo => randomizeBanjoParams(&params, is_anchor),
    }
    params.rng_seed = dsp.rngNext(&rng);
    maybeApplyRoughPick(&params, is_anchor);
    return params;
}

fn baseInstrumentParams() instruments.GuitarParams {
    return switch (selected_instrument) {
        .guitar => instruments.GUITAR_FAUST_PROMOTED_PARAMS,
        .banjo => BANJO_PARAMS,
    };
}

fn randomizeGuitarParams(params: *instruments.GuitarParams, is_anchor: bool) void {
    const pluck_position = params.pluck_position orelse 0.1678;
    const pluck_brightness = params.pluck_brightness orelse 0.68;
    const anchor_brightness: f32 = if (is_anchor) -0.025 else 0.0;
    params.pluck_position = std.math.clamp(pluck_position + randomRange(-0.018, 0.018), 0.12, 0.22);
    params.pluck_brightness = std.math.clamp(pluck_brightness + anchor_brightness + randomRange(-0.048, 0.02), 0.52, 0.72);
    params.attack_mix_scale *= randomRange(0.86, 1.05);
    params.attack_gain_scale *= randomRange(0.88, 1.04);
    params.string_decay_scale *= randomRange(0.96, 1.055);
    params.high_decay_scale *= randomRange(0.88, 1.04);
    params.bridge_coupling_scale *= randomRange(0.9, 1.06);
    params.mute_amount = std.math.clamp(params.mute_amount + randomRange(-0.012, 0.045), 0.0, 1.0);
    params.output_gain_scale *= randomRange(0.9, 1.025);
}

fn randomizeBanjoParams(params: *instruments.GuitarParams, is_anchor: bool) void {
    const pluck_position = params.pluck_position orelse 0.105;
    const pluck_brightness = params.pluck_brightness orelse 0.8;
    const anchor_brightness: f32 = if (is_anchor) -0.015 else 0.0;
    params.pluck_position = std.math.clamp(pluck_position + randomRange(-0.012, 0.012), 0.075, 0.145);
    params.pluck_brightness = std.math.clamp(pluck_brightness + anchor_brightness + randomRange(-0.07, 0.035), 0.66, 0.9);
    params.attack_mix_scale *= randomRange(0.9, 1.18);
    params.attack_gain_scale *= randomRange(0.88, 1.14);
    params.attack_decay_scale *= randomRange(0.88, 1.06);
    params.string_decay_scale *= randomRange(0.84, 1.04);
    params.high_decay_scale *= randomRange(0.82, 1.08);
    params.bridge_coupling_scale *= randomRange(0.84, 1.18);
    params.mute_amount = std.math.clamp(params.mute_amount + randomRange(-0.035, 0.09), 0.0, 1.0);
    params.output_gain_scale *= randomRange(0.82, 1.0);
}

fn maybeApplyRoughPick(params: *instruments.GuitarParams, is_anchor: bool) void {
    const base_chance: f32 = switch (selected_instrument) {
        .guitar => 0.08,
        .banjo => 0.16,
    };
    const chance = if (is_anchor) base_chance * 0.55 else base_chance;
    if (dsp.rngFloat(&rng) >= chance) return;

    const brightness = params.pluck_brightness orelse 0.68;
    params.pluck_brightness = std.math.clamp(brightness - randomRange(0.025, 0.09), 0.42, 0.92);
    params.mute_amount = std.math.clamp(params.mute_amount + randomRange(0.04, 0.16), 0.0, 1.0);
    params.attack_gain_scale *= randomRange(0.72, 0.94);
    params.output_gain_scale *= randomRange(0.72, 0.92);
}

fn humanPitchCents(is_anchor: bool, string_idx: usize) f32 {
    return human_performance.pitchCents(16, STRING_COUNT, &performer, &rng, performerProfile(), string_idx, is_anchor);
}

fn humanTimingDelaySamples(is_anchor: bool, step: u8, string_idx: usize) f32 {
    return human_performance.timingDelaySamples(16, STRING_COUNT, &performer, &rng, performerProfile(), step, string_idx, is_anchor);
}

fn openStringMidi(string_idx: usize) u8 {
    return switch (selected_instrument) {
        .guitar => OPEN_STRING_MIDI[string_idx],
        .banjo => BANJO_STRING_MIDI[string_idx],
    };
}

fn scheduleNote(freq: f32, velocity: f32, pan: f32, params: instruments.GuitarParams, flavor: InstrumentFlavor, delay: f32) void {
    const pending_idx = pendingSlot() orelse {
        triggerVoice(freq, velocity, pan, params, flavor);
        return;
    };
    pending[pending_idx] = .{
        .active = true,
        .delay = delay,
        .frequency_hz = freq,
        .velocity = velocity,
        .pan = pan,
        .params = params,
        .flavor = flavor,
    };
}

fn pendingSlot() ?usize {
    for (0..PENDING_COUNT) |idx| {
        if (!pending[idx].active) return idx;
    }
    return null;
}

fn processPendingNotes() void {
    for (0..PENDING_COUNT) |idx| {
        if (!pending[idx].active) continue;
        if (pending[idx].delay > 0.0) {
            pending[idx].delay -= 1.0;
            continue;
        }

        triggerVoice(pending[idx].frequency_hz, pending[idx].velocity, pending[idx].pan, pending[idx].params, pending[idx].flavor);
        pending[idx].active = false;
    }
}

fn triggerVoice(freq: f32, velocity: f32, pan: f32, params: instruments.GuitarParams, flavor: InstrumentFlavor) void {
    const voice_idx = voiceForTrigger();
    voices[voice_idx].pan = pan;
    voices[voice_idx].active = true;
    voices[voice_idx].flavor = flavor;
    instruments.guitarFaustPluckTriggerWithParams(&voices[voice_idx].synth, freq, velocity, params);
}

fn voiceForTrigger() usize {
    var best_idx: usize = 0;
    var best_age: u32 = 0;
    for (0..VOICE_COUNT) |idx| {
        if (!voices[idx].active) return idx;
        if (voices[idx].synth.age <= best_age) continue;
        best_age = voices[idx].synth.age;
        best_idx = idx;
    }
    return best_idx;
}

fn processVoices() [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;

    for (0..VOICE_COUNT) |idx| {
        if (!voices[idx].active) continue;
        const sample = instruments.guitarFaustPluckProcess(&voices[idx].synth) * instrumentVoiceEnvelope(voices[idx].flavor, voices[idx].synth.age);
        const stereo = dsp.panStereo(sample, voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
        if (voices[idx].synth.age < noteTailSamples(voices[idx].flavor)) continue;
        voices[idx].active = false;
    }

    return .{ left * 0.72, right * 0.72 };
}

fn noteTailSamples(flavor: InstrumentFlavor) u32 {
    return switch (flavor) {
        .guitar => NOTE_TAIL_SAMPLES,
        .banjo => BANJO_NOTE_TAIL_SAMPLES,
    };
}

fn instrumentVoiceEnvelope(flavor: InstrumentFlavor, age: u32) f32 {
    switch (flavor) {
        .guitar => return 1.0,
        .banjo => {
            const age_f: f32 = @floatFromInt(age);
            const decay_samples = dsp.SAMPLE_RATE * 0.16;
            return std.math.exp(-age_f / decay_samples);
        },
    }
}

fn tempoScale() f32 {
    return std.math.clamp(bpm, 0.35, 1.65);
}

fn guitarReverbWet(reverb_boost: f32) f32 {
    return std.math.clamp((reverb_mix + reverb_boost) * GUITAR_REVERB_SEND_SCALE, 0.0, GUITAR_REVERB_MAX_WET);
}

fn randomIndex(count: usize) usize {
    if (count == 0) {
        std.log.warn("procedural_americana_guitar.randomIndex: count is zero", .{});
        return 0;
    }
    return @intCast(dsp.rngNext(&rng) % @as(u32, @intCast(count)));
}

fn randomRange(min_value: f32, max_value: f32) f32 {
    return min_value + (max_value - min_value) * dsp.rngFloat(&rng);
}

fn centsRatio(cents: f32) f32 {
    return std.math.pow(f32, 2.0, cents / 1200.0);
}
