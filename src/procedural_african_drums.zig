// Procedural West African drum ensemble — v2 composition engine.
//
// 8-voice ensemble: 3 djembes (lead + 2 accompaniment), 3 dununs
// (dundunba, sangban, kenkeni with iron bells), shekere.
// Uses 12-step ternary cycle (12/8 feel), per-voice microtiming,
// lead improvisation, periodic breaks, and macro arc-driven evolution.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const cue_morph = @import("music/cue_morph.zig");
const entropy = @import("music/entropy.zig");
const pattern_history = @import("music/pattern_history.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

pub const CuePreset = enum(u8) {
    kuku,
    djole,
    fanga,
    soli,
};

pub var bpm: f32 = 1.0;
pub var reverb_mix: f32 = 0.28;
pub var drum_mix: f32 = 0.9;
pub var shaker_mix: f32 = 0.55;
pub var tone_mix: f32 = 0.62;
pub var slap_mix: f32 = 0.5;
pub var selected_cue: CuePreset = .kuku;

const DrumReverb = StereoReverb(.{ 1327, 1451, 1559, 1613 }, .{ 181, 487 });
var reverb: DrumReverb = dsp.stereoReverbInit(.{1327, 1451, 1559, 1613}, .{181, 487}, .{ 0.82, 0.83, 0.81, 0.84 });
var rng: dsp.Rng = dsp.rngInit(0xAF10_2000);

var engine: composition.CompositionEngine = .{};

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 7, 10, 0 }, .len = 3 };
    h.chords[1] = .{ .offsets = .{ 3, 10, 14, 0 }, .len = 3 };
    h.chords[2] = .{ .offsets = .{ 5, 12, 15, 0 }, .len = 3 };
    h.chords[3] = .{ .offsets = .{ 7, 14, 17, 0 }, .len = 3 };
    h.num_chords = 4;
    h.transitions[0] = .{ 0.15, 0.35, 0.30, 0.20, 0, 0, 0, 0 };
    h.transitions[1] = .{ 0.30, 0.12, 0.30, 0.28, 0, 0, 0, 0 };
    h.transitions[2] = .{ 0.28, 0.22, 0.12, 0.38, 0, 0, 0, 0 };
    h.transitions[3] = .{ 0.34, 0.22, 0.26, 0.18, 0, 0, 0, 0 };
    return h;
}

const AFRICAN_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 192, .shape = .plateau },
};

// ============================================================
// 12-step ternary sequencer (12/8 feel: 4 beats x 3 subdivisions)
// ============================================================

const NUM_STEPS: u8 = 12;

fn samplesPerSubdivision(bpm_val: f32) f32 {
    // One beat = 3 subdivisions, so subdivision = beat/3
    return dsp.SAMPLE_RATE * 60.0 / bpm_val / 3.0;
}

// Non-isochronous swing: timing ratios for the 3 subdivisions within each beat.
// Values >1 lengthen, <1 shorten. Must average to 1.0.
fn swingRatio(step: u8, swing: [3]f32) f32 {
    return swing[step % 3];
}

var step_counter: f32 = 0.0;
var current_step: u8 = 0;

fn advanceStep12(bpm_val: f32, swing: [3]f32) ?u8 {
    const base_spd = samplesPerSubdivision(bpm_val);
    const ratio = swingRatio(current_step, swing);
    step_counter += 1.0;
    if (step_counter < base_spd * ratio) return null;
    step_counter -= base_spd * ratio;
    const s = current_step;
    current_step = (current_step + 1) % NUM_STEPS;
    return s;
}

// ============================================================
// Microtiming: per-voice systematic offset + per-hit jitter
// ============================================================

const NUM_VOICES: usize = 7;
// Voice indices
const V_DJEMBE_LEAD: usize = 0;
const V_DJEMBE_ACC1: usize = 1;
const V_DJEMBE_ACC2: usize = 2;
const V_DUNDUNBA: usize = 3;
const V_SANGBAN: usize = 4;
const V_KENKENI: usize = 5;
const V_SHEKERE: usize = 6;
// Bell sounds come from dunun instruments, no separate voice index needed

// Systematic offset in samples (±). Kenkeni/bell = reference (0).
const VOICE_OFFSETS: [NUM_VOICES]f32 = .{
    3.8, // djembe lead: slightly behind
    -2.4, // djembe acc1: slightly ahead
    4.2, // djembe acc2: behind
    5.5, // dundunba: behind (heavy)
    -1.8, // sangban: slightly ahead
    0.0, // kenkeni: reference
    -3.2, // shekere: ahead
};

const JITTER_SAMPLES: f32 = 2.5; // ±2.5 samples random jitter per hit

const TriggerType = enum {
    none,
    djembe_bass,
    djembe_tone,
    djembe_slap,
    djembe_ghost_tone,
    djembe_ghost_slap,
    dunun_drum,
    dunun_bell,
    dunun_both,
    shekere,
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
        V_DJEMBE_LEAD, V_DJEMBE_ACC1, V_DJEMBE_ACC2 => {
            const djembe = &djembes[voice];
            switch (ttype) {
                .djembe_bass => instruments.djembeTriggerBass(djembe, vel),
                .djembe_tone => instruments.djembeTriggerTone(djembe, vel),
                .djembe_slap => instruments.djembeTriggerSlap(djembe, vel),
                .djembe_ghost_tone => instruments.djembeTriggerGhost(djembe, vel, .tone),
                .djembe_ghost_slap => instruments.djembeTriggerGhost(djembe, vel, .slap),
                else => {},
            }
        },
        V_DUNDUNBA => switch (ttype) {
            .dunun_drum => instruments.dununTriggerDrum(&dundunba, vel),
            .dunun_bell => instruments.dununTriggerBell(&dundunba),
            .dunun_both => {
                instruments.dununTriggerDrum(&dundunba, vel);
                instruments.dununTriggerBell(&dundunba);
            },
            else => {},
        },
        V_SANGBAN => switch (ttype) {
            .dunun_drum => instruments.dununTriggerDrum(&sangban, vel),
            .dunun_bell => instruments.dununTriggerBell(&sangban),
            .dunun_both => {
                instruments.dununTriggerDrum(&sangban, vel);
                instruments.dununTriggerBell(&sangban);
            },
            else => {},
        },
        V_KENKENI => switch (ttype) {
            .dunun_drum => instruments.dununTriggerDrum(&kenkeni, vel),
            .dunun_bell => instruments.dununTriggerBell(&kenkeni),
            .dunun_both => {
                instruments.dununTriggerDrum(&kenkeni, vel);
                instruments.dununTriggerBell(&kenkeni);
            },
            else => {},
        },
        V_SHEKERE => {
            if (ttype == .shekere) instruments.hiHatTrigger(&shekere);
        },
        else => {},
    }
}

// ============================================================
// Instruments
// ============================================================

var djembes: [3]instruments.Djembe = .{
    .{ .base_freq = 420.0, .volume = 0.75 }, // lead (highest)
    .{ .base_freq = 350.0, .volume = 0.65 }, // accompaniment 1
    .{ .base_freq = 285.0, .volume = 0.65 }, // accompaniment 2
};

var dundunba: instruments.Dunun = .{
    .base_freq = 82.0,
    .sweep = 35.0,
    .volume = 1.1,
    .body_lpf = dsp.lpfInit(200.0),
    .bell_freq = 520.0,
    .bell_volume = 0.3,
};
var sangban: instruments.Dunun = .{
    .base_freq = 135.0,
    .sweep = 28.0,
    .volume = 0.95,
    .body_lpf = dsp.lpfInit(320.0),
    .bell_freq = 680.0,
    .bell_volume = 0.28,
};
var kenkeni: instruments.Dunun = .{
    .base_freq = 215.0,
    .sweep = 18.0,
    .volume = 0.85,
    .body_lpf = dsp.lpfInit(420.0),
    .bell_freq = 920.0,
    .bell_volume = 0.25,
};
var shekere: instruments.HiHat = .{
    .volume = 0.48,
    .hpf = dsp.hpfInit(3800.0),
    .env = dsp.envelopeInit(0.001, 0.022, 0.0, 0.012),
};

// Stereo pan positions: -1 left, +1 right
const VOICE_PAN: [NUM_VOICES]f32 = .{
    0.0, // lead: center
    -0.45, // acc1: left
    0.42, // acc2: right
    -0.2, // dundunba: slightly left
    0.15, // sangban: slightly right
    -0.55, // kenkeni: left
    0.6, // shekere: right
};

// ============================================================
// Lead improvisation
// ============================================================

const LeadHit = enum { none, bass, tone, slap, ghost_tone, ghost_slap };
var lead_pattern: [NUM_STEPS]LeadHit = .{.none} ** NUM_STEPS;
var lead_cycle_count: u16 = 0;
var in_break: bool = false;
var break_remaining: u8 = 0;
const LEAD_HISTORY_SIZE: usize = 8;
var lead_history: pattern_history.PatternHistory = .{ .capacity = LEAD_HISTORY_SIZE };
var lead_phrase: composition.PhraseGenerator = .{
    .anchor = 4,
    .region_low = 0,
    .region_high = 9,
    .rest_chance = 0.24,
    .min_notes = 3,
    .max_notes = 8,
    .gravity = 2.3,
};
var lead_memory: composition.PhraseMemory = .{};

fn hashLeadPattern() u32 {
    return pattern_history.hashEnumPattern(LeadHit, lead_pattern[0..]);
}


fn randomLeadHit(is_strong: bool) LeadHit {
    const r = dsp.rngFloat(&rng);
    if (is_strong and r < 0.22) return .bass;
    if (r < 0.48) return .tone;
    if (r < 0.72) return .slap;
    if (r < 0.9) return .ghost_tone;
    return .ghost_slap;
}

fn leadHitFromPhraseNote(note: u8, is_strong: bool) LeadHit {
    if (is_strong and note % 5 == 0) return .bass;
    return switch (note % 5) {
        0 => .tone,
        1 => .slap,
        2 => .ghost_tone,
        3 => .ghost_slap,
        else => if (is_strong) .bass else .tone,
    };
}

fn mutateLeadPattern(spec: *const CueSpec, meso: f32) void {
    const mutations: u8 = 2 + @as(u8, @intCast(dsp.rngNext(&rng) % 3));
    const keep_chance = std.math.clamp(0.55 + spec.energy * 0.25 + meso * 0.15, 0.0, 0.98);
    for (0..mutations) |_| {
        const idx: usize = @intCast(dsp.rngNext(&rng) % @as(u32, NUM_STEPS));
        const step: u8 = @intCast(idx);
        const is_strong = (step % 3 == 0);
        if (dsp.rngFloat(&rng) < keep_chance) {
            lead_pattern[idx] = randomLeadHit(is_strong);
        } else {
            lead_pattern[idx] = .none;
        }
    }
}

fn forceLeadPerturbation() void {
    const idx: usize = @intCast(dsp.rngNext(&rng) % @as(u32, NUM_STEPS));
    const step: u8 = @intCast(idx);
    lead_pattern[idx] = randomLeadHit(step % 3 == 0);
}

fn generateLeadPattern(meso: f32, spec: *const CueSpec) void {
    var hit_count: u8 = 0;
    const energy = std.math.clamp(spec.energy * (0.4 + meso * 0.65), 0.0, 1.0);
    const recall_chance = std.math.clamp(0.22 + spec.energy * 0.22 + meso * 0.18, 0.18, 0.78);
    const from_cue = cue_state.from;
    const to_cue = cue_state.to;
    const morph_t = cue_state.progress;
    for (0..NUM_STEPS) |i| {
        const step: u8 = @intCast(i);
        // Strong beats (0, 3, 6, 9) get more hits
        const is_strong = (step % 3 == 0);
        const base_chance = lerpF32(baseChanceForCue(from_cue, is_strong), baseChanceForCue(to_cue, is_strong), morph_t);
        const chance = base_chance * energy * spec.lead_density;

        if (dsp.rngFloat(&rng) < chance) {
            const pick = composition.nextPhraseNoteWithMemory(&rng, &lead_phrase, &lead_memory, recall_chance);
            if (pick == null) {
                lead_pattern[i] = randomLeadHit(is_strong);
                hit_count += 1;
                continue;
            }
            lead_pattern[i] = leadHitFromPhraseNote(pick.?.note, is_strong);
            hit_count += 1;
        } else {
            lead_pattern[i] = .none;
        }
    }

    if (hit_count == 0) {
        const strong_slot: u8 = @intCast(dsp.rngNext(&rng) % 4);
        const idx: usize = @intCast(strong_slot * 3);
        lead_pattern[idx] = .tone;
    }
}

fn rebuildLeadPattern(meso: f32, spec: *const CueSpec) void {
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
    // Unison hits on strong beats
    for (0..NUM_STEPS) |i| {
        const step: u8 = @intCast(i);
        if (step % 3 == 0) {
            lead_pattern[i] = if (dsp.rngFloat(&rng) < 0.7) .bass else .tone;
        } else {
            lead_pattern[i] = if (dsp.rngFloat(&rng) < 0.15) .ghost_tone else .none;
        }
    }
}

// ============================================================
// Cue specs
// ============================================================

const CueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    base_bpm: f32,
    swing: [3]f32,
    chord_change_beats: f32,
    // 12-bit pattern masks (one bit per step in the 12-step cycle)
    acc1_tone_mask: u16,
    acc1_slap_mask: u16,
    acc2_tone_mask: u16,
    acc2_bass_mask: u16,
    dundunba_mask: u16,
    dundunba_bell_mask: u16,
    sangban_mask: u16,
    sangban_bell_mask: u16,
    kenkeni_mask: u16,
    kenkeni_bell_mask: u16,
    shekere_density: f32,
    lead_density: f32,
    lead_rebuild_cycles: u16,
    ghost_density: f32,
    fill_chance: f32,
    break_chance: f32,
    reverb_boost: f32,
    energy: f32,
    tempo_drift: f32,
};

fn stepActive12(mask: u16, step: u8) bool {
    return (mask & (@as(u16, 1) << @as(u4, @intCast(step)))) != 0;
}

// Kuku: energetic harvest/fishing dance from Guinea
// Djole: festive masquerade dance
// Fanga: welcoming rhythm, moderate tempo
// Soli: ceremonial rhythm for initiations, fast and intense
const CUE_SPECS: [4]CueSpec = .{
    // kuku
    .{
        .root = 38,
        .scale_type = .dorian,
        .base_bpm = 120.0,
        .swing = .{ 1.08, 0.92, 1.0 },
        .chord_change_beats = 12.0,
        // acc1: tone on 1,4,7,10 (strong beats) + slap accents
        .acc1_tone_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .acc1_slap_mask = (1 << 2) | (1 << 5) | (1 << 8) | (1 << 11),
        // acc2: complementary pattern
        .acc2_tone_mask = (1 << 1) | (1 << 4) | (1 << 7) | (1 << 10),
        .acc2_bass_mask = (1 << 0) | (1 << 6),
        // dundunba: sparse, heavy
        .dundunba_mask = (1 << 0) | (1 << 6),
        .dundunba_bell_mask = (1 << 0) | (1 << 6),
        // sangban: the core timeline pattern
        .sangban_mask = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 8) | (1 << 10),
        .sangban_bell_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        // kenkeni: steady pulse
        .kenkeni_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .kenkeni_bell_mask = 0,
        .shekere_density = 0.65,
        .lead_density = 0.72,
        .lead_rebuild_cycles = 4,
        .ghost_density = 0.22,
        .fill_chance = 0.18,
        .break_chance = 0.06,
        .reverb_boost = 0.02,
        .energy = 0.78,
        .tempo_drift = 0.08,
    },
    // djole
    .{
        .root = 41,
        .scale_type = .mixolydian,
        .base_bpm = 108.0,
        .swing = .{ 1.12, 0.88, 1.0 },
        .chord_change_beats = 8.0,
        .acc1_tone_mask = (1 << 0) | (1 << 2) | (1 << 5) | (1 << 9),
        .acc1_slap_mask = (1 << 3) | (1 << 7) | (1 << 11),
        .acc2_tone_mask = (1 << 1) | (1 << 4) | (1 << 7) | (1 << 10),
        .acc2_bass_mask = (1 << 0) | (1 << 3) | (1 << 9),
        .dundunba_mask = (1 << 0) | (1 << 4) | (1 << 8),
        .dundunba_bell_mask = (1 << 0) | (1 << 6),
        .sangban_mask = (1 << 0) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 10),
        .sangban_bell_mask = (1 << 0) | (1 << 2) | (1 << 5) | (1 << 7) | (1 << 10),
        .kenkeni_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .kenkeni_bell_mask = (1 << 0) | (1 << 4) | (1 << 8),
        .shekere_density = 0.78,
        .lead_density = 0.74,
        .lead_rebuild_cycles = 3,
        .ghost_density = 0.30,
        .fill_chance = 0.22,
        .break_chance = 0.05,
        .reverb_boost = 0.01,
        .energy = 0.72,
        .tempo_drift = 0.06,
    },
    // fanga
    .{
        .root = 36,
        .scale_type = .natural_minor,
        .base_bpm = 96.0,
        .swing = .{ 1.02, 0.98, 1.0 },
        .chord_change_beats = 16.0,
        .acc1_tone_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .acc1_slap_mask = (1 << 5) | (1 << 11),
        .acc2_tone_mask = (1 << 1) | (1 << 7),
        .acc2_bass_mask = (1 << 0) | (1 << 6),
        .dundunba_mask = (1 << 0) | (1 << 6),
        .dundunba_bell_mask = (1 << 0) | (1 << 6),
        .sangban_mask = (1 << 0) | (1 << 6),
        .sangban_bell_mask = (1 << 0) | (1 << 6),
        .kenkeni_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .kenkeni_bell_mask = 0,
        .shekere_density = 0.48,
        .lead_density = 0.44,
        .lead_rebuild_cycles = 6,
        .ghost_density = 0.15,
        .fill_chance = 0.12,
        .break_chance = 0.08,
        .reverb_boost = 0.04,
        .energy = 0.55,
        .tempo_drift = 0.04,
    },
    // soli
    .{
        .root = 43,
        .scale_type = .harmonic_minor,
        .base_bpm = 132.0,
        .swing = .{ 1.03, 0.97, 1.0 },
        .chord_change_beats = 6.0,
        .acc1_tone_mask = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10),
        .acc1_slap_mask = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11),
        .acc2_tone_mask = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11),
        .acc2_bass_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .dundunba_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .dundunba_bell_mask = (1 << 0) | (1 << 6),
        .sangban_mask = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10),
        .sangban_bell_mask = (1 << 0) | (1 << 4) | (1 << 8),
        .kenkeni_mask = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10),
        .kenkeni_bell_mask = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 9),
        .shekere_density = 0.82,
        .lead_density = 0.92,
        .lead_rebuild_cycles = 2,
        .ghost_density = 0.35,
        .fill_chance = 0.32,
        .break_chance = 0.08,
        .reverb_boost = 0.0,
        .energy = 0.95,
        .tempo_drift = 0.10,
    },
};

const AfricanCueMorph = cue_morph.CueMorph(CuePreset);
var cue_state: AfricanCueMorph = .{
    .from = .kuku,
    .to = .kuku,
    .progress = 1.0,
    .morph_beats = 24.0,
};

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn blendedCueSpec() CueSpec {
    const from = CUE_SPECS[@intFromEnum(cue_state.from)];
    const to = CUE_SPECS[@intFromEnum(cue_state.to)];
    const t = cue_state.progress;
    var spec = to;
    spec.base_bpm = lerpF32(from.base_bpm, to.base_bpm, t);
    spec.swing[0] = lerpF32(from.swing[0], to.swing[0], t);
    spec.swing[1] = lerpF32(from.swing[1], to.swing[1], t);
    spec.swing[2] = lerpF32(from.swing[2], to.swing[2], t);
    spec.shekere_density = lerpF32(from.shekere_density, to.shekere_density, t);
    spec.lead_density = lerpF32(from.lead_density, to.lead_density, t);
    spec.ghost_density = lerpF32(from.ghost_density, to.ghost_density, t);
    spec.fill_chance = lerpF32(from.fill_chance, to.fill_chance, t);
    spec.break_chance = lerpF32(from.break_chance, to.break_chance, t);
    spec.reverb_boost = lerpF32(from.reverb_boost, to.reverb_boost, t);
    spec.energy = lerpF32(from.energy, to.energy, t);
    spec.tempo_drift = lerpF32(from.tempo_drift, to.tempo_drift, t);
    return spec;
}

fn baseChanceForCue(cue: CuePreset, is_strong: bool) f32 {
    return switch (cue) {
        .fanga => if (is_strong) 0.62 else 0.16,
        .soli => if (is_strong) 0.82 else 0.42,
        .djole => if (is_strong) 0.74 else 0.36,
        .kuku => if (is_strong) 0.7 else 0.3,
    };
}

fn cueBellBias(cue: CuePreset) f32 {
    return switch (cue) {
        .kuku => 0.42,
        .djole => 0.58,
        .fanga => 0.28,
        .soli => 0.34,
    };
}

// ============================================================
// Public API
// ============================================================

pub fn reset() void {
    rng = dsp.rngInit(entropy.nextSeed(0xAF10_2000, @intFromEnum(selected_cue)));
    cue_morph.reset(CuePreset, &cue_state, selected_cue);
    reverb = dsp.stereoReverbInit(.{1327, 1451, 1559, 1613}, .{181, 487}, .{ 0.82, 0.83, 0.81, 0.84 });

    composition.compositionEngineReset(&engine, 
        .{ .root = 38, .scale_type = .dorian },
        initHarmony(),
        AFRICAN_ARCS,
        12.0,
        .none,
    );

    resetInstruments();
    step_counter = 0.0;
    current_step = 0;
    lead_cycle_count = 0;
    in_break = false;
    break_remaining = 0;
    pattern_history.clear(&lead_history);
    lead_phrase = .{
        .anchor = 4,
        .region_low = 0,
        .region_high = 9,
        .rest_chance = 0.24,
        .min_notes = 3,
        .max_notes = 8,
        .gravity = 2.3,
    };
    lead_memory = .{};
    pending = .{PendingTrigger{}} ** NUM_VOICES;
    composition.applyChordTonesToPhrases(&engine.harmony, engine.key.scale_type, .{&lead_phrase});

    applyCueParams();
    rebuildLeadPattern(0.5, &CUE_SPECS[@intFromEnum(selected_cue)]);
}

fn resetInstruments() void {
    djembes = .{
        .{ .base_freq = 420.0, .volume = 0.75 },
        .{ .base_freq = 350.0, .volume = 0.65 },
        .{ .base_freq = 285.0, .volume = 0.65 },
    };
    dundunba = .{
        .base_freq = 82.0,
        .sweep = 35.0,
        .volume = 1.1,
        .body_lpf = dsp.lpfInit(200.0),
        .bell_freq = 520.0,
        .bell_volume = 0.3,
    };
    sangban = .{
        .base_freq = 135.0,
        .sweep = 28.0,
        .volume = 0.95,
        .body_lpf = dsp.lpfInit(320.0),
        .bell_freq = 680.0,
        .bell_volume = 0.28,
    };
    kenkeni = .{
        .base_freq = 215.0,
        .sweep = 18.0,
        .volume = 0.85,
        .body_lpf = dsp.lpfInit(420.0),
        .bell_freq = 920.0,
        .bell_volume = 0.25,
    };
    shekere = .{
        .volume = 0.48,
        .hpf = dsp.hpfInit(3800.0),
        .env = dsp.envelopeInit(0.001, 0.022, 0.0, 0.012),
    };
}

pub fn triggerCue() void {
    applyCueParams();
}

pub const DebugSnapshot = struct {
    cue_from: u8,
    cue_to: u8,
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
    chord_change_beats: f32,
    next_chord_change_beats: f32,
    current_step: u8,
    lead_cycle_count: u16,
    in_break: bool,
    break_remaining: u8,
};

pub fn debugSnapshot() DebugSnapshot {
    return .{
        .cue_from = @intFromEnum(cue_state.from),
        .cue_to = @intFromEnum(cue_state.to),
        .cue_selected = @intFromEnum(selected_cue),
        .cue_progress = cue_state.progress,
        .key_root = engine.key.root,
        .key_scale = engine.key.scale_type,
        .chord_index = engine.harmony.current,
        .chord_count = engine.harmony.num_chords,
        .micro = composition.arcControllerTension(&engine.arcs.micro),
        .meso = composition.arcControllerTension(&engine.arcs.meso),
        .macro = composition.arcControllerTension(&engine.arcs.macro),
        .longform_intensity = composition.compositionEngineLongFormIntensity(&engine),
        .longform_cadence = composition.compositionEngineLongFormCadenceSpread(&engine),
        .longform_modulation = composition.compositionEngineLongFormModulationDrive(&engine),
        .section_id = composition.compositionEngineSectionId(&engine),
        .section_progress = composition.compositionEngineSectionProgress(&engine),
        .section_transition_count = composition.compositionEngineSectionTransitionCount(&engine),
        .section_distinct_transition_count = composition.compositionEngineSectionDistinctTransitionCount(&engine),
        .section_bridge_active = composition.compositionEngineSectionBridgeActive(&engine),
        .section_bridge_progress = composition.compositionEngineSectionBridgeProgress(&engine),
        .section_bridge_from = composition.compositionEngineSectionBridgeFromId(&engine),
        .section_bridge_to = composition.compositionEngineSectionBridgeToId(&engine),
        .chord_change_beats = engine.chord_change_beats,
        .next_chord_change_beats = engine.next_chord_change_beats,
        .current_step = current_step,
        .lead_cycle_count = lead_cycle_count,
        .in_break = in_break,
        .break_remaining = break_remaining,
    };
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const nominal_bpm = @max(CUE_SPECS[@intFromEnum(cue_state.to)].base_bpm * bpm, 1.0);
    const cue_spb = dsp.samplesPerBeat(nominal_bpm);

    for (0..frames) |i| {
        cue_morph.advance(CuePreset, &cue_state, cue_spb);
        var spec = blendedCueSpec();
        // Macro arc-driven tempo drift: rising BPM at climax
        const macro_t = composition.arcControllerTension(&engine.arcs.macro);
        const effective_bpm = spec.base_bpm * bpm * (1.0 + macro_t * spec.tempo_drift);
        const tick = composition.compositionEngineAdvanceSample(&engine, &rng, effective_bpm);
        if (tick.chord_changed) {
            composition.applyChordTonesToPhrases(&engine.harmony, engine.key.scale_type, .{&lead_phrase});
        }
        shekere.volume = 0.35 + spec.shekere_density * 0.25;

        if (advanceStep12(effective_bpm, spec.swing)) |step| {
            advanceStepAll(step, tick.meso, tick.micro, &spec);

            // End of 12-step cycle
            if (step == 11) {
                lead_cycle_count += 1;
                if (lead_cycle_count >= spec.lead_rebuild_cycles) {
                    lead_cycle_count = 0;

                    // Check for break
                    if (!in_break and dsp.rngFloat(&rng) < spec.break_chance * tick.macro) {
                        in_break = true;
                        break_remaining = 1 + @as(u8, @intCast(dsp.rngNext(&rng) % 2));
                        buildBreakPattern();
                    } else if (in_break) {
                        break_remaining -|= 1;
                        if (break_remaining == 0) {
                            in_break = false;
                        } else {
                            buildBreakPattern();
                        }
                    }

                    if (!in_break) {
                        rebuildLeadPattern(tick.meso, &spec);
                    }
                }
            }
        }

        processPendingTriggers();

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        // Mix djembes
        for (0..3) |d| {
            const s = instruments.djembeProcess(&djembes[d], &rng) * drum_mix;
            const pan_out = dsp.panStereo(s, VOICE_PAN[d]);
            left += pan_out[0];
            right += pan_out[1];
        }

        // Mix dununs (each produces drum + bell)
        inline for (.{
            .{ &dundunba, V_DUNDUNBA },
            .{ &sangban, V_SANGBAN },
            .{ &kenkeni, V_KENKENI },
        }) |pair| {
            const out = instruments.dununProcess(pair[0], &rng);
            const drum_s = out[0] * drum_mix * tone_mix;
            const bell_s = out[1] * drum_mix * slap_mix;
            const pan = VOICE_PAN[pair[1]];
            const drum_pan = dsp.panStereo(drum_s, pan);
            const bell_pan = dsp.panStereo(bell_s, pan * 0.6); // bells slightly more centered
            left += drum_pan[0] + bell_pan[0];
            right += drum_pan[1] + bell_pan[1];
        }

        // Mix shekere
        const shekere_s = instruments.hiHatProcess(&shekere, &rng) * shaker_mix;
        const shekere_pan = dsp.panStereo(shekere_s, VOICE_PAN[V_SHEKERE]);
        left += shekere_pan[0];
        right += shekere_pan[1];

        // Reverb
        const wet = reverb_mix + spec.reverb_boost + tick.meso * 0.03;
        const dry = 1.0 - wet;
        const rev = dsp.stereoReverbProcess(.{1327, 1451, 1559, 1613}, .{181, 487}, &reverb, .{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.88);
        buf[i * 2 + 1] = softClip(right * 0.88);
    }
}

// ============================================================
// Step logic
// ============================================================

fn advanceStepAll(step: u8, meso: f32, micro: f32, spec: *const CueSpec) void {
    _ = micro;
    const vel_base: f32 = (0.58 + meso * 0.3) * (0.8 + spec.energy * 0.24);
    const accent: f32 = if (step % 3 == 0) 1.0 else 0.72 + (spec.swing[0] - spec.swing[1]) * 0.2;

    // Lead djembe
    if (in_break) {
        // During break, all djembes play unison
        const hit = lead_pattern[step];
        if (hit != .none) {
            const ttype = leadHitToTrigger(hit);
            scheduleTrigger(V_DJEMBE_LEAD, ttype, vel_base * accent);
            scheduleTrigger(V_DJEMBE_ACC1, ttype, vel_base * accent * 0.85);
            scheduleTrigger(V_DJEMBE_ACC2, ttype, vel_base * accent * 0.8);
        }
    } else {
        // Lead follows improvised pattern
        const hit = lead_pattern[step];
        if (hit != .none) {
            scheduleTrigger(V_DJEMBE_LEAD, leadHitToTrigger(hit), vel_base * accent);
        }

        // Accompaniment 1: tone + slap pattern with fills
        if (stepActive12(spec.acc1_tone_mask, step)) {
            scheduleTrigger(V_DJEMBE_ACC1, .djembe_tone, vel_base * accent * 0.82);
        } else if (stepActive12(spec.acc1_slap_mask, step)) {
            if (dsp.rngFloat(&rng) < 0.55 + meso * 0.35) {
                scheduleTrigger(V_DJEMBE_ACC1, .djembe_slap, vel_base * 0.7);
            }
        } else if (dsp.rngFloat(&rng) < spec.ghost_density * meso) {
            scheduleTrigger(V_DJEMBE_ACC1, .djembe_ghost_tone, vel_base * 0.4);
        }

        // Accompaniment 2: complementary pattern
        if (stepActive12(spec.acc2_tone_mask, step)) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_tone, vel_base * accent * 0.78);
        } else if (stepActive12(spec.acc2_bass_mask, step)) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_bass, vel_base * 0.85);
        } else if (dsp.rngFloat(&rng) < spec.ghost_density * meso * 0.7) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_ghost_slap, vel_base * 0.35);
        }
    }

    // Dundunba: sparse heavy foundation
    if (stepActive12(spec.dundunba_mask, step)) {
        scheduleTrigger(V_DUNDUNBA, .dunun_drum, vel_base);
    } else if (dsp.rngFloat(&rng) < spec.fill_chance * meso) {
        scheduleTrigger(V_DUNDUNBA, .dunun_drum, vel_base * 0.6);
    }
    if (stepActive12(spec.dundunba_bell_mask, step)) {
        if (pending[V_DUNDUNBA].trigger_type == .dunun_drum and dsp.rngFloat(&rng) < bellChance(spec, V_DUNDUNBA, meso)) {
            pending[V_DUNDUNBA].trigger_type = .dunun_both;
        } else if (dsp.rngFloat(&rng) < bellChance(spec, V_DUNDUNBA, meso) * 0.7) {
            scheduleTrigger(V_DUNDUNBA, .dunun_bell, 0.0);
        }
    }

    // Sangban: core timeline
    if (stepActive12(spec.sangban_mask, step)) {
        scheduleTrigger(V_SANGBAN, .dunun_drum, vel_base * 0.9);
    }
    if (stepActive12(spec.sangban_bell_mask, step)) {
        if (pending[V_SANGBAN].trigger_type == .dunun_drum and dsp.rngFloat(&rng) < bellChance(spec, V_SANGBAN, meso)) {
            pending[V_SANGBAN].trigger_type = .dunun_both;
        } else if (dsp.rngFloat(&rng) < bellChance(spec, V_SANGBAN, meso)) {
            scheduleTrigger(V_SANGBAN, .dunun_bell, 0.0);
        }
    }

    // Kenkeni: steady pulse, always plays
    if (stepActive12(spec.kenkeni_mask, step)) {
        if (dsp.rngFloat(&rng) < bellChance(spec, V_KENKENI, meso)) {
            scheduleTrigger(V_KENKENI, .dunun_both, vel_base * 0.85);
        } else {
            scheduleTrigger(V_KENKENI, .dunun_drum, vel_base * 0.85);
        }
    } else if (stepActive12(spec.kenkeni_bell_mask, step)) {
        if (dsp.rngFloat(&rng) < bellChance(spec, V_KENKENI, meso) * 0.9) {
            scheduleTrigger(V_KENKENI, .dunun_bell, 0.0);
        }
    }

    // Shekere: density-gated with swing feel
    const shekere_chance: f32 = if (step % 3 == 0) spec.shekere_density else spec.shekere_density * 0.6 * (0.5 + meso * 0.5);
    if (dsp.rngFloat(&rng) < shekere_chance) {
        scheduleTrigger(V_SHEKERE, .shekere, 0.0);
    }
}

fn bellChance(spec: *const CueSpec, voice: usize, meso: f32) f32 {
    const from_cue = cue_state.from;
    const to_cue = cue_state.to;
    const cue_bias = lerpF32(cueBellBias(from_cue), cueBellBias(to_cue), cue_state.progress);
    const voice_bias: f32 = switch (voice) {
        V_DUNDUNBA => 0.65,
        V_SANGBAN => 0.85,
        V_KENKENI => 0.72,
        else => 0.6,
    };
    return std.math.clamp(cue_bias * voice_bias * (0.58 + spec.energy * 0.22 + meso * 0.2), 0.0, 1.0);
}

fn leadHitToTrigger(hit: LeadHit) TriggerType {
    return switch (hit) {
        .bass => .djembe_bass,
        .tone => .djembe_tone,
        .slap => .djembe_slap,
        .ghost_tone => .djembe_ghost_tone,
        .ghost_slap => .djembe_ghost_slap,
        .none => .none,
    };
}

fn applyCueParams() void {
    cue_morph.setTarget(CuePreset, &cue_state, selected_cue);
    const spec = &CUE_SPECS[@intFromEnum(cue_state.to)];
    engine.key.root = spec.root;
    engine.key.target_root = spec.root;
    engine.key.scale_type = spec.scale_type;
    composition.compositionEngineSetChordChangeBeats(&engine, spec.chord_change_beats);

    // Tune dunun frequencies slightly per cue for variety
    const cue_idx: f32 = @floatFromInt(@intFromEnum(cue_state.to));
    dundunba.base_freq = 78.0 + cue_idx * 4.0;
    sangban.base_freq = 130.0 + cue_idx * 5.0;
    kenkeni.base_freq = 210.0 + cue_idx * 6.0;
    shekere.volume = 0.35 + spec.shekere_density * 0.25;
}
