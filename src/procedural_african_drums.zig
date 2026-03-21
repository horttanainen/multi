// Procedural West African drum ensemble — v2 composition engine.
//
// 8-voice ensemble: 3 djembes (lead + 2 accompaniment), 3 dununs
// (dundunba, sangban, kenkeni with iron bells), shekere.
// Uses 12-step ternary cycle (12/8 feel), per-voice microtiming,
// lead improvisation, periodic breaks, and macro arc-driven evolution.
const std = @import("std");
const dsp = @import("music/dsp.zig");
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

// Public vars for settings compatibility.
pub var bpm: f32 = 1.0;
pub var reverb_mix: f32 = 0.28;
pub var drum_mix: f32 = 0.9;
pub var shaker_mix: f32 = 0.55;
pub var tone_mix: f32 = 0.62;
pub var slap_mix: f32 = 0.5;
pub var selected_cue: CuePreset = .kuku;

const DrumReverb = StereoReverb(.{ 1327, 1451, 1559, 1613 }, .{ 181, 487 });
var reverb: DrumReverb = DrumReverb.init(.{ 0.82, 0.83, 0.81, 0.84 });
var rng: dsp.Rng = dsp.Rng.init(0xAF10_2000);

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
    const offset = VOICE_OFFSETS[voice] + (rng.float() * 2.0 - 1.0) * JITTER_SAMPLES;
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
                .djembe_bass => djembe.triggerBass(vel),
                .djembe_tone => djembe.triggerTone(vel),
                .djembe_slap => djembe.triggerSlap(vel),
                .djembe_ghost_tone => djembe.triggerGhost(vel, .tone),
                .djembe_ghost_slap => djembe.triggerGhost(vel, .slap),
                else => {},
            }
        },
        V_DUNDUNBA => switch (ttype) {
            .dunun_drum => dundunba.triggerDrum(vel),
            .dunun_bell => dundunba.triggerBell(),
            .dunun_both => {
                dundunba.triggerDrum(vel);
                dundunba.triggerBell();
            },
            else => {},
        },
        V_SANGBAN => switch (ttype) {
            .dunun_drum => sangban.triggerDrum(vel),
            .dunun_bell => sangban.triggerBell(),
            .dunun_both => {
                sangban.triggerDrum(vel);
                sangban.triggerBell();
            },
            else => {},
        },
        V_KENKENI => switch (ttype) {
            .dunun_drum => kenkeni.triggerDrum(vel),
            .dunun_bell => kenkeni.triggerBell(),
            .dunun_both => {
                kenkeni.triggerDrum(vel);
                kenkeni.triggerBell();
            },
            else => {},
        },
        V_SHEKERE => {
            if (ttype == .shekere) shekere.trigger();
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
    .body_lpf = dsp.LPF.init(200.0),
    .bell_freq = 520.0,
    .bell_volume = 0.3,
};
var sangban: instruments.Dunun = .{
    .base_freq = 135.0,
    .sweep = 28.0,
    .volume = 0.95,
    .body_lpf = dsp.LPF.init(320.0),
    .bell_freq = 680.0,
    .bell_volume = 0.28,
};
var kenkeni: instruments.Dunun = .{
    .base_freq = 215.0,
    .sweep = 18.0,
    .volume = 0.85,
    .body_lpf = dsp.LPF.init(420.0),
    .bell_freq = 920.0,
    .bell_volume = 0.25,
};
var shekere: instruments.HiHat = .{
    .volume = 0.48,
    .hpf = dsp.HPF.init(3800.0),
    .env = dsp.Envelope.init(0.001, 0.022, 0.0, 0.012),
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

fn rebuildLeadPattern(meso: f32, spec: *const CueSpec) void {
    const energy = std.math.clamp(spec.energy * (0.4 + meso * 0.65), 0.0, 1.0);
    for (0..NUM_STEPS) |i| {
        const step: u8 = @intCast(i);
        // Strong beats (0, 3, 6, 9) get more hits
        const is_strong = (step % 3 == 0);
        const base_chance: f32 = switch (selected_cue) {
            .fanga => if (is_strong) 0.62 else 0.16,
            .soli => if (is_strong) 0.82 else 0.42,
            .djole => if (is_strong) 0.74 else 0.36,
            .kuku => if (is_strong) 0.7 else 0.3,
        };
        const chance = base_chance * energy * spec.lead_density;

        if (rng.float() < chance) {
            const r = rng.float();
            if (is_strong and r < 0.25) {
                lead_pattern[i] = .bass;
            } else if (r < 0.5) {
                lead_pattern[i] = .tone;
            } else if (r < 0.75) {
                lead_pattern[i] = .slap;
            } else if (r < 0.9) {
                lead_pattern[i] = .ghost_tone;
            } else {
                lead_pattern[i] = .ghost_slap;
            }
        } else {
            lead_pattern[i] = .none;
        }
    }
}

fn buildBreakPattern() void {
    // Unison hits on strong beats
    for (0..NUM_STEPS) |i| {
        const step: u8 = @intCast(i);
        if (step % 3 == 0) {
            lead_pattern[i] = if (rng.float() < 0.7) .bass else .tone;
        } else {
            lead_pattern[i] = if (rng.float() < 0.15) .ghost_tone else .none;
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

// ============================================================
// Public API
// ============================================================

pub fn reset() void {
    rng = dsp.Rng.init(0xAF10_2000 + @as(u32, @intFromEnum(selected_cue)) * 37);
    reverb = DrumReverb.init(.{ 0.82, 0.83, 0.81, 0.84 });

    engine.reset(
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
    pending = .{PendingTrigger{}} ** NUM_VOICES;

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
        .body_lpf = dsp.LPF.init(200.0),
        .bell_freq = 520.0,
        .bell_volume = 0.3,
    };
    sangban = .{
        .base_freq = 135.0,
        .sweep = 28.0,
        .volume = 0.95,
        .body_lpf = dsp.LPF.init(320.0),
        .bell_freq = 680.0,
        .bell_volume = 0.28,
    };
    kenkeni = .{
        .base_freq = 215.0,
        .sweep = 18.0,
        .volume = 0.85,
        .body_lpf = dsp.LPF.init(420.0),
        .bell_freq = 920.0,
        .bell_volume = 0.25,
    };
    shekere = .{
        .volume = 0.48,
        .hpf = dsp.HPF.init(3800.0),
        .env = dsp.Envelope.init(0.001, 0.022, 0.0, 0.012),
    };
}

pub fn triggerCue() void {
    applyCueParams();
    rebuildLeadPattern(0.5, &CUE_SPECS[@intFromEnum(selected_cue)]);
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spec = &CUE_SPECS[@intFromEnum(selected_cue)];
    // Macro arc-driven tempo drift: rising BPM at climax
    const macro_t = engine.arcs.macro.tension();
    const effective_bpm = spec.base_bpm * bpm * (1.0 + macro_t * spec.tempo_drift);

    for (0..frames) |i| {
        const tick = engine.advanceSample(&rng, effective_bpm);

        if (advanceStep12(effective_bpm, spec.swing)) |step| {
            advanceStepAll(step, tick.meso, tick.micro, spec);

            // End of 12-step cycle
            if (step == 11) {
                lead_cycle_count += 1;
                if (lead_cycle_count >= spec.lead_rebuild_cycles) {
                    lead_cycle_count = 0;

                    // Check for break
                    if (!in_break and rng.float() < spec.break_chance * tick.macro) {
                        in_break = true;
                        break_remaining = 1 + @as(u8, @intCast(rng.next() % 2));
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
                        rebuildLeadPattern(tick.meso, spec);
                    }
                }
            }
        }

        processPendingTriggers();

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        // Mix djembes
        for (0..3) |d| {
            const s = djembes[d].process(&rng) * drum_mix;
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
            const out = pair[0].process(&rng);
            const drum_s = out[0] * drum_mix * tone_mix;
            const bell_s = out[1] * drum_mix * slap_mix;
            const pan = VOICE_PAN[pair[1]];
            const drum_pan = dsp.panStereo(drum_s, pan);
            const bell_pan = dsp.panStereo(bell_s, pan * 0.6); // bells slightly more centered
            left += drum_pan[0] + bell_pan[0];
            right += drum_pan[1] + bell_pan[1];
        }

        // Mix shekere
        const shekere_s = shekere.process(&rng) * shaker_mix;
        const shekere_pan = dsp.panStereo(shekere_s, VOICE_PAN[V_SHEKERE]);
        left += shekere_pan[0];
        right += shekere_pan[1];

        // Reverb
        const wet = reverb_mix + spec.reverb_boost + tick.meso * 0.03;
        const dry = 1.0 - wet;
        const rev = reverb.process(.{ left, right });
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
            if (rng.float() < 0.55 + meso * 0.35) {
                scheduleTrigger(V_DJEMBE_ACC1, .djembe_slap, vel_base * 0.7);
            }
        } else if (rng.float() < spec.ghost_density * meso) {
            scheduleTrigger(V_DJEMBE_ACC1, .djembe_ghost_tone, vel_base * 0.4);
        }

        // Accompaniment 2: complementary pattern
        if (stepActive12(spec.acc2_tone_mask, step)) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_tone, vel_base * accent * 0.78);
        } else if (stepActive12(spec.acc2_bass_mask, step)) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_bass, vel_base * 0.85);
        } else if (rng.float() < spec.ghost_density * meso * 0.7) {
            scheduleTrigger(V_DJEMBE_ACC2, .djembe_ghost_slap, vel_base * 0.35);
        }
    }

    // Dundunba: sparse heavy foundation
    if (stepActive12(spec.dundunba_mask, step)) {
        scheduleTrigger(V_DUNDUNBA, .dunun_drum, vel_base);
    } else if (rng.float() < spec.fill_chance * meso) {
        scheduleTrigger(V_DUNDUNBA, .dunun_drum, vel_base * 0.6);
    }
    if (stepActive12(spec.dundunba_bell_mask, step)) {
        if (pending[V_DUNDUNBA].trigger_type == .dunun_drum and rng.float() < bellChance(spec, V_DUNDUNBA, meso)) {
            pending[V_DUNDUNBA].trigger_type = .dunun_both;
        } else if (rng.float() < bellChance(spec, V_DUNDUNBA, meso) * 0.7) {
            scheduleTrigger(V_DUNDUNBA, .dunun_bell, 0.0);
        }
    }

    // Sangban: core timeline
    if (stepActive12(spec.sangban_mask, step)) {
        scheduleTrigger(V_SANGBAN, .dunun_drum, vel_base * 0.9);
    }
    if (stepActive12(spec.sangban_bell_mask, step)) {
        if (pending[V_SANGBAN].trigger_type == .dunun_drum and rng.float() < bellChance(spec, V_SANGBAN, meso)) {
            pending[V_SANGBAN].trigger_type = .dunun_both;
        } else if (rng.float() < bellChance(spec, V_SANGBAN, meso)) {
            scheduleTrigger(V_SANGBAN, .dunun_bell, 0.0);
        }
    }

    // Kenkeni: steady pulse, always plays
    if (stepActive12(spec.kenkeni_mask, step)) {
        if (rng.float() < bellChance(spec, V_KENKENI, meso)) {
            scheduleTrigger(V_KENKENI, .dunun_both, vel_base * 0.85);
        } else {
            scheduleTrigger(V_KENKENI, .dunun_drum, vel_base * 0.85);
        }
    } else if (stepActive12(spec.kenkeni_bell_mask, step)) {
        if (rng.float() < bellChance(spec, V_KENKENI, meso) * 0.9) {
            scheduleTrigger(V_KENKENI, .dunun_bell, 0.0);
        }
    }

    // Shekere: density-gated with swing feel
    const shekere_chance: f32 = if (step % 3 == 0) spec.shekere_density else spec.shekere_density * 0.6 * (0.5 + meso * 0.5);
    if (rng.float() < shekere_chance) {
        scheduleTrigger(V_SHEKERE, .shekere, 0.0);
    }
}

fn bellChance(spec: *const CueSpec, voice: usize, meso: f32) f32 {
    const cue_bias: f32 = switch (selected_cue) {
        .kuku => 0.42,
        .djole => 0.58,
        .fanga => 0.28,
        .soli => 0.34,
    };
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
    const spec = &CUE_SPECS[@intFromEnum(selected_cue)];
    engine.key.root = spec.root;
    engine.key.target_root = spec.root;
    engine.key.scale_type = spec.scale_type;
    engine.chord_change_beats = spec.chord_change_beats;

    // Tune dunun frequencies slightly per cue for variety
    const cue_idx: f32 = @floatFromInt(@intFromEnum(selected_cue));
    dundunba.base_freq = 78.0 + cue_idx * 4.0;
    sangban.base_freq = 130.0 + cue_idx * 5.0;
    kenkeni.base_freq = 210.0 + cue_idx * 6.0;
    shekere.volume = 0.35 + spec.shekere_density * 0.25;
}
