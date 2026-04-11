// Procedural Japanese taiko ensemble — v2 composition engine.
//
// Kumi-daiko ensemble: odaiko, 2x nagado-daiko, 2x shime-daiko, atarigane.
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
};

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 120.0;
pub var reverb_mix: f32 = 0.32;
pub var drum_mix: f32 = 0.9;
pub var shaker_mix: f32 = 0.55; // maps to shime volume
pub var tone_mix: f32 = 0.65; // maps to nagado volume
pub var slap_mix: f32 = 0.5; // maps to atarigane volume
pub var selected_cue: CuePreset = .matsuri;

// ============================================================
// Reverb — large hall / outdoor space character
// ============================================================

const TaikoReverb = StereoReverb(.{ 1801, 1907, 2053, 2111 }, .{ 241, 557 });
var reverb: TaikoReverb = dsp.stereoReverbInit(.{1801, 1907, 2053, 2111}, .{241, 557}, .{ 0.87, 0.88, 0.86, 0.89 });
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
    kane_open_mask: u16,
    kane_muted_mask: u16,
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

const CUE_SPECS: [4]TaikoCueSpec = .{
    // matsuri — festival rhythm, moderate tempo, steady groove
    .{
        .root = 36,
        .scale_type = .dorian,
        .base_bpm = 116.0,
        .chord_change_beats = 16.0,
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
        // Kane: on beats, with muted off-beats
        .kane_open_mask = (1 << 0) | (1 << 8),
        .kane_muted_mask = (1 << 4) | (1 << 12),
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
    },
    // yatai_bayashi — float procession, building energy, faster
    .{
        .root = 38,
        .scale_type = .mixolydian,
        .base_bpm = 128.0,
        .chord_change_beats = 12.0,
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
        .kane_open_mask = (1 << 0) | (1 << 8),
        .kane_muted_mask = (1 << 6) | (1 << 14),
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
    },
    // miyake — powerful, athletic, driving rhythm
    .{
        .root = 34,
        .scale_type = .natural_minor,
        .base_bpm = 108.0,
        .chord_change_beats = 20.0,
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
        .kane_open_mask = (1 << 0),
        .kane_muted_mask = (1 << 8),
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
    },
    // oroshi — thunder roll, dramatic building, fastest
    .{
        .root = 41,
        .scale_type = .harmonic_minor,
        .base_bpm = 82.0,
        .chord_change_beats = 16.0,
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
        .kane_open_mask = (1 << 0) | (1 << 8),
        .kane_muted_mask = (1 << 12),
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
    shime1.base_freq = 400.0 + cue_idx * 20.0;
    shime2.base_freq = 440.0 + cue_idx * 20.0;
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
var shime1: instruments.Shime = .{ .base_freq = 420.0, .volume = 0.6 };
var shime2: instruments.Shime = .{ .base_freq = 460.0, .volume = 0.55 };
var kane: instruments.Atarigane = .{};

// ============================================================
// Microtiming
// ============================================================

const NUM_VOICES: usize = 6;
const V_ODAIKO: usize = 0;
const V_NAGADO1: usize = 1;
const V_NAGADO2: usize = 2;
const V_SHIME1: usize = 3;
const V_SHIME2: usize = 4;
const V_KANE: usize = 5;

const VOICE_OFFSETS: [NUM_VOICES]f32 = .{
    4.5, // odaiko: behind (massive drum, deliberate)
    1.8, // nagado1: slightly behind
    -1.5, // nagado2: slightly ahead
    0.0, // shime1: reference (timekeeper)
    0.5, // shime2: nearly on reference
    -2.0, // kane: slightly ahead (bright, cutting)
};
const JITTER_SAMPLES: f32 = 2.0;

const VOICE_PAN: [NUM_VOICES]f32 = .{
    0.0, // odaiko: center
    -0.35, // nagado1: left
    0.35, // nagado2: right
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
    muted,
};

const PendingTrigger = struct {
    trigger_type: TriggerType = .none,
    delay: f32 = 0.0,
    velocity: f32 = 0.0,
};

var pending: [NUM_VOICES]PendingTrigger = .{PendingTrigger{}} ** NUM_VOICES;

fn scheduleTrigger(voice: usize, ttype: TriggerType, vel: f32) void {
    const offset = VOICE_OFFSETS[voice] + (dsp.rngFloat(&rng) * 2.0 - 1.0) * JITTER_SAMPLES;
    pending[voice] = .{
        .trigger_type = ttype,
        .delay = @max(offset, 0.0),
        .velocity = vel,
    };
}

fn processPendingTriggers() void {
    for (0..NUM_VOICES) |i| {
        if (pending[i].trigger_type == .none) continue;
        if (pending[i].delay <= 0) {
            fireTrigger(i, pending[i].trigger_type, pending[i].velocity);
            pending[i].trigger_type = .none;
        } else {
            pending[i].delay -= 1.0;
        }
    }
}

fn fireTrigger(voice: usize, ttype: TriggerType, vel: f32) void {
    switch (voice) {
        V_ODAIKO => switch (ttype) {
            .don => instruments.odaikoTriggerDon(&odaiko, vel),
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
        V_SHIME1 => switch (ttype) {
            .don => instruments.shimeTriggerDon(&shime1, vel),
            .ka => instruments.shimeTriggerKa(&shime1, vel),
            .roll => instruments.shimeTriggerRoll(&shime1, vel),
            else => {},
        },
        V_SHIME2 => switch (ttype) {
            .don => instruments.shimeTriggerDon(&shime2, vel),
            .ka => instruments.shimeTriggerKa(&shime2, vel),
            .roll => instruments.shimeTriggerRoll(&shime2, vel),
            else => {},
        },
        V_KANE => switch (ttype) {
            .open => instruments.atariganeTriggerOpen(&kane, vel),
            .muted => instruments.atariganeTriggerMuted(&kane, vel),
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
    rng = dsp.rngInit(entropy.nextSeed(0xDA1C_0000, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    structural_cue = selected_cue;
    pending_scale_type = null;
    reverb = dsp.stereoReverbInit(.{1801, 1907, 2053, 2111}, .{241, 557}, .{ 0.87, 0.88, 0.86, 0.89 });
    lfo_space = .{ .period_beats = 96, .depth = 0.03 };

    composition.stepStyleRunnerReset(TaikoCueSpec, 4, &runner, &STYLE, .{ .root = 36, .scale_type = .dorian }, initHarmony(), CHORD_CHANGE_BEATS, .none, .{ 0.4, 0.5, 0.85, 0.7 }, .{ 0.3, 0.4, 0.8, 0.6 });

    resetInstruments();
    pending = .{PendingTrigger{}} ** NUM_VOICES;
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
    shime1 = .{ .base_freq = 420.0, .volume = 0.6 };
    shime2 = .{ .base_freq = 460.0, .volume = 0.55 };
    kane = .{};
}

pub fn triggerCue() void {
    applyCueParams();
}

pub const DebugSnapshot = struct {
    cue_from: u8,
    cue_to: u8,
    cue_structural: u8,
    cue_selected: u8,
    cue_progress: f32,
    key_root: u8,
    key_scale: composition.ScaleType,
    chord_index: u8,
    chord_count: u8,
    micro: f32,
    meso: f32,
    macro: f32,
    longform_intensity: f32,
    longform_cadence: f32,
    longform_modulation: f32,
    section_id: u8,
    section_progress: f32,
    section_transition_count: u32,
    section_distinct_transition_count: u8,
    section_bridge_active: bool,
    section_bridge_progress: f32,
    section_bridge_from: u8,
    section_bridge_to: u8,
    section_density: f32,
    section_harmonic_motion: f32,
    section_cadence_scale: f32,
    chord_change_beats: f32,
    next_chord_change_beats: f32,
    sequencer_step: u8,
    lead_cycle_count: u16,
    in_break: bool,
    in_call_response: bool,
    is_response_phase: bool,
};

pub fn debugSnapshot() DebugSnapshot {
    return .{
        .cue_from = @intFromEnum(cue_state.from),
        .cue_to = @intFromEnum(cue_state.to),
        .cue_structural = @intFromEnum(structural_cue),
        .cue_selected = @intFromEnum(selected_cue),
        .cue_progress = cue_state.progress,
        .key_root = runner.engine.key.root,
        .key_scale = runner.engine.key.scale_type,
        .chord_index = runner.engine.harmony.current,
        .chord_count = runner.engine.harmony.num_chords,
        .micro = composition.arcControllerTension(&runner.engine.arcs.micro),
        .meso = composition.arcControllerTension(&runner.engine.arcs.meso),
        .macro = composition.arcControllerTension(&runner.engine.arcs.macro),
        .longform_intensity = composition.compositionEngineLongFormIntensity(&runner.engine),
        .longform_cadence = composition.compositionEngineLongFormCadenceSpread(&runner.engine),
        .longform_modulation = composition.compositionEngineLongFormModulationDrive(&runner.engine),
        .section_id = composition.compositionEngineSectionId(&runner.engine),
        .section_progress = composition.compositionEngineSectionProgress(&runner.engine),
        .section_transition_count = composition.compositionEngineSectionTransitionCount(&runner.engine),
        .section_distinct_transition_count = composition.compositionEngineSectionDistinctTransitionCount(&runner.engine),
        .section_bridge_active = composition.compositionEngineSectionBridgeActive(&runner.engine),
        .section_bridge_progress = composition.compositionEngineSectionBridgeProgress(&runner.engine),
        .section_bridge_from = composition.compositionEngineSectionBridgeFromId(&runner.engine),
        .section_bridge_to = composition.compositionEngineSectionBridgeToId(&runner.engine),
        .section_density = composition.compositionEngineSectionDensity(&runner.engine),
        .section_harmonic_motion = composition.compositionEngineSectionHarmonicMotion(&runner.engine),
        .section_cadence_scale = composition.compositionEngineSectionCadenceScale(&runner.engine),
        .chord_change_beats = runner.engine.chord_change_beats,
        .next_chord_change_beats = runner.engine.next_chord_change_beats,
        .sequencer_step = runner.sequencer.step,
        .lead_cycle_count = lead_cycle_count,
        .in_break = in_break,
        .in_call_response = in_call_response,
        .is_response_phase = is_response_phase,
    };
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
        // Jo-Ha-Kyu tempo drift: macro arc pushes tempo up at climax
        const macro_t = composition.arcControllerTension(&runner.engine.arcs.macro);
        const effective_bpm = spec.base_bpm * bpm * (1.0 + macro_t * spec.tempo_drift);
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
        var left: f32 = 0.0;
        var right: f32 = 0.0;

        // Odaiko — massive center presence
        const odaiko_s = instruments.odaikoProcess(&odaiko) * drum_mix * runner.layer_levels[ODAIKO_LAYER] * 1.2;
        left += odaiko_s;
        right += odaiko_s;

        // Nagados
        const n1_s = instruments.nagadoProcess(&nagado1, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER];
        const n1_pan = dsp.panStereo(n1_s, VOICE_PAN[V_NAGADO1]);
        left += n1_pan[0];
        right += n1_pan[1];

        const n2_s = instruments.nagadoProcess(&nagado2, &rng) * drum_mix * tone_mix * runner.layer_levels[NAGADO_LAYER];
        const n2_pan = dsp.panStereo(n2_s, VOICE_PAN[V_NAGADO2]);
        left += n2_pan[0];
        right += n2_pan[1];

        // Shimes
        const s1_s = instruments.shimeProcess(&shime1, &rng) * shaker_mix * runner.layer_levels[SHIME_LAYER];
        const s1_pan = dsp.panStereo(s1_s, VOICE_PAN[V_SHIME1]);
        left += s1_pan[0];
        right += s1_pan[1];

        const s2_s = instruments.shimeProcess(&shime2, &rng) * shaker_mix * runner.layer_levels[SHIME_LAYER];
        const s2_pan = dsp.panStereo(s2_s, VOICE_PAN[V_SHIME2]);
        left += s2_pan[0];
        right += s2_pan[1];

        // Atarigane
        const kane_s = instruments.atariganeProcess(&kane, &rng) * slap_mix * runner.layer_levels[KANE_LAYER];
        left += kane_s; // center
        right += kane_s;

        // Reverb — large space
        const wet = (reverb_mix + spec.reverb_boost) * composition.slowLfoModulate(&lfo_space);
        const dry = 1.0 - wet;
        const rev = dsp.stereoReverbProcess(.{1801, 1907, 2053, 2111}, .{241, 557}, &reverb, .{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.85);
        buf[i * 2 + 1] = softClip(right * 0.85);
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
        advanceOroshiStep(step, meso, macro_t, vel_base);
        return;
    }

    // ---- Odaiko ----
    if (in_break and step >= 8 and step % 2 == 0) {
        // During break recovery: odaiko joins the unison build
        scheduleTrigger(V_ODAIKO, .don, vel_base * 0.9);
    } else if (composition.stepActive(spec.odaiko_mask, step)) {
        scheduleTrigger(V_ODAIKO, .don, vel_base * accent);
    } else if (composition.stepActive(spec.odaiko_fill_mask, step) and dsp.rngFloat(&rng) < spec.fill_density * macro_t) {
        scheduleTrigger(V_ODAIKO, .don, vel_base * 0.6);
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

    // ---- Shime-daiko (ji-uchi — always present) ----
    if (composition.stepActive(spec.shime_ji_mask, step)) {
        const is_accent = composition.stepActive(spec.shime_accent_mask, step);
        const shime_vel = if (is_accent) vel_base * (0.78 + spec.energy * 0.16) else vel_base * (0.42 + spec.energy * 0.18);

        // Shime 1: main ji-uchi
        scheduleTrigger(V_SHIME1, .don, shime_vel);

        // Shime 2: interlocking — plays the off-positions or rolls
        if (!composition.stepActive(spec.shime_ji_mask, (step + 1) % 16) or dsp.rngFloat(&rng) < 0.12 + spec.energy * 0.22) {
            scheduleTrigger(V_SHIME2, .don, shime_vel * 0.85);
        }
    }
    // Shime rolls during high tension
    if (dsp.rngFloat(&rng) < spec.roll_chance * macro_t and step % 4 == 3) {
        scheduleTrigger(V_SHIME1, .roll, vel_base * 0.6);
        scheduleTrigger(V_SHIME2, .roll, vel_base * 0.5);
    }

    // ---- Atarigane ----
    if (composition.stepActive(spec.kane_open_mask, step)) {
        if (dsp.rngFloat(&rng) < kaneOpenChance(spec, meso, macro_t)) {
            scheduleTrigger(V_KANE, .open, vel_base * 0.62);
        }
    } else if (composition.stepActive(spec.kane_muted_mask, step)) {
        if (dsp.rngFloat(&rng) < kaneMutedChance(spec, meso, macro_t)) {
            scheduleTrigger(V_KANE, .muted, vel_base * 0.42);
        }
    }
}

fn kaneOpenChance(spec: *const TaikoCueSpec, meso: f32, macro_t: f32) f32 {
    return std.math.clamp(0.08 + spec.energy * 0.14 + meso * 0.08 + macro_t * 0.12, 0.0, 0.42);
}

fn kaneMutedChance(spec: *const TaikoCueSpec, meso: f32, macro_t: f32) f32 {
    return std.math.clamp(0.04 + spec.energy * 0.1 + meso * 0.06 + macro_t * 0.08, 0.0, 0.32);
}

fn advanceOroshiStep(step: u8, meso: f32, macro_t: f32, vel_base: f32) void {
    const density_mask = oroshiDensityMask(macro_t);
    const quarter_mask: u16 = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12);
    const half_mask: u16 = (1 << 0) | (1 << 8);
    const accent: f32 = if (composition.stepActive(quarter_mask, step)) 1.0 else 0.74;
    const shime_vel = vel_base * (0.5 + macro_t * 0.32);
    const nagado_vel = vel_base * (0.58 + macro_t * 0.28) * accent;

    if (!composition.stepActive(density_mask, step)) {
        if (macro_t > 0.9 and step == 15 and dsp.rngFloat(&rng) < 0.65) {
            scheduleTrigger(V_SHIME1, .roll, vel_base * 0.52);
            scheduleTrigger(V_SHIME2, .roll, vel_base * 0.46);
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
        } else if (composition.stepActive(quarter_mask, step) and dsp.rngFloat(&rng) < 0.18 + meso * 0.2) {
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.64);
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
        if (composition.stepActive(quarter_mask, step)) {
            scheduleTrigger(V_SHIME1, .don, shime_vel);
        } else if (dsp.rngFloat(&rng) < 0.35 + meso * 0.2) {
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.72);
        }
    } else if (macro_t < 0.82) {
        if (step % 2 == 0) {
            scheduleTrigger(V_NAGADO1, .don, nagado_vel * 0.9);
            scheduleTrigger(V_SHIME1, .don, shime_vel);
        } else {
            scheduleTrigger(V_NAGADO2, .don, nagado_vel * 0.82);
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.76);
        }
    } else {
        if (step % 2 == 0) {
            scheduleTrigger(V_NAGADO1, .don, nagado_vel * 0.96);
            scheduleTrigger(V_SHIME1, .don, shime_vel * 1.05);
        } else {
            scheduleTrigger(V_NAGADO2, .don, nagado_vel * 0.9);
            scheduleTrigger(V_SHIME2, .ka, shime_vel * 0.9);
        }

        if (dsp.rngFloat(&rng) < 0.18 + macro_t * 0.2) {
            scheduleTrigger(V_SHIME1, .roll, vel_base * 0.34);
        }
    }

    if (macro_t > 0.38 and composition.stepActive(quarter_mask, step)) {
        scheduleTrigger(V_ODAIKO, .don, vel_base * (0.68 + macro_t * 0.22));
    }

    if (step == 0) {
        scheduleTrigger(V_KANE, .open, vel_base * (0.34 + macro_t * 0.16));
    } else if (macro_t > 0.72 and step == 8 and dsp.rngFloat(&rng) < 0.5) {
        scheduleTrigger(V_KANE, .muted, vel_base * 0.28);
    } else if (macro_t > 0.9 and step == 12 and dsp.rngFloat(&rng) < 0.38) {
        scheduleTrigger(V_KANE, .open, vel_base * 0.32);
    }
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
