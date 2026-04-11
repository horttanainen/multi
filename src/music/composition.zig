const std = @import("std");
const dsp = @import("dsp.zig");

pub const ArcShape = enum { rise, fall, rise_fall, plateau };

pub const ArcController = struct {
    beat_count: f32 = 0,
    section_beats: f32 = 32,
    shape: ArcShape = .rise_fall,
};

pub fn arcControllerAdvanceSample(controller: *ArcController, bpm_val: f32) void {
    controller.beat_count += bpm_val / (dsp.SAMPLE_RATE * 60.0);
    while (controller.beat_count >= controller.section_beats) {
        controller.beat_count -= controller.section_beats;
    }
}

pub fn arcControllerTension(controller: *const ArcController) f32 {
    const p = controller.beat_count / controller.section_beats;
    return switch (controller.shape) {
        .rise => p,
        .fall => 1.0 - p,
        .rise_fall => @sin(p * std.math.pi),
        .plateau => if (p < 0.25) p * 4.0 else if (p > 0.75) (1.0 - p) * 4.0 else 1.0,
    };
}

pub fn arcControllerReset(controller: *ArcController) void {
    controller.beat_count = 0;
}

pub const ScaleType = enum {
    minor_pentatonic,
    major_pentatonic,
    dorian,
    mixolydian,
    natural_minor,
    harmonic_minor,
};

const MAX_SCALE_NOTES = 7;

pub const ScaleIntervals = struct {
    intervals: [MAX_SCALE_NOTES]u8,
    len: u8,
};

pub fn getScaleIntervals(scale_type: ScaleType) ScaleIntervals {
    return switch (scale_type) {
        .minor_pentatonic => .{ .intervals = .{ 0, 3, 5, 7, 10, 0, 0 }, .len = 5 },
        .major_pentatonic => .{ .intervals = .{ 0, 2, 4, 7, 9, 0, 0 }, .len = 5 },
        .dorian => .{ .intervals = .{ 0, 2, 3, 5, 7, 9, 10 }, .len = 7 },
        .mixolydian => .{ .intervals = .{ 0, 2, 4, 5, 7, 9, 10 }, .len = 7 },
        .natural_minor => .{ .intervals = .{ 0, 2, 3, 5, 7, 8, 10 }, .len = 7 },
        .harmonic_minor => .{ .intervals = .{ 0, 2, 3, 5, 7, 8, 11 }, .len = 7 },
    };
}

pub fn scaleNoteToMidi(root: u8, scale_type: ScaleType, degree: u8) u8 {
    const si = getScaleIntervals(scale_type);
    const octave: u8 = degree / si.len;
    const step: u8 = degree % si.len;
    return root + octave * 12 + si.intervals[step];
}

pub fn scaleDegreesInRange(scale_type: ScaleType, octaves: u8) u8 {
    const si = getScaleIntervals(scale_type);
    return si.len * octaves;
}

pub const KeyState = struct {
    root: u8 = 36,
    target_root: u8 = 36,
    scale_type: ScaleType = .minor_pentatonic,
    transition_progress: f32 = 1.0,
    transition_speed: f32 = 0.0001,
};

pub fn keyStateModulateTo(state: *KeyState, new_root: u8) void {
    state.target_root = new_root;
    state.transition_progress = 0;
}

pub fn keyStateModulateByFourth(state: *KeyState) void {
    keyStateModulateTo(state, state.root + 5);
}

pub fn keyStateModulateByFifth(state: *KeyState) void {
    keyStateModulateTo(state, state.root + 7);
}

pub fn keyStateAdvanceSample(state: *KeyState) void {
    if (state.transition_progress >= 1.0) return;
    state.transition_progress += state.transition_speed;
    if (state.transition_progress >= 1.0) {
        state.transition_progress = 1.0;
        state.root = state.target_root;
    }
}

pub fn keyStateIsTransitioning(state: *const KeyState) bool {
    return state.transition_progress < 1.0;
}

pub fn keyStateNoteToMidi(state: *const KeyState, degree: u8) u8 {
    return scaleNoteToMidi(state.root, state.scale_type, degree);
}

pub const MAX_CHORD_TONES = 4;
pub const MAX_CHORDS = 8;

pub const ChordDef = struct {
    offsets: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES,
    len: u8 = 3,
};

pub const ChordMarkov = struct {
    chords: [MAX_CHORDS]ChordDef = .{ChordDef{}} ** MAX_CHORDS,
    num_chords: u8 = 0,
    transitions: [MAX_CHORDS][MAX_CHORDS]f32 = .{.{0} ** MAX_CHORDS} ** MAX_CHORDS,
    current: u8 = 0,
};

pub fn chordMarkovNextChord(harmony: *ChordMarkov, rng: *dsp.Rng) ChordDef {
    const row = harmony.transitions[harmony.current];
    var cumulative: f32 = 0;
    const r = dsp.rngFloat(rng);
    for (0..harmony.num_chords) |i| {
        cumulative += row[i];
        if (r < cumulative) {
            harmony.current = @intCast(i);
            return harmony.chords[i];
        }
    }
    harmony.current = 0;
    return harmony.chords[0];
}

pub fn chordMarkovCurrentMidiNotes(harmony: *const ChordMarkov, root: u8) [MAX_CHORD_TONES]u8 {
    const chord = harmony.chords[harmony.current];
    var notes: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES;
    for (0..chord.len) |i| {
        notes[i] = root + chord.offsets[i];
    }
    return notes;
}

pub fn chordMarkovScaleDegrees(harmony: *const ChordMarkov, scale_type: ScaleType) struct { tones: [MAX_CHORD_TONES]u8, count: u8 } {
    const chord = harmony.chords[harmony.current];
    const si = getScaleIntervals(scale_type);
    var tones: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES;
    for (0..chord.len) |ci| {
        var best_deg: u8 = 0;
        var best_dist: u8 = 255;
        for (0..si.len) |s| {
            const dist = if (si.intervals[s] > chord.offsets[ci])
                si.intervals[s] - chord.offsets[ci]
            else
                chord.offsets[ci] - si.intervals[s];
            if (dist < best_dist) {
                best_dist = dist;
                best_deg = @intCast(s);
            }
        }
        tones[ci] = best_deg;
    }
    return .{ .tones = tones, .count = chord.len };
}

pub const ArcSystem = struct {
    micro: ArcController = .{ .section_beats = 8, .shape = .rise_fall },
    meso: ArcController = .{ .section_beats = 48, .shape = .rise_fall },
    macro: ArcController = .{ .section_beats = 256, .shape = .rise_fall },
};

pub fn arcSystemAdvanceSample(arcs: *ArcSystem, bpm_val: f32) void {
    arcControllerAdvanceSample(&arcs.micro, bpm_val);
    arcControllerAdvanceSample(&arcs.meso, bpm_val);
    arcControllerAdvanceSample(&arcs.macro, bpm_val);
}

pub fn arcSystemReset(arcs: *ArcSystem) void {
    arcControllerReset(&arcs.micro);
    arcControllerReset(&arcs.meso);
    arcControllerReset(&arcs.macro);
}

pub const ModulationMode = enum {
    none,
    fourth,
    fifth,
    mixed,
};

pub const SectionId = enum(u8) {
    a,
    b,
    c,
    bridge,
    breakdown,
};

const SECTION_COUNT: usize = 5;
const SECTION_HISTORY_SIZE: usize = 8;

const SectionProfile = struct {
    min_beats: f32,
    max_beats: f32,
    intensity_center: f32,
    cadence_center: f32,
    modulation_center: f32,
    density_center: f32,
    harmonic_center: f32,
    cadence_scale_center: f32,
};

const SECTION_PROFILES: [SECTION_COUNT]SectionProfile = .{
    .{
        .min_beats = 56.0,
        .max_beats = 88.0,
        .intensity_center = 0.36,
        .cadence_center = 0.13,
        .modulation_center = 0.42,
        .density_center = 0.34,
        .harmonic_center = 0.3,
        .cadence_scale_center = 0.9,
    },
    .{
        .min_beats = 72.0,
        .max_beats = 108.0,
        .intensity_center = 0.52,
        .cadence_center = 0.18,
        .modulation_center = 0.5,
        .density_center = 0.52,
        .harmonic_center = 0.45,
        .cadence_scale_center = 1.0,
    },
    .{
        .min_beats = 84.0,
        .max_beats = 132.0,
        .intensity_center = 0.7,
        .cadence_center = 0.26,
        .modulation_center = 0.62,
        .density_center = 0.72,
        .harmonic_center = 0.62,
        .cadence_scale_center = 1.16,
    },
    .{
        .min_beats = 28.0,
        .max_beats = 52.0,
        .intensity_center = 0.64,
        .cadence_center = 0.32,
        .modulation_center = 0.76,
        .density_center = 0.66,
        .harmonic_center = 0.84,
        .cadence_scale_center = 1.28,
    },
    .{
        .min_beats = 24.0,
        .max_beats = 44.0,
        .intensity_center = 0.24,
        .cadence_center = 0.1,
        .modulation_center = 0.32,
        .density_center = 0.18,
        .harmonic_center = 0.2,
        .cadence_scale_center = 0.74,
    },
};

const SECTION_TRANSITION_WEIGHTS: [SECTION_COUNT][SECTION_COUNT]f32 = .{
    // from A
    .{ 0.04, 0.36, 0.24, 0.22, 0.14 },
    // from B
    .{ 0.22, 0.06, 0.32, 0.24, 0.16 },
    // from C
    .{ 0.28, 0.24, 0.04, 0.24, 0.20 },
    // from Bridge
    .{ 0.36, 0.28, 0.18, 0.04, 0.14 },
    // from Breakdown
    .{ 0.34, 0.26, 0.22, 0.14, 0.04 },
};

pub const CompositionTick = struct {
    micro: f32,
    meso: f32,
    macro: f32,
    chord_changed: bool,
};

pub fn easeLevels(comptime N: usize, levels: *[N]f32, targets: *const [N]f32, rate: f32) void {
    for (0..N) |i| {
        levels[i] += (targets[i] - levels[i]) * rate;
    }
}

pub const LayerCurve = struct {
    start: f32 = 0.0,
    offset: f32 = 0.0,
    slope: f32 = 1.0,
    min: f32 = 0.0,
    max: f32 = 1.0,
};

pub fn layerCurveTarget(curve: LayerCurve, macro: f32) f32 {
    const t = @max(macro - curve.start, 0.0);
    return std.math.clamp(curve.offset + t * curve.slope, curve.min, curve.max);
}

pub fn applyLayerCurves(comptime N: usize, curves: *const [N]LayerCurve, macro: f32, out: *[N]f32) void {
    for (0..N) |i| {
        out[i] = layerCurveTarget(curves[i], macro);
    }
}

pub fn StyleSpec(comptime CueSpecType: type, comptime LayerCount: usize, comptime TimingCount: usize) type {
    return struct {
        arcs: ArcSystem,
        layer_curves: [LayerCount]LayerCurve,
        voice_timings: [TimingCount]VoiceTimingSpec,
        cues: []const CueSpecType,
    };
}

pub const StepStyleFrame = struct {
    tick: CompositionTick,
    step: ?u8,
};

pub const StepSequencer16 = struct {
    step_counter: f32 = 0.0,
    step: u8 = 0,
};

pub fn stepSequencer16Reset(sequencer: *StepSequencer16) void {
    sequencer.step_counter = 0.0;
    sequencer.step = 0;
}

pub fn stepSequencer16AdvanceSample(sequencer: *StepSequencer16, bpm_val: f32) ?u8 {
    const samples_per_step = dsp.SAMPLE_RATE * 60.0 / bpm_val / 4.0;
    sequencer.step_counter += 1.0;
    if (sequencer.step_counter < samples_per_step) return null;
    sequencer.step_counter -= samples_per_step;
    const current_step = sequencer.step;
    sequencer.step = (sequencer.step + 1) % 16;
    return current_step;
}

pub fn tensionChance(base: f32, tension: f32) f32 {
    return base * (0.5 + tension * 0.5);
}

pub fn subdivisionChance(step: u8, onbeat: f32, offbeat: f32, tension: f32) f32 {
    if (step % 2 == 0) return onbeat;
    return tensionChance(offbeat, tension);
}

pub fn stepActive(mask: u16, step: u8) bool {
    return (mask & (@as(u16, 1) << @intCast(step))) != 0;
}

pub fn kickVelocity(step: u8, main_mask: u16, fill_mask: u16, fill_velocity: f32, rng: *dsp.Rng, fill_density: f32, tension: f32) ?f32 {
    if (stepActive(main_mask, step)) return 1.0;
    if (!stepActive(fill_mask, step)) return null;
    if (dsp.rngFloat(rng) >= tensionChance(fill_density, tension)) return null;
    return fill_velocity;
}

pub fn snareBackbeatOrGhost(step: u8, backbeat_mask: u16, rng: *dsp.Rng, ghost_chance: f32, tension: f32) enum { none, backbeat, ghost } {
    if (stepActive(backbeat_mask, step)) return .backbeat;
    if (ghost_chance <= 0 or dsp.rngFloat(rng) >= ghost_chance * tension) return .none;
    return .ghost;
}

pub fn leadStepChance(step: u8, density: f32, meso: f32, offbeat_scale: f32) f32 {
    if (step % 2 == 0) return tensionChance(density, meso);
    return density * offbeat_scale * meso;
}

pub const VoiceTimingSpec = struct {
    base_beats: f32,
    random_beats: f32 = 0.0,
};

pub fn voiceTimingSpecSample(timing: VoiceTimingSpec, rng: *dsp.Rng) f32 {
    return timing.base_beats + dsp.rngFloat(rng) * timing.random_beats;
}

pub fn StepStyleRunner(comptime CueSpecType: type, comptime LayerCount: usize) type {
    _ = CueSpecType;
    return struct {
        engine: CompositionEngine = .{},
        layer_targets: [LayerCount]f32 = .{0.0} ** LayerCount,
        layer_levels: [LayerCount]f32 = .{0.0} ** LayerCount,
        sequencer: StepSequencer16 = .{},
    };
}

pub fn stepStyleRunnerReset(
    comptime CueSpecType: type,
    comptime LayerCount: usize,
    runner: *StepStyleRunner(CueSpecType, LayerCount),
    style: *const StyleSpec(CueSpecType, LayerCount, 0),
    key_state: KeyState,
    harmony_state: ChordMarkov,
    chord_beats: f32,
    mode: ModulationMode,
    initial_targets: [LayerCount]f32,
    initial_levels: [LayerCount]f32,
) void {
    compositionEngineReset(&runner.engine, key_state, harmony_state, style.arcs, chord_beats, mode);
    runner.layer_targets = initial_targets;
    runner.layer_levels = initial_levels;
    stepSequencer16Reset(&runner.sequencer);
}

pub fn stepStyleRunnerAdvanceFrame(
    comptime CueSpecType: type,
    comptime LayerCount: usize,
    runner: *StepStyleRunner(CueSpecType, LayerCount),
    rng: *dsp.Rng,
    style: *const StyleSpec(CueSpecType, LayerCount, 0),
    bpm_val: f32,
    fade_rate: f32,
) StepStyleFrame {
    const tick = compositionEngineAdvanceSample(&runner.engine, rng, bpm_val);
    applyLayerCurves(LayerCount, &style.layer_curves, tick.macro, &runner.layer_targets);
    easeLevels(LayerCount, &runner.layer_levels, &runner.layer_targets, fade_rate);
    return .{
        .tick = tick,
        .step = stepSequencer16AdvanceSample(&runner.sequencer, bpm_val),
    };
}

const CHORD_HISTORY_SIZE: usize = 12;

const CompositionSectionState = struct {
    current: SectionId = .a,
    previous: ?SectionId = null,
    beat_counter: f32 = 0.0,
    section_beats: f32 = 72.0,
    transition_count: u32 = 0,
    distinct_transition_mask: u32 = 0,
    recent: [SECTION_HISTORY_SIZE]SectionId = .{.a} ** SECTION_HISTORY_SIZE,
    recent_count: u8 = 0,
    recent_pos: u8 = 0,
    density: f32 = 0.34,
    target_density: f32 = 0.34,
    harmonic_motion: f32 = 0.3,
    target_harmonic_motion: f32 = 0.3,
    cadence_scale: f32 = 0.9,
    target_cadence_scale: f32 = 0.9,
    bridge_active: bool = false,
    bridge_progress: f32 = 1.0,
    bridge_beats: f32 = 8.0,
    bridge_beat_counter: f32 = 0.0,
    bridge_from: SectionId = .a,
    bridge_to: SectionId = .a,
    bridge_source_density: f32 = 0.34,
    bridge_source_harmonic_motion: f32 = 0.3,
    bridge_source_cadence_scale: f32 = 0.9,
};

const LongFormDirector = struct {
    beat_counter: f32 = 0.0,
    section_beats: f32 = 384.0,
    intensity: f32 = 0.46,
    target_intensity: f32 = 0.46,
    cadence_spread: f32 = 0.16,
    target_cadence_spread: f32 = 0.16,
    modulation_drive: f32 = 0.52,
    target_modulation_drive: f32 = 0.52,
    primed: bool = false,
};

pub const CompositionEngine = struct {
    arcs: ArcSystem = .{},
    key: KeyState = .{},
    harmony: ChordMarkov = .{},
    director: LongFormDirector = .{},
    section: CompositionSectionState = .{},
    recent_chords: [CHORD_HISTORY_SIZE]u8 = .{0} ** CHORD_HISTORY_SIZE,
    recent_chord_count: u8 = 0,
    recent_chord_pos: u8 = 0,
    chord_beat_counter: f32 = 0.0,
    chord_change_base_beats: f32 = 16.0,
    chord_change_beats: f32 = 16.0,
    chord_change_target_beats: f32 = 16.0,
    next_chord_change_beats: f32 = 16.0,
    last_macro_quarter: u8 = 0,
    modulation_mode: ModulationMode = .mixed,
};

fn longFormDirectorReset(director: *LongFormDirector) void {
    director.beat_counter = 0.0;
    director.intensity = 0.46;
    director.target_intensity = 0.46;
    director.cadence_spread = 0.16;
    director.target_cadence_spread = 0.16;
    director.modulation_drive = 0.52;
    director.target_modulation_drive = 0.52;
    director.primed = false;
}

fn longFormDirectorPickTargets(director: *LongFormDirector, rng: *dsp.Rng) void {
    const intensity_step = (dsp.rngFloat(rng) * 2.0 - 1.0) * 0.24;
    const cadence_step = (dsp.rngFloat(rng) * 2.0 - 1.0) * 0.1;
    const modulation_step = (dsp.rngFloat(rng) * 2.0 - 1.0) * 0.16;

    var next_intensity = director.target_intensity + intensity_step;
    if (dsp.rngFloat(rng) < 0.18) {
        next_intensity += if (dsp.rngFloat(rng) < 0.5) -0.2 else 0.2;
    }
    director.target_intensity = std.math.clamp(next_intensity, 0.12, 0.96);
    director.target_cadence_spread = std.math.clamp(director.target_cadence_spread + cadence_step, 0.05, 0.42);
    director.target_modulation_drive = std.math.clamp(director.target_modulation_drive + modulation_step, 0.08, 0.94);
}

fn longFormDirectorAdvanceSample(director: *LongFormDirector, rng: *dsp.Rng, spb: f32) void {
    if (director.section_beats <= 0.0) {
        std.log.warn("longFormDirectorAdvanceSample: invalid section_beats={d}, using 384", .{director.section_beats});
        director.section_beats = 384.0;
    }

    if (!director.primed) {
        longFormDirectorPickTargets(director, rng);
        director.primed = true;
    }

    director.intensity += (director.target_intensity - director.intensity) * 0.00024;
    director.cadence_spread += (director.target_cadence_spread - director.cadence_spread) * 0.0002;
    director.modulation_drive += (director.target_modulation_drive - director.modulation_drive) * 0.00022;

    director.beat_counter += 1.0 / spb;
    if (director.beat_counter < director.section_beats) return;
    while (director.beat_counter >= director.section_beats) {
        director.beat_counter -= director.section_beats;
    }
    longFormDirectorPickTargets(director, rng);
}

fn compositionSectionStateReset(section: *CompositionSectionState) void {
    section.current = .a;
    section.previous = null;
    section.beat_counter = 0.0;
    section.section_beats = 72.0;
    section.transition_count = 0;
    section.distinct_transition_mask = 0;
    section.recent = .{.a} ** SECTION_HISTORY_SIZE;
    section.recent_count = 0;
    section.recent_pos = 0;
    compositionSectionStateRemember(section, section.current);

    const profile = SECTION_PROFILES[@intFromEnum(section.current)];
    section.density = profile.density_center;
    section.target_density = profile.density_center;
    section.harmonic_motion = profile.harmonic_center;
    section.target_harmonic_motion = profile.harmonic_center;
    section.cadence_scale = profile.cadence_scale_center;
    section.target_cadence_scale = profile.cadence_scale_center;
    section.bridge_active = false;
    section.bridge_progress = 1.0;
    section.bridge_beats = 8.0;
    section.bridge_beat_counter = 0.0;
    section.bridge_from = section.current;
    section.bridge_to = section.current;
    section.bridge_source_density = section.density;
    section.bridge_source_harmonic_motion = section.harmonic_motion;
    section.bridge_source_cadence_scale = section.cadence_scale;
}

fn compositionSectionStateProgress(section: *const CompositionSectionState) f32 {
    if (section.section_beats <= 0.0) return 0.0;
    return std.math.clamp(section.beat_counter / section.section_beats, 0.0, 1.0);
}

fn compositionSectionStateDistinctTransitionCount(section: *const CompositionSectionState) u8 {
    return @popCount(section.distinct_transition_mask);
}

fn compositionSectionStateRemember(section: *CompositionSectionState, section_id: SectionId) void {
    section.recent[section.recent_pos] = section_id;
    section.recent_pos = @intCast((@as(usize, section.recent_pos) + 1) % SECTION_HISTORY_SIZE);
    if (section.recent_count < SECTION_HISTORY_SIZE) section.recent_count += 1;
}

fn compositionSectionStateRecencyHits(section: *const CompositionSectionState, section_id: SectionId, depth: usize) u8 {
    if (depth == 0 or section.recent_count == 0) return 0;
    const sample_count: usize = @min(depth, section.recent_count);
    var hits: u8 = 0;
    for (0..sample_count) |offset| {
        const pos = (SECTION_HISTORY_SIZE + section.recent_pos - 1 - offset) % SECTION_HISTORY_SIZE;
        if (section.recent[pos] == section_id) hits += 1;
    }
    return hits;
}

fn compositionSectionStateSampleProfileValue(center: f32, spread: f32, min_val: f32, max_val: f32, rng: *dsp.Rng) f32 {
    const raw = center + (dsp.rngFloat(rng) * 2.0 - 1.0) * spread;
    return std.math.clamp(raw, min_val, max_val);
}

fn compositionSectionStateChooseSectionBeats(profile: SectionProfile, rng: *dsp.Rng) f32 {
    if (profile.max_beats <= profile.min_beats) {
        std.log.warn(
            "compositionSectionStateChooseSectionBeats: invalid range min={d} max={d}, using min",
            .{ profile.min_beats, profile.max_beats },
        );
        return @max(profile.min_beats, 1.0);
    }
    const width = profile.max_beats - profile.min_beats;
    return @max(profile.min_beats + dsp.rngFloat(rng) * width, 1.0);
}

fn compositionSectionStateChooseNext(section: *const CompositionSectionState, rng: *dsp.Rng) SectionId {
    const from_idx: usize = @intFromEnum(section.current);
    var weights = SECTION_TRANSITION_WEIGHTS[from_idx];

    for (0..SECTION_COUNT) |to_idx| {
        const candidate: SectionId = @enumFromInt(to_idx);
        if (candidate == section.current) {
            weights[to_idx] *= 0.03;
        }
        if (section.previous != null and candidate == section.previous.?) {
            weights[to_idx] *= 0.2;
        }

        const recency_hits = compositionSectionStateRecencyHits(section, candidate, 4);
        if (recency_hits >= 3) {
            weights[to_idx] *= 0.2;
        } else if (recency_hits == 2) {
            weights[to_idx] *= 0.45;
        } else if (recency_hits == 1) {
            weights[to_idx] *= 0.75;
        }
    }

    var total: f32 = 0.0;
    for (weights) |weight| total += weight;
    if (total <= 0.000001) {
        std.log.warn("compositionSectionStateChooseNext: transition weights collapsed, using fallback", .{});
        if (section.current != .b) return .b;
        return .a;
    }

    const r = dsp.rngFloat(rng) * total;
    var cumulative: f32 = 0.0;
    for (0..SECTION_COUNT) |to_idx| {
        cumulative += weights[to_idx];
        if (r < cumulative) return @enumFromInt(to_idx);
    }
    return @enumFromInt(SECTION_COUNT - 1);
}

fn compositionSectionStateApplyTargets(section: *CompositionSectionState, next: SectionId, rng: *dsp.Rng, director: *LongFormDirector) void {
    const profile = SECTION_PROFILES[@intFromEnum(next)];

    section.target_density = compositionSectionStateSampleProfileValue(profile.density_center, 0.08, 0.05, 0.98, rng);
    section.target_harmonic_motion = compositionSectionStateSampleProfileValue(profile.harmonic_center, 0.1, 0.02, 0.98, rng);
    section.target_cadence_scale = compositionSectionStateSampleProfileValue(profile.cadence_scale_center, 0.08, 0.55, 1.75, rng);

    director.target_intensity = compositionSectionStateSampleProfileValue(profile.intensity_center, 0.08, 0.1, 0.96, rng);
    director.target_cadence_spread = compositionSectionStateSampleProfileValue(profile.cadence_center, 0.05, 0.04, 0.45, rng);
    director.target_modulation_drive = compositionSectionStateSampleProfileValue(profile.modulation_center, 0.08, 0.06, 0.96, rng);

    section.section_beats = compositionSectionStateChooseSectionBeats(profile, rng);
}

fn compositionSectionStateChooseBridgeBeats(profile: SectionProfile, rng: *dsp.Rng) f32 {
    const min_beats = std.math.clamp(profile.min_beats * 0.08, 4.0, 18.0);
    const max_beats = std.math.clamp(profile.max_beats * 0.14, min_beats + 0.5, 26.0);
    if (max_beats <= min_beats) {
        std.log.warn(
            "compositionSectionStateChooseBridgeBeats: invalid bridge range min={d} max={d}, using min",
            .{ min_beats, max_beats },
        );
        return min_beats;
    }
    const span = max_beats - min_beats;
    const sampled = min_beats + dsp.rngFloat(rng) * span;
    if (!std.math.isFinite(sampled) or sampled <= 0.0) {
        std.log.warn(
            "compositionSectionStateChooseBridgeBeats: sampled invalid value {d}, using fallback 8",
            .{sampled},
        );
        return 8.0;
    }
    return sampled;
}

fn compositionSectionStateStartBridge(
    section: *CompositionSectionState,
    from: SectionId,
    to: SectionId,
    source_density: f32,
    source_harmonic_motion: f32,
    source_cadence_scale: f32,
    rng: *dsp.Rng,
) void {
    const profile = SECTION_PROFILES[@intFromEnum(to)];
    section.bridge_active = true;
    section.bridge_progress = 0.0;
    section.bridge_beat_counter = 0.0;
    section.bridge_beats = compositionSectionStateChooseBridgeBeats(profile, rng);
    section.bridge_from = from;
    section.bridge_to = to;
    section.bridge_source_density = source_density;
    section.bridge_source_harmonic_motion = source_harmonic_motion;
    section.bridge_source_cadence_scale = source_cadence_scale;
}

fn compositionSectionStateEnter(section: *CompositionSectionState, next: SectionId, rng: *dsp.Rng, director: *LongFormDirector) void {
    const source_density = section.density;
    const source_harmonic_motion = section.harmonic_motion;
    const source_cadence_scale = section.cadence_scale;
    const from = section.current;
    section.previous = from;
    section.current = next;
    section.transition_count +%= 1;
    compositionSectionStateRemember(section, next);

    const edge_bit_index: u5 = @intCast(@intFromEnum(from) * SECTION_COUNT + @intFromEnum(next));
    section.distinct_transition_mask |= (@as(u32, 1) << edge_bit_index);

    compositionSectionStateApplyTargets(section, next, rng, director);
    compositionSectionStateStartBridge(
        section,
        from,
        next,
        source_density,
        source_harmonic_motion,
        source_cadence_scale,
        rng,
    );
}

fn compositionSectionStateBridgeTarget(from: f32, to: f32, progress: f32) f32 {
    const t = std.math.clamp(progress, 0.0, 1.0);
    const smooth = t * t * (3.0 - 2.0 * t);
    return from + (to - from) * smooth;
}

fn compositionSectionStateSmoothTargets(section: *CompositionSectionState, spb: f32) void {
    if (section.bridge_active) {
        if (section.bridge_beats <= 0.0) {
            std.log.warn("compositionSectionStateSmoothTargets: invalid bridge_beats={d}, using fallback 8", .{section.bridge_beats});
            section.bridge_beats = 8.0;
        }
        section.bridge_beat_counter += 1.0 / spb;
        section.bridge_progress = std.math.clamp(section.bridge_beat_counter / section.bridge_beats, 0.0, 1.0);

        const bridge_density_target = compositionSectionStateBridgeTarget(section.bridge_source_density, section.target_density, section.bridge_progress);
        const bridge_harmonic_target = compositionSectionStateBridgeTarget(section.bridge_source_harmonic_motion, section.target_harmonic_motion, section.bridge_progress);
        const bridge_cadence_target = compositionSectionStateBridgeTarget(section.bridge_source_cadence_scale, section.target_cadence_scale, section.bridge_progress);

        section.density += (bridge_density_target - section.density) * 0.00052;
        section.harmonic_motion += (bridge_harmonic_target - section.harmonic_motion) * 0.00048;
        section.cadence_scale += (bridge_cadence_target - section.cadence_scale) * 0.00056;

        if (section.bridge_progress < 1.0) return;

        section.bridge_active = false;
        section.bridge_progress = 1.0;
        section.bridge_beat_counter = section.bridge_beats;
        section.bridge_from = section.current;
        section.bridge_to = section.current;
        return;
    }

    section.bridge_progress = 1.0;
    section.density += (section.target_density - section.density) * 0.0003;
    section.harmonic_motion += (section.target_harmonic_motion - section.harmonic_motion) * 0.00028;
    section.cadence_scale += (section.target_cadence_scale - section.cadence_scale) * 0.00032;
}

fn compositionSectionStateAdvanceSample(section: *CompositionSectionState, rng: *dsp.Rng, spb: f32, director: *LongFormDirector) void {
    if (spb <= 0.0) {
        std.log.warn("compositionSectionStateAdvanceSample: invalid spb={d}", .{spb});
        return;
    }

    if (section.section_beats <= 0.0) {
        std.log.warn("compositionSectionStateAdvanceSample: invalid section_beats={d}, restoring default", .{section.section_beats});
        section.section_beats = 72.0;
    }

    compositionSectionStateSmoothTargets(section, spb);
    section.beat_counter += 1.0 / spb;
    if (section.beat_counter < section.section_beats) return;

    while (section.beat_counter >= section.section_beats) {
        section.beat_counter -= section.section_beats;
    }

    const next = compositionSectionStateChooseNext(section, rng);
    compositionSectionStateEnter(section, next, rng, director);
}

pub fn compositionEngineSetChordChangeBeats(engine: *CompositionEngine, beats: f32) void {
    if (beats <= 0.0) {
        std.log.warn("compositionEngineSetChordChangeBeats: invalid beats {d}, clamping to 1.0", .{beats});
        engine.chord_change_base_beats = 1.0;
        compositionEngineUpdateChordCadenceTarget(engine);
        return;
    }
    engine.chord_change_base_beats = beats;
    compositionEngineUpdateChordCadenceTarget(engine);
}

pub fn compositionEngineLongFormIntensity(engine: *const CompositionEngine) f32 {
    return engine.director.intensity;
}

pub fn compositionEngineLongFormCadenceSpread(engine: *const CompositionEngine) f32 {
    return engine.director.cadence_spread;
}

pub fn compositionEngineLongFormModulationDrive(engine: *const CompositionEngine) f32 {
    return engine.director.modulation_drive;
}

pub fn compositionEngineSectionId(engine: *const CompositionEngine) u8 {
    return @intFromEnum(engine.section.current);
}

pub fn compositionEngineSectionProgress(engine: *const CompositionEngine) f32 {
    return compositionSectionStateProgress(&engine.section);
}

pub fn compositionEngineSectionTransitionCount(engine: *const CompositionEngine) u32 {
    return engine.section.transition_count;
}

pub fn compositionEngineSectionDistinctTransitionCount(engine: *const CompositionEngine) u8 {
    return compositionSectionStateDistinctTransitionCount(&engine.section);
}

pub fn compositionEngineSectionDensity(engine: *const CompositionEngine) f32 {
    return engine.section.density;
}

pub fn compositionEngineSectionHarmonicMotion(engine: *const CompositionEngine) f32 {
    return engine.section.harmonic_motion;
}

pub fn compositionEngineSectionCadenceScale(engine: *const CompositionEngine) f32 {
    return engine.section.cadence_scale;
}

pub fn compositionEngineSectionBridgeActive(engine: *const CompositionEngine) bool {
    return engine.section.bridge_active;
}

pub fn compositionEngineSectionBridgeProgress(engine: *const CompositionEngine) f32 {
    return engine.section.bridge_progress;
}

pub fn compositionEngineSectionBridgeFromId(engine: *const CompositionEngine) u8 {
    return @intFromEnum(engine.section.bridge_from);
}

pub fn compositionEngineSectionBridgeToId(engine: *const CompositionEngine) u8 {
    return @intFromEnum(engine.section.bridge_to);
}

pub fn compositionEngineReset(engine: *CompositionEngine, key_state: KeyState, harmony_state: ChordMarkov, arc_state: ArcSystem, chord_beats: f32, mode: ModulationMode) void {
    engine.key = key_state;
    engine.harmony = harmony_state;
    engine.arcs = arc_state;
    engine.chord_beat_counter = 0.0;
    const clamped_beats = @max(chord_beats, 1.0);
    engine.chord_change_base_beats = clamped_beats;
    engine.chord_change_beats = clamped_beats;
    engine.next_chord_change_beats = clamped_beats;
    engine.last_macro_quarter = 0;
    engine.modulation_mode = mode;
    longFormDirectorReset(&engine.director);
    compositionSectionStateReset(&engine.section);
    engine.director.intensity = SECTION_PROFILES[@intFromEnum(engine.section.current)].intensity_center;
    engine.director.target_intensity = engine.director.intensity;
    engine.director.cadence_spread = SECTION_PROFILES[@intFromEnum(engine.section.current)].cadence_center;
    engine.director.target_cadence_spread = engine.director.cadence_spread;
    engine.director.modulation_drive = SECTION_PROFILES[@intFromEnum(engine.section.current)].modulation_center;
    engine.director.target_modulation_drive = engine.director.modulation_drive;
    compositionEngineUpdateChordCadenceTarget(engine);
    compositionEngineClearRecentChordHistory(engine);
    if (engine.harmony.num_chords == 0) {
        std.log.warn("compositionEngineReset: harmony has no chords; novelty history disabled", .{});
        return;
    }
    compositionEngineRememberChord(engine, engine.harmony.current);
}

pub fn compositionEngineAdvanceSample(engine: *CompositionEngine, rng: *dsp.Rng, bpm_val: f32) CompositionTick {
    arcSystemAdvanceSample(&engine.arcs, bpm_val);
    keyStateAdvanceSample(&engine.key);

    const micro_t = arcControllerTension(&engine.arcs.micro);
    const meso_t = arcControllerTension(&engine.arcs.meso);
    const macro_t = arcControllerTension(&engine.arcs.macro);

    const spb = dsp.samplesPerBeat(bpm_val);
    if (spb <= 0.0) {
        std.log.warn("compositionEngineAdvanceSample: invalid samples-per-beat for bpm={d}, using fallback tick", .{bpm_val});
        return .{
            .micro = micro_t,
            .meso = meso_t,
            .macro = macro_t,
            .chord_changed = false,
        };
    }

    compositionSectionStateAdvanceSample(&engine.section, rng, spb, &engine.director);
    compositionEngineUpdateChordCadenceTarget(engine);
    longFormDirectorAdvanceSample(&engine.director, rng, spb);
    compositionEngineAdvanceChordCadenceMorph(engine, spb);
    engine.chord_beat_counter += 1.0 / spb;
    var chord_changed = false;
    if (engine.next_chord_change_beats <= 0.0) {
        std.log.warn("compositionEngineAdvanceSample: next_chord_change_beats <= 0 ({d}), resetting cadence", .{engine.next_chord_change_beats});
        engine.next_chord_change_beats = @max(engine.chord_change_beats, 1.0);
    }
    if (engine.chord_beat_counter >= engine.next_chord_change_beats) {
        engine.chord_beat_counter -= engine.next_chord_change_beats;
        chord_changed = compositionEngineAdvanceHarmonyWithNovelty(engine, rng, meso_t, macro_t);
        engine.next_chord_change_beats = compositionEngineSampleNextChordChangeBeats(engine, rng, meso_t, macro_t, engine.director.cadence_spread, engine.director.intensity);
        compositionEngineNudgeHarmonyTransitions(engine, rng, macro_t, engine.director.intensity);
    }

    const macro_quarter: u8 = @intFromFloat(engine.arcs.macro.beat_count / engine.arcs.macro.section_beats * 4.0);
    if (macro_quarter != engine.last_macro_quarter) {
        engine.last_macro_quarter = macro_quarter;
        if (macro_quarter == 0) {
            const modulation_gate = std.math.clamp(0.25 + engine.director.modulation_drive * 0.55 + macro_t * 0.15, 0.0, 1.0);
            if (dsp.rngFloat(rng) >= modulation_gate) {
                return .{
                    .micro = micro_t,
                    .meso = meso_t,
                    .macro = macro_t,
                    .chord_changed = chord_changed,
                };
            }
            switch (engine.modulation_mode) {
                .none => {},
                .fourth => keyStateModulateByFourth(&engine.key),
                .fifth => keyStateModulateByFifth(&engine.key),
                .mixed => {
                    const prefer_fourth = 0.5 + (engine.director.intensity - 0.5) * 0.25;
                    if (dsp.rngFloat(rng) < prefer_fourth) {
                        keyStateModulateByFourth(&engine.key);
                    } else {
                        keyStateModulateByFifth(&engine.key);
                    }
                },
            }
        }
    }

    return .{
        .micro = micro_t,
        .meso = meso_t,
        .macro = macro_t,
        .chord_changed = chord_changed,
    };
}

fn compositionEngineAdvanceChordCadenceMorph(engine: *CompositionEngine, spb: f32) void {
    const delta = engine.chord_change_target_beats - engine.chord_change_beats;
    if (@abs(delta) < 0.0001) {
        engine.chord_change_beats = engine.chord_change_target_beats;
        return;
    }
    const samples_per_morph = spb * 16.0;
    if (samples_per_morph <= 1.0) {
        std.log.warn("compositionEngineAdvanceChordCadenceMorph: invalid morph window spb={d}", .{spb});
        engine.chord_change_beats = engine.chord_change_target_beats;
        return;
    }
    const rate = 1.0 / samples_per_morph;
    engine.chord_change_beats += delta * rate;
}

fn compositionEngineUpdateChordCadenceTarget(engine: *CompositionEngine) void {
    const scaled = engine.chord_change_base_beats * engine.section.cadence_scale;
    if (scaled <= 0.0) {
        std.log.warn(
            "compositionEngineUpdateChordCadenceTarget: invalid cadence target base={d} scale={d}",
            .{ engine.chord_change_base_beats, engine.section.cadence_scale },
        );
        engine.chord_change_target_beats = 1.0;
        return;
    }
    engine.chord_change_target_beats = @max(scaled, 1.0);
}

fn compositionEngineSampleNextChordChangeBeats(engine: *CompositionEngine, rng: *dsp.Rng, meso_t: f32, macro_t: f32, cadence_spread: f32, director_intensity: f32) f32 {
    const base = @max(engine.chord_change_beats, 1.0);
    const spread = std.math.clamp(0.06 + macro_t * 0.14 + meso_t * 0.08 + cadence_spread * 0.55 + director_intensity * 0.1, 0.04, 0.62);
    const direction_bias = (director_intensity - 0.5) * 0.12;
    const ratio = 1.0 + (dsp.rngFloat(rng) * 2.0 - 1.0) * spread + direction_bias;
    const min_ratio = std.math.clamp(0.55 - cadence_spread * 0.32, 0.32, 0.75);
    const max_ratio = std.math.clamp(1.6 + cadence_spread * 0.9, 1.2, 2.2);
    return std.math.clamp(base * ratio, base * min_ratio, base * max_ratio);
}

fn compositionEngineNudgeHarmonyTransitions(engine: *CompositionEngine, rng: *dsp.Rng, macro_t: f32, director_intensity: f32) void {
    if (engine.harmony.num_chords < 2) return;
    if (dsp.rngFloat(rng) > 0.08 + macro_t * 0.14 + director_intensity * 0.12 + engine.section.harmonic_motion * 0.22) return;

    const row_idx: usize = engine.harmony.current;
    const chord_count: usize = @intCast(engine.harmony.num_chords);
    if (row_idx >= chord_count) {
        std.log.warn("compositionEngineNudgeHarmonyTransitions: row idx {d} out of range {d}", .{ row_idx, chord_count });
        return;
    }

    var row = &engine.harmony.transitions[row_idx];
    const target: usize = @intCast(dsp.rngNext(rng) % @as(u32, @intCast(chord_count)));
    const delta = 0.02 + dsp.rngFloat(rng) * (0.04 + director_intensity * 0.05 + engine.section.harmonic_motion * 0.04);
    row[target] += delta;
    row[row_idx] = @max(0.005, row[row_idx] - delta * 0.45);

    var sum: f32 = 0.0;
    for (0..chord_count) |i| {
        sum += row[i];
    }
    if (sum <= 0.00001) {
        std.log.warn("compositionEngineNudgeHarmonyTransitions: transition sum collapsed, restoring uniform row", .{});
        const uniform = 1.0 / @as(f32, @floatFromInt(chord_count));
        for (0..chord_count) |i| {
            row[i] = uniform;
        }
        return;
    }
    for (0..chord_count) |i| {
        row[i] /= sum;
    }
}

fn compositionEngineAdvanceHarmonyWithNovelty(engine: *CompositionEngine, rng: *dsp.Rng, meso_t: f32, macro_t: f32) bool {
    if (engine.harmony.num_chords == 0) {
        std.log.warn("compositionEngineAdvanceHarmonyWithNovelty: no chords available", .{});
        return false;
    }
    if (engine.harmony.num_chords == 1) {
        compositionEngineRememberChord(engine, engine.harmony.current);
        return true;
    }

    const attempt_count: usize = if (engine.section.harmonic_motion > 0.62)
        (if (engine.harmony.num_chords <= 3) 4 else 6)
    else
        (if (engine.harmony.num_chords <= 3) 3 else 5);
    var best: ChordMarkov = engine.harmony;
    var best_score: f32 = 9_999.0;

    for (0..attempt_count) |_| {
        var trial = engine.harmony;
        _ = chordMarkovNextChord(&trial, rng);
        const score = compositionEngineChordNoveltyScore(engine, trial.current, meso_t, macro_t);
        if (score >= best_score) continue;
        best = trial;
        best_score = score;
        if (best_score <= 0.0) break;
    }

    engine.harmony = best;
    compositionEngineRememberChord(engine, engine.harmony.current);
    return true;
}

fn compositionEngineChordNoveltyScore(engine: *const CompositionEngine, chord_idx: u8, meso_t: f32, macro_t: f32) f32 {
    if (engine.recent_chord_count == 0) return 0.0;

    var matches: u8 = 0;
    var recency_weight: f32 = 0.0;
    const count: usize = engine.recent_chord_count;

    for (0..count) |offset| {
        const hist_pos = (CHORD_HISTORY_SIZE + engine.recent_chord_pos - 1 - offset) % CHORD_HISTORY_SIZE;
        if (engine.recent_chords[hist_pos] != chord_idx) continue;
        matches += 1;
        const w = 1.0 - @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(count));
        recency_weight += w;
    }

    var score = @as(f32, @floatFromInt(matches)) * 0.65 + recency_weight * 0.9;
    const last_pos = (CHORD_HISTORY_SIZE + engine.recent_chord_pos - 1) % CHORD_HISTORY_SIZE;
    if (engine.recent_chords[last_pos] == chord_idx) {
        score += 1.1 + macro_t * 0.45;
    }
    score -= meso_t * 0.22;
    score -= engine.director.cadence_spread * 0.35;
    return score;
}

fn compositionEngineClearRecentChordHistory(engine: *CompositionEngine) void {
    engine.recent_chords = .{0} ** CHORD_HISTORY_SIZE;
    engine.recent_chord_count = 0;
    engine.recent_chord_pos = 0;
}

fn compositionEngineRememberChord(engine: *CompositionEngine, chord_idx: u8) void {
    engine.recent_chords[engine.recent_chord_pos] = chord_idx;
    engine.recent_chord_pos = @intCast((@as(usize, engine.recent_chord_pos) + 1) % CHORD_HISTORY_SIZE);
    if (engine.recent_chord_count < CHORD_HISTORY_SIZE) {
        engine.recent_chord_count += 1;
    }
}

pub const PhraseGenerator = struct {
    pub const MAX_LEN = 8;
    const REST: u8 = 0xFF;

    notes: [MAX_LEN]u8 = .{0} ** MAX_LEN,
    len: u8 = 0,
    pos: u8 = 0,
    anchor: u8 = 10,
    region_low: u8 = 5,
    region_high: u8 = 17,
    rest_chance: f32 = 0.3,
    min_notes: u8 = 3,
    max_notes: u8 = 7,
    chord_tones: [4]u8 = .{0} ** 4,
    chord_tone_count: u8 = 0,
    gravity: f32 = 2.0,
};

pub fn phraseGeneratorBuild(phrase: *PhraseGenerator, rng: *dsp.Rng) void {
    const clamped_min = @min(phrase.min_notes, PhraseGenerator.MAX_LEN);
    const clamped_max = @min(phrase.max_notes, PhraseGenerator.MAX_LEN);
    if (clamped_min > clamped_max) {
        std.log.warn("phraseGeneratorBuild: invalid phrase note range min={d} max={d}, using {d}", .{ phrase.min_notes, phrase.max_notes, PhraseGenerator.MAX_LEN });
        phrase.len = PhraseGenerator.MAX_LEN;
        phrase.pos = 0;
        return phraseGeneratorFill(phrase, rng);
    }
    if (phrase.max_notes > PhraseGenerator.MAX_LEN or phrase.min_notes > PhraseGenerator.MAX_LEN) {
        std.log.warn("phraseGeneratorBuild: clamping phrase note range min={d} max={d} to max len {d}", .{ phrase.min_notes, phrase.max_notes, PhraseGenerator.MAX_LEN });
    }
    const range = @as(u32, clamped_max - clamped_min) + 1;
    phrase.len = clamped_min + @as(u8, @intCast(dsp.rngNext(rng) % range));
    phrase.pos = 0;
    phraseGeneratorFill(phrase, rng);
}

fn phraseGeneratorFill(phrase: *PhraseGenerator, rng: *dsp.Rng) void {
    var current = phrase.anchor;
    const direction = dsp.rngNext(rng) % 3;
    for (0..phrase.len) |i| {
        const progress: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(phrase.len, 1)));
        const up_bias: f32 = switch (direction) {
            0 => 0.65,
            1 => 0.35,
            else => if (progress < 0.5) 0.7 else 0.3,
        };
        if (dsp.rngFloat(rng) < phrase.rest_chance and i > 0) {
            phrase.notes[i] = PhraseGenerator.REST;
        } else {
            current = phraseGeneratorSelectNote(phrase, rng, current, up_bias);
            phrase.notes[i] = current;
        }
    }
    if (current != PhraseGenerator.REST) phrase.anchor = current;
}

pub fn phraseGeneratorAdvance(phrase: *PhraseGenerator, rng: *dsp.Rng) ?u8 {
    if (phrase.pos >= phrase.len) {
        phraseGeneratorBuild(phrase, rng);
    }
    const idx = phrase.pos;
    phrase.pos += 1;
    const note = phrase.notes[idx];
    if (note == PhraseGenerator.REST) return null;
    return note;
}

pub fn phraseGeneratorSetChordTones(phrase: *PhraseGenerator, tones: []const u8) void {
    phrase.chord_tone_count = @intCast(@min(tones.len, 4));
    for (0..phrase.chord_tone_count) |i| {
        phrase.chord_tones[i] = tones[i];
    }
}

fn phraseGeneratorSelectNote(phrase: *const PhraseGenerator, rng_ptr: *dsp.Rng, current: u8, up_bias: f32) u8 {
    const candidate = phraseGeneratorBiasedScaleStep(rng_ptr, current, phrase.region_low, phrase.region_high, up_bias);
    if (phrase.chord_tone_count == 0) return candidate;
    if (phraseGeneratorIsChordTone(candidate, &phrase.chord_tones, phrase.chord_tone_count)) return candidate;
    if (dsp.rngFloat(rng_ptr) < phrase.gravity / (phrase.gravity + 1.0)) {
        return phraseGeneratorNearestChordTone(candidate, &phrase.chord_tones, phrase.chord_tone_count, phrase.region_low, phrase.region_high);
    }
    return candidate;
}

fn phraseGeneratorBiasedScaleStep(rng_ptr: *dsp.Rng, current: u8, low: u8, high: u8, up_bias: f32) u8 {
    const r = dsp.rngFloat(rng_ptr);
    var delta: i8 = 0;
    if (r < 0.6) {
        delta = if (dsp.rngFloat(rng_ptr) < up_bias) @as(i8, 1) else @as(i8, -1);
    } else if (r < 0.85) {
        delta = if (dsp.rngFloat(rng_ptr) < up_bias) @as(i8, 2) else @as(i8, -2);
    } else if (r < 0.95) {
        delta = if (dsp.rngFloat(rng_ptr) < up_bias) @as(i8, 3) else @as(i8, -3);
    }
    const new_raw: i16 = @as(i16, current) + delta;
    return @intCast(std.math.clamp(new_raw, @as(i16, low), @as(i16, high)));
}

fn phraseGeneratorIsChordTone(degree: u8, tones: *const [4]u8, count: u8) bool {
    for (0..count) |i| {
        if (degree == tones[i]) return true;
    }
    return false;
}

fn phraseGeneratorNearestChordTone(target: u8, tones: *const [4]u8, count: u8, low: u8, high: u8) u8 {
    var best: u8 = target;
    var best_dist: u8 = 255;
    for (0..count) |i| {
        const ct = tones[i];
        if (ct < low or ct > high) continue;
        const dist = if (ct > target) ct - target else target - ct;
        if (dist < best_dist) {
            best_dist = dist;
            best = ct;
        }
    }
    return best;
}

pub const PhraseMemory = struct {
    const SIZE = 6;
    const PLEN = PhraseGenerator.MAX_LEN;
    const REST = PhraseGenerator.REST;

    phrases: [SIZE][PLEN]u8 = .{.{0} ** PLEN} ** SIZE,
    lengths: [SIZE]u8 = .{0} ** SIZE,
    count: u8 = 0,
    write_pos: u8 = 0,
    recent_recall_signatures: [SIZE]u64 = .{0} ** SIZE,
    recent_recall_count: u8 = 0,
    recent_recall_pos: u8 = 0,
    novelty_debt: f32 = 0.0,
};

pub const PhraseRecallKind = enum {
    none,
    exact,
    transformed,
};

pub const PhraseVariationSnapshot = struct {
    total_picks: u32,
    recall_total: u32,
    recall_exact: u32,
    recall_transformed: u32,
    cooldown_violations: u32,
    transformed_ratio: f32,
    exact_ratio: f32,
    novelty_debt_avg: f32,
    novelty_debt_peak: f32,
};

const PhraseVariationStats = struct {
    total_picks: u32 = 0,
    recall_total: u32 = 0,
    recall_exact: u32 = 0,
    recall_transformed: u32 = 0,
    cooldown_violations: u32 = 0,
    novelty_debt_accum: f64 = 0.0,
    novelty_debt_samples: u32 = 0,
    novelty_debt_peak: f32 = 0.0,
};

const PHRASE_SIGNATURE_SEED: u64 = 0xcbf2_9ce4_8422_2325;
const PHRASE_SIGNATURE_PRIME: u64 = 0x1000_0000_01b3;
const PHRASE_COOLDOWN_WINDOW: u8 = 3;
const PHRASE_BASE_TRANSFORM_CHANCE: f32 = 0.72;
const PHRASE_DEBT_TRANSFORM_GAIN: f32 = 0.28;
const PHRASE_DEBT_EXACT_INCREMENT: f32 = 0.2;
const PHRASE_DEBT_COOLDOWN_PENALTY: f32 = 0.28;
const PHRASE_DEBT_TRANSFORM_DECAY: f32 = 0.16;
const PHRASE_DEBT_FRESH_DECAY: f32 = 0.08;
const PHRASE_DEBT_REST_DECAY: f32 = 0.04;

var phrase_variation_stats: PhraseVariationStats = .{};

pub fn phraseVariationStatsReset() void {
    phrase_variation_stats = .{};
}

pub fn phraseVariationStatsSnapshot() PhraseVariationSnapshot {
    const recall_total_f = @as(f32, @floatFromInt(phrase_variation_stats.recall_total));
    const transformed_ratio = if (phrase_variation_stats.recall_total == 0)
        0.0
    else
        @as(f32, @floatFromInt(phrase_variation_stats.recall_transformed)) / recall_total_f;
    const exact_ratio = if (phrase_variation_stats.recall_total == 0)
        0.0
    else
        @as(f32, @floatFromInt(phrase_variation_stats.recall_exact)) / recall_total_f;
    const novelty_debt_avg = if (phrase_variation_stats.novelty_debt_samples == 0)
        0.0
    else
        @as(f32, @floatCast(phrase_variation_stats.novelty_debt_accum / @as(f64, @floatFromInt(phrase_variation_stats.novelty_debt_samples))));
    return .{
        .total_picks = phrase_variation_stats.total_picks,
        .recall_total = phrase_variation_stats.recall_total,
        .recall_exact = phrase_variation_stats.recall_exact,
        .recall_transformed = phrase_variation_stats.recall_transformed,
        .cooldown_violations = phrase_variation_stats.cooldown_violations,
        .transformed_ratio = transformed_ratio,
        .exact_ratio = exact_ratio,
        .novelty_debt_avg = novelty_debt_avg,
        .novelty_debt_peak = phrase_variation_stats.novelty_debt_peak,
    };
}

fn phraseVariationStatsRememberDebt(debt: f32) void {
    phrase_variation_stats.novelty_debt_accum += debt;
    phrase_variation_stats.novelty_debt_samples +%= 1;
    if (debt > phrase_variation_stats.novelty_debt_peak) {
        phrase_variation_stats.novelty_debt_peak = debt;
    }
}

fn phraseVariationStatsRememberPick(pick: PhraseNotePick, memory: *const PhraseMemory, cooldown_violation: bool) void {
    phrase_variation_stats.total_picks +%= 1;
    if (!pick.recalled) {
        phraseVariationStatsRememberDebt(memory.novelty_debt);
        return;
    }
    phrase_variation_stats.recall_total +%= 1;
    if (pick.recall_kind == .exact) {
        phrase_variation_stats.recall_exact +%= 1;
    } else if (pick.recall_kind == .transformed) {
        phrase_variation_stats.recall_transformed +%= 1;
    } else {
        std.log.warn("phraseVariationStatsRememberPick: recalled pick missing recall_kind", .{});
        phrase_variation_stats.recall_exact +%= 1;
    }
    if (cooldown_violation) phrase_variation_stats.cooldown_violations +%= 1;
    phraseVariationStatsRememberDebt(memory.novelty_debt);
}

fn phraseSignature(notes: *const [PhraseGenerator.MAX_LEN]u8, len: u8) u64 {
    var sig = PHRASE_SIGNATURE_SEED;
    sig = (sig ^ len) *% PHRASE_SIGNATURE_PRIME;
    for (0..len) |i| {
        sig = (sig ^ notes[i]) *% PHRASE_SIGNATURE_PRIME;
    }
    return sig;
}

fn phraseMemoryRememberRecallSignature(memory: *PhraseMemory, signature: u64) void {
    memory.recent_recall_signatures[memory.recent_recall_pos] = signature;
    memory.recent_recall_pos = (memory.recent_recall_pos + 1) % PhraseMemory.SIZE;
    if (memory.recent_recall_count < PhraseMemory.SIZE) memory.recent_recall_count += 1;
}

fn phraseMemorySignatureSeenRecently(memory: *const PhraseMemory, signature: u64, depth: u8) bool {
    const capped_depth = @min(depth, memory.recent_recall_count);
    if (capped_depth == 0) return false;
    var offset: u8 = 0;
    while (offset < capped_depth) : (offset += 1) {
        const pos = (PhraseMemory.SIZE + memory.recent_recall_pos - 1 - offset) % PhraseMemory.SIZE;
        if (memory.recent_recall_signatures[pos] == signature) return true;
    }
    return false;
}

fn phraseMemoryCopyExact(src: *const [PhraseMemory.PLEN]u8, len: u8, out: *[PhraseMemory.PLEN]u8) void {
    for (0..len) |i| {
        out[i] = src[i];
    }
}

fn phraseMemoryApplyVariation(rng: *dsp.Rng, src: *const [PhraseMemory.PLEN]u8, len: u8, out: *[PhraseMemory.PLEN]u8, region_low: u8, region_high: u8) u8 {
    const transform = dsp.rngNext(rng) % 5;
    switch (transform) {
        0 => {
            const shift: i8 = switch (dsp.rngNext(rng) % 6) {
                0 => 1,
                1 => -1,
                2 => 2,
                3 => -2,
                4 => 3,
                else => -3,
            };
            for (0..len) |i| {
                if (src[i] == PhraseMemory.REST) {
                    out[i] = PhraseMemory.REST;
                    continue;
                }
                const raw: i16 = @as(i16, src[i]) + shift;
                out[i] = @intCast(std.math.clamp(raw, @as(i16, region_low), @as(i16, region_high)));
            }
            return len;
        },
        1 => {
            for (0..len) |i| {
                out[i] = src[len - 1 - i];
            }
            return len;
        },
        2 => {
            var out_len: u8 = 0;
            for (0..len) |i| {
                if (out_len >= PhraseMemory.PLEN) break;
                out[out_len] = src[i];
                out_len += 1;
                if (out_len >= PhraseMemory.PLEN) continue;
                if (src[i] == PhraseMemory.REST) continue;
                if (dsp.rngFloat(rng) >= 0.5) continue;
                out[out_len] = PhraseMemory.REST;
                out_len += 1;
            }
            return out_len;
        },
        3 => {
            var out_len: u8 = 0;
            for (0..len) |i| {
                if (out_len >= PhraseMemory.PLEN) break;
                out[out_len] = src[i];
                out_len += 1;
                if (i + 1 >= len or out_len >= PhraseMemory.PLEN) continue;
                if (src[i] == PhraseMemory.REST or src[i + 1] == PhraseMemory.REST) continue;
                const a: i16 = src[i];
                const b: i16 = src[i + 1];
                if (@abs(b - a) != 2) continue;
                out[out_len] = @intCast(std.math.clamp(@divTrunc(a + b, 2), @as(i16, region_low), @as(i16, region_high)));
                out_len += 1;
            }
            return out_len;
        },
        else => {
            var has_pivot = false;
            var pivot: i16 = 0;
            for (0..len) |i| {
                if (src[i] == PhraseMemory.REST) continue;
                has_pivot = true;
                pivot = src[i];
                break;
            }
            if (!has_pivot) {
                phraseMemoryCopyExact(src, len, out);
                return len;
            }
            for (0..len) |i| {
                if (src[i] == PhraseMemory.REST) {
                    out[i] = PhraseMemory.REST;
                    continue;
                }
                const raw = pivot - (@as(i16, src[i]) - pivot);
                out[i] = @intCast(std.math.clamp(raw, @as(i16, region_low), @as(i16, region_high)));
            }
            return len;
        },
    }
}

pub fn phraseMemoryStore(memory: *PhraseMemory, notes: *const [PhraseGenerator.MAX_LEN]u8, len: u8) void {
    memory.phrases[memory.write_pos] = notes.*;
    memory.lengths[memory.write_pos] = len;
    memory.write_pos = (memory.write_pos + 1) % PhraseMemory.SIZE;
    if (memory.count < PhraseMemory.SIZE) memory.count += 1;
}

pub fn phraseMemoryRecallVaried(memory: *const PhraseMemory, rng: *dsp.Rng, out: *[PhraseGenerator.MAX_LEN]u8, region_low: u8, region_high: u8) ?u8 {
    if (memory.count == 0) return null;
    const idx = @as(u8, @intCast(dsp.rngNext(rng) % memory.count));
    const src = &memory.phrases[idx];
    const len = memory.lengths[idx];
    if (len == 0) return null;
    return phraseMemoryApplyVariation(rng, src, len, out, region_low, region_high);
}

const PhraseRecallOutcome = struct {
    len: u8,
    transformed: bool,
    cooldown_violation: bool,
};

fn phraseMemoryRecallWithPolicy(memory: *PhraseMemory, rng: *dsp.Rng, out: *[PhraseGenerator.MAX_LEN]u8, region_low: u8, region_high: u8) ?PhraseRecallOutcome {
    if (memory.count == 0) return null;
    const idx = @as(u8, @intCast(dsp.rngNext(rng) % memory.count));
    const src = &memory.phrases[idx];
    const len = memory.lengths[idx];
    if (len == 0) {
        std.log.warn("phraseMemoryRecallWithPolicy: selected empty phrase idx={d} count={d}", .{ idx, memory.count });
        return null;
    }

    const signature = phraseSignature(src, len);
    const in_cooldown = phraseMemorySignatureSeenRecently(memory, signature, PHRASE_COOLDOWN_WINDOW);
    const transform_bias = std.math.clamp(PHRASE_BASE_TRANSFORM_CHANCE + memory.novelty_debt * PHRASE_DEBT_TRANSFORM_GAIN, 0.0, 1.0);
    const transformed = in_cooldown or dsp.rngFloat(rng) < transform_bias;

    var out_len: u8 = len;
    if (transformed) {
        out_len = phraseMemoryApplyVariation(rng, src, len, out, region_low, region_high);
    } else {
        phraseMemoryCopyExact(src, len, out);
    }
    if (out_len == 0) {
        std.log.warn("phraseMemoryRecallWithPolicy: variation collapsed to zero length idx={d}", .{idx});
        return null;
    }

    var cooldown_violation = false;
    if (!transformed and in_cooldown) cooldown_violation = true;

    if (transformed) {
        memory.novelty_debt = std.math.clamp(memory.novelty_debt - PHRASE_DEBT_TRANSFORM_DECAY, 0.0, 1.0);
    } else {
        memory.novelty_debt = std.math.clamp(memory.novelty_debt + PHRASE_DEBT_EXACT_INCREMENT, 0.0, 1.0);
        if (cooldown_violation) {
            memory.novelty_debt = std.math.clamp(memory.novelty_debt + PHRASE_DEBT_COOLDOWN_PENALTY, 0.0, 1.0);
        }
    }
    phraseMemoryRememberRecallSignature(memory, signature);

    return .{
        .len = out_len,
        .transformed = transformed,
        .cooldown_violation = cooldown_violation,
    };
}

pub const PhraseNotePick = struct {
    note: u8,
    recalled: bool,
    recall_kind: PhraseRecallKind = .none,
};

pub const PhraseConfig = struct {
    rest_chance: f32,
    region_low: u8,
    region_high: u8,
};

pub fn applyPhraseConfig(spec: PhraseConfig, phrase: *PhraseGenerator) void {
    phrase.rest_chance = spec.rest_chance;
    phrase.region_low = spec.region_low;
    phrase.region_high = spec.region_high;
}

pub fn nextPhraseNoteWithMemory(rng: *dsp.Rng, phrase: *PhraseGenerator, memory: *PhraseMemory, recall_chance: f32) ?PhraseNotePick {
    if (memory.count > 0 and dsp.rngFloat(rng) < recall_chance) {
        var recalled_notes: [PhraseGenerator.MAX_LEN]u8 = undefined;
        const recalled = phraseMemoryRecallWithPolicy(memory, rng, &recalled_notes, phrase.region_low, phrase.region_high) orelse return nextPhraseNote(rng, phrase, memory);
        if (recalled.len == 0) {
            std.log.warn("nextPhraseNoteWithMemory: recalled zero-length phrase", .{});
            return nextPhraseNote(rng, phrase, memory);
        }

        var note = recalled_notes[0];
        if (note == PhraseGenerator.REST) {
            var found = false;
            var i: u8 = 1;
            while (i < recalled.len) : (i += 1) {
                if (recalled_notes[i] == PhraseGenerator.REST) continue;
                note = recalled_notes[i];
                found = true;
                break;
            }
            if (!found) return nextPhraseNote(rng, phrase, memory);
        }

        const pick: PhraseNotePick = .{
            .note = note,
            .recalled = true,
            .recall_kind = if (recalled.transformed) .transformed else .exact,
        };
        phraseVariationStatsRememberPick(pick, memory, recalled.cooldown_violation);
        return pick;
    }
    return nextPhraseNote(rng, phrase, memory);
}

fn nextPhraseNote(rng: *dsp.Rng, phrase: *PhraseGenerator, memory: *PhraseMemory) ?PhraseNotePick {
    const note = phraseGeneratorAdvance(phrase, rng) orelse {
        memory.novelty_debt = std.math.clamp(memory.novelty_debt - PHRASE_DEBT_REST_DECAY, 0.0, 1.0);
        phraseVariationStatsRememberDebt(memory.novelty_debt);
        return null;
    };
    if (phrase.pos == 1 and phrase.len > 0) {
        phraseMemoryStore(memory, &phrase.notes, phrase.len);
    }
    memory.novelty_debt = std.math.clamp(memory.novelty_debt - PHRASE_DEBT_FRESH_DECAY, 0.0, 1.0);
    const pick: PhraseNotePick = .{
        .note = note,
        .recalled = false,
        .recall_kind = .none,
    };
    phraseVariationStatsRememberPick(pick, memory, false);
    return pick;
}

pub fn applyChordTonesToPhrases(harmony: *const ChordMarkov, scale_type: ScaleType, phrases: anytype) void {
    const degrees = chordMarkovScaleDegrees(harmony, scale_type);
    inline for (phrases) |phrase| {
        phraseGeneratorSetChordTones(phrase, degrees.tones[0..degrees.count]);
    }
}

pub const SlowLfo = struct {
    phase: f32 = 0,
    period_beats: f32 = 120,
    depth: f32 = 0.05,
};

pub fn slowLfoAdvanceSample(lfo: *SlowLfo, bpm_val: f32) void {
    lfo.phase += bpm_val / (dsp.SAMPLE_RATE * 60.0) * dsp.TAU / lfo.period_beats;
    if (lfo.phase > dsp.TAU) lfo.phase -= dsp.TAU;
}

pub fn slowLfoModulate(lfo: *const SlowLfo) f32 {
    return 1.0 + @sin(lfo.phase) * lfo.depth;
}

pub fn slowLfoValue(lfo: *const SlowLfo) f32 {
    return @sin(lfo.phase) * lfo.depth;
}
