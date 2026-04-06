const std = @import("std");
const dsp = @import("dsp.zig");
const composition = @import("composition.zig");
const instruments = @import("instruments.zig");

pub const DrumEvent = enum {
    none,
    backbeat,
    ghost,
};

pub const DrumStepEvents = struct {
    kick_velocity: ?f32 = null,
    snare: DrumEvent = .none,
    hat: bool = false,
};

pub const DrumPatternSpec = struct {
    kick_main_mask: u16 = 0,
    kick_fill_mask: u16 = 0,
    kick_fill_velocity: f32 = 0.7,
    kick_fill_density: f32 = 0.0,
    snare_backbeat_mask: u16 = 0,
    snare_ghost_chance: f32 = 0.0,
    hat_onbeat_chance: f32 = 0.0,
    hat_offbeat_chance: f32 = 0.0,
};

pub fn drumStepEvents(step: u8, meso: f32, rng: *dsp.Rng, spec: DrumPatternSpec) DrumStepEvents {
    return .{
        .kick_velocity = composition.kickVelocity(step, spec.kick_main_mask, spec.kick_fill_mask, spec.kick_fill_velocity, rng, spec.kick_fill_density, meso),
        .snare = switch (composition.snareBackbeatOrGhost(step, spec.snare_backbeat_mask, rng, spec.snare_ghost_chance, meso)) {
            .none => .none,
            .backbeat => .backbeat,
            .ghost => .ghost,
        },
        .hat = dsp.rngFloat(rng) < composition.subdivisionChance(step, spec.hat_onbeat_chance, spec.hat_offbeat_chance, meso),
    };
}

pub fn applyDrumStep(events: DrumStepEvents, kick: *instruments.Kick, snare: ?*instruments.Snare, hat: ?*instruments.HiHat) void {
    if (events.kick_velocity) |velocity| {
        instruments.kickTrigger(kick, velocity);
    }
    if (events.snare != .none and snare == null) {
        std.log.warn("applyDrumStep: snare event {s} without snare instrument", .{@tagName(events.snare)});
    }
    if (events.hat and hat == null) {
        std.log.warn("applyDrumStep: hat event without hat instrument", .{});
    }
    if (events.snare == .backbeat and snare != null) {
        instruments.snareTrigger(snare.?);
    }
    if (events.snare == .ghost and snare != null) {
        instruments.snareTriggerGhost(snare.?);
    }
    if (events.hat and hat != null) {
        instruments.hiHatTrigger(hat.?);
    }
}

pub const StepBassSpec = struct {
    trigger_mask: u16,
    base_rest_chance: f32,
    meso_rest_spread: f32,
    filter_base_hz: f32,
    filter_micro_hz: f32,
    filter_meso_hz: f32,
};

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

pub fn triggerStepBass(
    step: u8,
    micro: f32,
    meso: f32,
    lfo_mod: f32,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    phrase: *composition.PhraseGenerator,
    bass: *instruments.SawBass,
    spec: StepBassSpec,
) void {
    if (!composition.stepActive(spec.trigger_mask, step)) return;

    phrase.rest_chance = std.math.clamp(spec.base_rest_chance + (1.0 - meso) * spec.meso_rest_spread, 0.0, 1.0);
    const note_idx = composition.phraseGeneratorAdvance(phrase, rng) orelse {
        dsp.envelopeTrigger(&bass.env);
        instruments.sawBassSetFilter(bass, (spec.filter_base_hz + micro * spec.filter_micro_hz + meso * spec.filter_meso_hz) * lfo_mod);
        return;
    };
    instruments.sawBassTrigger(bass, dsp.midiToFreq(composition.keyStateNoteToMidi(key, note_idx)));
    instruments.sawBassSetFilter(bass, (spec.filter_base_hz + micro * spec.filter_micro_hz + meso * spec.filter_meso_hz) * lfo_mod);
}

fn phraseStepWithoutMemory(rng: *dsp.Rng, phrase: *composition.PhraseGenerator) ?composition.PhraseNotePick {
    const note = composition.phraseGeneratorAdvance(phrase, rng) orelse return null;
    return .{
        .note = note,
        .recalled = false,
    };
}

pub fn fillChordFrequencies(comptime N: usize, freqs: *[N]f32, key_root: u8, chord: composition.ChordDef, octave_offset: i8) void {
    for (0..N) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        const midi: i16 = @as(i16, key_root) + @as(i16, offset) + @as(i16, octave_offset) * 12;
        freqs[idx] = dsp.midiToFreq(@intCast(midi));
    }
}

pub const DrumKitLayer = struct {
    kick: instruments.Kick = .{},
    snare: instruments.Snare = .{},
    hat: instruments.HiHat = .{},
};

pub const DrumMixSpec = struct {
    kick_left: f32 = 0.85,
    kick_right: f32 = 0.85,
    snare_left: f32 = 0.72,
    snare_right: f32 = 0.72,
    hat_left: f32 = 0.42,
    hat_right: f32 = 0.52,
};

pub fn resetDrumKitLayer(layer: *DrumKitLayer, kick: instruments.Kick, snare: instruments.Snare, hat: instruments.HiHat) void {
    layer.kick = kick;
    layer.snare = snare;
    layer.hat = hat;
}

pub fn advanceDrumKitLayer(layer: *DrumKitLayer, step: u8, meso: f32, rng: *dsp.Rng, spec: DrumPatternSpec) void {
    applyDrumStep(drumStepEvents(step, meso, rng, spec), &layer.kick, &layer.snare, &layer.hat);
}

pub fn mixDrumKitLayer(layer: *DrumKitLayer, rng: *dsp.Rng, level: f32, spec: DrumMixSpec) [2]f32 {
    const kick_s = instruments.kickProcess(&layer.kick) * level;
    const snare_s = instruments.snareProcess(&layer.snare, rng) * level;
    const hat_s = instruments.hiHatProcess(&layer.hat, rng) * level;
    return .{
        kick_s * spec.kick_left + snare_s * spec.snare_left + hat_s * spec.hat_left,
        kick_s * spec.kick_right + snare_s * spec.snare_right + hat_s * spec.hat_right,
    };
}

pub const StepBassLayer = struct {
    bass: instruments.SawBass = .{},
    phrase: composition.PhraseGenerator = .{},
};

pub fn resetStepBassLayer(layer: *StepBassLayer, bass: instruments.SawBass, phrase: composition.PhraseGenerator) void {
    layer.bass = bass;
    layer.phrase = phrase;
}

pub fn applyStepBassChord(layer: *StepBassLayer, harmony: *const composition.ChordMarkov, scale_type: composition.ScaleType, key_root: u8) void {
    composition.applyChordTonesToPhrases(harmony, scale_type, .{&layer.phrase});
    const chord = harmony.chords[harmony.current];
    layer.bass.freq = dsp.midiToFreq(key_root + chord.offsets[0]);
}

pub fn advanceStepBassLayer(
    layer: *StepBassLayer,
    step: u8,
    micro: f32,
    meso: f32,
    lfo_mod: f32,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    spec: StepBassSpec,
) void {
    triggerStepBass(step, micro, meso, lfo_mod, rng, key, &layer.phrase, &layer.bass, spec);
}

pub fn mixStepBassLayer(layer: *StepBassLayer, level: f32, left_gain: f32, right_gain: f32) [2]f32 {
    const sample = instruments.sawBassProcess(&layer.bass) * level;
    return .{ sample * left_gain, sample * right_gain };
}

const ElectricGuitar3 = instruments.ElectricGuitar(3, 2, 4);

pub const GuitarChordLayer = struct {
    guitar: ElectricGuitar3 = instruments.electricGuitarInit(3, 2, 4, 0.35, 0.008, 4500.0, 120.0),
    retrigger: u8 = 4,
    attack: f32 = 0.004,
    decay: f32 = 0.36,
    sustain: f32 = 0.0,
    release: f32 = 0.14,
    strum_interval_samples: u32 = 120,
    strum_countdown: u32 = 0,
    pending_voice_count: u8 = 0,
    pending_order: [3]u8 = .{ 0, 1, 2 },
    downstroke: bool = true,
};

pub const GuitarCueSpec = struct {
    gain: f32,
    od_amount: f32,
    cabinet_lpf_hz: f32,
    cabinet_hpf_hz: f32,
    retrigger: u8,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
};

pub fn resetGuitarChordLayer(layer: *GuitarChordLayer, pan_spread: f32, unison_spread: f32, cab_lpf_hz: f32, cab_hpf_hz: f32) void {
    layer.* = .{
        .guitar = instruments.electricGuitarInit(3, 2, 4, pan_spread, unison_spread, cab_lpf_hz, cab_hpf_hz),
    };
}

pub fn applyGuitarCue(layer: *GuitarChordLayer, spec: GuitarCueSpec) void {
    layer.guitar.gain = spec.gain;
    layer.guitar.od_amount = spec.od_amount;
    instruments.electricGuitarSetCabinet(3, 2, 4, &layer.guitar, spec.cabinet_lpf_hz, spec.cabinet_hpf_hz);
    layer.retrigger = spec.retrigger;
    layer.attack = spec.attack;
    layer.decay = spec.decay;
    layer.sustain = spec.sustain;
    layer.release = spec.release;
}

pub fn applyGuitarChord(layer: *GuitarChordLayer, key_root: u8, chord: composition.ChordDef) void {
    var freqs: [3]f32 = undefined;
    fillChordFrequencies(3, &freqs, key_root, chord, 0);
    instruments.electricGuitarSetFreqs(3, 2, 4, &layer.guitar, &freqs);
}

pub fn advanceGuitarChordLayer(layer: *GuitarChordLayer, step: u8) void {
    if (step % layer.retrigger != 0) return;
    layer.pending_voice_count = 3;
    layer.strum_countdown = 0;
    if (layer.downstroke) {
        layer.pending_order = .{ 0, 1, 2 };
    } else {
        layer.pending_order = .{ 2, 1, 0 };
    }
    layer.downstroke = !layer.downstroke;
}

pub fn mixGuitarChordLayer(layer: *GuitarChordLayer, level: f32, drive: f32) [2]f32 {
    if (layer.pending_voice_count > 0) {
        if (layer.strum_countdown > 0) {
            layer.strum_countdown -= 1;
        } else {
            const trigger_idx = @as(usize, layer.pending_order[3 - layer.pending_voice_count]);
            const pick_strength = 1.0 - @as(f32, @floatFromInt(3 - layer.pending_voice_count)) * 0.14;
            instruments.electricGuitarTriggerVoice(3, 2, 4, &layer.guitar, trigger_idx, layer.attack, layer.decay, layer.sustain, layer.release, pick_strength);
            layer.pending_voice_count -= 1;
            layer.strum_countdown = layer.strum_interval_samples;
        }
    }
    const out = instruments.electricGuitarProcess(3, 2, 4, &layer.guitar, drive);
    return .{ out[0] * level, out[1] * level };
}

const LeadVoice = dsp.Voice(3, 2);

pub const ProcessedLeadLayer = struct {
    voice: LeadVoice = .{ .unison_spread = 0.005, .filter = dsp.lpfInit(2200.0), .vibrato_rate_hz = 5.6, .vibrato_depth = 0.0038 },
    cab_lpf: dsp.LPF = dsp.lpfInit(5000.0),
    cab_hpf: dsp.HPF = dsp.hpfInit(200.0),
    phrase: composition.PhraseGenerator = .{},
    memory: composition.PhraseMemory = .{},
    density: f32 = 0.5,
    pan: f32 = 0.08,
    recall_chance: f32 = 0.3,
    output_gain: f32 = 0.4,
};

pub const LeadCueSpec = struct {
    density: f32,
    phrase: composition.PhraseConfig,
};

pub const LeadTriggerSpec = struct {
    gate: f32,
    drive: f32,
    micro: f32,
    meso: f32,
    filter_lfo_mod: f32,
};

pub fn resetProcessedLeadLayer(layer: *ProcessedLeadLayer, phrase: composition.PhraseGenerator) void {
    layer.* = .{
        .voice = .{ .unison_spread = 0.005, .filter = dsp.lpfInit(2200.0), .vibrato_rate_hz = 5.6, .vibrato_depth = 0.0038 },
        .phrase = phrase,
    };
}

pub fn applyProcessedLeadCue(layer: *ProcessedLeadLayer, spec: LeadCueSpec) void {
    layer.density = spec.density;
    composition.applyPhraseConfig(spec.phrase, &layer.phrase);
}

pub fn applyProcessedLeadChord(layer: *ProcessedLeadLayer, harmony: *const composition.ChordMarkov, scale_type: composition.ScaleType) void {
    composition.applyChordTonesToPhrases(harmony, scale_type, .{&layer.phrase});
}

pub fn maybeTriggerProcessedLeadLayer(
    layer: *ProcessedLeadLayer,
    step: u8,
    rng: *dsp.Rng,
    key: *const composition.KeyState,
    spec: LeadTriggerSpec,
) void {
    const trigger_chance = composition.leadStepChance(step, layer.density, spec.meso, 0.25);
    if (dsp.rngFloat(rng) >= trigger_chance) return;

    const picked = nextPhraseStep(rng, spec.meso, &layer.phrase, &layer.memory, .{
        .base_rest_chance = layer.phrase.rest_chance,
        .recall_chance = layer.recall_chance,
    }) orelse return;
    const freq = dsp.midiToFreq(composition.keyStateNoteToMidi(key, picked.note));
    const decay = if (picked.recalled)
        0.14 + (1.0 - spec.gate) * 0.2 + spec.meso * 0.1
    else
        0.14 + (1.0 - spec.gate) * 0.2 + spec.micro * 0.1;
    dsp.voiceTrigger(3, 4, &layer.voice, freq, dsp.envelopeInit(0.002, decay, 0.0, 0.08 + spec.gate * 0.08));
    layer.voice.filter = dsp.lpfInit((1800.0 + spec.drive * 3000.0 + spec.meso * 1200.0) * spec.filter_lfo_mod);
}

pub fn mixProcessedLeadLayer(layer: *ProcessedLeadLayer, level: f32, meso: f32, drive: f32) [2]f32 {
    const raw = dsp.voiceProcessRaw(3, 4, &layer.voice);
    if (raw.env_val <= 0.0001) return .{ 0.0, 0.0 };

    var wave = raw.osc;
    wave += @sin(layer.voice.phases[0] * 2.0) * 0.15;
    wave = instruments.overdrive(wave, 1.2 + drive * 2.5 + meso * 0.8);
    wave = dsp.lpfProcess(&layer.voice.filter, wave);
    wave = dsp.hpfProcess(&layer.cab_hpf, wave);
    wave = dsp.lpfProcess(&layer.cab_lpf, wave);

    const stereo = dsp.panStereo(wave * raw.env_val * layer.output_gain * level, layer.pan);
    return stereo;
}

const PadVoice = dsp.Voice(3, 1);
const StabVoice = dsp.Voice(2, 1);

pub const PadChordLayer = struct {
    pub const COUNT = 3;

    pads: [COUNT]PadVoice = .{
        .{ .fm_ratio = 1.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = dsp.lpfInit(1600.0), .pan = -0.55 },
        .{ .fm_ratio = 2.0, .fm_depth = 0.75, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = dsp.lpfInit(1500.0), .pan = 0.0 },
        .{ .fm_ratio = 3.0, .fm_depth = 0.7, .fm_env_depth = 0.4, .unison_spread = 0.005, .filter = dsp.lpfInit(1550.0), .pan = 0.55 },
    },
};

pub fn resetPadChordLayer(layer: *PadChordLayer) void {
    layer.* = .{};
}

pub fn applyPadChord(layer: *PadChordLayer, key_root: u8, chord: composition.ChordDef, filter_mod: f32) [PadChordLayer.COUNT]f32 {
    var freqs: [PadChordLayer.COUNT]f32 = undefined;
    fillChordFrequencies(PadChordLayer.COUNT, &freqs, key_root, chord, 1);
    for (0..PadChordLayer.COUNT) |idx| {
        layer.pads[idx].filter = dsp.lpfInit((1100.0 + filter_mod * 900.0) + @as(f32, @floatFromInt(idx)) * 120.0);
        dsp.voiceTrigger(3, 1, &layer.pads[idx], freqs[idx], dsp.envelopeInit(0.8, 0.5, 0.72, 2.8));
    }
    return freqs;
}

pub fn mixPadChordLayer(layer: *PadChordLayer, level: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..PadChordLayer.COUNT) |idx| {
        const sample = dsp.voiceProcess(3, 1, &layer.pads[idx]) * level;
        const stereo = dsp.panStereo(sample, layer.pads[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

pub const StabChordLayer = struct {
    pub const COUNT = 3;

    voices: [COUNT]StabVoice = .{
        .{ .unison_spread = 0.004, .pan = -0.3 },
        .{ .unison_spread = 0.004, .pan = 0.0 },
        .{ .unison_spread = 0.004, .pan = 0.3 },
    },
    env: dsp.Envelope = dsp.envelopeInit(0.002, 0.08, 0.0, 0.05),
};

pub fn resetStabChordLayer(layer: *StabChordLayer) void {
    layer.* = .{};
}

pub fn applyStabChord(layer: *StabChordLayer, freqs: *const [StabChordLayer.COUNT]f32) void {
    for (0..StabChordLayer.COUNT) |idx| {
        layer.voices[idx].freq = freqs[idx];
    }
}

pub fn maybeTriggerStabChordLayer(layer: *StabChordLayer, step: u8, micro: f32, meso: f32, rng: *dsp.Rng, stab_chance: f32) void {
    const stab_trigger = switch (step) {
        3, 11 => true,
        7, 15 => dsp.rngFloat(rng) < stab_chance * (0.35 + meso * 0.45),
        else => false,
    };
    if (!stab_trigger or dsp.rngFloat(rng) >= stab_chance * (0.55 + meso * 0.55)) return;
    layer.env = dsp.envelopeInit(0.002, 0.05 + micro * 0.06, 0.0, 0.04 + meso * 0.04);
    dsp.envelopeTrigger(&layer.env);
}

pub fn mixStabChordLayer(layer: *StabChordLayer, level: f32) [2]f32 {
    const env_val = dsp.envelopeProcess(&layer.env);
    if (env_val < 0.001) return .{ 0.0, 0.0 };

    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..StabChordLayer.COUNT) |idx| {
        layer.voices[idx].env = .{
            .state = .sustain,
            .level = env_val,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = env_val,
            .release_rate = 0,
        };
        const sample = dsp.voiceProcess(2, 1, &layer.voices[idx]) * 0.08 * level;
        const stereo = dsp.panStereo(sample, layer.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
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
