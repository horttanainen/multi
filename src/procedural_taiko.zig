// Procedural Japanese taiko ensemble — v2 composition engine.
//
// Kumi-daiko ensemble: odaiko, 4x nagado/chū-daiko, 2x shime-daiko, atarigane.
// 16-step sequencer with swing, per-voice microtiming, lead improvisation
// with phrase memory, Jo-Ha-Kyu macro arc (sparse→layered→driving unison),
// call-and-response passages, and dramatic breaks with "ma" (silence).
const std = @import("std");
const dsp = @import("music/dsp.zig");
const cue_morph = @import("music/cue_morph.zig");
const entropy = @import("music/entropy.zig");
const pattern_history = @import("music/pattern_history.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

pub const CuePreset = enum(u8) {
    matsuri,
    yatai_bayashi,
    miyake,
    oroshi,
    hachijo,
    bon_odori,
    furi_uchi,
};

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 120.0;
pub var reverb_mix: f32 = 0.32;
pub var drum_mix: f32 = 0.9;
pub var shaker_mix: f32 = 0.55; // maps to shime volume
pub var tone_mix: f32 = 0.65; // maps to nagado volume
pub var slap_mix: f32 = 0.5; // maps to atarigane volume
pub var selected_cue: CuePreset = .matsuri;
pub var collect_bus_stats: bool = false;
// Per-voice mute used by probe/test code to render individual voices.
pub var voice_mute: [NUM_VOICES]bool = .{false} ** NUM_VOICES;
const TAIKO_ODAIKO_BUS_GAIN: f32 = 0.54;
const TAIKO_NAGADO_BUS_GAIN: f32 = 0.90;
const TAIKO_SHIME_BUS_GAIN: f32 = 1.20;
const TAIKO_KANE_BUS_GAIN: f32 = 1.0;
const TAIKO_REVERB_SEND_GAIN: f32 = 0.55;
const TAIKO_REVERB_RETURN_GAIN: f32 = 0.45;
const TAIKO_REVERB_DRY_DUCK: f32 = 0.18;
const TAIKO_REVERB_MAX_WET: f32 = 0.48;
const TAIKO_MASTER_OUTPUT_GAIN: f32 = 0.90;

pub const TaikoMeterStats = struct {
    samples: u64 = 0,
    sum_sq: f64 = 0.0,
    peak_abs: f32 = 0.0,
};

pub const TaikoBusStats = struct {
    odaiko: TaikoMeterStats = .{},
    nagado: TaikoMeterStats = .{},
    shime: TaikoMeterStats = .{},
    kane: TaikoMeterStats = .{},
    dry: TaikoMeterStats = .{},
    reverb: TaikoMeterStats = .{},
    final: TaikoMeterStats = .{},
};

var bus_stats: TaikoBusStats = .{};

pub fn resetBusStats() void {
    bus_stats = .{};
}

pub fn getBusStats() TaikoBusStats {
    return bus_stats;
}

pub fn meterRms(meter: TaikoMeterStats) f64 {
    if (meter.samples == 0) return 0.0;
    return @sqrt(meter.sum_sq / @as(f64, @floatFromInt(meter.samples)));
}

// ============================================================
// Reverb — large hall / outdoor space character
// ============================================================

const TaikoReverb = StereoReverb(.{ 1801, 1907, 2053, 2111 }, .{ 241, 557 });
var reverb: TaikoReverb = dsp.stereoReverbInit(.{ 1801, 1907, 2053, 2111 }, .{ 241, 557 }, .{ 0.87, 0.88, 0.86, 0.89 });
var rng: dsp.Rng = dsp.rngInit(0xDA1C_0000);

fn initHarmony() composition.ChordMarkov {
    // Taiko is primarily rhythmic, but we use chord progressions
    // to subtly shift the odaiko/nagado tuning color over time.
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 7, 12, 0 }, .len = 3 };
    h.chords[1] = .{ .offsets = .{ 5, 12, 17, 0 }, .len = 3 };
    h.chords[2] = .{ .offsets = .{ 7, 14, 19, 0 }, .len = 3 };
    h.chords[3] = .{ .offsets = .{ 3, 10, 15, 0 }, .len = 3 };
    h.num_chords = 4;
    h.transitions[0] = .{ 0.15, 0.35, 0.30, 0.20, 0, 0, 0, 0 };
    h.transitions[1] = .{ 0.30, 0.15, 0.25, 0.30, 0, 0, 0, 0 };
    h.transitions[2] = .{ 0.35, 0.25, 0.10, 0.30, 0, 0, 0, 0 };
    h.transitions[3] = .{ 0.30, 0.30, 0.25, 0.15, 0, 0, 0, 0 };
    return h;
}

// Jo-Ha-Kyu: the macro arc drives the overall intensity.
// micro = fill detail, meso = phrase energy, macro = Jo-Ha-Kyu envelope.
const TAIKO_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};

var lfo_space: composition.SlowLfo = .{ .period_beats = 96, .depth = 0.03 };
// Slow tempo LFO for cross-cycle drift (procession acceleration). Depth=1.0
// so slowLfoValue returns pure sin(phase); per-cue magnitude is applied via
// spec.tempo_cycle_drift in the per-sample bpm calc.
var tempo_lfo: composition.SlowLfo = .{ .period_beats = 1024.0, .depth = 1.0 };
// A/B sub-flavor state for kuse-style alternation across macro cycles.
var macro_cycle_count: u32 = 0;
var last_macro_beat_global: f32 = -1.0;
var active_variant_offset: f32 = 0.0;

// ============================================================
// Layer system — Jo-Ha-Kyu vertical activation
// ============================================================

const ODAIKO_LAYER = 0;
const NAGADO_LAYER = 1;
const SHIME_LAYER = 2;
const KANE_LAYER = 3;

const TAIKO_LAYER_CURVES: [4]composition.LayerCurve = .{
    // Odaiko: sparse at first, full presence at macro > 0.3
    .{ .start = 0.0, .offset = 0.35, .slope = 0.65, .max = 1.0 },
    // Nagado: enters early, builds to full
    .{ .start = 0.0, .offset = 0.5, .slope = 0.5, .max = 1.0 },
    // Shime: ji-uchi is always present (high offset)
    .{ .start = 0.0, .offset = 0.85, .slope = 0.15, .max = 1.0 },
    // Atarigane: enters with shime
    .{ .start = 0.0, .offset = 0.7, .slope = 0.3, .max = 1.0 },
};

const LAYER_FADE_RATE: f32 = 0.00004;
const CHORD_CHANGE_BEATS: f32 = 16.0;

const TaikoCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    base_bpm: f32,
    chord_change_beats: f32,
    pattern_style: TaikoPatternStyle,
    progressive_roll: bool = false,
    swing_amount: f32, // 0 = straight, 0.15 = moderate swing
    // 16-bit step masks
    odaiko_mask: u16,
    odaiko_fill_mask: u16,
    nagado1_don_mask: u16,
    nagado1_ka_mask: u16,
    nagado2_don_mask: u16,
    nagado2_ka_mask: u16,
    shime_ji_mask: u16, // ji-uchi ground pattern
    shime_accent_mask: u16,
    // Dynamics
    lead_density: f32,
    lead_rebuild_cycles: u16,
    ghost_density: f32,
    fill_density: f32,
    break_chance: f32,
    call_response_chance: f32,
    roll_chance: f32,
    energy: f32,
    reverb_boost: f32,
    // Tempo drift: macro arc can push tempo up slightly at Kyu
    tempo_drift: f32,
    // Pattern hold cadence — how many macro-arc beats between repicks for
    // supporting voices. Repicks happen at multiples of these counts within
    // each macro cycle, plus at every cycle wrap. Larger = steadier groove.
    // Macro section is 256 beats (~2 min) — so e.g. 128 = 2 phases per cycle.
    kane_hold_beats: u16,
    nagado_back_hold_beats: u16,
    // Cycle-indexed pattern bias — emulates the "kuse" rotation of festival
    // bayashi where the lead-implied accompaniment shifts across verses.
    // 0 = picker uses only intensity; 1 = cycle dominates fully. Tune per cue.
    cycle_bias_amount: f32,
    // Cross-cycle tempo drift — models processional acceleration of yatai
    // bayashi where the tempo rises and falls slowly over many minutes.
    // 0 = no drift. 0.03 = ±3% slow modulation. Use only for procession music.
    tempo_cycle_drift: f32,
    // A/B sub-flavors — models the kuse/honbun alternation of festival music.
    // Variant B is selected for variant_period_cycles macro arcs at a time
    // (intervened with the same length of variant A). 0 = no variants.
    // variant_intensity_offset shifts the picker target toward sparse (<0) or
    // dense (>0) for the duration that B is active.
    variant_period_cycles: u8,
    variant_intensity_offset: f32,
};

const TaikoStyleSpec = composition.StyleSpec(TaikoCueSpec, 4, 0);
const STYLE: TaikoStyleSpec = .{
    .arcs = TAIKO_ARCS,
    .layer_curves = TAIKO_LAYER_CURVES,
    .voice_timings = .{},
    .cues = &CUE_SPECS,
};
const TaikoRunner = composition.StepStyleRunner(TaikoCueSpec, 4);
var runner: TaikoRunner = .{};

// ============================================================
// Cue specs — different taiko traditions
// ============================================================

const TaikoPatternStyle = enum {
    matsuri,
    yatai_bayashi,
    miyake,
    oroshi,
    hachijo,
    bon_odori,
    furi_uchi,
};

const CUE_SPECS: [7]TaikoCueSpec = .{
    // matsuri — festival rhythm, moderate tempo, steady groove
    .{
        .root = 36,
        .scale_type = .dorian,
        .base_bpm = 116.0,
        .chord_change_beats = 16.0,
        .pattern_style = .matsuri,
        .progressive_roll = false,
        .swing_amount = 0.08,
        // Odaiko: beats 1 and 9 (half notes)
        .odaiko_mask = (1 << 0) | (1 << 8),
        .odaiko_fill_mask = (1 << 4) | (1 << 12),
        // Nagado 1: DON-DOKO feel (1, +, 5, +, 9, +, 13, +)
        .nagado1_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .nagado1_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        // Nagado 2: complementary
        .nagado2_don_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .nagado2_ka_mask = (1 << 1) | (1 << 5) | (1 << 9) | (1 << 13),
        // Shime: steady eighth notes
        .shime_ji_mask = 0x5555, // every other step
        .shime_accent_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .lead_density = 0.6,
        .lead_rebuild_cycles = 4,
        .ghost_density = 0.18,
        .fill_density = 0.22,
        .break_chance = 0.05,
        .call_response_chance = 0.12,
        .roll_chance = 0.08,
        .energy = 0.68,
        .reverb_boost = 0.04,
        .tempo_drift = 0.02,
        // 4 kane phases (~33s each) + 2 backline phases (~66s each) per macro cycle (~2.2 min).
        .kane_hold_beats = 64,
        .nagado_back_hold_beats = 128,
        // Matsuri kuse rotation — pattern preference shifts across festival verses.
        .cycle_bias_amount = 0.3,
        // Matsuri tempo is steady party music — no cross-cycle drift.
        .tempo_cycle_drift = 0.0,
        // Matsuri alternates between two kuse flavors every 3 macro cycles (~6.6 min).
        // B-flavor leans denser (more chi/ki fills in kane, more doko in backline).
        .variant_period_cycles = 3,
        .variant_intensity_offset = 0.25,
    },
    // yatai_bayashi — float procession, building energy, faster
    .{
        .root = 38,
        .scale_type = .mixolydian,
        .base_bpm = 128.0,
        .chord_change_beats = 12.0,
        .pattern_style = .yatai_bayashi,
        .progressive_roll = false,
        .swing_amount = 0.12,
        .odaiko_mask = (1 << 0) | (1 << 8),
        .odaiko_fill_mask = (1 << 4) | (1 << 10) | (1 << 14),
        .nagado1_don_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 8) | (1 << 11) | (1 << 14),
        .nagado1_ka_mask = (1 << 2) | (1 << 5) | (1 << 10) | (1 << 13),
        .nagado2_don_mask = (1 << 1) | (1 << 4) | (1 << 7) | (1 << 9) | (1 << 12) | (1 << 15),
        .nagado2_ka_mask = (1 << 3) | (1 << 8) | (1 << 11),
        .shime_ji_mask = 0xFFFF, // every step (sixteenths)
        .shime_accent_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .lead_density = 0.72,
        .lead_rebuild_cycles = 3,
        .ghost_density = 0.24,
        .fill_density = 0.32,
        .break_chance = 0.04,
        .call_response_chance = 0.18,
        .roll_chance = 0.12,
        .energy = 0.78,
        .reverb_boost = 0.02,
        .tempo_drift = 0.04,
        // 2 kane phases (~60s each) + 2 backline phases (~60s each) per macro cycle (~2 min).
        // Yatai is a steady driving procession — supporting voices hold their figures.
        .kane_hold_beats = 128,
        .nagado_back_hold_beats = 128,
        // Yatai is hypnotically repetitive — no kuse rotation.
        .cycle_bias_amount = 0.0,
        // Yatai processional acceleration — gradual tempo rise/fall across ~9-min period.
        .tempo_cycle_drift = 0.03,
        // Yatai stays in one mode for the entire procession — no A/B.
        .variant_period_cycles = 0,
        .variant_intensity_offset = 0.0,
    },
    // miyake — powerful, athletic, driving rhythm
    .{
        .root = 34,
        .scale_type = .natural_minor,
        .base_bpm = 108.0,
        .chord_change_beats = 20.0,
        .pattern_style = .miyake,
        .progressive_roll = false,
        .swing_amount = 0.05,
        .odaiko_mask = (1 << 0) | (1 << 6) | (1 << 8) | (1 << 14),
        .odaiko_fill_mask = (1 << 3) | (1 << 11),
        .nagado1_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .nagado1_ka_mask = (1 << 3) | (1 << 7) | (1 << 11) | (1 << 15),
        .nagado2_don_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .nagado2_ka_mask = (1 << 1) | (1 << 5) | (1 << 9) | (1 << 13),
        .shime_ji_mask = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 14),
        .shime_accent_mask = (1 << 0) | (1 << 8),
        .lead_density = 0.55,
        .lead_rebuild_cycles = 5,
        .ghost_density = 0.12,
        .fill_density = 0.18,
        .break_chance = 0.07,
        .call_response_chance = 0.08,
        .roll_chance = 0.06,
        .energy = 0.75,
        .reverb_boost = 0.06,
        .tempo_drift = 0.015,
        // 2 kane phases (~71s each) + 1 backline phase (~142s) per macro cycle (~2.4 min).
        // Miyake is bold and rock-steady — backline holds for the entire macro cycle.
        .kane_hold_beats = 128,
        .nagado_back_hold_beats = 256,
        // Miyake has mild section-transition variation, less than matsuri.
        .cycle_bias_amount = 0.2,
        // Miyake is rock-steady — no cross-cycle tempo drift.
        .tempo_cycle_drift = 0.0,
        // Miyake alternates every 4 cycles (~9.4 min). B-flavor is more spacious.
        .variant_period_cycles = 4,
        .variant_intensity_offset = -0.20,
    },
    // oroshi — thunder roll, dramatic building, fastest
    .{
        .root = 41,
        .scale_type = .harmonic_minor,
        .base_bpm = 82.0,
        .chord_change_beats = 16.0,
        .pattern_style = .oroshi,
        .progressive_roll = true,
        .swing_amount = 0.0,
        .odaiko_mask = (1 << 0) | (1 << 8),
        .odaiko_fill_mask = (1 << 4) | (1 << 12),
        .nagado1_don_mask = (1 << 0) | (1 << 8),
        .nagado1_ka_mask = (1 << 4) | (1 << 12),
        .nagado2_don_mask = (1 << 4) | (1 << 12),
        .nagado2_ka_mask = 0,
        .shime_ji_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .shime_accent_mask = (1 << 0) | (1 << 8),
        .lead_density = 0.18,
        .lead_rebuild_cycles = 8,
        .ghost_density = 0.06,
        .fill_density = 0.12,
        .break_chance = 0.0,
        .call_response_chance = 0.0,
        .roll_chance = 0.06,
        .energy = 0.82,
        .reverb_boost = 0.0,
        .tempo_drift = 0.18,
        // 4 kane phases (~47s each) per macro cycle (~3.1 min). Backline is silent in oroshi.
        .kane_hold_beats = 64,
        .nagado_back_hold_beats = 128,
        // Oroshi is a single building figure that loops — no kuse rotation.
        .cycle_bias_amount = 0.0,
        // Oroshi keeps its own dramatic build; no cross-cycle tempo drift.
        .tempo_cycle_drift = 0.0,
        // Oroshi is a single building figure — no A/B variants.
        .variant_period_cycles = 0,
        .variant_intensity_offset = 0.0,
    },
    // hachijo — island style, two players on one drum: steady ground (shitabyōshi)
    // under a free improvising lead (uwabyōshi). Conversational, intimate.
    .{
        .root = 38,
        .scale_type = .dorian,
        .base_bpm = 96.0,
        .chord_change_beats = 16.0,
        .pattern_style = .hachijo,
        .progressive_roll = false,
        .swing_amount = 0.06,
        // Odaiko: very sparse, gentle pulse on beat 1
        .odaiko_mask = (1 << 0),
        .odaiko_fill_mask = (1 << 8),
        // Lead nagado (uwabyōshi) follows lead_pattern; masks describe its baseline.
        .nagado1_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .nagado1_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        // Nagado 2 is sparse support
        .nagado2_don_mask = (1 << 8),
        .nagado2_ka_mask = 0,
        // Shime light, quarters only
        .shime_ji_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .shime_accent_mask = (1 << 0) | (1 << 8),
        .lead_density = 0.78, // high — improv is the point
        .lead_rebuild_cycles = 2, // frequent — lead is the variation engine
        .ghost_density = 0.20,
        .fill_density = 0.18,
        .break_chance = 0.08,
        .call_response_chance = 0.22,
        .roll_chance = 0.05,
        .energy = 0.55,
        .reverb_boost = 0.08,
        .tempo_drift = 0.02,
        // Kane shifts frequently (conversational accents); backline holds rock-steady.
        .kane_hold_beats = 64,
        .nagado_back_hold_beats = 256,
        // Hachijo has many "verses" — conversational rotation is strong.
        .cycle_bias_amount = 0.35,
        .tempo_cycle_drift = 0.0,
        .variant_period_cycles = 4,
        .variant_intensity_offset = 0.15,
    },
    // bon_odori — Obon summer dance accompaniment. Slow-to-moderate,
    // repetitive, communal. Easy quarter feel, minimal syncopation.
    .{
        .root = 36,
        .scale_type = .major_pentatonic,
        .base_bpm = 94.0,
        .chord_change_beats = 16.0,
        .pattern_style = .bon_odori,
        .progressive_roll = false,
        .swing_amount = 0.02,
        // Odaiko prominent on all quarters (the dance pulse)
        .odaiko_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .odaiko_fill_mask = 0,
        // Lead nagado on the same quarter grid, less syncopated than matsuri
        .nagado1_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .nagado1_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .nagado2_don_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .nagado2_ka_mask = 0,
        // Shime steady 8ths
        .shime_ji_mask = 0x5555,
        .shime_accent_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .lead_density = 0.50,
        .lead_rebuild_cycles = 6, // slow to evolve — repetitive by design
        .ghost_density = 0.10,
        .fill_density = 0.12,
        .break_chance = 0.02,
        .call_response_chance = 0.05,
        .roll_chance = 0.03,
        .energy = 0.52,
        .reverb_boost = 0.02,
        .tempo_drift = 0.0, // steady for dancing
        .kane_hold_beats = 128,
        .nagado_back_hold_beats = 128,
        .cycle_bias_amount = 0.10, // very repetitive
        .tempo_cycle_drift = 0.0,
        .variant_period_cycles = 0, // bon-odori stays in one mode
        .variant_intensity_offset = 0.0,
    },
    // furi_uchi — ceremonial slow style. Sparse, dignified, dramatic.
    // Lots of "ma" (silence) between strikes; rolls are structural.
    .{
        .root = 33,
        .scale_type = .harmonic_minor,
        .base_bpm = 72.0,
        .chord_change_beats = 24.0,
        .pattern_style = .furi_uchi,
        .progressive_roll = false,
        .swing_amount = 0.0,
        // Odaiko on half notes — big, deliberate
        .odaiko_mask = (1 << 0) | (1 << 8),
        .odaiko_fill_mask = (1 << 4) | (1 << 12),
        // Lead nagado on the strong beats
        .nagado1_don_mask = (1 << 0) | (1 << 8),
        .nagado1_ka_mask = (1 << 4) | (1 << 12),
        .nagado2_don_mask = (1 << 4) | (1 << 12),
        .nagado2_ka_mask = 0,
        // Shime extremely sparse, half notes only
        .shime_ji_mask = (1 << 0) | (1 << 8),
        .shime_accent_mask = (1 << 0),
        .lead_density = 0.30, // sparse
        .lead_rebuild_cycles = 8, // rarely changes
        .ghost_density = 0.05,
        .fill_density = 0.20,
        .break_chance = 0.0,
        .call_response_chance = 0.0,
        .roll_chance = 0.18, // rolls are the structural element
        .energy = 0.40,
        .reverb_boost = 0.12, // big ceremonial space
        .tempo_drift = 0.04,
        // One phase per macro cycle for both — utterly steady.
        .kane_hold_beats = 256,
        .nagado_back_hold_beats = 256,
        .cycle_bias_amount = 0.15,
        .tempo_cycle_drift = 0.0,
        .variant_period_cycles = 4,
        .variant_intensity_offset = -0.15, // B-flavor is even sparser
    },
};

const TaikoCueMorph = cue_morph.CueMorph(CuePreset);
var cue_state: TaikoCueMorph = .{
    .from = .matsuri,
    .to = .matsuri,
    .progress = 1.0,
    .morph_beats = 24.0,
};
var structural_cue: CuePreset = .matsuri;
var pending_scale_type: ?composition.ScaleType = null;

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn blendedCueSpec() TaikoCueSpec {
    const from = CUE_SPECS[@intFromEnum(cue_state.from)];
    const to = CUE_SPECS[@intFromEnum(cue_state.to)];
    const t = cue_state.progress;
    var spec = CUE_SPECS[@intFromEnum(structural_cue)];
    spec.base_bpm = lerpF32(from.base_bpm, to.base_bpm, t);
    spec.swing_amount = lerpF32(from.swing_amount, to.swing_amount, t);
    spec.lead_density = lerpF32(from.lead_density, to.lead_density, t);
    spec.ghost_density = lerpF32(from.ghost_density, to.ghost_density, t);
    spec.fill_density = lerpF32(from.fill_density, to.fill_density, t);
    spec.break_chance = lerpF32(from.break_chance, to.break_chance, t);
    spec.call_response_chance = lerpF32(from.call_response_chance, to.call_response_chance, t);
    spec.roll_chance = lerpF32(from.roll_chance, to.roll_chance, t);
    spec.energy = lerpF32(from.energy, to.energy, t);
    spec.reverb_boost = lerpF32(from.reverb_boost, to.reverb_boost, t);
    spec.tempo_drift = lerpF32(from.tempo_drift, to.tempo_drift, t);
    return spec;
}

fn cueIndexF32(cue: CuePreset) f32 {
    return @floatFromInt(@intFromEnum(cue));
}

fn applyInstrumentTuning(cue_idx: f32) void {
    odaiko.base_freq = 44.0 + cue_idx * 4.0;
    nagado1.base_freq = 130.0 + cue_idx * 12.0;
    nagado2.base_freq = 155.0 + cue_idx * 12.0;
    nagado3.base_freq = 142.0 + cue_idx * 10.0;
    nagado4.base_freq = 174.0 + cue_idx * 9.0;
    shime1.base_freq = 390.0 + cue_idx * 14.0;
    shime2.base_freq = 426.0 + cue_idx * 14.0;
    kane.base_freq = 880.0 + cue_idx * 40.0;
}

fn randomizeTemporalState(initial_bpm: f32) void {
    if (initial_bpm <= 0.0) {
        std.log.warn("procedural_taiko.randomizeTemporalState: invalid bpm={d}, skipping randomization", .{initial_bpm});
        return;
    }
    runner.engine.arcs.micro.beat_count = dsp.rngFloat(&rng) * runner.engine.arcs.micro.section_beats;
    runner.engine.arcs.meso.beat_count = dsp.rngFloat(&rng) * runner.engine.arcs.meso.section_beats;
    runner.engine.arcs.macro.beat_count = dsp.rngFloat(&rng) * runner.engine.arcs.macro.section_beats;
    const macro_quarter_f = runner.engine.arcs.macro.beat_count / runner.engine.arcs.macro.section_beats * 4.0;
    runner.engine.last_macro_quarter = @intFromFloat(std.math.clamp(macro_quarter_f, 0.0, 3.0));

    runner.sequencer.step = @intCast(dsp.rngNext(&rng) % 16);
    const samples_per_step = dsp.SAMPLE_RATE * 60.0 / initial_bpm / 4.0;
    if (samples_per_step <= 1.0) {
        std.log.warn("procedural_taiko.randomizeTemporalState: invalid samples_per_step={d}", .{samples_per_step});
        runner.sequencer.step_counter = 0.0;
    } else {
        runner.sequencer.step_counter = dsp.rngFloat(&rng) * samples_per_step;
    }

    runner.engine.chord_beat_counter = dsp.rngFloat(&rng) * @max(runner.engine.chord_change_beats, 1.0);
}

fn maybeAdvanceStructuralCue(step: u8) void {
    if (step != 15) return;
    const target_cue = cue_state.to;
    if (structural_cue == target_cue) return;

    const switch_p = std.math.clamp((cue_state.progress - 0.15) / 0.85, 0.0, 1.0);
    if (dsp.rngFloat(&rng) >= switch_p) return;

    structural_cue = target_cue;
    const target = CUE_SPECS[@intFromEnum(structural_cue)];
    composition.compositionEngineSetChordChangeBeats(&runner.engine, target.chord_change_beats);
    composition.keyStateModulateTo(&runner.engine.key, target.root);
    pending_scale_type = target.scale_type;
}

// ============================================================
// Instruments
// ============================================================

var odaiko: instruments.Odaiko = .{};
var nagado1: instruments.Nagado = .{ .base_freq = 140.0, .volume = 0.85 };
var nagado2: instruments.Nagado = .{ .base_freq = 165.0, .volume = 0.78 };
var nagado3: instruments.Nagado = .{ .base_freq = 148.0, .volume = 0.62 };
var nagado4: instruments.Nagado = .{ .base_freq = 178.0, .volume = 0.58 };
var shime1: instruments.Shime = .{ .base_freq = 400.0, .volume = 0.6 };
var shime2: instruments.Shime = .{ .base_freq = 436.0, .volume = 0.55 };
var kane: instruments.Atarigane = .{};

// ============================================================
// Microtiming
// ============================================================

const NUM_VOICES: usize = 8;
const V_ODAIKO: usize = 0;
const V_NAGADO1: usize = 1;
const V_NAGADO2: usize = 2;
const V_NAGADO3: usize = 3;
const V_NAGADO4: usize = 4;
const V_SHIME1: usize = 5;
const V_SHIME2: usize = 6;
const V_KANE: usize = 7;

const VOICE_OFFSETS: [NUM_VOICES]f32 = .{
    4.5, // odaiko: behind (massive drum, deliberate)
    1.8, // nagado1: slightly behind
    -1.5, // nagado2: slightly ahead
    0.8, // nagado3: ensemble support, near center
    -0.8, // nagado4: ensemble support, answering side
    0.0, // shime1: reference (timekeeper)
    0.5, // shime2: nearly on reference
    -2.0, // kane: slightly ahead (bright, cutting)
};
const JITTER_SAMPLES: f32 = 2.0;

const VOICE_PAN: [NUM_VOICES]f32 = .{
    0.0, // odaiko: center
    -0.42, // nagado1: left
    0.42, // nagado2: right
    -0.16, // nagado3: inner left
    0.16, // nagado4: inner right
    -0.55, // shime1: further left
    0.55, // shime2: further right
    0.0, // kane: center (cuts through)
};

const TriggerType = enum {
    none,
    don,
    ka,
    ghost,
    roll,
    open,
    chi,
    ki,
    choke,
    damp,
    muted,
};

const PendingTrigger = struct {
    trigger_type: TriggerType = .none,
    delay: f32 = 0.0,
    velocity: f32 = 0.0,
};

const PENDING_SLOTS_PER_VOICE: usize = 8;
const EMPTY_PENDING_ROW: [PENDING_SLOTS_PER_VOICE]PendingTrigger = .{PendingTrigger{}} ** PENDING_SLOTS_PER_VOICE;
var pending: [NUM_VOICES][PENDING_SLOTS_PER_VOICE]PendingTrigger = .{EMPTY_PENDING_ROW} ** NUM_VOICES;

fn scheduleTrigger(voice: usize, ttype: TriggerType, vel: f32) void {
    scheduleTriggerAfter(voice, ttype, vel, 0.0);
}

fn scheduleTriggerAfter(voice: usize, ttype: TriggerType, vel: f32, extra_delay_samples: f32) void {
    if (voice >= NUM_VOICES) {
        std.log.warn("procedural_taiko.scheduleTriggerAfter: voice {d} out of range", .{voice});
        return;
    }
    if (ttype == .none or vel <= 0.0) return;

    const offset = VOICE_OFFSETS[voice] + extra_delay_samples + (dsp.rngFloat(&rng) * 2.0 - 1.0) * JITTER_SAMPLES;
    for (0..PENDING_SLOTS_PER_VOICE) |slot| {
        if (pending[voice][slot].trigger_type != .none) continue;
        pending[voice][slot] = .{
            .trigger_type = ttype,
            .delay = @max(offset, 0.0),
            .velocity = vel,
        };
        return;
    }
}

fn processPendingTriggers() void {
    for (0..NUM_VOICES) |i| {
        for (0..PENDING_SLOTS_PER_VOICE) |slot| {
            if (pending[i][slot].trigger_type == .none) continue;
            if (pending[i][slot].delay <= 0) {
                fireTrigger(i, pending[i][slot].trigger_type, pending[i][slot].velocity);
                pending[i][slot].trigger_type = .none;
            } else {
                pending[i][slot].delay -= 1.0;
            }
        }
    }
}

const KUCHI_PAIR_DELAY_SAMPLES: f32 = dsp.SAMPLE_RATE * 0.034;
const KUCHI_SOFT_PAIR_DELAY_SAMPLES: f32 = dsp.SAMPLE_RATE * 0.026;
const KANE_STROKE_DELAY_SAMPLES: f32 = dsp.SAMPLE_RATE * 0.108;

fn scheduleDoko(voice: usize, vel: f32) void {
    scheduleTrigger(voice, .don, vel);
    scheduleTriggerAfter(voice, .ghost, vel * 0.62, KUCHI_PAIR_DELAY_SAMPLES);
}

fn scheduleDoro(voice: usize, vel: f32) void {
    scheduleTrigger(voice, .don, vel);
    scheduleTriggerAfter(voice, .don, vel * 0.56, KUCHI_PAIR_DELAY_SAMPLES);
}

fn scheduleKara(voice: usize, vel: f32) void {
    scheduleTrigger(voice, .ka, vel);
    scheduleTriggerAfter(voice, .ka, vel * 0.82, KUCHI_SOFT_PAIR_DELAY_SAMPLES);
}

fn scheduleTsuku(voice: usize, vel: f32) void {
    scheduleTrigger(voice, .ghost, vel);
    scheduleTriggerAfter(voice, .ghost, vel * 0.70, KUCHI_SOFT_PAIR_DELAY_SAMPLES);
}

fn scheduleDonKa(voice: usize, vel: f32) void {
    scheduleTrigger(voice, .don, vel);
    scheduleTriggerAfter(voice, .ka, vel * 0.72, KUCHI_PAIR_DELAY_SAMPLES);
}

fn fireTrigger(voice: usize, ttype: TriggerType, vel: f32) void {
    switch (voice) {
        V_ODAIKO => switch (ttype) {
            .don => instruments.odaikoTriggerDon(&odaiko, vel),
            .ka => instruments.odaikoTriggerKa(&odaiko, vel),
            .ghost => instruments.odaikoTriggerGhost(&odaiko, vel),
            else => {},
        },
        V_NAGADO1 => switch (ttype) {
            .don => instruments.nagadoTriggerDon(&nagado1, vel),
            .ka => instruments.nagadoTriggerKa(&nagado1, vel),
            .ghost => instruments.nagadoTriggerGhost(&nagado1, vel),
            else => {},
        },
        V_NAGADO2 => switch (ttype) {
            .don => instruments.nagadoTriggerDon(&nagado2, vel),
            .ka => instruments.nagadoTriggerKa(&nagado2, vel),
            .ghost => instruments.nagadoTriggerGhost(&nagado2, vel),
            else => {},
        },
        V_NAGADO3 => switch (ttype) {
            .don => instruments.nagadoTriggerDon(&nagado3, vel),
            .ka => instruments.nagadoTriggerKa(&nagado3, vel),
            .ghost => instruments.nagadoTriggerGhost(&nagado3, vel),
            else => {},
        },
        V_NAGADO4 => switch (ttype) {
            .don => instruments.nagadoTriggerDon(&nagado4, vel),
            .ka => instruments.nagadoTriggerKa(&nagado4, vel),
            .ghost => instruments.nagadoTriggerGhost(&nagado4, vel),
            else => {},
        },
        V_SHIME1 => switch (ttype) {
            .don => instruments.shimeTriggerDon(&shime1, vel),
            .ka => instruments.shimeTriggerKa(&shime1, vel),
            .ghost => instruments.shimeTriggerRoll(&shime1, vel),
            .roll => instruments.shimeTriggerRoll(&shime1, vel),
            else => {},
        },
        V_SHIME2 => switch (ttype) {
            .don => instruments.shimeTriggerDon(&shime2, vel),
            .ka => instruments.shimeTriggerKa(&shime2, vel),
            .ghost => instruments.shimeTriggerRoll(&shime2, vel),
            .roll => instruments.shimeTriggerRoll(&shime2, vel),
            else => {},
        },
        V_KANE => switch (ttype) {
            .open => instruments.atariganeTriggerChan(&kane, vel),
            .chi => instruments.atariganeTriggerChi(&kane, vel),
            .ki => instruments.atariganeTriggerKi(&kane, vel),
            .choke, .muted => instruments.atariganeTriggerChoke(&kane, vel),
            .damp => instruments.atariganeDamp(&kane, vel),
            else => {},
        },
        else => {},
    }
}

// ============================================================
// Lead improvisation (nagado1 solos over ensemble)
// ============================================================

const LeadHit = enum { none, don, ka, ghost, don_don };
var lead_pattern: [16]LeadHit = .{.none} ** 16;
var lead_cycle_count: u16 = 0;
var in_break: bool = false;
var break_remaining: u8 = 0;
var in_call_response: bool = false;
var call_response_remaining: u8 = 0;
var is_response_phase: bool = false;
const LEAD_HISTORY_SIZE: usize = 10;
var lead_history: pattern_history.PatternHistory = .{ .capacity = LEAD_HISTORY_SIZE };

fn hashLeadPattern() u32 {
    return pattern_history.hashEnumPattern(LeadHit, lead_pattern[0..]);
}

fn randomTaikoLeadHit(is_strong: bool) LeadHit {
    const r = dsp.rngFloat(&rng);
    if (is_strong and r < 0.22) return .don_don;
    if (r < 0.52) return .don;
    if (r < 0.84) return .ka;
    return .ghost;
}

fn mutateLeadPattern(spec: *const TaikoCueSpec, meso: f32) void {
    const mutations: u8 = 2 + @as(u8, @intCast(dsp.rngNext(&rng) % 4));
    const keep_chance = std.math.clamp(0.5 + spec.energy * 0.26 + meso * 0.18, 0.0, 0.98);
    for (0..mutations) |_| {
        const idx: usize = @intCast(dsp.rngNext(&rng) % 16);
        const step: u8 = @intCast(idx);
        if (dsp.rngFloat(&rng) < keep_chance) {
            lead_pattern[idx] = randomTaikoLeadHit(step % 4 == 0);
            continue;
        }
        lead_pattern[idx] = .none;
    }
}

fn forceLeadPerturbation() void {
    const idx: usize = @intCast(dsp.rngNext(&rng) % 16);
    const step: u8 = @intCast(idx);
    lead_pattern[idx] = randomTaikoLeadHit(step % 4 == 0);
}

fn generateLeadPattern(meso: f32, spec: *const TaikoCueSpec) void {
    var hit_count: u8 = 0;
    const energy = std.math.clamp(spec.energy * (0.35 + meso * 0.75), 0.0, 1.0);

    for (0..16) |i| {
        const step: u8 = @intCast(i);
        const is_strong = (step % 4 == 0);
        const is_mid = (step % 2 == 0);
        const base_chance: f32 = if (is_strong) 0.72 else if (is_mid) 0.4 + spec.swing_amount * 0.45 else 0.16 + spec.swing_amount * 0.35;
        const chance = base_chance * energy * spec.lead_density;
        if (dsp.rngFloat(&rng) >= chance) {
            lead_pattern[i] = .none;
            continue;
        }

        // Use phrase generator for pitch-aware hit selection.
        const pick = composition.nextPhraseNoteWithMemory(&rng, &lead_phrase, &lead_memory, 0.3);
        if (pick == null) {
            lead_pattern[i] = .ghost;
            hit_count += 1;
            continue;
        }
        const p = pick.?;
        if (is_strong and p.note % 3 == 0) {
            lead_pattern[i] = .don_don;
            hit_count += 1;
            continue;
        }
        if (p.note % 2 == 0) {
            lead_pattern[i] = .don;
            hit_count += 1;
            continue;
        }
        lead_pattern[i] = .ka;
        hit_count += 1;
    }

    if (hit_count == 0) {
        const idx: usize = @intCast((dsp.rngNext(&rng) % 4) * 4);
        lead_pattern[idx] = .don;
    }
}

// Phrase memory for lead nagado — motif recall for musical coherence
var lead_phrase: composition.PhraseGenerator = .{
    .anchor = 4,
    .region_low = 0,
    .region_high = 8,
    .rest_chance = 0.2,
    .min_notes = 3,
    .max_notes = 7,
    .gravity = 2.5,
};
var lead_memory: composition.PhraseMemory = .{};

fn rebuildLeadPattern(meso: f32, spec: *const TaikoCueSpec) void {
    generateLeadPattern(meso, spec);
    var hash = hashLeadPattern();
    if (pattern_history.seenRecently(&lead_history, hash)) {
        mutateLeadPattern(spec, meso);
        hash = hashLeadPattern();
        if (pattern_history.seenRecently(&lead_history, hash)) {
            forceLeadPerturbation();
            hash = hashLeadPattern();
        }
    }
    pattern_history.remember(&lead_history, hash);
}

fn buildBreakPattern() void {
    // "Ma" (silence) followed by unison hits — dramatic taiko break
    for (0..16) |i| {
        const step: u8 = @intCast(i);
        if (step < 8) {
            // First half: silence (ma)
            lead_pattern[i] = if (step == 0) .don else .none;
        } else {
            // Second half: building unison DON
            if (step % 2 == 0) {
                lead_pattern[i] = .don;
            } else if (step >= 12) {
                lead_pattern[i] = .don; // fill in for climax
            } else {
                lead_pattern[i] = .none;
            }
        }
    }
}

fn buildCallPattern() void {
    // Leader plays a phrase
    for (0..16) |i| {
        const step: u8 = @intCast(i);
        if (step < 8) {
            // Call: leader plays
            const chance: f32 = if (step % 2 == 0) 0.7 else 0.3;
            if (dsp.rngFloat(&rng) < chance) {
                lead_pattern[i] = if (step % 4 == 0) .don_don else if (dsp.rngFloat(&rng) < 0.6) .don else .ka;
            } else {
                lead_pattern[i] = .none;
            }
        } else {
            // Response will be handled in advanceStep (all nagados echo)
            lead_pattern[i] = .none;
        }
    }
}

// ============================================================
// Public API
// ============================================================

pub fn reset() void {
    resetBusStats();
    rng = dsp.rngInit(entropy.nextSeed(0xDA1C_0000, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    structural_cue = selected_cue;
    pending_scale_type = null;
    reverb = dsp.stereoReverbInit(.{ 1801, 1907, 2053, 2111 }, .{ 241, 557 }, .{ 0.87, 0.88, 0.86, 0.89 });
    lfo_space = .{ .period_beats = 96, .depth = 0.03 };
    tempo_lfo = .{ .period_beats = 1024.0, .depth = 1.0 };
    macro_cycle_count = 0;
    last_macro_beat_global = -1.0;
    active_variant_offset = 0.0;

    composition.stepStyleRunnerReset(TaikoCueSpec, 4, &runner, &STYLE, .{ .root = 36, .scale_type = .dorian }, initHarmony(), CHORD_CHANGE_BEATS, .none, .{ 0.4, 0.5, 0.85, 0.7 }, .{ 0.3, 0.4, 0.8, 0.6 });

    resetInstruments();
    pending = .{EMPTY_PENDING_ROW} ** NUM_VOICES;
    kane_state = .{};
    nagado_back_state = .{};
    lead_cycle_count = 0;
    in_break = false;
    break_remaining = 0;
    in_call_response = false;
    call_response_remaining = 0;
    is_response_phase = false;
    pattern_history.clear(&lead_history);
    lead_phrase = .{ .anchor = 4, .region_low = 0, .region_high = 8, .rest_chance = 0.2, .min_notes = 3, .max_notes = 7, .gravity = 2.5 };
    lead_memory = .{};

    const initial = CUE_SPECS[@intFromEnum(selected_cue)];
    runner.engine.key.root = initial.root;
    runner.engine.key.target_root = initial.root;
    runner.engine.key.scale_type = initial.scale_type;
    composition.compositionEngineSetChordChangeBeats(&runner.engine, initial.chord_change_beats);
    applyInstrumentTuning(cueIndexF32(selected_cue));
    const reset_bpm = @max(CUE_SPECS[@intFromEnum(structural_cue)].base_bpm * bpm, 1.0);
    randomizeTemporalState(reset_bpm);
    const spec = &CUE_SPECS[@intFromEnum(cue_state.to)];
    if (!spec.progressive_roll) {
        rebuildLeadPattern(0.3, spec);
    }
}

fn resetInstruments() void {
    odaiko = .{};
    nagado1 = .{ .base_freq = 140.0, .volume = 0.85 };
    nagado2 = .{ .base_freq = 165.0, .volume = 0.78 };
    nagado3 = .{ .base_freq = 148.0, .volume = 0.62 };
    nagado4 = .{ .base_freq = 178.0, .volume = 0.58 };
    shime1 = .{ .base_freq = 400.0, .volume = 0.6 };
    shime2 = .{ .base_freq = 436.0, .volume = 0.55 };
    kane = .{};
}

fn meterSample(meter: *TaikoMeterStats, sample: f32) void {
    meter.samples += 1;
    meter.peak_abs = @max(meter.peak_abs, @abs(sample));
    const sample_f64: f64 = sample;
    meter.sum_sq += sample_f64 * sample_f64;
}

fn meterStereo(meter: *TaikoMeterStats, left: f32, right: f32) void {
    meterSample(meter, left);
    meterSample(meter, right);
}

fn meterTaikoBuses(
    odaiko_bus: [2]f32,
    nagado_bus: [2]f32,
    shime_bus: [2]f32,
    kane_bus: [2]f32,
    dry_bus: [2]f32,
    reverb_bus: [2]f32,
    final_bus: [2]f32,
) void {
    if (!collect_bus_stats) return;

    meterStereo(&bus_stats.odaiko, odaiko_bus[0], odaiko_bus[1]);
    meterStereo(&bus_stats.nagado, nagado_bus[0], nagado_bus[1]);
    meterStereo(&bus_stats.shime, shime_bus[0], shime_bus[1]);
    meterStereo(&bus_stats.kane, kane_bus[0], kane_bus[1]);
    meterStereo(&bus_stats.dry, dry_bus[0], dry_bus[1]);
    meterStereo(&bus_stats.reverb, reverb_bus[0], reverb_bus[1]);
    meterStereo(&bus_stats.final, final_bus[0], final_bus[1]);
}

pub fn triggerCue() void {
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const nominal_bpm = @max(CUE_SPECS[@intFromEnum(cue_state.to)].base_bpm * bpm, 1.0);
    const cue_spb = dsp.samplesPerBeat(nominal_bpm);

    for (0..frames) |i| {
        cue_morph.advance(CuePreset, &cue_state, cue_spb);
        var spec = blendedCueSpec();
        const section_density = composition.compositionEngineSectionDensity(&runner.engine);
        const section_harmonic = composition.compositionEngineSectionHarmonicMotion(&runner.engine);
        const from_cue = cue_state.from;
        const to_cue = cue_state.to;
        const cue_idx = lerpF32(cueIndexF32(from_cue), cueIndexF32(to_cue), cue_state.progress);

        spec.lead_density = std.math.clamp(spec.lead_density * (0.72 + section_density * 0.62), 0.04, 0.98);
        spec.ghost_density = std.math.clamp(spec.ghost_density * (0.7 + section_density * 0.65), 0.02, 0.9);
        spec.fill_density = std.math.clamp(spec.fill_density * (0.7 + section_density * 0.75), 0.03, 0.95);
        spec.energy = std.math.clamp(spec.energy * (0.78 + section_density * 0.42), 0.1, 1.0);
        spec.call_response_chance = std.math.clamp(spec.call_response_chance * (0.75 + section_harmonic * 0.55), 0.0, 0.95);
        spec.roll_chance = std.math.clamp(spec.roll_chance * (0.8 + section_harmonic * 0.45), 0.0, 0.95);

        applyInstrumentTuning(cue_idx);
        // Track macro-cycle wraps for A/B sub-flavor alternation.
        const cur_macro_beat = runner.engine.arcs.macro.beat_count;
        if (last_macro_beat_global > cur_macro_beat) {
            macro_cycle_count +%= 1;
        }
        last_macro_beat_global = cur_macro_beat;
        if (spec.variant_period_cycles > 0) {
            const variant_b_active = (macro_cycle_count / spec.variant_period_cycles) & 1 == 1;
            active_variant_offset = if (variant_b_active) spec.variant_intensity_offset else 0.0;
        } else {
            active_variant_offset = 0.0;
        }

        // Within-arc tempo drift: macro arc pushes tempo up at Kyu climax.
        const macro_t = composition.arcControllerTension(&runner.engine.arcs.macro);
        const inner_bpm = spec.base_bpm * bpm * (1.0 + macro_t * spec.tempo_drift);
        // Cross-cycle tempo drift via slow LFO (procession acceleration).
        // Period 1024 beats ≈ 8 min at yatai 128 bpm — much longer than macro arc.
        composition.slowLfoAdvanceSample(&tempo_lfo, inner_bpm);
        const tempo_cycle_mod = 1.0 + composition.slowLfoValue(&tempo_lfo) * spec.tempo_cycle_drift;
        const effective_bpm = inner_bpm * tempo_cycle_mod;
        composition.slowLfoAdvanceSample(&lfo_space, effective_bpm);
        const frame = composition.stepStyleRunnerAdvanceFrame(TaikoCueSpec, 4, &runner, &rng, &STYLE, effective_bpm, LAYER_FADE_RATE);

        if (frame.tick.chord_changed and pending_scale_type != null and cue_state.progress >= 0.5) {
            runner.engine.key.scale_type = pending_scale_type.?;
            pending_scale_type = null;
        }

        if (frame.step) |step| {
            maybeAdvanceStructuralCue(step);
            advanceStep(step, frame.tick.meso, frame.tick.micro, &spec);

            // End of 16-step bar
            if (step == 15 and !spec.progressive_roll) {
                lead_cycle_count += 1;
                if (lead_cycle_count >= spec.lead_rebuild_cycles) {
                    lead_cycle_count = 0;

                    // Check for break ("ma" moment)
                    if (!in_break and !in_call_response and dsp.rngFloat(&rng) < spec.break_chance * frame.tick.macro) {
                        in_break = true;
                        break_remaining = 1;
                        buildBreakPattern();
                    } else if (in_break) {
                        break_remaining -|= 1;
                        if (break_remaining == 0) {
                            in_break = false;
                        }
                    }

                    // Check for call-and-response
                    if (!in_break and !in_call_response and dsp.rngFloat(&rng) < spec.call_response_chance * frame.tick.meso) {
                        in_call_response = true;
                        call_response_remaining = 2 + @as(u8, @intCast(dsp.rngNext(&rng) % 3));
                        is_response_phase = false;
                        buildCallPattern();
                    } else if (in_call_response) {
                        is_response_phase = !is_response_phase;
                        call_response_remaining -|= 1;
                        if (call_response_remaining == 0) {
                            in_call_response = false;
                        } else {
                            buildCallPattern();
                        }
                    }

                    if (!in_break and !in_call_response) {
                        rebuildLeadPattern(frame.tick.meso, &spec);
                    }
                }
            }
        }

        processPendingTriggers();

        // ---- Mix ----
        var dry_left: f32 = 0.0;
        var dry_right: f32 = 0.0;

        // Long-form director-driven mix scaling. Background voices (kane,
        // backline, shime) breathe with director.intensity; the lead nagado
        // and odaiko stay full-presence so the groove anchor never sags.
        const director_norm = std.math.clamp((composition.compositionEngineLongFormIntensity(&runner.engine) - 0.12) / 0.84, 0.0, 1.0);
        const back_dir_scale = 0.70 + director_norm * 0.30;
        const kane_dir_scale = 0.55 + director_norm * 0.45;
        const shime_dir_scale = 0.85 + director_norm * 0.15;

        // Odaiko — massive center presence
        const odaiko_raw = instruments.odaikoProcess(&odaiko) * drum_mix * runner.layer_levels[ODAIKO_LAYER] * 1.2 * TAIKO_ODAIKO_BUS_GAIN;
        const odaiko_s = if (voice_mute[V_ODAIKO]) 0.0 else odaiko_raw;
        const odaiko_bus = .{ odaiko_s, odaiko_s };
        dry_left += odaiko_bus[0];
        dry_right += odaiko_bus[1];

        // Nagados
        const n1_raw = instruments.nagadoProcess(&nagado1, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER] * TAIKO_NAGADO_BUS_GAIN;
        const n1_s = if (voice_mute[V_NAGADO1]) 0.0 else n1_raw;
        const n1_pan = dsp.panStereo(n1_s, VOICE_PAN[V_NAGADO1]);
        dry_left += n1_pan[0];
        dry_right += n1_pan[1];

        const n2_raw = instruments.nagadoProcess(&nagado2, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER] * TAIKO_NAGADO_BUS_GAIN;
        const n2_s = if (voice_mute[V_NAGADO2]) 0.0 else n2_raw;
        const n2_pan = dsp.panStereo(n2_s, VOICE_PAN[V_NAGADO2]);
        dry_left += n2_pan[0];
        dry_right += n2_pan[1];

        const n3_raw = instruments.nagadoProcess(&nagado3, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER] * TAIKO_NAGADO_BUS_GAIN * back_dir_scale;
        const n3_s = if (voice_mute[V_NAGADO3]) 0.0 else n3_raw;
        const n3_pan = dsp.panStereo(n3_s, VOICE_PAN[V_NAGADO3]);
        dry_left += n3_pan[0];
        dry_right += n3_pan[1];

        const n4_raw = instruments.nagadoProcess(&nagado4, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER] * TAIKO_NAGADO_BUS_GAIN * back_dir_scale;
        const n4_s = if (voice_mute[V_NAGADO4]) 0.0 else n4_raw;
        const n4_pan = dsp.panStereo(n4_s, VOICE_PAN[V_NAGADO4]);
        dry_left += n4_pan[0];
        dry_right += n4_pan[1];

        const nagado_bus = .{
            n1_pan[0] + n2_pan[0] + n3_pan[0] + n4_pan[0],
            n1_pan[1] + n2_pan[1] + n3_pan[1] + n4_pan[1],
        };

        // Shimes
        const s1_raw = instruments.shimeProcess(&shime1, &rng) * shaker_mix * runner.layer_levels[SHIME_LAYER] * TAIKO_SHIME_BUS_GAIN * shime_dir_scale;
        const s1_s = if (voice_mute[V_SHIME1]) 0.0 else s1_raw;
        const s1_pan = dsp.panStereo(s1_s, VOICE_PAN[V_SHIME1]);
        dry_left += s1_pan[0];
        dry_right += s1_pan[1];

        const s2_raw = instruments.shimeProcess(&shime2, &rng) * shaker_mix * runner.layer_levels[SHIME_LAYER] * TAIKO_SHIME_BUS_GAIN * shime_dir_scale;
        const s2_s = if (voice_mute[V_SHIME2]) 0.0 else s2_raw;
        const s2_pan = dsp.panStereo(s2_s, VOICE_PAN[V_SHIME2]);
        dry_left += s2_pan[0];
        dry_right += s2_pan[1];
        const shime_bus = .{ s1_pan[0] + s2_pan[0], s1_pan[1] + s2_pan[1] };

        // Atarigane
        const kane_raw = instruments.atariganeProcess(&kane, &rng) * slap_mix * runner.layer_levels[KANE_LAYER] * TAIKO_KANE_BUS_GAIN * kane_dir_scale;
        const kane_s = if (voice_mute[V_KANE]) 0.0 else kane_raw;
        const kane_bus = .{ kane_s, kane_s };
        dry_left += kane_bus[0]; // center
        dry_right += kane_bus[1];

        // Reverb — large space
        const wet = std.math.clamp((reverb_mix + spec.reverb_boost) * composition.slowLfoModulate(&lfo_space), 0.0, TAIKO_REVERB_MAX_WET);
        const dry_gain = 1.0 - wet * TAIKO_REVERB_DRY_DUCK;
        const rev = dsp.stereoReverbProcess(.{ 1801, 1907, 2053, 2111 }, .{ 241, 557 }, &reverb, .{
            dry_left * TAIKO_REVERB_SEND_GAIN,
            dry_right * TAIKO_REVERB_SEND_GAIN,
        });
        const output_scale = dry_gain * TAIKO_MASTER_OUTPUT_GAIN;
        const dry_bus = .{ dry_left * output_scale, dry_right * output_scale };
        const reverb_bus = .{
            rev[0] * wet * TAIKO_REVERB_RETURN_GAIN * TAIKO_MASTER_OUTPUT_GAIN,
            rev[1] * wet * TAIKO_REVERB_RETURN_GAIN * TAIKO_MASTER_OUTPUT_GAIN,
        };
        const final_bus = .{
            softClip(dry_bus[0] + reverb_bus[0]),
            softClip(dry_bus[1] + reverb_bus[1]),
        };

        meterTaikoBuses(
            .{ odaiko_bus[0] * output_scale, odaiko_bus[1] * output_scale },
            .{ nagado_bus[0] * output_scale, nagado_bus[1] * output_scale },
            .{ shime_bus[0] * output_scale, shime_bus[1] * output_scale },
            .{ kane_bus[0] * output_scale, kane_bus[1] * output_scale },
            dry_bus,
            reverb_bus,
            final_bus,
        );

        buf[i * 2] = final_bus[0];
        buf[i * 2 + 1] = final_bus[1];
    }
}

// ============================================================
// Step logic
// ============================================================

fn advanceStep(step: u8, meso: f32, micro: f32, spec: *const TaikoCueSpec) void {
    _ = micro;
    const macro_t = composition.arcControllerTension(&runner.engine.arcs.macro);
    const vel_base: f32 = (0.48 + meso * 0.36) * (0.82 + spec.energy * 0.28);
    const accent: f32 = if (step % 4 == 0) 1.0 else if (step % 2 == 0) 0.76 + spec.swing_amount * 0.35 else 0.56 + spec.swing_amount * 0.4;

    if (spec.progressive_roll) {
        advanceOroshiStep(step, meso, macro_t, vel_base, spec);
        return;
    }

    // ---- Odaiko ----
    if (in_break and step >= 8 and step % 2 == 0) {
        // During break recovery: odaiko joins the unison build
        scheduleTrigger(V_ODAIKO, .don, vel_base * 0.9);
    } else if (composition.stepActive(spec.odaiko_mask, step)) {
        scheduleTrigger(V_ODAIKO, .don, vel_base * accent);
    } else if (composition.stepActive(spec.odaiko_fill_mask, step) and dsp.rngFloat(&rng) < spec.fill_density * macro_t) {
        const fill_type: TriggerType = if (dsp.rngFloat(&rng) < 0.62) .ka else .don;
        const fill_vel: f32 = if (fill_type == .ka) vel_base * 0.58 else vel_base * 0.58;
        scheduleTrigger(V_ODAIKO, fill_type, fill_vel);
    } else if (step % 4 == 2 and dsp.rngFloat(&rng) < spec.fill_density * macro_t * 0.22) {
        scheduleTrigger(V_ODAIKO, .ka, vel_base * 0.40);
    } else if (dsp.rngFloat(&rng) < spec.ghost_density * macro_t * 0.3) {
        scheduleTrigger(V_ODAIKO, .ghost, vel_base * 0.3);
    }

    // ---- Nagado lead (nagado1) ----
    if (in_break) {
        const hit = lead_pattern[step];
        if (hit != .none) {
            const ttype = leadHitToTrigger(hit);
            scheduleTrigger(V_NAGADO1, ttype, vel_base * accent);
            // During breaks, nagado2 mirrors (unison power)
            scheduleTrigger(V_NAGADO2, ttype, vel_base * accent * 0.9);
        }
    } else if (in_call_response and is_response_phase and step >= 8) {
        // Response phase: nagado2 echoes the call pattern from first half
        if (step >= 8) {
            const echo_step = step - 8;
            const hit = lead_pattern[echo_step];
            if (hit != .none) {
                scheduleTrigger(V_NAGADO2, leadHitToTrigger(hit), vel_base * accent * 0.85);
            }
        }
        // Lead continues its pattern
        const hit = lead_pattern[step];
        if (hit != .none) {
            scheduleTrigger(V_NAGADO1, leadHitToTrigger(hit), vel_base * accent);
        }
    } else {
        // Normal: lead follows improvised pattern
        const hit = lead_pattern[step];
        if (hit != .none) {
            scheduleTrigger(V_NAGADO1, leadHitToTrigger(hit), vel_base * accent);
        }

        // Nagado 2: accompaniment pattern
        if (composition.stepActive(spec.nagado2_don_mask, step)) {
            scheduleTrigger(V_NAGADO2, .don, vel_base * accent * 0.78);
        } else if (composition.stepActive(spec.nagado2_ka_mask, step)) {
            if (dsp.rngFloat(&rng) < 0.5 + meso * 0.4) {
                scheduleTrigger(V_NAGADO2, .ka, vel_base * 0.65);
            }
        } else if (dsp.rngFloat(&rng) < spec.ghost_density * meso * 0.5) {
            scheduleTrigger(V_NAGADO2, .ghost, vel_base * 0.3);
        }
    }
    advanceNagadoBackline(step, meso, macro_t, vel_base, accent, spec);

    advanceShimeJi(step, meso, macro_t, vel_base, spec);

    advanceAtarigane(step, meso, macro_t, vel_base, spec);
}

fn advanceNagadoBackline(step: u8, meso: f32, macro_t: f32, vel_base: f32, accent: f32, spec: *const TaikoCueSpec) void {
    const back_vel = vel_base * (0.36 + macro_t * 0.18 + meso * 0.08);

    if (in_break) {
        if (step >= 8 and step % 2 == 0) {
            scheduleTrigger(V_NAGADO3, .don, back_vel * accent * 0.92);
            scheduleTrigger(V_NAGADO4, .don, back_vel * accent * 0.86);
        } else if (step >= 12 and step % 2 == 1) {
            scheduleKara(V_NAGADO4, back_vel * 0.48);
        }
        return;
    }

    if (spec.pattern_style == .oroshi) return;

    const intensity = nagadoBackPatternIntensity(meso, macro_t, spec.energy);
    const total_phase = updatePatternPhase(&nagado_back_state, spec.nagado_back_hold_beats);
    const style_changed = nagado_back_state.last_style != spec.pattern_style;
    const phase_changed = nagado_back_state.last_total_phase != total_phase;

    if (style_changed or phase_changed) {
        nagado_back_state.last_style = spec.pattern_style;
        nagado_back_state.last_total_phase = total_phase;
        nagado_back_state.current_idx = pickNagadoBackPattern(spec.pattern_style, intensity, nagado_back_state.cycle_count, spec.cycle_bias_amount);
    }

    const bank = nagadoBackPatternBank(spec.pattern_style);
    if (bank.len == 0) {
        std.log.warn("procedural_taiko.advanceNagadoBackline: empty backline bank for style {s}", .{@tagName(spec.pattern_style)});
        return;
    }
    const pattern = bank[nagado_back_state.current_idx % @as(u8, @intCast(bank.len))];

    fireNagadoBackStep(step, pattern, back_vel, accent);
}

fn shimeBaseVelocity(step: u8, vel_base: f32, spec: *const TaikoCueSpec) f32 {
    const is_accent = composition.stepActive(spec.shime_accent_mask, step);
    if (is_accent) return vel_base * (0.76 + spec.energy * 0.16);
    return vel_base * (0.38 + spec.energy * 0.18);
}

fn advanceShimeJi(step: u8, meso: f32, macro_t: f32, vel_base: f32, spec: *const TaikoCueSpec) void {
    const shime_vel = shimeBaseVelocity(step, vel_base, spec);

    switch (spec.pattern_style) {
        .matsuri => advanceMatsuriShimeJi(step, meso, shime_vel),
        .yatai_bayashi => advanceYataiShimeJi(step, meso, macro_t, shime_vel),
        .miyake => advanceMiyakeShimeJi(step, meso, macro_t, shime_vel),
        .oroshi => {},
        .hachijo => advanceHachijoShimeJi(step, meso, shime_vel),
        .bon_odori => advanceBonOdoriShimeJi(step, shime_vel),
        .furi_uchi => advanceFuriUchiShimeJi(step, macro_t, shime_vel),
    }

    if (dsp.rngFloat(&rng) < spec.roll_chance * macro_t and step % 4 == 3) {
        scheduleTrigger(V_SHIME1, .roll, vel_base * 0.54);
        scheduleTsuku(V_SHIME2, vel_base * 0.34);
    }
}

fn advanceMatsuriShimeJi(step: u8, meso: f32, shime_vel: f32) void {
    switch (step % 8) {
        0 => {
            scheduleTrigger(V_SHIME1, .don, shime_vel * 1.04);
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.62);
        },
        2 => {
            scheduleDoko(V_SHIME1, shime_vel * 0.78);
            if (dsp.rngFloat(&rng) < 0.34 + meso * 0.18) {
                scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.48);
            }
        },
        4 => {
            scheduleTrigger(V_SHIME1, .don, shime_vel * 0.86);
            scheduleTsuku(V_SHIME2, shime_vel * 0.44);
        },
        6 => {
            scheduleDonKa(V_SHIME1, shime_vel * 0.82);
            scheduleKara(V_SHIME2, shime_vel * 0.54);
        },
        7 => if (dsp.rngFloat(&rng) < 0.22 + meso * 0.18) {
            scheduleTrigger(V_SHIME2, .ghost, shime_vel * 0.38);
        },
        else => if (dsp.rngFloat(&rng) < 0.08 + meso * 0.08) {
            scheduleTrigger(V_SHIME1, .ka, shime_vel * 0.36);
        },
    }
}

fn advanceYataiShimeJi(step: u8, meso: f32, macro_t: f32, shime_vel: f32) void {
    if (step % 2 == 0) {
        scheduleTrigger(V_SHIME1, .don, shime_vel * 0.88);
        scheduleTrigger(V_SHIME2, .ghost, shime_vel * (0.54 + macro_t * 0.10));
    } else {
        scheduleTrigger(V_SHIME1, .ghost, shime_vel * 0.62);
        if (step % 4 == 1) {
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.52);
        } else {
            scheduleTrigger(V_SHIME2, .ghost, shime_vel * 0.44);
        }
    }

    if (step % 8 == 3 and dsp.rngFloat(&rng) < 0.35 + meso * 0.24) {
        scheduleKara(V_SHIME2, shime_vel * 0.52);
    } else if (step % 8 == 7 and dsp.rngFloat(&rng) < 0.30 + macro_t * 0.24) {
        scheduleTsuku(V_SHIME1, shime_vel * 0.42);
    }
}

fn advanceMiyakeShimeJi(step: u8, meso: f32, macro_t: f32, shime_vel: f32) void {
    if (step % 4 == 0) {
        scheduleTrigger(V_SHIME1, .don, shime_vel * 0.94);
        scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.56);
        return;
    }

    if (step % 4 == 2) {
        scheduleKara(V_SHIME1, shime_vel * 0.58);
        if (dsp.rngFloat(&rng) < 0.28 + macro_t * 0.20) {
            scheduleTrigger(V_SHIME2, .ghost, shime_vel * 0.42);
        }
        return;
    }

    if (dsp.rngFloat(&rng) < 0.10 + meso * 0.18) {
        scheduleTrigger(if (step % 4 == 1) V_SHIME2 else V_SHIME1, .ghost, shime_vel * 0.36);
    }
}

// Hachijo — light steady ground. Quarter-note feel, sparse.
fn advanceHachijoShimeJi(step: u8, meso: f32, shime_vel: f32) void {
    switch (step % 4) {
        0 => {
            scheduleTrigger(V_SHIME1, .don, shime_vel * 0.92);
        },
        2 => {
            if (dsp.rngFloat(&rng) < 0.55 + meso * 0.20) {
                scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.58);
            }
        },
        else => {},
    }
}

// Bon-odori — even quarter ground with kara on off-eighths.
fn advanceBonOdoriShimeJi(step: u8, shime_vel: f32) void {
    switch (step % 4) {
        0 => {
            scheduleTrigger(V_SHIME1, .don, shime_vel);
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.52);
        },
        2 => {
            scheduleTrigger(V_SHIME1, .ka, shime_vel * 0.62);
        },
        else => {},
    }
}

// Furi-uchi — very sparse, ceremonial. Mostly silent.
fn advanceFuriUchiShimeJi(step: u8, macro_t: f32, shime_vel: f32) void {
    if (step == 0) {
        scheduleTrigger(V_SHIME1, .don, shime_vel);
        scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.50);
    } else if (step == 8 and macro_t > 0.35) {
        scheduleTrigger(V_SHIME1, .ka, shime_vel * 0.60);
    }
}

// ============================================================
// Atarigane pattern bank — kuchi-shoga 16-step bayashi figures
// chan = open ring (long-decay center stroke, the "downbeat" sound)
// chi  = bright rim stroke
// ki   = sharper edge click
// damp = explicit hand-damp, used at phrase endings only
// Banks are ordered sparse -> dense; pickKanePattern weights by intensity.
// ============================================================

const AtariganePattern = struct {
    chan_mask: u16,
    chi_mask: u16,
    ki_mask: u16,
    damp_mask: u16,
};

// Matsuri — festival groove. Chan on the downbeats, chi/ki sprinkled.
const MATSURI_KANE_PATTERNS = [_]AtariganePattern{
    // Sparse: "CHAN — — — — — chi — | CHAN — — — — — chi —"
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 6) | (1 << 14),
        .ki_mask = 0,
        .damp_mask = (1 << 15),
    },
    // Moderate: "CHAN — chi ki — chi — ki | CHAN — chi ki — chi — ki"
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 2) | (1 << 5) | (1 << 10) | (1 << 13),
        .ki_mask = (1 << 3) | (1 << 7) | (1 << 11) | (1 << 15),
        .damp_mask = 0,
    },
    // Dense: "CHAN — chi ki chi ki ki ki | CHAN — chi ki chi ki ki —"
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 2) | (1 << 4) | (1 << 10) | (1 << 12),
        .ki_mask = (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 11) | (1 << 13) | (1 << 14),
        .damp_mask = (1 << 15),
    },
};

// Yatai-bayashi — driving float-procession. Continuous 16ths under chan accents.
const YATAI_KANE_PATTERNS = [_]AtariganePattern{
    // Quarter chans with chi-ki off-beat fills
    .{
        .chan_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .chi_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .ki_mask = (1 << 3) | (1 << 7) | (1 << 11) | (1 << 15),
        .damp_mask = 0,
    },
    // Driving 16ths — chan on 1 & 3, every other 16th filled
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 2) | (1 << 4) | (1 << 6) | (1 << 10) | (1 << 12) | (1 << 14),
        .ki_mask = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11) | (1 << 13) | (1 << 15),
        .damp_mask = 0,
    },
    // Call-and-answer: front half busy, back half holds
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 2) | (1 << 4) | (1 << 6) | (1 << 12),
        .ki_mask = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 14),
        .damp_mask = (1 << 15),
    },
};

// Miyake — bold and spacious. Chans dominate, ornaments are sparse.
const MIYAKE_KANE_PATTERNS = [_]AtariganePattern{
    // Very spacious: chan on 1, single chi at the back
    .{
        .chan_mask = (1 << 0),
        .chi_mask = (1 << 10),
        .ki_mask = 0,
        .damp_mask = (1 << 14),
    },
    // Half-time chans with chi-ki pickup
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 6) | (1 << 14),
        .ki_mask = (1 << 4) | (1 << 12),
        .damp_mask = (1 << 15),
    },
    // Building energy: ki pickups before each chan
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 6) | (1 << 14),
        .ki_mask = (1 << 5) | (1 << 7) | (1 << 13) | (1 << 15),
        .damp_mask = 0,
    },
};

// Hachijo — intimate conversational style. Kane is sparse, conversational.
const HACHIJO_KANE_PATTERNS = [_]AtariganePattern{
    // Sparse: chan @ 1 only
    .{
        .chan_mask = (1 << 0),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = (1 << 14),
    },
    // Moderate: chan @ 1 + 3, chi pickup before chan 3
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 6),
        .ki_mask = 0,
        .damp_mask = (1 << 14),
    },
    // Lively: chan @ 1 + 3, chi on off-eighths
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 4) | (1 << 12),
        .ki_mask = (1 << 6) | (1 << 14),
        .damp_mask = (1 << 15),
    },
};

// Bon-odori — communal dance. Kane is very sparse, only the strong beats.
const BON_ODORI_KANE_PATTERNS = [_]AtariganePattern{
    // Single chan per bar (very repetitive)
    .{
        .chan_mask = (1 << 0),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = 0,
    },
    // Half notes
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = 0,
    },
    // Half notes + simple chi on beat 2 & 4
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 4) | (1 << 12),
        .ki_mask = 0,
        .damp_mask = 0,
    },
};

// Furi-uchi — ceremonial. Kane is almost silent, marking only the most
// dignified moments. The space between strokes is the point.
const FURI_UCHI_KANE_PATTERNS = [_]AtariganePattern{
    // Single chan, long ring through the whole bar
    .{
        .chan_mask = (1 << 0),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = 0,
    },
    // Chan with a damp at phrase end
    .{
        .chan_mask = (1 << 0),
        .chi_mask = (1 << 8),
        .ki_mask = 0,
        .damp_mask = (1 << 15),
    },
    // Half notes
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = (1 << 15),
    },
};

// Oroshi — thunder roll, dramatic build. Kane is sparse; even at peak
// it stays uncluttered so it reads as a tolling gong over the roll.
const OROSHI_KANE_PATTERNS = [_]AtariganePattern{
    // Pre-roll: a single chan and a damp
    .{
        .chan_mask = (1 << 0),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = (1 << 14),
    },
    // Building: half-note chans
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = 0,
        .ki_mask = 0,
        .damp_mask = (1 << 15),
    },
    // Peak: half-note chans with chi pickup before the second chan
    .{
        .chan_mask = (1 << 0) | (1 << 8),
        .chi_mask = (1 << 6) | (1 << 14),
        .ki_mask = 0,
        .damp_mask = (1 << 15),
    },
};

const KANE_BANK_MAX: usize = 8;

// Tracks macro-arc-tied pattern selection. A "phase" is hold_beats long;
// patterns hold for one phase. Cycle count + intra-cycle phase gives a
// monotonic id that detects both phase boundaries AND macro cycle wraps,
// so a hold_beats >= section_beats still triggers exactly one repick per
// macro cycle.
const PatternPhaseState = struct {
    current_idx: u8 = 0,
    last_style: TaikoPatternStyle = .matsuri,
    last_total_phase: i64 = -1,
    cycle_count: u32 = 0,
    last_beat: f32 = -1.0,
};
var kane_state: PatternPhaseState = .{};

fn kanePatternBank(style: TaikoPatternStyle) []const AtariganePattern {
    return switch (style) {
        .matsuri => &MATSURI_KANE_PATTERNS,
        .yatai_bayashi => &YATAI_KANE_PATTERNS,
        .miyake => &MIYAKE_KANE_PATTERNS,
        .oroshi => &OROSHI_KANE_PATTERNS,
        .hachijo => &HACHIJO_KANE_PATTERNS,
        .bon_odori => &BON_ODORI_KANE_PATTERNS,
        .furi_uchi => &FURI_UCHI_KANE_PATTERNS,
    };
}

fn kanePatternIntensity(meso: f32, macro_t: f32, energy: f32) f32 {
    // Long-form director drifts on a ~3-min period that's coprime with the macro
    // arc, so the combined intensity never exactly repeats across cycles.
    // active_variant_offset adds a kuse-style A/B shift for the cues that use it.
    const director_t = composition.compositionEngineLongFormIntensity(&runner.engine);
    return std.math.clamp(0.20 * energy + 0.40 * macro_t + 0.25 * meso + 0.15 * director_t + active_variant_offset, 0.0, 1.0);
}

// Advance the shared phase-tracking state for a supporting voice. Returns the
// (possibly new) total phase id. The id increments at every hold-boundary
// crossing within a macro cycle and at every macro cycle wrap.
fn updatePatternPhase(state: *PatternPhaseState, hold_beats: u16) i64 {
    const macro_arc = &runner.engine.arcs.macro;
    const beat = macro_arc.beat_count;
    const section = macro_arc.section_beats;
    if (state.last_beat > beat) {
        state.cycle_count +%= 1;
    }
    state.last_beat = beat;

    const hold: f32 = @floatFromInt(@max(hold_beats, 1));
    const phases_per_cycle: u32 = @max(@as(u32, @intFromFloat(@ceil(section / hold))), 1);
    const intra_phase: u32 = @intFromFloat(beat / hold);
    return @as(i64, @intCast(@as(u64, state.cycle_count) * phases_per_cycle + intra_phase));
}

// Compute the picker's "target" position in the bank, blending intensity
// (driven by macro/meso/energy/director) with a cycle-indexed rotation
// (kuse-like alternation across macro arcs). bias_amount=0 → pure intensity;
// bias_amount=1 → cycle dominates.
fn pickerTarget(bank_len: usize, intensity: f32, cycle_count: u32, bias_amount: f32) f32 {
    if (bank_len <= 1) return 0.0;
    const max_idx_f: f32 = @floatFromInt(bank_len - 1);
    const cycle_idx_f: f32 = @floatFromInt(cycle_count % @as(u32, @intCast(bank_len)));
    const cycle_target = cycle_idx_f / max_idx_f;
    return std.math.clamp(intensity * (1.0 - bias_amount) + cycle_target * bias_amount, 0.0, 1.0);
}

// Bias selection toward sparser indices at low target, denser at high.
fn pickKanePattern(style: TaikoPatternStyle, intensity: f32, cycle_count: u32, bias_amount: f32) u8 {
    const bank = kanePatternBank(style);
    if (bank.len == 0) {
        std.log.warn("procedural_taiko.pickKanePattern: empty kane bank for style {s}", .{@tagName(style)});
        return 0;
    }
    if (bank.len == 1) return 0;

    const target = pickerTarget(bank.len, intensity, cycle_count, bias_amount);
    var weights: [KANE_BANK_MAX]f32 = undefined;
    var total: f32 = 0.0;
    const max_idx_f: f32 = @floatFromInt(bank.len - 1);
    for (0..bank.len) |i| {
        const idx_f: f32 = @floatFromInt(i);
        const dist = @abs(idx_f / max_idx_f - target);
        const w = @max(0.1, 1.0 - dist * 0.85);
        weights[i] = w;
        total += w;
    }
    var r = dsp.rngFloat(&rng) * total;
    for (0..bank.len) |i| {
        r -= weights[i];
        if (r <= 0.0) return @intCast(i);
    }
    return @intCast(bank.len - 1);
}

fn jitterVoiceVel(vel: f32) f32 {
    return vel * (1.0 + (dsp.rngFloat(&rng) - 0.5) * 0.16); // +/- 8%
}

fn kanePhraseVelocity(vel_base: f32, spec: *const TaikoCueSpec, macro_t: f32) f32 {
    return vel_base * (0.46 + spec.energy * 0.16 + macro_t * 0.10);
}

fn advanceAtarigane(step: u8, meso: f32, macro_t: f32, vel_base: f32, spec: *const TaikoCueSpec) void {
    const intensity = kanePatternIntensity(meso, macro_t, spec.energy);
    const total_phase = updatePatternPhase(&kane_state, spec.kane_hold_beats);
    const style_changed = kane_state.last_style != spec.pattern_style;
    const phase_changed = kane_state.last_total_phase != total_phase;

    if (style_changed or phase_changed) {
        kane_state.last_style = spec.pattern_style;
        kane_state.last_total_phase = total_phase;
        kane_state.current_idx = pickKanePattern(spec.pattern_style, intensity, kane_state.cycle_count, spec.cycle_bias_amount);
    }

    const bank = kanePatternBank(spec.pattern_style);
    if (bank.len == 0) {
        std.log.warn("procedural_taiko.advanceAtarigane: empty kane bank for style {s}", .{@tagName(spec.pattern_style)});
        return;
    }
    const pattern = bank[kane_state.current_idx % @as(u8, @intCast(bank.len))];

    const kane_vel = kanePhraseVelocity(vel_base, spec, macro_t);
    fireKanePatternStep(step, pattern, kane_vel, macro_t);
}

fn fireKanePatternStep(step: u8, pattern: AtariganePattern, kane_vel: f32, macro_t: f32) void {
    // Priority: chan > chi > ki on overlapping bits.
    if (composition.stepActive(pattern.chan_mask, step)) {
        const accent: f32 = if (step == 0) 1.0 else 0.86;
        scheduleTrigger(V_KANE, .open, jitterVoiceVel(kane_vel * accent));
        // Occasional chiki-flam ornament riding the chan, only at high intensity.
        if (macro_t > 0.7 and dsp.rngFloat(&rng) < 0.18) {
            scheduleTriggerAfter(V_KANE, .chi, jitterVoiceVel(kane_vel * 0.44), KANE_STROKE_DELAY_SAMPLES * 0.55);
        }
    } else if (composition.stepActive(pattern.chi_mask, step)) {
        scheduleTrigger(V_KANE, .chi, jitterVoiceVel(kane_vel * 0.62));
    } else if (composition.stepActive(pattern.ki_mask, step)) {
        scheduleTrigger(V_KANE, .ki, jitterVoiceVel(kane_vel * 0.48));
    }

    if (composition.stepActive(pattern.damp_mask, step)) {
        const damp_amount = 0.40 + macro_t * 0.18;
        scheduleTrigger(V_KANE, .damp, damp_amount);
    }
}

// ============================================================
// Nagado backline pattern bank — kuchi-shoga figures for n3/n4
// The backline (chū-daiko) plays its own supporting figures behind the
// lead nagado. Each pattern is a complete bar-level specification for
// both backline voices. Priority within a voice: doro > doko > don > ka
// (for n3) and kara > don > ka > ghost (for n4).
// ============================================================

const NagadoBacklinePattern = struct {
    n3_don_mask: u16,
    n3_ka_mask: u16,
    n3_doko_mask: u16, // don+ghost combo (scheduleDoko)
    n3_doro_mask: u16, // don+don combo (scheduleDoro)
    n4_don_mask: u16,
    n4_ka_mask: u16,
    n4_kara_mask: u16, // ka+ka combo (scheduleKara)
    n4_ghost_mask: u16,
};

// Matsuri — festival groove. Backline answers the lead with quarter dons
// and off-eighth ka-doubles, with denser figures during higher intensity.
const MATSURI_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Mirror (canonical ji-uchi): n3 follows lead don, n4 kara fills off-beats
    .{
        .n3_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n4_ghost_mask = 0,
    },
    // Hocket: n3 anchors 1+3, n4 fills 2+4 — alternating quarters
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 4) | (1 << 12),
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 2) | (1 << 10),
        .n4_ka_mask = (1 << 6) | (1 << 14),
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Doro answer: long rolls on beat 3, ghost texture
    .{
        .n3_don_mask = (1 << 0),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = (1 << 8),
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = (1 << 4) | (1 << 12),
        .n4_ghost_mask = (1 << 6) | (1 << 14),
    },
};

// Yatai-bayashi — forward-driving float procession.
const YATAI_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Push hocket: n3 on quarters, n4 on the off-eighths
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = (1 << 4) | (1 << 12),
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 2) | (1 << 10),
        .n4_ka_mask = (1 << 6) | (1 << 14),
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Doko spray: quarter-doko on n3, kara fill on n4 off-eighths
    .{
        .n3_don_mask = 0,
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n4_ghost_mask = 0,
    },
    // Syncopated push: n3 syncopated dons, n4 counter, ghost ground
    .{
        .n3_don_mask = (1 << 1) | (1 << 9),
        .n3_ka_mask = (1 << 3) | (1 << 7) | (1 << 11) | (1 << 15),
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 5) | (1 << 13),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
    },
};

// Miyake — bold and athletic. Backline plays heavy unison hits with rolls.
const MIYAKE_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Unison power: both voices on quarters, n3 fills with doko
    .{
        .n3_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Doro hammers: rolling answer on off-quarters, ghost texture beneath
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = (1 << 4) | (1 << 12),
        .n4_don_mask = (1 << 0) | (1 << 8),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
    },
    // Spacious breathing: very wide with single anchors and a kara fill
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = (1 << 4) | (1 << 12),
        .n4_ghost_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
    },
};

// Hachijo — the shimoshirabe (under-pattern). This is the FOUNDATION over
// which the lead uwabyoshi improvises freely. It must stay rock-steady.
const HACHIJO_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Steady ground: n3 quarters, n4 off-eighths
    .{
        .n3_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Subtle variation: n3 don 1 & 3 with doko on 2 & 4, n4 ka off-eighths
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 4) | (1 << 12),
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Slightly more active: n3 doko quarters, n4 ghost off-eighths
    .{
        .n3_don_mask = 0,
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
    },
};

// Bon-odori — communal dance backline. Very steady, even quarter feel.
const BON_ODORI_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Simple quarters with off-eighth ka
    .{
        .n3_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = (1 << 2) | (1 << 6) | (1 << 10) | (1 << 14),
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Same but with kara doubles on 2 & 4 of n4
    .{
        .n3_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = (1 << 2) | (1 << 10),
        .n4_ghost_mask = (1 << 6) | (1 << 14),
    },
    // Doko fills on n3
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = (1 << 4) | (1 << 12),
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
};

// Furi-uchi — ceremonial backline. Sparse, dignified, with rolls for drama.
const FURI_UCHI_NAGADO_BACK_PATTERNS = [_]NagadoBacklinePattern{
    // Single anchor: n3 on 1, n4 on 3
    .{
        .n3_don_mask = (1 << 0),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 8),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Long roll on beat 3 (the dramatic "now" of furi-uchi)
    .{
        .n3_don_mask = (1 << 0),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = (1 << 8),
        .n4_don_mask = 0,
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = 0,
    },
    // Unison anchors with ghost texture (building section)
    .{
        .n3_don_mask = (1 << 0) | (1 << 8),
        .n3_ka_mask = 0,
        .n3_doko_mask = 0,
        .n3_doro_mask = 0,
        .n4_don_mask = (1 << 0) | (1 << 8),
        .n4_ka_mask = 0,
        .n4_kara_mask = 0,
        .n4_ghost_mask = (1 << 4) | (1 << 12),
    },
};

var nagado_back_state: PatternPhaseState = .{};

fn nagadoBackPatternBank(style: TaikoPatternStyle) []const NagadoBacklinePattern {
    return switch (style) {
        .matsuri => &MATSURI_NAGADO_BACK_PATTERNS,
        .yatai_bayashi => &YATAI_NAGADO_BACK_PATTERNS,
        .miyake => &MIYAKE_NAGADO_BACK_PATTERNS,
        .oroshi => &.{},
        .hachijo => &HACHIJO_NAGADO_BACK_PATTERNS,
        .bon_odori => &BON_ODORI_NAGADO_BACK_PATTERNS,
        .furi_uchi => &FURI_UCHI_NAGADO_BACK_PATTERNS,
    };
}

fn nagadoBackPatternIntensity(meso: f32, macro_t: f32, energy: f32) f32 {
    const director_t = composition.compositionEngineLongFormIntensity(&runner.engine);
    return std.math.clamp(0.18 * energy + 0.42 * macro_t + 0.25 * meso + 0.15 * director_t + active_variant_offset, 0.0, 1.0);
}

fn pickNagadoBackPattern(style: TaikoPatternStyle, intensity: f32, cycle_count: u32, bias_amount: f32) u8 {
    const bank = nagadoBackPatternBank(style);
    if (bank.len == 0) {
        std.log.warn("procedural_taiko.pickNagadoBackPattern: empty backline bank for style {s}", .{@tagName(style)});
        return 0;
    }
    if (bank.len == 1) return 0;

    const target = pickerTarget(bank.len, intensity, cycle_count, bias_amount);
    var weights: [KANE_BANK_MAX]f32 = undefined;
    var total: f32 = 0.0;
    const max_idx_f: f32 = @floatFromInt(bank.len - 1);
    for (0..bank.len) |i| {
        const idx_f: f32 = @floatFromInt(i);
        const dist = @abs(idx_f / max_idx_f - target);
        const w = @max(0.1, 1.0 - dist * 0.85);
        weights[i] = w;
        total += w;
    }
    var r = dsp.rngFloat(&rng) * total;
    for (0..bank.len) |i| {
        r -= weights[i];
        if (r <= 0.0) return @intCast(i);
    }
    return @intCast(bank.len - 1);
}

fn fireNagadoBackStep(step: u8, pattern: NagadoBacklinePattern, back_vel: f32, accent: f32) void {
    // Nagado 3 — priority: doro > doko > don > ka (only one fires per step).
    if (composition.stepActive(pattern.n3_doro_mask, step)) {
        scheduleDoro(V_NAGADO3, jitterVoiceVel(back_vel * 0.62));
    } else if (composition.stepActive(pattern.n3_doko_mask, step)) {
        scheduleDoko(V_NAGADO3, jitterVoiceVel(back_vel * 0.58));
    } else if (composition.stepActive(pattern.n3_don_mask, step)) {
        scheduleTrigger(V_NAGADO3, .don, jitterVoiceVel(back_vel * accent * 0.78));
    } else if (composition.stepActive(pattern.n3_ka_mask, step)) {
        scheduleTrigger(V_NAGADO3, .ka, jitterVoiceVel(back_vel * 0.46));
    }

    // Nagado 4 — priority: kara > don > ka > ghost.
    if (composition.stepActive(pattern.n4_kara_mask, step)) {
        scheduleKara(V_NAGADO4, jitterVoiceVel(back_vel * 0.52));
    } else if (composition.stepActive(pattern.n4_don_mask, step)) {
        scheduleTrigger(V_NAGADO4, .don, jitterVoiceVel(back_vel * accent * 0.72));
    } else if (composition.stepActive(pattern.n4_ka_mask, step)) {
        scheduleTrigger(V_NAGADO4, .ka, jitterVoiceVel(back_vel * 0.46));
    } else if (composition.stepActive(pattern.n4_ghost_mask, step)) {
        scheduleTrigger(V_NAGADO4, .ghost, jitterVoiceVel(back_vel * 0.38));
    }
}

fn advanceOroshiStep(step: u8, meso: f32, macro_t: f32, vel_base: f32, spec: *const TaikoCueSpec) void {
    const density_mask = oroshiDensityMask(macro_t);
    const quarter_mask: u16 = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12);
    const half_mask: u16 = (1 << 0) | (1 << 8);
    const accent: f32 = if (composition.stepActive(quarter_mask, step)) 1.0 else 0.74;
    const shime_vel = vel_base * (0.5 + macro_t * 0.32);
    const nagado_vel = vel_base * (0.58 + macro_t * 0.28) * accent;

    if (!composition.stepActive(density_mask, step)) {
        if (macro_t > 0.9 and step == 15 and dsp.rngFloat(&rng) < 0.65) {
            scheduleTrigger(V_SHIME1, .roll, vel_base * 0.52);
            scheduleTsuku(V_SHIME2, vel_base * 0.42);
        }
        return;
    }

    if (macro_t < 0.24) {
        if (composition.stepActive(half_mask, step)) {
            const lead_on_n1 = dsp.rngFloat(&rng) < 0.58 + meso * 0.22;
            const lead_voice: usize = if (lead_on_n1) V_NAGADO1 else V_NAGADO2;
            const support_voice: usize = if (lead_on_n1) V_NAGADO2 else V_NAGADO1;
            scheduleTrigger(lead_voice, .don, nagado_vel * 0.9);
            if (dsp.rngFloat(&rng) < 0.2 + meso * 0.2) {
                const support_hit: TriggerType = if (dsp.rngFloat(&rng) < 0.58) .ghost else .ka;
                scheduleTrigger(support_voice, support_hit, nagado_vel * 0.5);
            }
            if (dsp.rngFloat(&rng) < 0.16 + meso * 0.12) {
                scheduleTrigger(V_NAGADO3, .ghost, nagado_vel * 0.38);
            }
        } else if (composition.stepActive(quarter_mask, step) and dsp.rngFloat(&rng) < 0.18 + meso * 0.2) {
            scheduleKara(V_SHIME2, shime_vel * 0.48);
        }
        if (step == 0 or (step == 8 and dsp.rngFloat(&rng) < 0.52 + meso * 0.2)) {
            scheduleTrigger(V_SHIME1, .don, shime_vel * (0.74 + dsp.rngFloat(&rng) * 0.18));
        } else if (step == 12 and dsp.rngFloat(&rng) < 0.16 + meso * 0.16) {
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.56);
        }
        if (step % 8 == 4 and dsp.rngFloat(&rng) < 0.07 + meso * 0.12) {
            scheduleTrigger(V_ODAIKO, .ghost, vel_base * 0.32);
        }
    } else if (macro_t < 0.52) {
        scheduleTrigger(V_NAGADO1, .don, nagado_vel * 0.88);
        if (step % 8 == 4) {
            scheduleDoko(V_NAGADO3, nagado_vel * 0.46);
        }
        if (composition.stepActive(quarter_mask, step)) {
            scheduleTrigger(V_SHIME1, .don, shime_vel);
        } else if (dsp.rngFloat(&rng) < 0.35 + meso * 0.2) {
            scheduleKara(V_SHIME2, shime_vel * 0.54);
        }
    } else if (macro_t < 0.82) {
        if (step % 2 == 0) {
            scheduleTrigger(V_NAGADO1, .don, nagado_vel * 0.9);
            scheduleTrigger(V_NAGADO3, .don, nagado_vel * 0.58);
            scheduleTrigger(V_SHIME1, .don, shime_vel);
        } else {
            scheduleTrigger(V_NAGADO2, .don, nagado_vel * 0.82);
            scheduleTrigger(V_NAGADO4, .ka, nagado_vel * 0.48);
            scheduleKara(V_SHIME2, shime_vel * 0.58);
        }
    } else {
        if (step % 2 == 0) {
            scheduleTrigger(V_NAGADO1, .don, nagado_vel * 0.96);
            scheduleDoko(V_NAGADO3, nagado_vel * 0.54);
            scheduleTrigger(V_SHIME1, .don, shime_vel * 1.05);
        } else {
            scheduleTrigger(V_NAGADO2, .don, nagado_vel * 0.9);
            scheduleTrigger(V_NAGADO4, .ka, nagado_vel * 0.54);
            scheduleKara(V_SHIME2, shime_vel * 0.66);
        }

        if (dsp.rngFloat(&rng) < 0.18 + macro_t * 0.2) {
            scheduleTsuku(V_SHIME1, vel_base * 0.30);
        }
    }

    if (macro_t > 0.38 and composition.stepActive(quarter_mask, step)) {
        scheduleTrigger(V_ODAIKO, .don, vel_base * (0.68 + macro_t * 0.22));
    }

    advanceAtarigane(step, meso, macro_t, vel_base, spec);
}

fn oroshiDensityMask(macro_t: f32) u16 {
    if (macro_t < 0.24) return (1 << 0) | (1 << 8);
    if (macro_t < 0.52) return (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12);
    if (macro_t < 0.82) return 0x5555;
    return 0xFFFF;
}

fn leadHitToTrigger(hit: LeadHit) TriggerType {
    return switch (hit) {
        .don, .don_don => .don,
        .ka => .ka,
        .ghost => .ghost,
        .none => .none,
    };
}

fn applyCueParams() void {
    const prev_to = cue_state.to;
    cue_morph.setTarget(CuePreset, &cue_state, selected_cue);
    if (cue_state.to == prev_to and cue_state.progress >= 1.0) {
        return;
    }
    const target = CUE_SPECS[@intFromEnum(cue_state.to)];
    composition.compositionEngineSetChordChangeBeats(&runner.engine, target.chord_change_beats);
    composition.keyStateModulateTo(&runner.engine.key, target.root);
    pending_scale_type = target.scale_type;
}
