// Procedural monastic choir style — v2 composition engine.
//
// Uses chord progression, multi-scale arcs, chant motif memory, macro key
// movement, and cue-specific timing so the presets diverge both harmonically
// and behaviorally over time.
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");

const StereoReverb = dsp.StereoReverb;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;
const panStereo = dsp.panStereo;

pub const CuePreset = enum(u8) {
    cathedral,
    procession,
    vigil,
    crusade,
};

pub var bpm: f32 = 44.0;
pub var reverb_mix: f32 = 0.72;
pub var choir_vol: f32 = 0.15;
pub var breathiness: f32 = 0.3;
pub var drone_mix: f32 = 0.55;
pub var chant_mix: f32 = 0.58;
pub var selected_cue: CuePreset = .cathedral;

const ChoirReverb = StereoReverb(.{ 2039, 1877, 1733, 1601 }, .{ 307, 709 });
var reverb: ChoirReverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
var rng: dsp.Rng = dsp.Rng.init(0x4300_9000);

var engine: composition.CompositionEngine = .{};

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 10 }, .len = 4 };
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 15 }, .len = 4 };
    h.chords[2] = .{ .offsets = .{ 5, 8, 12, 15 }, .len = 4 };
    h.chords[3] = .{ .offsets = .{ 7, 10, 14, 17 }, .len = 4 };
    h.chords[4] = .{ .offsets = .{ 10, 14, 17, 22 }, .len = 4 };
    h.num_chords = 5;
    h.transitions[0] = .{ 0.10, 0.18, 0.28, 0.16, 0.28, 0, 0, 0 };
    h.transitions[1] = .{ 0.26, 0.10, 0.24, 0.10, 0.30, 0, 0, 0 };
    h.transitions[2] = .{ 0.28, 0.14, 0.10, 0.22, 0.26, 0, 0, 0 };
    h.transitions[3] = .{ 0.24, 0.14, 0.20, 0.10, 0.32, 0, 0, 0 };
    h.transitions[4] = .{ 0.34, 0.12, 0.18, 0.14, 0.22, 0, 0, 0 };
    return h;
}

const CHOIR_ARCS: composition.ArcSystem = .{
    .micro = .{ .section_beats = 16, .shape = .rise_fall },
    .meso = .{ .section_beats = 64, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};
var lfo_reverb: composition.SlowLfo = .{ .period_beats = 180, .depth = 0.04 };

var drone_target: f32 = 0.9;
var pad_target: f32 = 0.75;
var chant_target: f32 = 0.2;
var breath_target: f32 = 0.35;

var drone_level: f32 = 0.8;
var pad_level: f32 = 0.5;
var chant_level: f32 = 0.0;
var breath_level: f32 = 0.25;

const LAYER_FADE_RATE: f32 = 0.000025;

const ChoirPart = instruments.ChoirPart;
const PAD_COUNT = 3;
var pad_parts: [PAD_COUNT]ChoirPart = .{
    ChoirPart.init(0.006, -0.35, 0),
    ChoirPart.init(0.006, 0.0, 1),
    ChoirPart.init(0.006, 0.35, 2),
};
var chant_part: ChoirPart = ChoirPart.init(0.004, 0.08, 1);

var chant_phrase: composition.PhraseGenerator = .{
    .anchor = 12,
    .region_low = 9,
    .region_high = 16,
    .rest_chance = 0.18,
    .min_notes = 4,
    .max_notes = 8,
    .gravity = 3.5,
};
var chant_memory: composition.PhraseMemory = .{};

var drone: instruments.SineDrone = instruments.SineDrone.init(midiToFreq(36), 180.0, 1.0016, 0.78, 0.32, 0.32);
var breath_lpf: dsp.LPF = dsp.LPF.init(1200.0);
var shimmer_lpf: dsp.LPF = dsp.LPF.init(3400.0);

var chant_beat_counter: f32 = 0.0;

var cue_reverb_boost: f32 = 0.0;
var cue_breath_boost: f32 = 0.0;
var cue_chant_recall_chance: f32 = 0.3;
var cue_chant_threshold: f32 = 0.35;
var cue_chord_change_beats: f32 = 16.0;
var cue_chant_beat_len: f32 = 2.0;
var cue_pad_attack: f32 = 1.4;
var cue_pad_release: f32 = 5.8;
var cue_chant_attack: f32 = 0.18;
var cue_chant_release: f32 = 1.6;

pub fn reset() void {
    reverb = ChoirReverb.init(.{ 0.93, 0.94, 0.93, 0.92 });
    rng = dsp.Rng.init(0x4300_9000 + @as(u32, @intFromEnum(selected_cue)) * 23);
    engine.reset(.{ .root = 38, .scale_type = .natural_minor }, initHarmony(), CHOIR_ARCS, 16.0, .none);
    lfo_reverb = .{ .period_beats = 180, .depth = 0.04 };
    drone_target = 0.9;
    pad_target = 0.75;
    chant_target = 0.2;
    breath_target = 0.35;
    drone_level = 0.8;
    pad_level = 0.5;
    chant_level = 0.0;
    breath_level = 0.25;
    pad_parts = .{
        ChoirPart.init(0.006, -0.35, 0),
        ChoirPart.init(0.006, 0.0, 1),
        ChoirPart.init(0.006, 0.35, 2),
    };
    chant_part = ChoirPart.init(0.004, 0.08, 1);
    chant_phrase = .{
        .anchor = 12,
        .region_low = 9,
        .region_high = 16,
        .rest_chance = 0.18,
        .min_notes = 4,
        .max_notes = 8,
        .gravity = 3.5,
    };
    chant_memory = .{};
    drone = instruments.SineDrone.init(midiToFreq(36), 180.0, 1.0016, 0.78, 0.32, 0.32);
    breath_lpf = dsp.LPF.init(1200.0);
    shimmer_lpf = dsp.LPF.init(3400.0);
    chant_beat_counter = 0.0;
    applyCueParams();
    advanceChord();
}

pub fn triggerCue() void {
    applyCueParams();
    advanceChord();
    chant_beat_counter = 0.0;
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = dsp.samplesPerBeat(bpm);

    for (0..frames) |i| {
        lfo_reverb.advanceSample(bpm);
        engine.chord_change_beats = cue_chord_change_beats;
        const tick = engine.advanceSample(&rng, bpm);
        if (tick.chord_changed) {
            advanceChord();
        }

        chant_beat_counter += 1.0 / spb;
        if (chant_beat_counter >= cue_chant_beat_len) {
            chant_beat_counter -= cue_chant_beat_len;
            triggerChantNote(tick.meso, tick.micro);
        }

        updateLayerTargets(tick.macro);
        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        chant_level += (chant_target - chant_level) * LAYER_FADE_RATE;
        breath_level += (breath_target - breath_level) * LAYER_FADE_RATE;

        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const drone_sample = drone.process() * drone_mix * choir_vol * drone_level;
        left += drone_sample * 0.9;
        right += drone_sample * 0.9;

        for (0..PAD_COUNT) |idx| {
            const sample = pad_parts[idx].process() * choir_vol * pad_level;
            const stereo = panStereo(sample, pad_parts[idx].pan);
            left += stereo[0];
            right += stereo[1];
        }

        const chant_sample = chant_part.process() * choir_vol * chant_mix * chant_level;
        const chant_stereo = panStereo(chant_sample, chant_part.pan);
        left += chant_stereo[0];
        right += chant_stereo[1];

        const breath = processBreath(tick.meso) * breath_level;
        left += breath;
        right += breath;

        const wet = (reverb_mix + cue_reverb_boost) * lfo_reverb.modulate();
        const dry = 1.0 - wet;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * wet;
        right = right * dry + rev[1] * wet;

        buf[i * 2] = softClip(left * 0.88);
        buf[i * 2 + 1] = softClip(right * 0.88);
    }
}

fn applyCueParams() void {
    switch (selected_cue) {
        .cathedral => {
            engine.key.root = 38;
            engine.key.target_root = 38;
            cue_reverb_boost = 0.08;
            cue_breath_boost = 0.05;
            cue_chant_recall_chance = 0.28;
            cue_chant_threshold = 0.25;
            cue_chord_change_beats = 18.0;
            cue_chant_beat_len = 2.5;
            cue_pad_attack = 2.0;
            cue_pad_release = 7.5;
            cue_chant_attack = 0.22;
            cue_chant_release = 2.1;
            chant_phrase.rest_chance = 0.24;
            chant_phrase.region_low = 9;
            chant_phrase.region_high = 15;
            chant_phrase.min_notes = 4;
            chant_phrase.max_notes = 7;
            drone.filter = dsp.LPF.init(160.0);
            drone.detune_ratio = 1.0012;
        },
        .procession => {
            engine.key.root = 40;
            engine.key.target_root = 40;
            cue_reverb_boost = 0.02;
            cue_breath_boost = 0.0;
            cue_chant_recall_chance = 0.22;
            cue_chant_threshold = 0.12;
            cue_chord_change_beats = 12.0;
            cue_chant_beat_len = 1.5;
            cue_pad_attack = 1.0;
            cue_pad_release = 4.5;
            cue_chant_attack = 0.12;
            cue_chant_release = 1.2;
            chant_phrase.rest_chance = 0.14;
            chant_phrase.region_low = 10;
            chant_phrase.region_high = 17;
            chant_phrase.min_notes = 5;
            chant_phrase.max_notes = 8;
            drone.filter = dsp.LPF.init(220.0);
            drone.detune_ratio = 1.0018;
        },
        .vigil => {
            engine.key.root = 36;
            engine.key.target_root = 36;
            cue_reverb_boost = 0.12;
            cue_breath_boost = 0.12;
            cue_chant_recall_chance = 0.4;
            cue_chant_threshold = 0.5;
            cue_chord_change_beats = 22.0;
            cue_chant_beat_len = 3.5;
            cue_pad_attack = 2.6;
            cue_pad_release = 8.5;
            cue_chant_attack = 0.28;
            cue_chant_release = 2.6;
            chant_phrase.rest_chance = 0.36;
            chant_phrase.region_low = 8;
            chant_phrase.region_high = 13;
            chant_phrase.min_notes = 3;
            chant_phrase.max_notes = 5;
            drone.filter = dsp.LPF.init(130.0);
            drone.detune_ratio = 1.0009;
        },
        .crusade => {
            engine.key.root = 41;
            engine.key.target_root = 41;
            cue_reverb_boost = 0.0;
            cue_breath_boost = -0.05;
            cue_chant_recall_chance = 0.18;
            cue_chant_threshold = 0.08;
            cue_chord_change_beats = 10.0;
            cue_chant_beat_len = 1.0;
            cue_pad_attack = 0.8;
            cue_pad_release = 3.6;
            cue_chant_attack = 0.08;
            cue_chant_release = 0.95;
            chant_phrase.rest_chance = 0.08;
            chant_phrase.region_low = 11;
            chant_phrase.region_high = 18;
            chant_phrase.min_notes = 5;
            chant_phrase.max_notes = 9;
            drone.filter = dsp.LPF.init(240.0);
            drone.detune_ratio = 1.0021;
        },
    }
    engine.key.scale_type = switch (selected_cue) {
        .cathedral => .dorian,
        .procession => .mixolydian,
        .vigil => .harmonic_minor,
        .crusade => .natural_minor,
    };
    engine.modulation_mode = if (selected_cue == .crusade) .fourth else .none;
}

fn advanceChord() void {
    const chord = engine.harmony.chords[engine.harmony.current];
    for (0..PAD_COUNT) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        pad_parts[idx].voice.freq = midiToFreq(engine.key.root + offset);
        pad_parts[idx].trigger(pad_parts[idx].voice.freq, dsp.Envelope.init(cue_pad_attack, 1.4, 0.76, cue_pad_release));
        pad_parts[idx].setVowel(@intCast((@intFromEnum(selected_cue) + idx + engine.harmony.current) % 4));
    }

    const degrees = engine.harmony.chordScaleDegrees(engine.key.scale_type);
    chant_phrase.setChordTones(degrees.tones[0..degrees.count]);
    drone.freq = midiToFreq(engine.key.root + chord.offsets[0] - 12);
    chant_part.setVowel(@intCast((@intFromEnum(selected_cue) + engine.harmony.current) % 4));
}

fn triggerChantNote(meso: f32, micro: f32) void {
    if (chant_level < 0.05) return;

    chant_phrase.rest_chance = chant_phrase.rest_chance * (1.15 - meso * 0.18);

    if (chant_memory.count > 0 and rng.float() < cue_chant_recall_chance) {
        var varied_notes: [composition.PhraseGenerator.MAX_LEN]u8 = undefined;
        if (chant_memory.recallVaried(&rng, &varied_notes, chant_phrase.region_low, chant_phrase.region_high)) |varied_len| {
            if (varied_len > 0 and varied_notes[0] != 0xFF) {
                const freq = midiToFreq(engine.key.noteToMidi(varied_notes[0]));
                chant_part.trigger(freq, dsp.Envelope.init(cue_chant_attack, 0.6 + micro * 0.4, 0.55, cue_chant_release));
                return;
            }
        }
    }

    if (chant_phrase.advance(&rng)) |note_idx| {
        const freq = midiToFreq(engine.key.noteToMidi(note_idx));
        chant_part.trigger(freq, dsp.Envelope.init(cue_chant_attack, 0.5 + meso * 0.35, 0.55, cue_chant_release));
        if (chant_phrase.pos == 0 and chant_phrase.len > 0) {
            chant_memory.store(&chant_phrase.notes, chant_phrase.len);
        }
    }
}

fn updateLayerTargets(macro: f32) void {
    drone_target = 0.65 + macro * 0.35;
    pad_target = 0.3 + macro * 0.7;
    chant_target = if (macro > cue_chant_threshold) @min((macro - cue_chant_threshold) * 1.25, 0.95) else 0.0;
    breath_target = 0.18 + (1.0 - macro) * 0.35;
}

fn processBreath(meso: f32) f32 {
    if (breathiness <= 0.001) return 0.0;

    const breath_mod = (breathiness + cue_breath_boost) * (1.0 - meso * 0.25);
    const noise = rng.float() * 2.0 - 1.0;
    const base = breath_lpf.process(noise);
    const shimmer = shimmer_lpf.process(noise * 0.35);
    return (base * 0.015 + shimmer * 0.006) * breath_mod;
}
