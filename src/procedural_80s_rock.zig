// Procedural 80s rock style — v2 composition engine.
//
// Markov chord progressions, multi-scale arcs, phrase-generated lead
// with motif memory, chord-tone gravity, key modulation by 5ths,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter flavors (arena/night_drive/power_ballad/combat).
// Uses shared engine instruments: ElectricGuitar, SawBass, Kick, Snare, HiHat.
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;

// ============================================================
// Tweakable parameters (written by musicConfigMenu / settings)
// ============================================================

pub const CuePreset = enum(u8) {
    arena,
    night_drive,
    power_ballad,
    combat,
};

pub var bpm: f32 = 1.0;
const BASE_BPM: f32 = 112.0;
pub var reverb_mix: f32 = 0.35;
pub var lead_mix: f32 = 0.5;
pub var chord_mix: f32 = 0.34;
pub var drive: f32 = 0.55;
pub var drum_mix: f32 = 0.8;
pub var bass_mix: f32 = 0.7;
pub var gate: f32 = 0.45;
pub var selected_cue: CuePreset = .arena;

// ============================================================
// Reverb
// ============================================================

const RockReverb = StereoReverb(.{ 1327, 1451, 1559, 1613 }, .{ 181, 487 });
var reverb: RockReverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
var rng: dsp.Rng = dsp.Rng.init(0x80F0);

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 7, 12, 0 }, .len = 3 }; // I
    h.chords[1] = .{ .offsets = .{ 5, 12, 17, 0 }, .len = 3 }; // IV
    h.chords[2] = .{ .offsets = .{ 7, 14, 19, 0 }, .len = 3 }; // V
    h.chords[3] = .{ .offsets = .{ 9, 16, 21, 0 }, .len = 3 }; // vi
    h.chords[4] = .{ .offsets = .{ 10, 17, 22, 0 }, .len = 3 }; // bVII
    h.chords[5] = .{ .offsets = .{ 3, 10, 15, 0 }, .len = 3 }; // bIII
    h.num_chords = 6;
    h.transitions[0] = .{ 0.05, 0.30, 0.25, 0.15, 0.15, 0.10, 0, 0 };
    h.transitions[1] = .{ 0.25, 0.05, 0.35, 0.10, 0.15, 0.10, 0, 0 };
    h.transitions[2] = .{ 0.40, 0.20, 0.05, 0.15, 0.10, 0.10, 0, 0 };
    h.transitions[3] = .{ 0.15, 0.25, 0.25, 0.05, 0.20, 0.10, 0, 0 };
    h.transitions[4] = .{ 0.35, 0.20, 0.15, 0.10, 0.05, 0.15, 0, 0 };
    h.transitions[5] = .{ 0.20, 0.30, 0.20, 0.10, 0.15, 0.05, 0, 0 };
    return h;
}

// ============================================================
// Multi-scale arc system template
// ============================================================

const ROCK_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 4, .shape = .rise_fall },
    .meso = .{ .section_beats = 32, .shape = .rise_fall },
    .macro = .{ .section_beats = 128, .shape = .rise_fall },
};

// ============================================================
// Slow LFOs
// ============================================================

var lfo_filter: composition.SlowLfo = .{ .period_beats = 64, .depth = 0.06 };
var lfo_drive: composition.SlowLfo = .{ .period_beats = 96, .depth = 0.04 };

// ============================================================
// Layer volumes (vertical activation)
// ============================================================

const DRUM_LAYER = 0;
const BASS_LAYER = 1;
const CHORD_LAYER = 2;
const LEAD_LAYER = 3;
const ROCK_DRUM_PATTERN: layers.DrumPatternSpec = .{
    .kick_main_mask = (1 << 0) | (1 << 8),
    .kick_fill_mask = ~@as(u16, (1 << 0) | (1 << 8)),
    .kick_fill_velocity = 0.7,
    .snare_backbeat_mask = (1 << 4) | (1 << 12),
    .hat_onbeat_chance = 0.9,
};
const ROCK_DRUM_MIX: layers.DrumMixSpec = .{};
const ROCK_BASS_LAYER_SPEC: layers.StepBassSpec = .{
    .trigger_mask = 0x5555,
    .base_rest_chance = 0.05,
    .meso_rest_spread = 0.0,
    .filter_base_hz = 380.0,
    .filter_micro_hz = 0.0,
    .filter_meso_hz = 0.0,
};
const ROCK_LAYER_CURVES: [4]composition.LayerCurve = .{
    .{ .offset = 0.85, .slope = 0.15, .max = 1.0 },
    .{ .offset = 0.8, .slope = 0.2, .max = 1.0 },
    .{ .offset = 0.3, .slope = 0.7, .max = 1.0 },
    .{ .start = 0.25, .offset = 0.0, .slope = 1.6, .max = 1.0 },
};

const LAYER_FADE_RATE: f32 = 0.00005;

const ROCK_BASS_PHRASE: composition.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 6,
    .rest_chance = 0.05,
    .min_notes = 3,
    .max_notes = 6,
    .gravity = 3.0,
};
const ROCK_LEAD_PHRASE: composition.PhraseGenerator = .{
    .anchor = 10,
    .region_low = 7,
    .region_high = 17,
    .rest_chance = 0.15,
    .min_notes = 4,
    .max_notes = 8,
    .gravity = 3.0,
};
const CHORD_CHANGE_BEATS: f32 = 8.0;
const RockCueSpec = struct {
    root: u8,
    scale_type: composition.ScaleType,
    chord_change_beats: f32,
    modulation_mode: composition.ModulationMode,
    kick_main_mask: u16,
    kick_fill_mask: u16,
    snare_backbeat_mask: u16,
    bass_trigger_mask: u16,
    bass_rest_chance: f32,
    extra_kick_density: f32,
    hat_density: f32,
    lead_density: f32,
    lead_gate: f32,
    energy: f32,
    reverb_boost: f32,
    snare_ghost: f32,
    chord_retrigger: u8,
    chord_attack: f32,
    chord_decay: f32,
    chord_sustain: f32,
    chord_release: f32,
    guitar_gain: f32,
    guitar_od_amount: f32,
    cabinet_lpf_hz: f32,
    cabinet_hpf_hz: f32,
    lead_phrase: composition.PhraseConfig,
};
const CUE_SPECS: [4]RockCueSpec = .{
    .{
        .root = 40,
        .scale_type = .mixolydian,
        .chord_change_beats = 8.0,
        .modulation_mode = .fifth,
        .kick_main_mask = (1 << 0) | (1 << 8),
        .kick_fill_mask = (1 << 6) | (1 << 14),
        .snare_backbeat_mask = (1 << 4) | (1 << 12),
        .bass_trigger_mask = 0x5555,
        .bass_rest_chance = 0.06,
        .extra_kick_density = 0.35,
        .hat_density = 0.6,
        .lead_density = 0.65,
        .lead_gate = 0.42,
        .energy = 0.7,
        .reverb_boost = 0.1,
        .snare_ghost = 0.15,
        .chord_retrigger = 4,
        .chord_attack = 0.003,
        .chord_decay = 0.5,
        .chord_sustain = 0.3,
        .chord_release = 0.2,
        .guitar_gain = 0.9,
        .guitar_od_amount = 1.7,
        .cabinet_lpf_hz = 5000.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.12, .region_low = 7, .region_high = 17 },
    },
    .{
        .root = 38,
        .scale_type = .natural_minor,
        .chord_change_beats = 8.0,
        .modulation_mode = .none,
        .kick_main_mask = (1 << 0) | (1 << 7) | (1 << 8),
        .kick_fill_mask = (1 << 14),
        .snare_backbeat_mask = (1 << 4) | (1 << 12),
        .bass_trigger_mask = (1 << 0) | (1 << 3) | (1 << 4) | (1 << 7) | (1 << 8) | (1 << 11) | (1 << 12) | (1 << 15),
        .bass_rest_chance = 0.14,
        .extra_kick_density = 0.1,
        .hat_density = 0.75,
        .lead_density = 0.3,
        .lead_gate = 0.6,
        .energy = 0.35,
        .reverb_boost = 0.2,
        .snare_ghost = 0.05,
        .chord_retrigger = 8,
        .chord_attack = 0.02,
        .chord_decay = 0.8,
        .chord_sustain = 0.5,
        .chord_release = 0.4,
        .guitar_gain = 0.62,
        .guitar_od_amount = 1.0,
        .cabinet_lpf_hz = 3000.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.4, .region_low = 9, .region_high = 15 },
    },
    .{
        .root = 36,
        .scale_type = .natural_minor,
        .chord_change_beats = 16.0,
        .modulation_mode = .none,
        .kick_main_mask = (1 << 0) | (1 << 8),
        .kick_fill_mask = (1 << 15),
        .snare_backbeat_mask = (1 << 4) | (1 << 12),
        .bass_trigger_mask = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 12),
        .bass_rest_chance = 0.22,
        .extra_kick_density = 0.05,
        .hat_density = 0.15,
        .lead_density = 0.25,
        .lead_gate = 0.72,
        .energy = 0.2,
        .reverb_boost = 0.15,
        .snare_ghost = 0.0,
        .chord_retrigger = 8,
        .chord_attack = 0.03,
        .chord_decay = 1.2,
        .chord_sustain = 0.6,
        .chord_release = 0.6,
        .guitar_gain = 0.5,
        .guitar_od_amount = 0.8,
        .cabinet_lpf_hz = 2500.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.45, .region_low = 8, .region_high = 14 },
    },
    .{
        .root = 43,
        .scale_type = .harmonic_minor,
        .chord_change_beats = 4.0,
        .modulation_mode = .mixed,
        .kick_main_mask = (1 << 0) | (1 << 3) | (1 << 8) | (1 << 11),
        .kick_fill_mask = (1 << 5) | (1 << 6) | (1 << 13) | (1 << 14) | (1 << 15),
        .snare_backbeat_mask = (1 << 4) | (1 << 12),
        .bass_trigger_mask = 0xFFFF,
        .bass_rest_chance = 0.02,
        .extra_kick_density = 0.7,
        .hat_density = 0.95,
        .lead_density = 0.85,
        .lead_gate = 0.28,
        .energy = 0.95,
        .reverb_boost = 0.0,
        .snare_ghost = 0.25,
        .chord_retrigger = 2,
        .chord_attack = 0.001,
        .chord_decay = 0.06,
        .chord_sustain = 0.0,
        .chord_release = 0.03,
        .guitar_gain = 1.05,
        .guitar_od_amount = 2.3,
        .cabinet_lpf_hz = 3500.0,
        .cabinet_hpf_hz = 150.0,
        .lead_phrase = .{ .rest_chance = 0.05, .region_low = 7, .region_high = 19 },
    },
};
const RockStyleSpec = composition.StyleSpec(RockCueSpec, 4, 0);
const STYLE: RockStyleSpec = .{
    .arcs = ROCK_ARCS,
    .layer_curves = ROCK_LAYER_CURVES,
    .voice_timings = .{},
    .cues = &CUE_SPECS,
};
const RockRunner = composition.StepStyleRunner(RockCueSpec, 4);
var runner: RockRunner = .{};
var drums: layers.DrumKitLayer = .{};
var bass_layer: layers.StepBassLayer = .{};
var guitar_layer: layers.GuitarChordLayer = .{};
var lead_layer: layers.ProcessedLeadLayer = .{};

// Cue-derived parameters
var cue_energy: f32 = 0.5;
var cue_reverb_boost: f32 = 0.0;

// ============================================================
// Public API
// ============================================================

pub fn triggerCue() void {
    applyCueParams();
}

pub fn reset() void {
    rng = dsp.Rng.init(@as(u32, 0x80F0_0000) + @as(u32, @intFromEnum(selected_cue)) * 17);
    lfo_filter = .{ .period_beats = 64, .depth = 0.06 };
    lfo_drive = .{ .period_beats = 96, .depth = 0.04 };
    layers.resetDrumKitLayer(&drums, .{}, .{}, .{});
    layers.resetStepBassLayer(&bass_layer, .{ .drive = 0.55 }, ROCK_BASS_PHRASE);
    layers.resetGuitarChordLayer(&guitar_layer, 0.35, 0.008, 4500.0, 120.0);
    layers.resetProcessedLeadLayer(&lead_layer, ROCK_LEAD_PHRASE);

    reverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
    runner.reset(&STYLE, .{ .root = 40, .scale_type = .mixolydian }, initHarmony(), CHORD_CHANGE_BEATS, .fifth, .{ 1.0, 1.0, 0.8, 0.3 }, .{ 1.0, 0.8, 0.5, 0.0 });
    applyCueParams();
    advanceChord();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const eff_bpm = BASE_BPM * bpm;
    for (0..frames) |i| {
        const frame = runner.advanceFrame(&rng, &STYLE, eff_bpm, LAYER_FADE_RATE);
        lfo_filter.advanceSample(eff_bpm);
        lfo_drive.advanceSample(eff_bpm);

        if (frame.tick.chord_changed) {
            advanceChord();
        }

        if (frame.step) |step| {
            advanceStep(step, frame.tick.meso, frame.tick.micro);
        }

        // ---- Mix ----
        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const drums_out = layers.mixDrumKitLayer(&drums, &rng, drum_mix * runner.layer_levels[DRUM_LAYER], ROCK_DRUM_MIX);
        left += drums_out[0];
        right += drums_out[1];

        const bass_out = layers.mixStepBassLayer(&bass_layer, bass_mix * runner.layer_levels[BASS_LAYER], 0.85, 0.8);
        left += bass_out[0];
        right += bass_out[1];

        const eff_drive = drive * lfo_drive.modulate() + cue_energy * 0.2;
        const guitar_out = layers.mixGuitarChordLayer(&guitar_layer, chord_mix * runner.layer_levels[CHORD_LAYER], eff_drive);
        left += guitar_out[0];
        right += guitar_out[1];

        const lead_out = layers.mixProcessedLeadLayer(&lead_layer, lead_mix * runner.layer_levels[LEAD_LAYER], frame.tick.meso, eff_drive);
        left += lead_out[0];
        right += lead_out[1];

        const eff_reverb = reverb_mix + cue_reverb_boost;
        const rev = reverb.process(.{ left, right });
        const dry = 1.0 - eff_reverb;
        left = left * dry + rev[0] * eff_reverb;
        right = right * dry + rev[1] * eff_reverb;

        buf[i * 2] = softClip(left * 0.82);
        buf[i * 2 + 1] = softClip(right * 0.82);
    }
}

// ============================================================
// Cue parameter application — dramatic differences per flavor
// ============================================================

fn applyCueParams() void {
    const spec = STYLE.cues[@intFromEnum(selected_cue)];
    runner.engine.key.root = spec.root;
    runner.engine.key.target_root = spec.root;
    runner.engine.key.scale_type = spec.scale_type;
    runner.engine.chord_change_beats = spec.chord_change_beats;
    runner.engine.modulation_mode = spec.modulation_mode;
    cue_energy = spec.energy;
    cue_reverb_boost = spec.reverb_boost;
    layers.applyGuitarCue(&guitar_layer, .{
        .gain = spec.guitar_gain,
        .od_amount = spec.guitar_od_amount,
        .cabinet_lpf_hz = spec.cabinet_lpf_hz,
        .cabinet_hpf_hz = spec.cabinet_hpf_hz,
        .retrigger = spec.chord_retrigger,
        .attack = spec.chord_attack,
        .decay = spec.chord_decay,
        .sustain = spec.chord_sustain,
        .release = spec.chord_release,
    });
    layers.applyProcessedLeadCue(&lead_layer, .{
        .density = spec.lead_density,
        .phrase = spec.lead_phrase,
    });
    bass_layer.phrase.rest_chance = spec.bass_rest_chance;
}

// ============================================================
// Chord progression
// ============================================================

fn advanceChord() void {
    const chord = runner.engine.harmony.chords[runner.engine.harmony.current];
    layers.applyGuitarChord(&guitar_layer, runner.engine.key.root, chord);
    layers.applyProcessedLeadChord(&lead_layer, &runner.engine.harmony, runner.engine.key.scale_type);
    layers.applyStepBassChord(&bass_layer, &runner.engine.harmony, runner.engine.key.scale_type, runner.engine.key.root);
}

// ============================================================
// Sequencer (16th note grid)
// ============================================================

fn advanceStep(step: u8, meso: f32, micro: f32) void {
    const spec = STYLE.cues[@intFromEnum(selected_cue)];
    layers.advanceDrumKitLayer(&drums, step, meso, &rng, .{
        .kick_main_mask = spec.kick_main_mask,
        .kick_fill_mask = spec.kick_fill_mask,
        .kick_fill_velocity = ROCK_DRUM_PATTERN.kick_fill_velocity,
        .kick_fill_density = spec.extra_kick_density,
        .snare_backbeat_mask = spec.snare_backbeat_mask,
        .snare_ghost_chance = spec.snare_ghost,
        .hat_onbeat_chance = ROCK_DRUM_PATTERN.hat_onbeat_chance,
        .hat_offbeat_chance = spec.hat_density,
    });

    if (spec.bass_trigger_mask & (@as(u16, 1) << @as(u4, @intCast(step))) != 0) {
        layers.advanceStepBassLayer(&bass_layer, step, micro, meso, lfo_filter.modulate(), &rng, &runner.engine.key, .{
            .trigger_mask = spec.bass_trigger_mask,
            .base_rest_chance = spec.bass_rest_chance,
            .meso_rest_spread = ROCK_BASS_LAYER_SPEC.meso_rest_spread,
            .filter_base_hz = 380.0 + drive * 900.0 + cue_energy * 400.0,
            .filter_micro_hz = ROCK_BASS_LAYER_SPEC.filter_micro_hz,
            .filter_meso_hz = ROCK_BASS_LAYER_SPEC.filter_meso_hz,
        });
    }

    layers.advanceGuitarChordLayer(&guitar_layer, step);
    layers.maybeTriggerProcessedLeadLayer(&lead_layer, step, &rng, &runner.engine.key, .{
        .gate = spec.lead_gate,
        .drive = drive,
        .micro = micro,
        .meso = meso,
        .filter_lfo_mod = lfo_filter.modulate(),
    });
}
