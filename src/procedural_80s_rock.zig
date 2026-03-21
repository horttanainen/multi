// Procedural 80s rock style — v2 composition engine.
//
// Markov chord progressions, multi-scale arcs, phrase-generated lead
// with motif memory, chord-tone gravity, key modulation by 5ths,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter flavors (arena/night_drive/power_ballad/combat).
// Drums stay hand-rolled.
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

var key: synth.KeyState = .{ .root = 40, .scale_type = .mixolydian }; // E2 mixolydian

var harmony: synth.ChordMarkov = initHarmony();

fn initHarmony() synth.ChordMarkov {
    var h: synth.ChordMarkov = .{};
    // Rock power chords (root + 5th + octave)
    h.chords[0] = .{ .offsets = .{ 0, 7, 12, 0 }, .len = 3 }; // I
    h.chords[1] = .{ .offsets = .{ 5, 12, 17, 0 }, .len = 3 }; // IV
    h.chords[2] = .{ .offsets = .{ 7, 14, 19, 0 }, .len = 3 }; // V
    h.chords[3] = .{ .offsets = .{ 9, 16, 21, 0 }, .len = 3 }; // vi
    h.chords[4] = .{ .offsets = .{ 10, 17, 22, 0 }, .len = 3 }; // bVII
    h.chords[5] = .{ .offsets = .{ 3, 10, 15, 0 }, .len = 3 }; // bIII
    h.num_chords = 6;
    // Rock loves I-IV-V, with bVII for 80s flavor
    //                  I     IV    V     vi    bVII  bIII
    h.transitions[0] = .{ 0.05, 0.30, 0.25, 0.15, 0.15, 0.10, 0, 0 }; // from I
    h.transitions[1] = .{ 0.25, 0.05, 0.35, 0.10, 0.15, 0.10, 0, 0 }; // from IV
    h.transitions[2] = .{ 0.40, 0.20, 0.05, 0.15, 0.10, 0.10, 0, 0 }; // from V
    h.transitions[3] = .{ 0.15, 0.25, 0.25, 0.05, 0.20, 0.10, 0, 0 }; // from vi
    h.transitions[4] = .{ 0.35, 0.20, 0.15, 0.10, 0.05, 0.15, 0, 0 }; // from bVII
    h.transitions[5] = .{ 0.20, 0.30, 0.20, 0.10, 0.15, 0.05, 0, 0 }; // from bIII
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
// Slow LFOs for organic movement
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

const LAYER_FADE_RATE: f32 = 0.00005; // ~1 sec fade at 48kHz

// ============================================================
// Phrase memory for lead motif development
// ============================================================

var lead_memory: synth.PhraseMemory = .{};

// ============================================================
// Drums (hand-rolled, too specialized for Voice type)
// ============================================================

var kick_phase: f32 = 0.0;
var kick_pitch_env: f32 = 0.0;
var kick_env: Envelope = Envelope.init(0.001, 0.16, 0.0, 0.1);

var snare_phase: f32 = 0.0;
var snare_env: Envelope = Envelope.init(0.001, 0.12, 0.0, 0.06);
var snare_noise_lpf: LPF = LPF.init(3400.0);
var snare_body_lpf: LPF = LPF.init(2200.0);

var hat_env: Envelope = Envelope.init(0.001, 0.03, 0.0, 0.02);
var hat_hpf: HPF = HPF.init(6000.0);

// ============================================================
// Bass: saw + sub (no unison needed for mono bass)
// ============================================================

var bass_phase: f32 = 0.0;
var bass_sub_phase: f32 = 0.0;
var bass_freq: f32 = midiToFreq(40);
var bass_env: Envelope = Envelope.init(0.002, 0.18, 0.0, 0.08);
var bass_lpf: LPF = LPF.init(800.0);
var bass_phrase: synth.PhraseGenerator = .{
    .anchor = 0,
    .region_low = 0,
    .region_high = 6,
    .rest_chance = 0.05,
    .min_notes = 3,
    .max_notes = 6,
    .gravity = 3.0,
};

// ============================================================
// Chords: 3 voices × Voice(2, 1) for detuned power chords
// ============================================================

const ChordVoice = synth.Voice(2, 1);
var chord_voices: [3]ChordVoice = .{
    .{ .unison_spread = 0.006, .pan = -0.22 },
    .{ .unison_spread = 0.006, .pan = 0.0 },
    .{ .unison_spread = 0.006, .pan = 0.22 },
};
var chord_env: Envelope = Envelope.init(0.004, 0.36, 0.0, 0.14);

// ============================================================
// Lead: Voice(3, 1) for thick synth lead with phrase generation
// ============================================================

const LeadVoice = synth.Voice(3, 1);
var lead_voice: LeadVoice = .{
    .unison_spread = 0.005,
    .filter = LPF.init(2200.0),
};
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
const CHORD_CHANGE_BEATS: f32 = 8.0; // change chord every 2 bars (8 beats at 16th note grid)
var last_macro_quarter: u8 = 0;

// Cue-derived parameters (set by applyCueParams)
var cue_extra_kick_density: f32 = 0.0; // 0-1, chance of extra kicks
var cue_hat_density: f32 = 0.5; // 0-1, hat pattern density
var cue_lead_density: f32 = 0.5; // 0-1, lead note frequency
var cue_energy: f32 = 0.5; // 0-1, filter/drive boost

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

    kick_phase = 0.0;
    kick_pitch_env = 0.0;
    kick_env = Envelope.init(0.001, 0.16, 0.0, 0.1);

    snare_phase = 0.0;
    snare_env = Envelope.init(0.001, 0.12, 0.0, 0.06);
    snare_noise_lpf = LPF.init(3400.0);
    snare_body_lpf = LPF.init(2200.0);

    hat_env = Envelope.init(0.001, 0.03, 0.0, 0.02);
    hat_hpf = HPF.init(6000.0);

    bass_phase = 0.0;
    bass_sub_phase = 0.0;
    bass_freq = midiToFreq(40);
    bass_env = Envelope.init(0.002, 0.18, 0.0, 0.08);
    bass_lpf = LPF.init(800.0);
    bass_phrase = .{ .anchor = 0, .region_low = 0, .region_high = 6, .rest_chance = 0.05, .min_notes = 3, .max_notes = 6, .gravity = 3.0 };

    chord_voices = .{
        .{ .unison_spread = 0.006, .pan = -0.22 },
        .{ .unison_spread = 0.006, .pan = 0.0 },
        .{ .unison_spread = 0.006, .pan = 0.22 },
    };
    chord_env = Envelope.init(0.004, 0.36, 0.0, 0.14);

    lead_voice = .{ .unison_spread = 0.005, .filter = LPF.init(2200.0) };
    lead_phrase = .{ .anchor = 10, .region_low = 7, .region_high = 17, .rest_chance = 0.15, .min_notes = 4, .max_notes = 8, .gravity = 3.0 };

    reverb = RockReverb.init(.{ 0.84, 0.85, 0.83, 0.86 });
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const samples_per_step = SAMPLE_RATE * 60.0 / bpm / 4.0; // 16th note grid
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        // Advance modulation systems
        arcs.advanceSample(bpm);
        key.advanceSample();
        lfo_filter.advanceSample(bpm);
        lfo_drive.advanceSample(bpm);

        const micro = arcs.micro.tension();
        const meso = arcs.meso.tension();
        const macro = arcs.macro.tension();

        // === Chord progression (Markov) ===
        chord_beat_counter += 1.0 / spb;
        if (chord_beat_counter >= CHORD_CHANGE_BEATS) {
            chord_beat_counter -= CHORD_CHANGE_BEATS;
            advanceChord();
        }

        // === Key modulation on macro arc boundaries ===
        const macro_quarter: u8 = @intFromFloat(arcs.macro.beat_count / arcs.macro.section_beats * 4.0);
        if (macro_quarter != last_macro_quarter) {
            last_macro_quarter = macro_quarter;
            if (macro_quarter == 0) {
                // Every full macro cycle, key change by 5th (classic rock modulation)
                key.modulateByFifth();
            }
        }

        // === Vertical layer activation ===
        updateLayerTargets(macro);
        drum_level += (drum_target - drum_level) * LAYER_FADE_RATE;
        bass_level += (bass_target - bass_level) * LAYER_FADE_RATE;
        chord_level += (chord_target - chord_level) * LAYER_FADE_RATE;
        lead_level += (lead_target - lead_level) * LAYER_FADE_RATE;

        // === 16th note sequencer ===
        step_counter += 1.0;
        if (step_counter >= samples_per_step) {
            step_counter -= samples_per_step;
            advanceStep(meso, micro);
        }

        // ---- Mix ----
        var left: f32 = 0.0;
        var right: f32 = 0.0;

        const d_level = drum_mix * drum_level;
        const kick = processKick() * d_level;
        left += kick * 0.85;
        right += kick * 0.85;

        const snare = processSnare() * d_level;
        left += snare * 0.72;
        right += snare * 0.72;

        const hat = processHat() * d_level;
        left += hat * 0.42;
        right += hat * 0.52;

        const bass = processBass() * bass_mix * bass_level;
        left += bass * 0.85;
        right += bass * 0.8;

        const eff_drive = drive * lfo_drive.modulate() + cue_energy * 0.15;
        const chords = processChords(meso, eff_drive);
        left += chords[0] * chord_level;
        right += chords[1] * chord_level;

        const lead = processLead(meso, eff_drive) * lead_mix * lead_level;
        const lead_stereo = panStereo(lead, 0.08);
        left += lead_stereo[0];
        right += lead_stereo[1];

        const rev = reverb.process(.{ left, right });
        const dry = 1.0 - reverb_mix;
        left = left * dry + rev[0] * reverb_mix;
        right = right * dry + rev[1] * reverb_mix;

        buf[i * 2] = softClip(left * 0.82);
        buf[i * 2 + 1] = softClip(right * 0.82);
    }
}

// ============================================================
// Cue parameter application
// ============================================================

fn applyCueParams() void {
    switch (selected_cue) {
        .arena => {
            cue_extra_kick_density = 0.3;
            cue_hat_density = 0.5;
            cue_lead_density = 0.6;
            cue_energy = 0.6;
            lead_phrase.rest_chance = 0.15;
            lead_phrase.region_low = 7;
            lead_phrase.region_high = 17;
        },
        .night_drive => {
            cue_extra_kick_density = 0.15;
            cue_hat_density = 0.8; // busy hi-hats
            cue_lead_density = 0.4;
            cue_energy = 0.4;
            lead_phrase.rest_chance = 0.3;
            lead_phrase.region_low = 9;
            lead_phrase.region_high = 16;
        },
        .power_ballad => {
            cue_extra_kick_density = 0.1;
            cue_hat_density = 0.2;
            cue_lead_density = 0.3;
            cue_energy = 0.3;
            lead_phrase.rest_chance = 0.4;
            lead_phrase.region_low = 8;
            lead_phrase.region_high = 15;
        },
        .combat => {
            cue_extra_kick_density = 0.6;
            cue_hat_density = 0.9;
            cue_lead_density = 0.8;
            cue_energy = 0.8;
            lead_phrase.rest_chance = 0.08;
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

    // Update chord voice frequencies from Markov chord + key root
    const chord = harmony.chords[harmony.current];
    for (0..3) |idx| {
        const offset = if (idx < chord.len) chord.offsets[idx] else chord.offsets[0];
        chord_voices[idx].freq = midiToFreq(key.root + offset);
    }

    // Update chord-tone gravity for lead and bass
    const degrees = harmony.chordScaleDegrees(key.scale_type);
    lead_phrase.setChordTones(degrees.tones[0..degrees.count]);
    bass_phrase.setChordTones(degrees.tones[0..degrees.count]);

    // Bass root follows chord
    bass_freq = midiToFreq(key.root + chord.offsets[0]);
}

// ============================================================
// Sequencer (16th note grid)
// ============================================================

fn advanceStep(meso: f32, micro: f32) void {
    const step = bar_step;
    beat_number += 1;

    // --- Kick: beats 1 and 3, plus cue-driven extra hits ---
    if (step == 0 or step == 8) {
        kick_env.trigger();
        kick_pitch_env = 1.0;
    }
    // Extra kick ghost notes modulated by cue + macro tension
    if (step != 0 and step != 8 and step % 2 == 0) {
        if (rng.float() < cue_extra_kick_density * (0.5 + meso * 0.5)) {
            kick_env.trigger();
            kick_pitch_env = 0.7;
        }
    }

    // --- Snare: beats 2 and 4 ---
    if (step == 4 or step == 12) {
        snare_env.trigger();
    }

    // --- Hi-hat: density driven by cue ---
    const hat_chance = if (step % 2 == 0)
        0.9 // on-beats almost always
    else
        cue_hat_density * (0.6 + meso * 0.4); // off-beats driven by cue + tension

    if (rng.float() < hat_chance) {
        hat_env.trigger();
    }

    // --- Bass: 8th notes, phrase-driven root motion ---
    if (step % 2 == 0) {
        bass_env.trigger();
        if (bass_phrase.advance(&rng)) |note_idx| {
            bass_freq = midiToFreq(key.noteToMidi(note_idx));
        }
        const filter_mod = lfo_filter.modulate();
        bass_lpf = LPF.init((380.0 + drive * 900.0 + cue_energy * 300.0) * filter_mod);
    }

    // --- Chords: every quarter note ---
    if (step % 4 == 0) {
        chord_env = Envelope.init(0.004, 0.18 + gate * 0.45, 0.0, 0.1 + gate * 0.18);
        chord_env.trigger();
    }

    // --- Lead: phrase-generated, density from cue ---
    const lead_trigger_chance = if (step % 2 == 0)
        cue_lead_density * (0.6 + meso * 0.4)
    else
        cue_lead_density * 0.3 * meso; // off-beats only at high tension

    if (rng.float() < lead_trigger_chance) {
        triggerLeadNote(meso, micro);
    }

    bar_step = (bar_step + 1) % 16;
}

fn triggerLeadNote(meso: f32, micro: f32) void {
    // Sometimes recall a stored motif variation
    if (lead_memory.count > 0 and rng.float() < 0.3) {
        var varied_notes: [synth.PhraseGenerator.MAX_LEN]u8 = undefined;
        if (lead_memory.recallVaried(&rng, &varied_notes, lead_phrase.region_low, lead_phrase.region_high)) |varied_len| {
            if (varied_len > 0 and varied_notes[0] != 0xFF) {
                const freq = midiToFreq(key.noteToMidi(varied_notes[0]));
                const env_decay = 0.14 + (1.0 - gate) * 0.2 + meso * 0.1;
                lead_voice.trigger(freq, Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08));
                lead_voice.filter = LPF.init((1200.0 + drive * 2800.0 + meso * 1000.0) * lfo_filter.modulate());
                return;
            }
        }
    }

    if (lead_phrase.advance(&rng)) |note_idx| {
        const freq = midiToFreq(key.noteToMidi(note_idx));
        const env_decay = 0.14 + (1.0 - gate) * 0.2 + micro * 0.1;
        lead_voice.trigger(freq, Envelope.init(0.002, env_decay, 0.0, 0.08 + gate * 0.08));
        lead_voice.filter = LPF.init((1200.0 + drive * 2800.0 + meso * 1000.0) * lfo_filter.modulate());

        // Store completed phrases for motif recall
        if (lead_phrase.pos == 0 and lead_phrase.len > 0) {
            lead_memory.store(&lead_phrase.notes, lead_phrase.len);
        }
    }
}

// ============================================================
// Vertical layer activation
// ============================================================

fn updateLayerTargets(macro: f32) void {
    // Drums: always there, slightly louder at peaks
    drum_target = 0.85 + macro * 0.15;

    // Bass: always present
    bass_target = 0.8 + macro * 0.2;

    // Chords: fade in with macro
    chord_target = 0.3 + macro * 0.7;

    // Lead: emerges at moderate tension, full at peak
    lead_target = if (macro > 0.25) @min((macro - 0.25) * 1.6, 1.0) else 0.0;
}

// ============================================================
// DSP processing
// ============================================================

fn processKick() f32 {
    const env = kick_env.process();
    if (env <= 0.0001) return 0.0;

    kick_pitch_env *= 0.993;
    const freq = 44.0 + kick_pitch_env * 90.0;
    kick_phase += freq * INV_SR * TAU;
    if (kick_phase > TAU) kick_phase -= TAU;
    return @sin(kick_phase) * env * 1.5;
}

fn processSnare() f32 {
    const env = snare_env.process();
    if (env <= 0.0001) return 0.0;

    snare_phase += 190.0 * INV_SR * TAU;
    if (snare_phase > TAU) snare_phase -= TAU;
    const noise = snare_noise_lpf.process(rng.float() * 2.0 - 1.0);
    const tone = snare_body_lpf.process(@sin(snare_phase));
    return (noise * 0.78 + tone * 0.35) * env;
}

fn processHat() f32 {
    const env = hat_env.process();
    if (env <= 0.0001) return 0.0;
    const noise = hat_hpf.process(rng.float() * 2.0 - 1.0);
    return noise * env * 0.45;
}

fn processBass() f32 {
    const env = bass_env.process();
    if (env <= 0.0001) return 0.0;

    bass_phase += bass_freq * INV_SR * TAU;
    if (bass_phase > TAU) bass_phase -= TAU;
    bass_sub_phase += bass_freq * 0.5 * INV_SR * TAU;
    if (bass_sub_phase > TAU) bass_sub_phase -= TAU;

    const saw = bass_phase / std.math.pi - 1.0;
    const sub = @sin(bass_sub_phase);
    var sample = saw * (0.6 + drive * 0.35) + sub * 0.4;
    sample = bass_lpf.process(sample);
    sample *= 1.0 + drive * 0.45;
    return sample * env * 0.55;
}

fn processChords(meso: f32, eff_drive: f32) [2]f32 {
    const env = chord_env.process();
    if (env <= 0.0001) return .{ 0.0, 0.0 };

    var left: f32 = 0.0;
    var right: f32 = 0.0;
    for (0..3) |idx| {
        chord_voices[idx].env = .{
            .state = .sustain,
            .level = env,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = env,
            .release_rate = 0,
        };

        const raw = chord_voices[idx].processRaw();
        if (raw.env_val <= 0.0001) continue;

        var wave = raw.osc;
        wave *= 1.0 + eff_drive * 0.6 + meso * 0.2;
        if (wave > 0.85) wave = 0.85;
        if (wave < -0.85) wave = -0.85;
        wave *= raw.env_val * (0.18 + eff_drive * 0.22);

        const stereo = panStereo(wave, chord_voices[idx].pan);
        left += stereo[0];
        right += stereo[1];
    }
    return .{ left, right };
}

fn processLead(meso: f32, eff_drive: f32) f32 {
    const raw = lead_voice.processRaw();
    if (raw.env_val <= 0.0001) return 0.0;

    var wave = raw.osc;
    wave += @sin(lead_voice.phases[0] * 2.0) * 0.18;
    wave = lead_voice.filter.process(wave);
    wave *= 1.0 + eff_drive * 0.35 + meso * 0.15;
    return wave * raw.env_val * 0.4;
}
