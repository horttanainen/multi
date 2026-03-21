// Procedural 80s rock style — v2 composition engine.
//
// Markov chord progressions, multi-scale arcs, phrase-generated lead
// with motif memory, chord-tone gravity, key modulation by 5ths,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter flavors (arena/night_drive/power_ballad/combat).
// Uses shared engine instruments: ElectricGuitar, SawBass, Kick, Snare, HiHat.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const HPF = synth.HPF;
const StereoReverb = synth.StereoReverb;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

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
var rng: synth.Rng = synth.Rng.init(0x80F0);

// ============================================================
// Key state & Markov chord progression
// ============================================================

var key: synth.KeyState = .{ .root = 40, .scale_type = .mixolydian };

var harmony: synth.ChordMarkov = initHarmony();

fn initHarmony() synth.ChordMarkov {
    var h: synth.ChordMarkov = .{};
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
// Multi-scale arc system
// ============================================================

var arcs: synth.ArcSystem = .{
    .micro = .{ .section_beats = 4, .shape = .rise_fall },
    .meso = .{ .section_beats = 32, .shape = .rise_fall },
    .macro = .{ .section_beats = 128, .shape = .rise_fall },
};

// ============================================================
// Slow LFOs
// ============================================================

var lfo_filter: synth.SlowLfo = .{ .period_beats = 64, .depth = 0.06 };
var lfo_drive: synth.SlowLfo = .{ .period_beats = 96, .depth = 0.04 };

// ============================================================
// Layer volumes (vertical activation)
// ============================================================

var drum_target: f32 = 1.0;
var bass_target: f32 = 1.0;
var chord_target: f32 = 0.8;
var lead_target: f32 = 0.3;

var drum_level: f32 = 1.0;
var bass_level: f32 = 0.8;
var chord_level: f32 = 0.5;
var lead_level: f32 = 0.0;

const LAYER_FADE_RATE: f32 = 0.00005;

// ============================================================
// Phrase memory for lead motif development
// ============================================================

var lead_memory: synth.PhraseMemory = .{};

// ============================================================
// Instruments (shared engine types from synth.zig)
// ============================================================

// Drums
var kick: synth.Kick = .{};
var snare: synth.Snare = .{};
var hat: synth.HiHat = .{};

// Bass
var bass: synth.SawBass = .{ .drive = 0.55 };
var bass_phrase: synth.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 6,
    .rest_chance = 0.05,
    .min_notes = 3,
    .max_notes = 6,
    .gravity = 3.0,
};

// Guitar chords: 3 voices × Voice(2, 4) through overdrive + cabinet
const RockGuitar = synth.ElectricGuitar(3, 2, 4);
var guitar: RockGuitar = RockGuitar.init(0.35, 0.008, 4500.0, 120.0);

// Lead guitar: Voice(3, 2) with its own overdrive + cabinet
const LeadVoice = synth.Voice(3, 2);
var lead_voice: LeadVoice = .{
    .unison_spread = 0.005,
    .filter = LPF.init(2200.0),
};
var lead_cab_lpf: LPF = LPF.init(5000.0);
var lead_cab_hpf: HPF = HPF.init(200.0);
var lead_phrase: synth.PhraseGenerator = .{
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

var step_counter: f32 = 0.0;
var bar_step: u8 = 0;
var beat_number: u32 = 0;
var chord_beat_counter: f32 = 0;
const CHORD_CHANGE_BEATS: f32 = 8.0;
var last_macro_quarter: u8 = 0;

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
    rng = synth.Rng.init(@as(u32, 0x80F0_0000) + @as(u32, @intFromEnum(selected_cue)) * 17);

    key = .{ .root = 40, .scale_type = .mixolydian };
    harmony = initHarmony();
    arcs = .{
        .micro = .{ .section_beats = 4, .shape = .rise_fall },
        .meso = .{ .section_beats = 32, .shape = .rise_fall },
        .macro = .{ .section_beats = 128, .shape = .rise_fall },
    };
    lfo_filter = .{ .period_beats = 64, .depth = 0.06 };
    lfo_drive = .{ .period_beats = 96, .depth = 0.04 };
    lead_memory = .{};

    drum_target = 1.0;
    bass_target = 1.0;
    chord_target = 0.8;
    lead_target = 0.3;
    drum_level = 1.0;
    bass_level = 0.8;
    chord_level = 0.5;
    lead_level = 0.0;

    step_counter = 0.0;
    bar_step = 0;
    beat_number = 0;
    chord_beat_counter = 0;
    last_macro_quarter = 0;

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
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm / 4.0;
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        arcs.advanceSample(bpm);
        key.advanceSample();
        lfo_filter.advanceSample(bpm);
        lfo_drive.advanceSample(bpm);

        const meso = arcs.meso.tension();
        const macro = arcs.macro.tension();
        const micro = arcs.micro.tension();

        chord_beat_counter += 1.0 / spb;
        if (chord_beat_counter >= CHORD_CHANGE_BEATS) {
            chord_beat_counter -= CHORD_CHANGE_BEATS;
            advanceChord();
        }

        const macro_quarter: u8 = @intFromFloat(arcs.macro.beat_count / arcs.macro.section_beats * 4.0);
        if (macro_quarter != last_macro_quarter) {
            last_macro_quarter = macro_quarter;
            if (macro_quarter == 0) {
                key.modulateByFifth();
            }
        }

        updateLayerTargets(macro);
        drum_level += (drum_target - drum_level) * LAYER_FADE_RATE;
        bass_level += (bass_target - bass_level) * LAYER_FADE_RATE;
        chord_level += (chord_target - chord_level) * LAYER_FADE_RATE;
        lead_level += (lead_target - lead_level) * LAYER_FADE_RATE;

        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep(meso, micro);
        }

        // ---- Mix ----
        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const d_level = drum_mix * drum_level;
        const kick_s = kick.process() * d_level;
        left += kick_s * 0.85;
        right += kick_s * 0.85;

        const snare_s = snare.process(&rng) * d_level;
        left += snare_s * 0.72;
        right += snare_s * 0.72;

        const hat_s = hat.process(&rng) * d_level;
        left += hat_s * 0.42;
        right += hat_s * 0.52;

        const bass_s = bass.process() * bass_mix * bass_level;
        left += bass_s * 0.85;
        right += bass_s * 0.8;

        const eff_drive = drive * lfo_drive.modulate() + cue_energy * 0.2;
        const guitar_out = guitar.process(eff_drive);
        left += guitar_out[0] * chord_level;
        right += guitar_out[1] * chord_level;

        const lead_s = processLead(meso, eff_drive) * lead_mix * lead_level;
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
    switch (selected_cue) {
        .arena => {
            cue_extra_kick_density = 0.35;
            cue_hat_density = 0.6;
            cue_lead_density = 0.65;
            cue_energy = 0.7;
            cue_reverb_boost = 0.1;
            cue_snare_ghost = 0.15;
            cue_chord_retrigger = 4;
            cue_chord_attack = 0.003;
            cue_chord_decay = 0.5;
            cue_chord_sustain = 0.3;
            cue_chord_release = 0.2;
            guitar.gain = 1.3;
            guitar.od_amount = 3.0;
            guitar.setCabinet(5000.0, 120.0);
            lead_phrase.rest_chance = 0.12;
            lead_phrase.region_low = 7;
            lead_phrase.region_high = 17;
        },
        .night_drive => {
            cue_extra_kick_density = 0.1;
            cue_hat_density = 0.75;
            cue_lead_density = 0.3;
            cue_energy = 0.35;
            cue_reverb_boost = 0.2;
            cue_snare_ghost = 0.05;
            cue_chord_retrigger = 8;
            cue_chord_attack = 0.02;
            cue_chord_decay = 0.8;
            cue_chord_sustain = 0.5;
            cue_chord_release = 0.4;
            guitar.gain = 0.8;
            guitar.od_amount = 1.8;
            guitar.setCabinet(3000.0, 120.0);
            lead_phrase.rest_chance = 0.4;
            lead_phrase.region_low = 9;
            lead_phrase.region_high = 15;
        },
        .power_ballad => {
            cue_extra_kick_density = 0.05;
            cue_hat_density = 0.15;
            cue_lead_density = 0.25;
            cue_energy = 0.2;
            cue_reverb_boost = 0.15;
            cue_snare_ghost = 0.0;
            cue_chord_retrigger = 8;
            cue_chord_attack = 0.03;
            cue_chord_decay = 1.2;
            cue_chord_sustain = 0.6;
            cue_chord_release = 0.6;
            guitar.gain = 0.6;
            guitar.od_amount = 1.2;
            guitar.setCabinet(2500.0, 120.0);
            lead_phrase.rest_chance = 0.45;
            lead_phrase.region_low = 8;
            lead_phrase.region_high = 14;
        },
        .combat => {
            cue_extra_kick_density = 0.7;
            cue_hat_density = 0.95;
            cue_lead_density = 0.85;
            cue_energy = 0.95;
            cue_reverb_boost = 0.0;
            cue_snare_ghost = 0.25;
            cue_chord_retrigger = 2;
            cue_chord_attack = 0.001;
            cue_chord_decay = 0.06;
            cue_chord_sustain = 0.0;
            cue_chord_release = 0.03;
            guitar.gain = 1.8;
            guitar.od_amount = 4.5;
            guitar.setCabinet(3500.0, 150.0);
            lead_phrase.rest_chance = 0.05;
            lead_phrase.region_low = 7;
            lead_phrase.region_high = 19;
        },
    }
}

// ============================================================
// Chord progression
// ============================================================

fn advanceChord() void {
    _ = harmony.nextChord(&rng);

    const chord = harmony.chords[harmony.current];
    var freqs: [3]f32 = undefined;
    for (0..3) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        freqs[idx] = midiToFreq(key.root + offset);
    }
    guitar.setFreqs(&freqs);

    const degrees = harmony.chordScaleDegrees(key.scale_type);
    lead_phrase.setChordTones(degrees.tones[0..degrees.count]);
    bass_phrase.setChordTones(degrees.tones[0..degrees.count]);

    bass.freq = midiToFreq(key.root + chord.offsets[0]);
}

// ============================================================
// Sequencer (16th note grid)
// ============================================================

fn advanceStep(meso: f32, micro: f32) void {
    const step = bar_step;
    beat_number += 1;

    // --- Kick ---
    if (step == 0 or step == 8) {
        kick.trigger(1.0);
    }
    if (step != 0 and step != 8) {
        if (rng.float() < cue_extra_kick_density * (0.5 + meso * 0.5)) {
            kick.trigger(0.7);
        }
    }

    // --- Snare ---
    if (step == 4 or step == 12) {
        snare.trigger();
    } else if (cue_snare_ghost > 0 and rng.float() < cue_snare_ghost * meso) {
        snare.triggerGhost();
    }

    // --- Hi-hat ---
    const hat_chance = if (step % 2 == 0) @as(f32, 0.9) else cue_hat_density * (0.5 + meso * 0.5);
    if (rng.float() < hat_chance) {
        hat.trigger();
    }

    // --- Bass ---
    if (step % 2 == 0) {
        if (bass_phrase.advance(&rng)) |note_idx| {
            bass.trigger(midiToFreq(key.noteToMidi(note_idx)));
        } else {
            bass.env.trigger();
        }
        const filter_mod = lfo_filter.modulate();
        bass.setFilter((380.0 + drive * 900.0 + cue_energy * 400.0) * filter_mod);
    }

    // --- Guitar chords ---
    if (step % cue_chord_retrigger == 0) {
        guitar.triggerEnv(cue_chord_attack, cue_chord_decay, cue_chord_sustain, cue_chord_release);
    }

    // --- Lead ---
    const lead_trigger_chance = if (step % 2 == 0)
        cue_lead_density * (0.5 + meso * 0.5)
    else
        cue_lead_density * 0.25 * meso;
    if (rng.float() < lead_trigger_chance) {
        triggerLeadNote(meso, micro);
    }

    bar_step = (bar_step + 1) % 16;
}

fn triggerLeadNote(meso: f32, micro: f32) void {
    if (lead_memory.count > 0 and rng.float() < 0.3) {
        var varied_notes: [synth.PhraseGenerator.MAX_LEN]u8 = undefined;
        if (lead_memory.recallVaried(&rng, &varied_notes, lead_phrase.region_low, lead_phrase.region_high)) |varied_len| {
            if (varied_len > 0 and varied_notes[0] != 0xFF) {
                const freq = midiToFreq(key.noteToMidi(varied_notes[0]));
                const env_decay = 0.14 + (1.0 - gate) * 0.2 + meso * 0.1;
                lead_voice.trigger(freq, Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08));
                lead_voice.filter = LPF.init((1800.0 + drive * 3000.0 + meso * 1200.0) * lfo_filter.modulate());
                return;
            }
        }
    }

    if (lead_phrase.advance(&rng)) |note_idx| {
        const freq = midiToFreq(key.noteToMidi(note_idx));
        const env_decay = 0.14 + (1.0 - gate) * 0.2 + micro * 0.1;
        lead_voice.trigger(freq, Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08));
        lead_voice.filter = LPF.init((1800.0 + drive * 3000.0 + meso * 1200.0) * lfo_filter.modulate());

        if (lead_phrase.pos == 0 and lead_phrase.len > 0) {
            lead_memory.store(&lead_phrase.notes, lead_phrase.len);
        }
    }
}

// ============================================================
// Vertical layer activation
// ============================================================

fn updateLayerTargets(macro: f32) void {
    drum_target = 0.85 + macro * 0.15;
    bass_target = 0.8 + macro * 0.2;
    chord_target = 0.3 + macro * 0.7;
    lead_target = if (macro > 0.25) @min((macro - 0.25) * 1.6, 1.0) else 0.0;
}

// ============================================================
// Lead DSP (uses overdrive + cabinet like guitar)
// ============================================================

fn processLead(meso: f32, eff_drive: f32) f32 {
    const raw = lead_voice.processRaw();
    if (raw.env_val <= 0.0001) return 0.0;

    var wave = raw.osc;
    wave += @sin(lead_voice.phases[0] * 2.0) * 0.15;
    wave = synth.overdrive(wave, 1.2 + eff_drive * 2.5 + meso * 0.8);
    wave = lead_voice.filter.process(wave);
    wave = lead_cab_hpf.process(wave);
    wave = lead_cab_lpf.process(wave);

    return wave * raw.env_val * 0.4;
}
