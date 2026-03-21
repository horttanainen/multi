// Procedural 80s rock style — v2 composition engine.
//
// Markov chord progressions, multi-scale arcs, phrase-generated lead
// with motif memory, chord-tone gravity, key modulation by 5ths,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter flavors (arena/night_drive/power_ballad/combat).
// Uses shared engine instruments: ElectricGuitar, SawBass, Kick, Snare, HiHat.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const composition = @import("music/composition.zig");

const Envelope = dsp.Envelope;
const LPF = dsp.LPF;
const HPF = dsp.HPF;
const StereoReverb = dsp.StereoReverb;
const midiToFreq = dsp.midiToFreq;
const softClip = dsp.softClip;
const panStereo = dsp.panStereo;
const TAU = dsp.TAU;
const INV_SR = dsp.INV_SR;
const SAMPLE_RATE = dsp.SAMPLE_RATE;

// ============================================================
// Tweakable parameters (written by musicConfigMenu / settings)
// ============================================================

pub const CuePreset = enum(u8) {
    arena,
    night_drive,
    power_ballad,
    combat,
};

pub var bpm: f32 = 112.0;
pub var reverb_mix: f32 = 0.35;
pub var lead_mix: f32 = 0.5;
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
const KICK_MAIN_MASK: u16 = (1 << 0) | (1 << 8);
const SNARE_BACKBEAT_MASK: u16 = (1 << 4) | (1 << 12);
const ROCK_LAYER_CURVES: [4]composition.LayerCurve = .{
    .{ .offset = 0.85, .slope = 0.15, .max = 1.0 },
    .{ .offset = 0.8, .slope = 0.2, .max = 1.0 },
    .{ .offset = 0.3, .slope = 0.7, .max = 1.0 },
    .{ .start = 0.25, .offset = 0.0, .slope = 1.6, .max = 1.0 },
};

const LAYER_FADE_RATE: f32 = 0.00005;

// ============================================================
// Phrase memory for lead motif development
// ============================================================

var lead_memory: composition.PhraseMemory = .{};

// ============================================================
// Instruments
// ============================================================

// Drums
var kick: instruments.Kick = .{};
var snare: instruments.Snare = .{};
var hat: instruments.HiHat = .{};

// Bass
var bass: instruments.SawBass = .{ .drive = 0.55 };
var bass_phrase: composition.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 6,
    .rest_chance = 0.05,
    .min_notes = 3,
    .max_notes = 6,
    .gravity = 3.0,
};

// Guitar chords: 3 voices × Voice(2, 4) through overdrive + cabinet
const RockGuitar = instruments.ElectricGuitar(3, 2, 4);
var guitar: RockGuitar = RockGuitar.init(0.35, 0.008, 4500.0, 120.0);

// Lead guitar: Voice(3, 2) with its own overdrive + cabinet
const LeadVoice = dsp.Voice(3, 2);
var lead_voice: LeadVoice = .{
    .unison_spread = 0.005,
    .filter = LPF.init(2200.0),
};
var lead_cab_lpf: LPF = LPF.init(5000.0);
var lead_cab_hpf: HPF = HPF.init(200.0);
var lead_phrase: composition.PhraseGenerator = .{
    .anchor = 10,
    .region_low = 7,
    .region_high = 17,
    .rest_chance = 0.15,
    .min_notes = 4,
    .max_notes = 8,
    .gravity = 3.0,
};

// ============================================================
// Sequencer state
// ============================================================

var beat_number: u32 = 0;
const CHORD_CHANGE_BEATS: f32 = 8.0;
const RockCueSpec = struct {
    extra_kick_density: f32,
    hat_density: f32,
    lead_density: f32,
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
        .extra_kick_density = 0.35,
        .hat_density = 0.6,
        .lead_density = 0.65,
        .energy = 0.7,
        .reverb_boost = 0.1,
        .snare_ghost = 0.15,
        .chord_retrigger = 4,
        .chord_attack = 0.003,
        .chord_decay = 0.5,
        .chord_sustain = 0.3,
        .chord_release = 0.2,
        .guitar_gain = 1.3,
        .guitar_od_amount = 3.0,
        .cabinet_lpf_hz = 5000.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.12, .region_low = 7, .region_high = 17 },
    },
    .{
        .extra_kick_density = 0.1,
        .hat_density = 0.75,
        .lead_density = 0.3,
        .energy = 0.35,
        .reverb_boost = 0.2,
        .snare_ghost = 0.05,
        .chord_retrigger = 8,
        .chord_attack = 0.02,
        .chord_decay = 0.8,
        .chord_sustain = 0.5,
        .chord_release = 0.4,
        .guitar_gain = 0.8,
        .guitar_od_amount = 1.8,
        .cabinet_lpf_hz = 3000.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.4, .region_low = 9, .region_high = 15 },
    },
    .{
        .extra_kick_density = 0.05,
        .hat_density = 0.15,
        .lead_density = 0.25,
        .energy = 0.2,
        .reverb_boost = 0.15,
        .snare_ghost = 0.0,
        .chord_retrigger = 8,
        .chord_attack = 0.03,
        .chord_decay = 1.2,
        .chord_sustain = 0.6,
        .chord_release = 0.6,
        .guitar_gain = 0.6,
        .guitar_od_amount = 1.2,
        .cabinet_lpf_hz = 2500.0,
        .cabinet_hpf_hz = 120.0,
        .lead_phrase = .{ .rest_chance = 0.45, .region_low = 8, .region_high = 14 },
    },
    .{
        .extra_kick_density = 0.7,
        .hat_density = 0.95,
        .lead_density = 0.85,
        .energy = 0.95,
        .reverb_boost = 0.0,
        .snare_ghost = 0.25,
        .chord_retrigger = 2,
        .chord_attack = 0.001,
        .chord_decay = 0.06,
        .chord_sustain = 0.0,
        .chord_release = 0.03,
        .guitar_gain = 1.8,
        .guitar_od_amount = 4.5,
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

// Cue-derived parameters
var cue_extra_kick_density: f32 = 0.0;
var cue_hat_density: f32 = 0.5;
var cue_lead_density: f32 = 0.5;
var cue_energy: f32 = 0.5;
var cue_reverb_boost: f32 = 0.0;
var cue_snare_ghost: f32 = 0.0;
var cue_chord_retrigger: u8 = 4;
var cue_chord_attack: f32 = 0.004;
var cue_chord_decay: f32 = 0.36;
var cue_chord_sustain: f32 = 0.0;
var cue_chord_release: f32 = 0.14;

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
    lead_memory = .{};
    beat_number = 0;

    kick = .{};
    snare = .{};
    hat = .{};

    bass = .{ .drive = 0.55 };
    bass_phrase = .{ .anchor = 0, .region_low = 0, .region_high = 6, .rest_chance = 0.05, .min_notes = 3, .max_notes = 6, .gravity = 3.0 };

    guitar = RockGuitar.init(0.35, 0.008, 4500.0, 120.0);

    lead_voice = .{ .unison_spread = 0.005, .filter = LPF.init(2200.0) };
    lead_cab_lpf = LPF.init(5000.0);
    lead_cab_hpf = HPF.init(200.0);
    lead_phrase = .{ .anchor = 10, .region_low = 7, .region_high = 17, .rest_chance = 0.15, .min_notes = 4, .max_notes = 8, .gravity = 3.0 };

    reverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
    runner.reset(&STYLE, .{ .root = 40, .scale_type = .mixolydian }, initHarmony(), CHORD_CHANGE_BEATS, .fifth, .{ 1.0, 1.0, 0.8, 0.3 }, .{ 1.0, 0.8, 0.5, 0.0 });
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    for (0..frames) |i| {
        const frame = runner.advanceFrame(&rng, &STYLE, bpm, LAYER_FADE_RATE);
        lfo_filter.advanceSample(bpm);
        lfo_drive.advanceSample(bpm);

        if (frame.tick.chord_changed) {
            advanceChord();
        }

        if (frame.step) |step| {
            advanceStep(step, frame.tick.meso, frame.tick.micro);
        }

        // ---- Mix ----
        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const d_level = drum_mix * runner.layer_levels[DRUM_LAYER];
        const kick_s = kick.process() * d_level;
        left += kick_s * 0.85;
        right += kick_s * 0.85;

        const snare_s = snare.process(&rng) * d_level;
        left += snare_s * 0.72;
        right += snare_s * 0.72;

        const hat_s = hat.process(&rng) * d_level;
        left += hat_s * 0.42;
        right += hat_s * 0.52;

        const bass_s = bass.process() * bass_mix * runner.layer_levels[BASS_LAYER];
        left += bass_s * 0.85;
        right += bass_s * 0.8;

        const eff_drive = drive * lfo_drive.modulate() + cue_energy * 0.2;
        const guitar_out = guitar.process(eff_drive);
        left += guitar_out[0] * runner.layer_levels[CHORD_LAYER];
        right += guitar_out[1] * runner.layer_levels[CHORD_LAYER];

        const lead_s = processLead(frame.tick.meso, eff_drive) * lead_mix * runner.layer_levels[LEAD_LAYER];
        const lead_stereo = panStereo(lead_s, 0.08);
        left += lead_stereo[0];
        right += lead_stereo[1];

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
    runner.engine.key.root = 40;
    runner.engine.key.target_root = 40;
    runner.engine.key.scale_type = .mixolydian;
    runner.engine.chord_change_beats = CHORD_CHANGE_BEATS;
    runner.engine.modulation_mode = .fifth;
    cue_extra_kick_density = spec.extra_kick_density;
    cue_hat_density = spec.hat_density;
    cue_lead_density = spec.lead_density;
    cue_energy = spec.energy;
    cue_reverb_boost = spec.reverb_boost;
    cue_snare_ghost = spec.snare_ghost;
    cue_chord_retrigger = spec.chord_retrigger;
    cue_chord_attack = spec.chord_attack;
    cue_chord_decay = spec.chord_decay;
    cue_chord_sustain = spec.chord_sustain;
    cue_chord_release = spec.chord_release;
    guitar.gain = spec.guitar_gain;
    guitar.od_amount = spec.guitar_od_amount;
    guitar.setCabinet(spec.cabinet_lpf_hz, spec.cabinet_hpf_hz);
    composition.applyPhraseConfig(spec.lead_phrase, &lead_phrase);
}

// ============================================================
// Chord progression
// ============================================================

fn advanceChord() void {
    const chord = runner.engine.harmony.chords[runner.engine.harmony.current];
    var freqs: [3]f32 = undefined;
    for (0..3) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        freqs[idx] = midiToFreq(runner.engine.key.root + offset);
    }
    guitar.setFreqs(&freqs);

    composition.applyChordTonesToPhrases(&runner.engine.harmony, runner.engine.key.scale_type, .{ &lead_phrase, &bass_phrase });

    bass.freq = midiToFreq(runner.engine.key.root + chord.offsets[0]);
}

// ============================================================
// Sequencer (16th note grid)
// ============================================================

fn advanceStep(step: u8, meso: f32, micro: f32) void {
    beat_number += 1;

    if (composition.kickVelocity(step, KICK_MAIN_MASK, ~KICK_MAIN_MASK, 0.7, &rng, cue_extra_kick_density, meso)) |velocity| {
        kick.trigger(velocity);
    }

    switch (composition.snareBackbeatOrGhost(step, SNARE_BACKBEAT_MASK, &rng, cue_snare_ghost, meso)) {
        .backbeat => snare.trigger(),
        .ghost => snare.triggerGhost(),
        .none => {},
    }

    const hat_chance = composition.subdivisionChance(step, 0.9, cue_hat_density, meso);
    if (rng.float() < hat_chance) {
        hat.trigger();
    }

    if (step % 2 == 0) {
        if (bass_phrase.advance(&rng)) |note_idx| {
            bass.trigger(midiToFreq(runner.engine.key.noteToMidi(note_idx)));
        } else {
            bass.env.trigger();
        }
        const filter_mod = lfo_filter.modulate();
        bass.setFilter((380.0 + drive * 900.0 + cue_energy * 400.0) * filter_mod);
    }

    if (step % cue_chord_retrigger == 0) {
        guitar.triggerEnv(cue_chord_attack, cue_chord_decay, cue_chord_sustain, cue_chord_release);
    }

    const lead_trigger_chance = composition.leadStepChance(step, cue_lead_density, meso, 0.25);
    if (rng.float() < lead_trigger_chance) {
        triggerLeadNote(meso, micro);
    }
}

fn triggerLeadNote(meso: f32, micro: f32) void {
    const picked = composition.nextPhraseNoteWithMemory(&rng, &lead_phrase, &lead_memory, 0.3) orelse return;
    const freq = midiToFreq(runner.engine.key.noteToMidi(picked.note));
    const env_decay = if (picked.recalled)
        0.14 + (1.0 - gate) * 0.2 + meso * 0.1
    else
        0.14 + (1.0 - gate) * 0.2 + micro * 0.1;
    lead_voice.trigger(freq, Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08));
    lead_voice.filter = LPF.init((1800.0 + drive * 3000.0 + meso * 1200.0) * lfo_filter.modulate());
}

// ============================================================
// Vertical layer activation
// ============================================================

// ============================================================
// Lead DSP (uses overdrive + cabinet like guitar)
// ============================================================

fn processLead(meso: f32, eff_drive: f32) f32 {
    const raw = lead_voice.processRaw();
    if (raw.env_val <= 0.0001) return 0.0;

    var wave = raw.osc;
    wave += @sin(lead_voice.phases[0] * 2.0) * 0.15;
    wave = instruments.overdrive(wave, 1.2 + eff_drive * 2.5 + meso * 0.8);
    wave = lead_voice.filter.process(wave);
    wave = lead_cab_hpf.process(wave);
    wave = lead_cab_lpf.process(wave);

    return wave * raw.env_val * 0.4;
}
