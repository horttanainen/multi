const std = @import("std");
const dsp = @import("dsp.zig");
const composition = @import("composition.zig");
const instruments = @import("instruments.zig");

pub const PhraseStepSpec = struct {
    base_rest_chance: f32,
    rest_offset: f32 = 0.0,
    rest_scale: f32 = 1.0,
    meso_scale: f32 = 0.0,
    recall_chance: f32 = 0.0,
};

pub fn nextPhraseStep(
    rng: *dsp.Rng,
    meso: f32,
    phrase: *composition.PhraseGenerator,
    memory: ?*composition.PhraseMemory,
    spec: PhraseStepSpec,
) ?composition.PhraseNotePick {
    phrase.rest_chance = std.math.clamp((spec.base_rest_chance + spec.rest_offset) * (spec.rest_scale - meso * spec.meso_scale), 0.0, 1.0);
    if (memory == null or spec.recall_chance <= 0.0) {
        return phraseStepWithoutMemory(rng, phrase);
    }
    return composition.nextPhraseNoteWithMemory(rng, phrase, memory.?, spec.recall_chance);
}

fn phraseStepWithoutMemory(rng: *dsp.Rng, phrase: *composition.PhraseGenerator) ?composition.PhraseNotePick {
    const note = composition.phraseGeneratorAdvance(phrase, rng) orelse return null;
    return .{
        .note = note,
        .recalled = false,
    };
}

pub const DroneLayer = struct {
    drone: instruments.SineDrone = instruments.sineDroneInit(dsp.midiToFreq(36), 120.0, 1.002, 1.0, 0.5, 0.02),
};

pub fn resetDroneLayer(layer: *DroneLayer, drone: instruments.SineDrone) void {
    layer.drone = drone;
}

pub fn applyDroneCue(layer: *DroneLayer, cutoff_hz: f32, detune_ratio: f32) void {
    layer.drone.filter = dsp.lpfInit(cutoff_hz);
    layer.drone.detune_ratio = detune_ratio;
}

pub fn applyDroneChord(layer: *DroneLayer, key_root: u8, chord: composition.ChordDef, octave_offset: i8) void {
    const midi: i16 = @as(i16, key_root) + @as(i16, chord.offsets[0]) + @as(i16, octave_offset) * 12;
    layer.drone.freq = dsp.midiToFreq(@intCast(midi));
}

pub fn mixDroneLayer(layer: *DroneLayer, level: f32) [2]f32 {
    const sample = instruments.sineDroneProcess(&layer.drone) * level;
    return .{ sample, sample };
}

pub const ChoirPadLayer = struct {
    pub const COUNT = 3;

    parts: [COUNT]instruments.ChoirPart = .{
        instruments.choirPartInit(0.006, -0.35, 0),
        instruments.choirPartInit(0.006, 0.0, 1),
        instruments.choirPartInit(0.006, 0.35, 2),
    },
};

pub fn resetChoirPadLayer(layer: *ChoirPadLayer) void {
    layer.* = .{};
}

pub fn applyChoirPadChord(
    layer: *ChoirPadLayer,
    key_root: u8,
    chord: composition.ChordDef,
    cue_pad_attack: f32,
    cue_pad_release: f32,
    cue_index: u8,
    chord_index: u8,
) void {
    for (0..ChoirPadLayer.COUNT) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        layer.parts[idx].voice.freq = dsp.midiToFreq(key_root + offset);
        instruments.choirPartTrigger(&layer.parts[idx], layer.parts[idx].voice.freq, dsp.envelopeInit(cue_pad_attack, 1.4, 0.76, cue_pad_release));
        instruments.choirPartSetVowel(&layer.parts[idx], @intCast((cue_index + idx + chord_index) % 4));
    }
}

pub fn mixChoirPadLayer(layer: *ChoirPadLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..ChoirPadLayer.COUNT) |idx| {
        const sample = instruments.choirPartProcess(&layer.parts[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.parts[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

pub const ChoirChantLayer = struct {
    part: instruments.ChoirPart = instruments.choirPartInit(0.004, 0.08, 1),
    phrase: composition.PhraseGenerator = .{},
    memory: composition.PhraseMemory = .{},
};

pub const ChoirChantCueSpec = struct {
    phrase: composition.PhraseConfig,
    min_notes: u8,
    max_notes: u8,
    recall_chance: f32,
    attack: f32,
    release: f32,
};

pub fn resetChoirChantLayer(layer: *ChoirChantLayer, phrase: composition.PhraseGenerator) void {
    layer.* = .{
        .phrase = phrase,
    };
}

pub fn applyChoirChantCue(layer: *ChoirChantLayer, spec: ChoirChantCueSpec) void {
    composition.applyPhraseConfig(spec.phrase, &layer.phrase);
    layer.phrase.min_notes = spec.min_notes;
    layer.phrase.max_notes = spec.max_notes;
}

pub fn applyChoirChantChord(layer: *ChoirChantLayer, key_root: u8, harmony: *const composition.ChordMarkov, scale_type: composition.ScaleType, cue_index: u8) void {
    const degrees = composition.chordMarkovScaleDegrees(harmony, scale_type);
    composition.phraseGeneratorSetChordTones(&layer.phrase, degrees.tones[0..degrees.count]);
    instruments.choirPartSetVowel(&layer.part, @intCast((cue_index + harmony.current) % 4));
    _ = key_root;
}

pub fn maybeTriggerChoirChant(
    layer: *ChoirChantLayer,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    chant_level: f32,
    meso: f32,
    micro: f32,
    spec: ChoirChantCueSpec,
) void {
    if (chant_level < 0.05) return;

    const picked = nextPhraseStep(rng, meso, &layer.phrase, &layer.memory, .{
        .base_rest_chance = layer.phrase.rest_chance,
        .rest_scale = 1.15,
        .meso_scale = 0.18,
        .recall_chance = spec.recall_chance,
    }) orelse return;
    const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, picked.note));
    const decay = if (picked.recalled) 0.6 + micro * 0.4 else 0.5 + meso * 0.35;
    instruments.choirPartTrigger(&layer.part, freq, dsp.envelopeInit(spec.attack, decay, 0.55, spec.release));
}

pub fn mixChoirChantLayer(layer: *ChoirChantLayer, level: f32, mix: f32) [2]f32 {
    const sample = instruments.choirPartProcess(&layer.part) * level * mix;
    return dsp.panStereo(sample, layer.part.pan);
}

pub const BreathLayer = struct {
    breath_lpf: dsp.LPF = dsp.lpfInit(1200.0),
    shimmer_lpf: dsp.LPF = dsp.lpfInit(3400.0),
};

pub fn resetBreathLayer(layer: *BreathLayer) void {
    layer.* = .{};
}

pub fn mixBreathLayer(layer: *BreathLayer, rng: *dsp.Rng, breathiness: f32, cue_breath_boost: f32, meso: f32, level: f32) [2]f32 {
    if (breathiness <= 0.001 or level <= 0.0001) return .{ 0.0, 0.0 };
    const breath_mod = (breathiness + cue_breath_boost) * (1.0 - meso * 0.25);
    const noise = dsp.rngFloat(rng) * 2.0 - 1.0;
    const base = dsp.lpfProcess(&layer.breath_lpf, noise);
    const shimmer = dsp.lpfProcess(&layer.shimmer_lpf, noise * 0.35);
    const sample = (base * 0.015 + shimmer * 0.006) * breath_mod * level;
    return .{ sample, sample };
}

const AmbientDroneVoice = dsp.Voice(2, 1);
const AmbientPadVoice = dsp.Voice(3, 4);
const AmbientMelodyVoice = dsp.Voice(2, 1);
const AmbientArpVoice = dsp.Voice(1, 1);

pub const AmbientDroneLayer = struct {
    pub const COUNT = 2;

    voices: [COUNT]AmbientDroneVoice = .{
        .{ .unison_spread = 0.003, .filter = dsp.lpfInit(200.0), .pan = -0.3 },
        .{ .unison_spread = 0.003, .filter = dsp.lpfInit(180.0), .pan = 0.3 },
    },
    beat_counter: [COUNT]f32 = .{ 0, 0 },
    beat_len: [COUNT]f32 = .{ 23.5, 29.75 },
    phrases: [COUNT]composition.PhraseGenerator = .{
        .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
        .{ .anchor = 2, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    },
};

pub fn resetAmbientDroneLayer(layer: *AmbientDroneLayer) void {
    layer.* = .{};
}

pub fn advanceAmbientDroneLayer(
    layer: *AmbientDroneLayer,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    spb: f32,
    meso: f32,
    filter_base: f32,
    filter_range: f32,
    filter_mod: f32,
    env_attack: f32,
    env_release: f32,
) void {
    for (0..AmbientDroneLayer.COUNT) |idx| {
        layer.beat_counter[idx] += 1.0 / spb;
        if (layer.beat_counter[idx] < layer.beat_len[idx]) continue;
        layer.beat_counter[idx] -= layer.beat_len[idx];
        const note_idx = composition.phraseGeneratorAdvance(&layer.phrases[idx], rng) orelse continue;
        const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, note_idx));
        layer.voices[idx].filter = dsp.lpfInit((filter_base + meso * filter_range) * filter_mod);
        dsp.voiceTrigger(2, 1, &layer.voices[idx], freq, dsp.envelopeInit(env_attack, 0.5, 0.8, env_release));
    }
}

pub fn mixAmbientDroneLayer(layer: *AmbientDroneLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..AmbientDroneLayer.COUNT) |idx| {
        const sample = dsp.voiceProcess(2, 1, &layer.voices[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

pub const AmbientPadLayer = struct {
    pub const COUNT = 3;

    voices: [COUNT]AmbientPadVoice = .{
        .{ .unison_spread = 0.005, .filter = dsp.lpfInit(800.0), .pan = -0.4 },
        .{ .unison_spread = 0.005, .filter = dsp.lpfInit(700.0), .pan = 0.0 },
        .{ .unison_spread = 0.005, .filter = dsp.lpfInit(750.0), .pan = 0.4 },
    },
    beat_counter: [COUNT]f32 = .{ 0, 0, 0 },
    beat_len: [COUNT]f32 = .{ 13.25, 17.5, 21.75 },
    note_idx: [COUNT]u8 = .{ 5, 7, 9 },
};

pub fn resetAmbientPadLayer(layer: *AmbientPadLayer) void {
    layer.* = .{};
}

pub fn applyAmbientPadChord(layer: *AmbientPadLayer, key_root: u8, scale_type: composition.ScaleType, chord: composition.ChordDef) void {
    for (0..@min(AmbientPadLayer.COUNT, chord.len)) |idx| {
        const si = composition.getScaleIntervals(scale_type);
        var best_deg: u8 = layer.note_idx[idx];
        var best_dist: u8 = 255;
        for (0..3) |oct| {
            for (0..si.len) |s| {
                const deg: u8 = @intCast(@as(usize, si.len) * oct + s);
                const midi = composition.scaleNoteToMidi(key_root, scale_type, deg);
                const target_midi = key_root + chord.offsets[idx] + @as(u8, @intCast(oct)) * 12;
                const dist = if (midi > target_midi) midi - target_midi else target_midi - midi;
                if (dist >= best_dist) continue;
                best_dist = dist;
                best_deg = deg;
            }
        }
        layer.note_idx[idx] = best_deg;
    }
}

pub fn advanceAmbientPadLayer(
    layer: *AmbientPadLayer,
    key: *const composition.KeyState,
    spb: f32,
    meso: f32,
    filter_base: f32,
    filter_range: f32,
    filter_mod: f32,
    env_attack: f32,
    env_release: f32,
) void {
    for (0..AmbientPadLayer.COUNT) |idx| {
        layer.beat_counter[idx] += 1.0 / spb;
        if (layer.beat_counter[idx] < layer.beat_len[idx]) continue;
        layer.beat_counter[idx] -= layer.beat_len[idx];
        const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, layer.note_idx[idx]));
        layer.voices[idx].filter = dsp.lpfInit((filter_base + meso * filter_range) * filter_mod);
        dsp.voiceTrigger(3, 4, &layer.voices[idx], freq, dsp.envelopeInit(env_attack, 0.3, 0.6, env_release));
    }
}

pub fn mixAmbientPadLayer(layer: *AmbientPadLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..AmbientPadLayer.COUNT) |idx| {
        const sample = dsp.voiceProcess(3, 4, &layer.voices[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

pub const AmbientMelodyLayer = struct {
    pub const COUNT = 2;

    voices: [COUNT]AmbientMelodyVoice = .{
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = -0.5 },
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = 0.5 },
    },
    beat_counter: [COUNT]f32 = .{ 0, 0 },
    beat_len: [COUNT]f32 = .{ 8.5, 11.25 },
    phrases: [COUNT]composition.PhraseGenerator = .{
        .{ .anchor = 10, .region_low = 8, .region_high = 14, .rest_chance = 0.55, .min_notes = 2, .max_notes = 5, .gravity = 4.0 },
        .{ .anchor = 11, .region_low = 9, .region_high = 14, .rest_chance = 0.6, .min_notes = 2, .max_notes = 4, .gravity = 4.0 },
    },
    memory: composition.PhraseMemory = .{},
};

pub fn resetAmbientMelodyLayer(layer: *AmbientMelodyLayer) void {
    layer.* = .{};
}

pub fn applyAmbientMelodyChord(layer: *AmbientMelodyLayer, harmony: *const composition.ChordMarkov, scale_type: composition.ScaleType) void {
    const degrees = composition.chordMarkovScaleDegrees(harmony, scale_type);
    for (0..AmbientMelodyLayer.COUNT) |idx| {
        composition.phraseGeneratorSetChordTones(&layer.phrases[idx], degrees.tones[0..degrees.count]);
    }
}

pub fn advanceAmbientMelodyLayer(
    layer: *AmbientMelodyLayer,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    spb: f32,
    meso: f32,
    micro: f32,
    recall_chance: f32,
    env_attack: f32,
    env_decay: f32,
    env_release: f32,
) void {
    for (0..AmbientMelodyLayer.COUNT) |idx| {
        layer.beat_counter[idx] += 1.0 / spb;
        if (layer.beat_counter[idx] < layer.beat_len[idx]) continue;
        layer.beat_counter[idx] -= layer.beat_len[idx];
        const picked = nextPhraseStep(rng, meso, &layer.phrases[idx], &layer.memory, .{
            .base_rest_chance = layer.phrases[idx].rest_chance,
            .rest_scale = 1.3,
            .meso_scale = 0.6,
            .recall_chance = recall_chance,
        }) orelse continue;
        const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, picked.note));
        dsp.voiceTrigger(2, 1, &layer.voices[idx], freq, dsp.envelopeInit(env_attack, env_decay + micro * 1.0, 0.0, env_release));
    }
}

pub fn mixAmbientMelodyLayer(layer: *AmbientMelodyLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..AmbientMelodyLayer.COUNT) |idx| {
        const sample = dsp.voiceProcess(2, 1, &layer.voices[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

pub const AmbientArpLayer = struct {
    pub const COUNT = 3;

    voices: [COUNT]AmbientArpVoice = .{
        .{ .pan = -0.7 },
        .{ .pan = 0.0 },
        .{ .pan = 0.7 },
    },
    beat_counter: [COUNT]f32 = .{ 0, 0, 0 },
    beat_len: [COUNT]f32 = .{ 3.75, 5.25, 4.5 },
    phrases: [COUNT]composition.PhraseGenerator = .{
        .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
        .{ .anchor = 15, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
        .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.55, .min_notes = 2, .max_notes = 4, .gravity = 4.5 },
    },
};

pub fn resetAmbientArpLayer(layer: *AmbientArpLayer) void {
    layer.* = .{};
}

pub fn applyAmbientArpChord(layer: *AmbientArpLayer, harmony: *const composition.ChordMarkov, scale_type: composition.ScaleType) void {
    const degrees = composition.chordMarkovScaleDegrees(harmony, scale_type);
    for (0..AmbientArpLayer.COUNT) |idx| {
        composition.phraseGeneratorSetChordTones(&layer.phrases[idx], degrees.tones[0..degrees.count]);
    }
}

pub fn advanceAmbientArpLayer(
    layer: *AmbientArpLayer,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    spb: f32,
    meso: f32,
    micro: f32,
    env_decay: f32,
    env_release: f32,
) void {
    for (0..AmbientArpLayer.COUNT) |idx| {
        layer.beat_counter[idx] += 1.0 / spb;
        if (layer.beat_counter[idx] < layer.beat_len[idx]) continue;
        layer.beat_counter[idx] -= layer.beat_len[idx];
        layer.phrases[idx].rest_chance = 0.5 * (1.3 - meso * 0.5);
        const note_idx = composition.phraseGeneratorAdvance(&layer.phrases[idx], rng) orelse continue;
        const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, note_idx));
        dsp.voiceTrigger(1, 1, &layer.voices[idx], freq, dsp.envelopeInit(0.08, env_decay + micro * 0.5, 0.0, env_release));
    }
}

pub fn mixAmbientArpLayer(layer: *AmbientArpLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..AmbientArpLayer.COUNT) |idx| {
        const sample = dsp.voiceProcess(1, 1, &layer.voices[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}
