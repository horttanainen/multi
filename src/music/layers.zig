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
        .hat = rng.float() < composition.subdivisionChance(step, spec.hat_onbeat_chance, spec.hat_offbeat_chance, meso),
    };
}

pub fn applyDrumStep(events: DrumStepEvents, kick: *instruments.Kick, snare: ?*instruments.Snare, hat: ?*instruments.HiHat) void {
    if (events.kick_velocity) |velocity| {
        kick.trigger(velocity);
    }
    if (events.snare != .none and snare == null) {
        std.log.warn("applyDrumStep: snare event {s} without snare instrument", .{@tagName(events.snare)});
    }
    if (events.hat and hat == null) {
        std.log.warn("applyDrumStep: hat event without hat instrument", .{});
    }
    if (events.snare == .backbeat and snare != null) {
        snare.?.trigger();
    }
    if (events.snare == .ghost and snare != null) {
        snare.?.triggerGhost();
    }
    if (events.hat and hat != null) {
        hat.?.trigger();
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
    const note_idx = phrase.advance(rng) orelse {
        bass.env.trigger();
        bass.setFilter((spec.filter_base_hz + micro * spec.filter_micro_hz + meso * spec.filter_meso_hz) * lfo_mod);
        return;
    };
    bass.trigger(dsp.midiToFreq(key.noteToMidi(note_idx)));
    bass.setFilter((spec.filter_base_hz + micro * spec.filter_micro_hz + meso * spec.filter_meso_hz) * lfo_mod);
}

fn phraseStepWithoutMemory(rng: *dsp.Rng, phrase: *composition.PhraseGenerator) ?composition.PhraseNotePick {
    const note = phrase.advance(rng) orelse return null;
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
    const kick_s = layer.kick.process() * level;
    const snare_s = layer.snare.process(rng) * level;
    const hat_s = layer.hat.process(rng) * level;
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
    const sample = layer.bass.process() * level;
    return .{ sample * left_gain, sample * right_gain };
}

const ElectricGuitar3 = instruments.ElectricGuitar(3, 2, 4);

pub const GuitarChordLayer = struct {
    guitar: ElectricGuitar3 = ElectricGuitar3.init(0.35, 0.008, 4500.0, 120.0),
    retrigger: u8 = 4,
    attack: f32 = 0.004,
    decay: f32 = 0.36,
    sustain: f32 = 0.0,
    release: f32 = 0.14,
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
        .guitar = ElectricGuitar3.init(pan_spread, unison_spread, cab_lpf_hz, cab_hpf_hz),
    };
}

pub fn applyGuitarCue(layer: *GuitarChordLayer, spec: GuitarCueSpec) void {
    layer.guitar.gain = spec.gain;
    layer.guitar.od_amount = spec.od_amount;
    layer.guitar.setCabinet(spec.cabinet_lpf_hz, spec.cabinet_hpf_hz);
    layer.retrigger = spec.retrigger;
    layer.attack = spec.attack;
    layer.decay = spec.decay;
    layer.sustain = spec.sustain;
    layer.release = spec.release;
}

pub fn applyGuitarChord(layer: *GuitarChordLayer, key_root: u8, chord: composition.ChordDef) void {
    var freqs: [3]f32 = undefined;
    fillChordFrequencies(3, &freqs, key_root, chord, 0);
    layer.guitar.setFreqs(&freqs);
}

pub fn advanceGuitarChordLayer(layer: *GuitarChordLayer, step: u8) void {
    if (step % layer.retrigger != 0) return;
    layer.guitar.triggerEnv(layer.attack, layer.decay, layer.sustain, layer.release);
}

pub fn mixGuitarChordLayer(layer: *GuitarChordLayer, level: f32, drive: f32) [2]f32 {
    const out = layer.guitar.process(drive);
    return .{ out[0] * level, out[1] * level };
}

const LeadVoice = dsp.Voice(3, 2);

pub const ProcessedLeadLayer = struct {
    voice: LeadVoice = .{ .unison_spread = 0.005, .filter = dsp.LPF.init(2200.0) },
    cab_lpf: dsp.LPF = dsp.LPF.init(5000.0),
    cab_hpf: dsp.HPF = dsp.HPF.init(200.0),
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
    if (rng.float() >= trigger_chance) return;

    const picked = nextPhraseStep(rng, spec.meso, &layer.phrase, &layer.memory, .{
        .base_rest_chance = layer.phrase.rest_chance,
        .recall_chance = layer.recall_chance,
    }) orelse return;
    const freq = dsp.midiToFreq(key.noteToMidi(picked.note));
    const decay = if (picked.recalled)
        0.14 + (1.0 - spec.gate) * 0.2 + spec.meso * 0.1
    else
        0.14 + (1.0 - spec.gate) * 0.2 + spec.micro * 0.1;
    layer.voice.trigger(freq, dsp.Envelope.init(0.002, decay, 0.0, 0.08 + spec.gate * 0.08));
    layer.voice.filter = dsp.LPF.init((1800.0 + spec.drive * 3000.0 + spec.meso * 1200.0) * spec.filter_lfo_mod);
}

pub fn mixProcessedLeadLayer(layer: *ProcessedLeadLayer, level: f32, meso: f32, drive: f32) [2]f32 {
    const raw = layer.voice.processRaw();
    if (raw.env_val <= 0.0001) return .{ 0.0, 0.0 };

    var wave = raw.osc;
    wave += @sin(layer.voice.phases[0] * 2.0) * 0.15;
    wave = instruments.overdrive(wave, 1.2 + drive * 2.5 + meso * 0.8);
    wave = layer.voice.filter.process(wave);
    wave = layer.cab_hpf.process(wave);
    wave = layer.cab_lpf.process(wave);

    const stereo = dsp.panStereo(wave * raw.env_val * layer.output_gain * level, layer.pan);
    return stereo;
}
