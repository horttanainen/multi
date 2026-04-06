const std = @import("std");
const dsp = @import("dsp.zig");

pub const ArcShape = enum { rise, fall, rise_fall, plateau };

pub const ArcController = struct {
    beat_count: f32 = 0,
    section_beats: f32 = 32,
    shape: ArcShape = .rise_fall,

    pub fn advanceSample(self: *ArcController, bpm_val: f32) void {
        self.beat_count += bpm_val / (dsp.SAMPLE_RATE * 60.0);
        while (self.beat_count >= self.section_beats) {
            self.beat_count -= self.section_beats;
        }
    }

    pub fn tension(self: *const ArcController) f32 {
        const p = self.beat_count / self.section_beats;
        return switch (self.shape) {
            .rise => p,
            .fall => 1.0 - p,
            .rise_fall => @sin(p * std.math.pi),
            .plateau => if (p < 0.25) p * 4.0 else if (p > 0.75) (1.0 - p) * 4.0 else 1.0,
        };
    }

    pub fn reset(self: *ArcController) void {
        self.beat_count = 0;
    }
};

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

    pub fn modulateTo(self: *KeyState, new_root: u8) void {
        self.target_root = new_root;
        self.transition_progress = 0;
    }

    pub fn modulateByFourth(self: *KeyState) void {
        self.modulateTo(self.root + 5);
    }

    pub fn modulateByFifth(self: *KeyState) void {
        self.modulateTo(self.root + 7);
    }

    pub fn advanceSample(self: *KeyState) void {
        if (self.transition_progress >= 1.0) return;
        self.transition_progress += self.transition_speed;
        if (self.transition_progress >= 1.0) {
            self.transition_progress = 1.0;
            self.root = self.target_root;
        }
    }

    pub fn isTransitioning(self: *const KeyState) bool {
        return self.transition_progress < 1.0;
    }

    pub fn noteToMidi(self: *const KeyState, degree: u8) u8 {
        return scaleNoteToMidi(self.root, self.scale_type, degree);
    }
};

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

    pub fn nextChord(self: *ChordMarkov, rng: *dsp.Rng) ChordDef {
        const row = self.transitions[self.current];
        var cumulative: f32 = 0;
        const r = rng.float();
        for (0..self.num_chords) |i| {
            cumulative += row[i];
            if (r < cumulative) {
                self.current = @intCast(i);
                return self.chords[i];
            }
        }
        self.current = 0;
        return self.chords[0];
    }

    pub fn currentMidiNotes(self: *const ChordMarkov, root: u8) [MAX_CHORD_TONES]u8 {
        const chord = self.chords[self.current];
        var notes: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES;
        for (0..chord.len) |i| {
            notes[i] = root + chord.offsets[i];
        }
        return notes;
    }

    pub fn chordScaleDegrees(self: *const ChordMarkov, scale_type: ScaleType) struct { tones: [MAX_CHORD_TONES]u8, count: u8 } {
        const chord = self.chords[self.current];
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
};

pub const ArcSystem = struct {
    micro: ArcController = .{ .section_beats = 8, .shape = .rise_fall },
    meso: ArcController = .{ .section_beats = 48, .shape = .rise_fall },
    macro: ArcController = .{ .section_beats = 256, .shape = .rise_fall },

    pub fn advanceSample(self: *ArcSystem, bpm_val: f32) void {
        self.micro.advanceSample(bpm_val);
        self.meso.advanceSample(bpm_val);
        self.macro.advanceSample(bpm_val);
    }

    pub fn reset(self: *ArcSystem) void {
        self.micro.reset();
        self.meso.reset();
        self.macro.reset();
    }
};

pub const ModulationMode = enum {
    none,
    fourth,
    fifth,
    mixed,
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

    pub fn target(self: LayerCurve, macro: f32) f32 {
        const t = @max(macro - self.start, 0.0);
        return std.math.clamp(self.offset + t * self.slope, self.min, self.max);
    }
};

pub fn applyLayerCurves(comptime N: usize, curves: *const [N]LayerCurve, macro: f32, out: *[N]f32) void {
    for (0..N) |i| {
        out[i] = curves[i].target(macro);
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

    pub fn reset(self: *StepSequencer16) void {
        self.step_counter = 0.0;
        self.step = 0;
    }

    pub fn advanceSample(self: *StepSequencer16, bpm_val: f32) ?u8 {
        const samples_per_step = dsp.SAMPLE_RATE * 60.0 / bpm_val / 4.0;
        self.step_counter += 1.0;
        if (self.step_counter < samples_per_step) return null;
        self.step_counter -= samples_per_step;
        const current_step = self.step;
        self.step = (self.step + 1) % 16;
        return current_step;
    }
};

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
    if (rng.float() >= tensionChance(fill_density, tension)) return null;
    return fill_velocity;
}

pub fn snareBackbeatOrGhost(step: u8, backbeat_mask: u16, rng: *dsp.Rng, ghost_chance: f32, tension: f32) enum { none, backbeat, ghost } {
    if (stepActive(backbeat_mask, step)) return .backbeat;
    if (ghost_chance <= 0 or rng.float() >= ghost_chance * tension) return .none;
    return .ghost;
}

pub fn leadStepChance(step: u8, density: f32, meso: f32, offbeat_scale: f32) f32 {
    if (step % 2 == 0) return tensionChance(density, meso);
    return density * offbeat_scale * meso;
}

pub const VoiceTimingSpec = struct {
    base_beats: f32,
    random_beats: f32 = 0.0,

    pub fn sample(self: VoiceTimingSpec, rng: *dsp.Rng) f32 {
        return self.base_beats + rng.float() * self.random_beats;
    }
};

pub fn StepStyleRunner(comptime CueSpecType: type, comptime LayerCount: usize) type {
    return struct {
        engine: CompositionEngine = .{},
        layer_targets: [LayerCount]f32 = .{0.0} ** LayerCount,
        layer_levels: [LayerCount]f32 = .{0.0} ** LayerCount,
        sequencer: StepSequencer16 = .{},

        pub fn reset(
            self: *@This(),
            style: *const StyleSpec(CueSpecType, LayerCount, 0),
            key_state: KeyState,
            harmony_state: ChordMarkov,
            chord_beats: f32,
            mode: ModulationMode,
            initial_targets: [LayerCount]f32,
            initial_levels: [LayerCount]f32,
        ) void {
            self.engine.reset(key_state, harmony_state, style.arcs, chord_beats, mode);
            self.layer_targets = initial_targets;
            self.layer_levels = initial_levels;
            self.sequencer.reset();
        }

        pub fn advanceFrame(
            self: *@This(),
            rng: *dsp.Rng,
            style: *const StyleSpec(CueSpecType, LayerCount, 0),
            bpm_val: f32,
            fade_rate: f32,
        ) StepStyleFrame {
            const tick = self.engine.advanceSample(rng, bpm_val);
            applyLayerCurves(LayerCount, &style.layer_curves, tick.macro, &self.layer_targets);
            easeLevels(LayerCount, &self.layer_levels, &self.layer_targets, fade_rate);
            return .{
                .tick = tick,
                .step = self.sequencer.advanceSample(bpm_val),
            };
        }
    };
}

pub const CompositionEngine = struct {
    const CHORD_HISTORY_SIZE: usize = 12;

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

        fn reset(self: *LongFormDirector) void {
            self.beat_counter = 0.0;
            self.intensity = 0.46;
            self.target_intensity = 0.46;
            self.cadence_spread = 0.16;
            self.target_cadence_spread = 0.16;
            self.modulation_drive = 0.52;
            self.target_modulation_drive = 0.52;
            self.primed = false;
        }

        fn advanceSample(self: *LongFormDirector, rng: *dsp.Rng, spb: f32) void {
            if (self.section_beats <= 0.0) {
                std.log.warn("CompositionEngine.LongFormDirector.advanceSample: invalid section_beats={d}, using 384", .{self.section_beats});
                self.section_beats = 384.0;
            }

            if (!self.primed) {
                self.pickTargets(rng);
                self.primed = true;
            }

            self.intensity += (self.target_intensity - self.intensity) * 0.00024;
            self.cadence_spread += (self.target_cadence_spread - self.cadence_spread) * 0.0002;
            self.modulation_drive += (self.target_modulation_drive - self.modulation_drive) * 0.00022;

            self.beat_counter += 1.0 / spb;
            if (self.beat_counter < self.section_beats) return;
            while (self.beat_counter >= self.section_beats) {
                self.beat_counter -= self.section_beats;
            }
            self.pickTargets(rng);
        }

        fn pickTargets(self: *LongFormDirector, rng: *dsp.Rng) void {
            const intensity_step = (rng.float() * 2.0 - 1.0) * 0.24;
            const cadence_step = (rng.float() * 2.0 - 1.0) * 0.1;
            const modulation_step = (rng.float() * 2.0 - 1.0) * 0.16;

            var next_intensity = self.target_intensity + intensity_step;
            if (rng.float() < 0.18) {
                next_intensity += if (rng.float() < 0.5) -0.2 else 0.2;
            }
            self.target_intensity = std.math.clamp(next_intensity, 0.12, 0.96);
            self.target_cadence_spread = std.math.clamp(self.target_cadence_spread + cadence_step, 0.05, 0.42);
            self.target_modulation_drive = std.math.clamp(self.target_modulation_drive + modulation_step, 0.08, 0.94);
        }
    };

    arcs: ArcSystem = .{},
    key: KeyState = .{},
    harmony: ChordMarkov = .{},
    director: LongFormDirector = .{},
    recent_chords: [CHORD_HISTORY_SIZE]u8 = .{0} ** CHORD_HISTORY_SIZE,
    recent_chord_count: u8 = 0,
    recent_chord_pos: u8 = 0,
    chord_beat_counter: f32 = 0.0,
    chord_change_beats: f32 = 16.0,
    chord_change_target_beats: f32 = 16.0,
    next_chord_change_beats: f32 = 16.0,
    last_macro_quarter: u8 = 0,
    modulation_mode: ModulationMode = .mixed,

    pub fn setChordChangeBeats(self: *CompositionEngine, beats: f32) void {
        if (beats <= 0.0) {
            std.log.warn("CompositionEngine.setChordChangeBeats: invalid beats {d}, clamping to 1.0", .{beats});
            self.chord_change_target_beats = 1.0;
            return;
        }
        self.chord_change_target_beats = beats;
    }

    pub fn longFormIntensity(self: *const CompositionEngine) f32 {
        return self.director.intensity;
    }

    pub fn longFormCadenceSpread(self: *const CompositionEngine) f32 {
        return self.director.cadence_spread;
    }

    pub fn longFormModulationDrive(self: *const CompositionEngine) f32 {
        return self.director.modulation_drive;
    }

    pub fn reset(self: *CompositionEngine, key_state: KeyState, harmony_state: ChordMarkov, arc_state: ArcSystem, chord_beats: f32, mode: ModulationMode) void {
        self.key = key_state;
        self.harmony = harmony_state;
        self.arcs = arc_state;
        self.chord_beat_counter = 0.0;
        const clamped_beats = @max(chord_beats, 1.0);
        self.chord_change_beats = clamped_beats;
        self.chord_change_target_beats = clamped_beats;
        self.next_chord_change_beats = clamped_beats;
        self.last_macro_quarter = 0;
        self.modulation_mode = mode;
        self.director.reset();
        self.clearRecentChordHistory();
        if (self.harmony.num_chords == 0) {
            std.log.warn("CompositionEngine.reset: harmony has no chords; novelty history disabled", .{});
            return;
        }
        self.rememberChord(self.harmony.current);
    }

    pub fn advanceSample(self: *CompositionEngine, rng: *dsp.Rng, bpm_val: f32) CompositionTick {
        self.arcs.advanceSample(bpm_val);
        self.key.advanceSample();

        const micro_t = self.arcs.micro.tension();
        const meso_t = self.arcs.meso.tension();
        const macro_t = self.arcs.macro.tension();

        const spb = dsp.samplesPerBeat(bpm_val);
        if (spb <= 0.0) {
            std.log.warn("CompositionEngine.advanceSample: invalid samples-per-beat for bpm={d}, using fallback tick", .{bpm_val});
            return .{
                .micro = micro_t,
                .meso = meso_t,
                .macro = macro_t,
                .chord_changed = false,
            };
        }

        self.director.advanceSample(rng, spb);
        self.advanceChordCadenceMorph(spb);
        self.chord_beat_counter += 1.0 / spb;
        var chord_changed = false;
        if (self.next_chord_change_beats <= 0.0) {
            std.log.warn("CompositionEngine.advanceSample: next_chord_change_beats <= 0 ({d}), resetting cadence", .{self.next_chord_change_beats});
            self.next_chord_change_beats = @max(self.chord_change_beats, 1.0);
        }
        if (self.chord_beat_counter >= self.next_chord_change_beats) {
            self.chord_beat_counter -= self.next_chord_change_beats;
            chord_changed = self.advanceHarmonyWithNovelty(rng, meso_t, macro_t);
            self.next_chord_change_beats = self.sampleNextChordChangeBeats(rng, meso_t, macro_t, self.director.cadence_spread, self.director.intensity);
            self.nudgeHarmonyTransitions(rng, macro_t, self.director.intensity);
        }

        const macro_quarter: u8 = @intFromFloat(self.arcs.macro.beat_count / self.arcs.macro.section_beats * 4.0);
        if (macro_quarter != self.last_macro_quarter) {
            self.last_macro_quarter = macro_quarter;
            if (macro_quarter == 0) {
                const modulation_gate = std.math.clamp(0.25 + self.director.modulation_drive * 0.55 + macro_t * 0.15, 0.0, 1.0);
                if (rng.float() >= modulation_gate) {
                    return .{
                        .micro = micro_t,
                        .meso = meso_t,
                        .macro = macro_t,
                        .chord_changed = chord_changed,
                    };
                }
                switch (self.modulation_mode) {
                    .none => {},
                    .fourth => self.key.modulateByFourth(),
                    .fifth => self.key.modulateByFifth(),
                    .mixed => {
                        const prefer_fourth = 0.5 + (self.director.intensity - 0.5) * 0.25;
                        if (rng.float() < prefer_fourth) {
                            self.key.modulateByFourth();
                        } else {
                            self.key.modulateByFifth();
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

    fn advanceChordCadenceMorph(self: *CompositionEngine, spb: f32) void {
        const delta = self.chord_change_target_beats - self.chord_change_beats;
        if (@abs(delta) < 0.0001) {
            self.chord_change_beats = self.chord_change_target_beats;
            return;
        }
        const samples_per_morph = spb * 16.0;
        if (samples_per_morph <= 1.0) {
            std.log.warn("CompositionEngine.advanceChordCadenceMorph: invalid morph window spb={d}", .{spb});
            self.chord_change_beats = self.chord_change_target_beats;
            return;
        }
        const rate = 1.0 / samples_per_morph;
        self.chord_change_beats += delta * rate;
    }

    fn sampleNextChordChangeBeats(self: *CompositionEngine, rng: *dsp.Rng, meso_t: f32, macro_t: f32, cadence_spread: f32, director_intensity: f32) f32 {
        const base = @max(self.chord_change_beats, 1.0);
        const spread = std.math.clamp(0.06 + macro_t * 0.14 + meso_t * 0.08 + cadence_spread * 0.55 + director_intensity * 0.1, 0.04, 0.62);
        const direction_bias = (director_intensity - 0.5) * 0.12;
        const ratio = 1.0 + (rng.float() * 2.0 - 1.0) * spread + direction_bias;
        const min_ratio = std.math.clamp(0.55 - cadence_spread * 0.32, 0.32, 0.75);
        const max_ratio = std.math.clamp(1.6 + cadence_spread * 0.9, 1.2, 2.2);
        return std.math.clamp(base * ratio, base * min_ratio, base * max_ratio);
    }

    fn nudgeHarmonyTransitions(self: *CompositionEngine, rng: *dsp.Rng, macro_t: f32, director_intensity: f32) void {
        if (self.harmony.num_chords < 2) return;
        if (rng.float() > 0.09 + macro_t * 0.16 + director_intensity * 0.14) return;

        const row_idx: usize = self.harmony.current;
        const chord_count: usize = @intCast(self.harmony.num_chords);
        if (row_idx >= chord_count) {
            std.log.warn("CompositionEngine.nudgeHarmonyTransitions: row idx {d} out of range {d}", .{ row_idx, chord_count });
            return;
        }

        var row = &self.harmony.transitions[row_idx];
        const target: usize = @intCast(rng.next() % @as(u32, @intCast(chord_count)));
        const delta = 0.02 + rng.float() * (0.04 + director_intensity * 0.05);
        row[target] += delta;
        row[row_idx] = @max(0.005, row[row_idx] - delta * 0.45);

        var sum: f32 = 0.0;
        for (0..chord_count) |i| {
            sum += row[i];
        }
        if (sum <= 0.00001) {
            std.log.warn("CompositionEngine.nudgeHarmonyTransitions: transition sum collapsed, restoring uniform row", .{});
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

    fn advanceHarmonyWithNovelty(self: *CompositionEngine, rng: *dsp.Rng, meso_t: f32, macro_t: f32) bool {
        if (self.harmony.num_chords == 0) {
            std.log.warn("CompositionEngine.advanceHarmonyWithNovelty: no chords available", .{});
            return false;
        }
        if (self.harmony.num_chords == 1) {
            self.rememberChord(self.harmony.current);
            return true;
        }

        const attempt_count: usize = if (self.harmony.num_chords <= 3) 3 else 5;
        var best: ChordMarkov = self.harmony;
        var best_score: f32 = 9_999.0;

        for (0..attempt_count) |_| {
            var trial = self.harmony;
            _ = trial.nextChord(rng);
            const score = self.chordNoveltyScore(trial.current, meso_t, macro_t);
            if (score >= best_score) continue;
            best = trial;
            best_score = score;
            if (best_score <= 0.0) break;
        }

        self.harmony = best;
        self.rememberChord(self.harmony.current);
        return true;
    }

    fn chordNoveltyScore(self: *const CompositionEngine, chord_idx: u8, meso_t: f32, macro_t: f32) f32 {
        if (self.recent_chord_count == 0) return 0.0;

        var matches: u8 = 0;
        var recency_weight: f32 = 0.0;
        const count: usize = self.recent_chord_count;

        for (0..count) |offset| {
            const hist_pos = (CHORD_HISTORY_SIZE + self.recent_chord_pos - 1 - offset) % CHORD_HISTORY_SIZE;
            if (self.recent_chords[hist_pos] != chord_idx) continue;
            matches += 1;
            const w = 1.0 - @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(count));
            recency_weight += w;
        }

        var score = @as(f32, @floatFromInt(matches)) * 0.65 + recency_weight * 0.9;
        const last_pos = (CHORD_HISTORY_SIZE + self.recent_chord_pos - 1) % CHORD_HISTORY_SIZE;
        if (self.recent_chords[last_pos] == chord_idx) {
            score += 1.1 + macro_t * 0.45;
        }
        score -= meso_t * 0.22;
        score -= self.director.cadence_spread * 0.35;
        return score;
    }

    fn clearRecentChordHistory(self: *CompositionEngine) void {
        self.recent_chords = .{0} ** CHORD_HISTORY_SIZE;
        self.recent_chord_count = 0;
        self.recent_chord_pos = 0;
    }

    fn rememberChord(self: *CompositionEngine, chord_idx: u8) void {
        self.recent_chords[self.recent_chord_pos] = chord_idx;
        self.recent_chord_pos = @intCast((@as(usize, self.recent_chord_pos) + 1) % CHORD_HISTORY_SIZE);
        if (self.recent_chord_count < CHORD_HISTORY_SIZE) {
            self.recent_chord_count += 1;
        }
    }
};

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

    pub fn build(self: *PhraseGenerator, rng: *dsp.Rng) void {
        const clamped_min = @min(self.min_notes, MAX_LEN);
        const clamped_max = @min(self.max_notes, MAX_LEN);
        if (clamped_min > clamped_max) {
            std.log.warn("PhraseGenerator.build: invalid phrase note range min={d} max={d}, using {d}", .{ self.min_notes, self.max_notes, MAX_LEN });
            self.len = MAX_LEN;
            self.pos = 0;
            return self.fill(rng);
        }
        if (self.max_notes > MAX_LEN or self.min_notes > MAX_LEN) {
            std.log.warn("PhraseGenerator.build: clamping phrase note range min={d} max={d} to max len {d}", .{ self.min_notes, self.max_notes, MAX_LEN });
        }
        const range = @as(u32, clamped_max - clamped_min) + 1;
        self.len = clamped_min + @as(u8, @intCast(rng.next() % range));
        self.pos = 0;
        self.fill(rng);
    }

    fn fill(self: *PhraseGenerator, rng: *dsp.Rng) void {
        var current = self.anchor;
        const direction = rng.next() % 3;
        for (0..self.len) |i| {
            const progress: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(self.len, 1)));
            const up_bias: f32 = switch (direction) {
                0 => 0.65,
                1 => 0.35,
                else => if (progress < 0.5) 0.7 else 0.3,
            };
            if (rng.float() < self.rest_chance and i > 0) {
                self.notes[i] = REST;
            } else {
                current = self.selectNote(rng, current, up_bias);
                self.notes[i] = current;
            }
        }
        if (current != REST) self.anchor = current;
    }

    pub fn advance(self: *PhraseGenerator, rng: *dsp.Rng) ?u8 {
        if (self.pos >= self.len) {
            self.build(rng);
        }
        const idx = self.pos;
        self.pos += 1;
        const note = self.notes[idx];
        if (note == REST) return null;
        return note;
    }

    pub fn setChordTones(self: *PhraseGenerator, tones: []const u8) void {
        self.chord_tone_count = @intCast(@min(tones.len, 4));
        for (0..self.chord_tone_count) |i| {
            self.chord_tones[i] = tones[i];
        }
    }

    fn selectNote(self: *const PhraseGenerator, rng_ptr: *dsp.Rng, current: u8, up_bias: f32) u8 {
        const candidate = biasedScaleStep(rng_ptr, current, self.region_low, self.region_high, up_bias);
        if (self.chord_tone_count == 0) return candidate;
        if (isChordTone(candidate, &self.chord_tones, self.chord_tone_count)) return candidate;
        if (rng_ptr.float() < self.gravity / (self.gravity + 1.0)) {
            return nearestChordTone(candidate, &self.chord_tones, self.chord_tone_count, self.region_low, self.region_high);
        }
        return candidate;
    }

    fn biasedScaleStep(rng_ptr: *dsp.Rng, current: u8, low: u8, high: u8, up_bias: f32) u8 {
        const r = rng_ptr.float();
        var delta: i8 = 0;
        if (r < 0.6) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 1) else @as(i8, -1);
        } else if (r < 0.85) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 2) else @as(i8, -2);
        } else if (r < 0.95) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 3) else @as(i8, -3);
        }
        const new_raw: i16 = @as(i16, current) + delta;
        return @intCast(std.math.clamp(new_raw, @as(i16, low), @as(i16, high)));
    }

    fn isChordTone(degree: u8, tones: *const [4]u8, count: u8) bool {
        for (0..count) |i| {
            if (degree == tones[i]) return true;
        }
        return false;
    }

    fn nearestChordTone(target: u8, tones: *const [4]u8, count: u8, low: u8, high: u8) u8 {
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
};

pub const PhraseMemory = struct {
    const SIZE = 6;
    const PLEN = PhraseGenerator.MAX_LEN;
    const REST = PhraseGenerator.REST;

    phrases: [SIZE][PLEN]u8 = .{.{0} ** PLEN} ** SIZE,
    lengths: [SIZE]u8 = .{0} ** SIZE,
    count: u8 = 0,
    write_pos: u8 = 0,

    pub fn store(self: *PhraseMemory, notes: *const [PLEN]u8, len: u8) void {
        self.phrases[self.write_pos] = notes.*;
        self.lengths[self.write_pos] = len;
        self.write_pos = (self.write_pos + 1) % SIZE;
        if (self.count < SIZE) self.count += 1;
    }

    pub fn recallVaried(self: *const PhraseMemory, rng: *dsp.Rng, out: *[PLEN]u8, region_low: u8, region_high: u8) ?u8 {
        if (self.count == 0) return null;
        const idx = @as(u8, @intCast(rng.next() % self.count));
        const src = self.phrases[idx];
        const len = self.lengths[idx];
        if (len == 0) return null;

        const transform = rng.next() % 4;
        switch (transform) {
            0 => {
                const shift: i8 = switch (rng.next() % 4) {
                    0 => 1,
                    1 => -1,
                    2 => 2,
                    else => -2,
                };
                for (0..len) |i| {
                    if (src[i] == REST) {
                        out[i] = REST;
                    } else {
                        const raw: i16 = @as(i16, src[i]) + shift;
                        out[i] = @intCast(std.math.clamp(raw, @as(i16, region_low), @as(i16, region_high)));
                    }
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
                    if (out_len >= PLEN) break;
                    out[out_len] = src[i];
                    out_len += 1;
                    if (out_len < PLEN and src[i] != REST and rng.float() < 0.5) {
                        out[out_len] = REST;
                        out_len += 1;
                    }
                }
                return out_len;
            },
            else => {
                var out_len: u8 = 0;
                for (0..len) |i| {
                    if (out_len >= PLEN) break;
                    out[out_len] = src[i];
                    out_len += 1;
                    if (i + 1 < len and src[i] != REST and src[i + 1] != REST and out_len < PLEN) {
                        const a: i16 = src[i];
                        const b: i16 = src[i + 1];
                        if (@abs(b - a) == 2) {
                            out[out_len] = @intCast(std.math.clamp(@divTrunc(a + b, 2), @as(i16, region_low), @as(i16, region_high)));
                            out_len += 1;
                        }
                    }
                }
                return out_len;
            },
        }
    }
};

pub const PhraseNotePick = struct {
    note: u8,
    recalled: bool,
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
    if (memory.count > 0 and rng.float() < recall_chance) {
        var varied_notes: [PhraseGenerator.MAX_LEN]u8 = undefined;
        const varied_len = memory.recallVaried(rng, &varied_notes, phrase.region_low, phrase.region_high) orelse return nextPhraseNote(rng, phrase, memory);
        if (varied_len == 0 or varied_notes[0] == PhraseGenerator.REST) return nextPhraseNote(rng, phrase, memory);
        return .{ .note = varied_notes[0], .recalled = true };
    }
    return nextPhraseNote(rng, phrase, memory);
}

fn nextPhraseNote(rng: *dsp.Rng, phrase: *PhraseGenerator, memory: *PhraseMemory) ?PhraseNotePick {
    const note = phrase.advance(rng) orelse return null;
    if (phrase.pos == 0 and phrase.len > 0) {
        memory.store(&phrase.notes, phrase.len);
    }
    return .{ .note = note, .recalled = false };
}

pub fn applyChordTonesToPhrases(harmony: *const ChordMarkov, scale_type: ScaleType, phrases: anytype) void {
    const degrees = harmony.chordScaleDegrees(scale_type);
    inline for (phrases) |phrase| {
        phrase.setChordTones(degrees.tones[0..degrees.count]);
    }
}

pub const SlowLfo = struct {
    phase: f32 = 0,
    period_beats: f32 = 120,
    depth: f32 = 0.05,

    pub fn advanceSample(self: *SlowLfo, bpm_val: f32) void {
        self.phase += bpm_val / (dsp.SAMPLE_RATE * 60.0) * dsp.TAU / self.period_beats;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
    }

    pub fn modulate(self: *const SlowLfo) f32 {
        return 1.0 + @sin(self.phase) * self.depth;
    }

    pub fn value(self: *const SlowLfo) f32 {
        return @sin(self.phase) * self.depth;
    }
};
