// Procedural ambient music style — v2 composition engine.
//
// Uses Markov chord progressions, multi-scale arcs, phrase memory
// with motif development, chord-tone gravity, key modulation,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter sets ("flavors") not fixed note sequences.
const std = @import("std");
const synth = @import("synth.zig");

const Envelope = synth.Envelope;
const LPF = synth.LPF;
const StereoReverb = synth.StereoReverb;
const midiToFreq = synth.midiToFreq;
const softClip = synth.softClip;
const panStereo = synth.panStereo;
const TAU = synth.TAU;
const INV_SR = synth.INV_SR;
const SAMPLE_RATE = synth.SAMPLE_RATE;

// ============================================================
// Tweakable parameters (written by musicConfigMenu)
// ============================================================

pub var bpm: f32 = 72.0;
pub var reverb_mix: f32 = 0.6;
pub var drone_vol: f32 = 0.15;
pub var pad_vol: f32 = 0.08;
pub var melody_vol: f32 = 0.04;
pub var arp_vol: f32 = 0.015;

// ============================================================
// Reverb
// ============================================================

const AmbientReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: AmbientReverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });

// ============================================================
// Key state & chord progression
// ============================================================

var key: synth.KeyState = .{ .root = 36, .scale_type = .minor_pentatonic };

var harmony: synth.ChordMarkov = initHarmony();

fn initHarmony() synth.ChordMarkov {
    var h: synth.ChordMarkov = .{};
    // Ambient chords: i, III, iv, VI, VII, v (relative minor/modal feel)
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 0 }, .len = 3 }; // i (minor)
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 0 }, .len = 3 }; // III (major)
    h.chords[2] = .{ .offsets = .{ 5, 8, 0, 0 }, .len = 3 }; // iv (minor, no 5th = open)
    h.chords[3] = .{ .offsets = .{ 8, 0, 3, 0 }, .len = 3 }; // VI (major)
    h.chords[4] = .{ .offsets = .{ 10, 2, 5, 0 }, .len = 3 }; // VII (major)
    h.chords[5] = .{ .offsets = .{ 7, 10, 2, 0 }, .len = 3 }; // v (minor)
    h.num_chords = 6;
    // Transition matrix: ambient favors slow, plagal movement
    //                  i     III    iv    VI    VII    v
    h.transitions[0] = .{ 0.1, 0.25, 0.25, 0.2, 0.1, 0.1, 0, 0 }; // from i
    h.transitions[1] = .{ 0.2, 0.1, 0.3, 0.2, 0.1, 0.1, 0, 0 }; // from III
    h.transitions[2] = .{ 0.3, 0.15, 0.05, 0.25, 0.15, 0.1, 0, 0 }; // from iv
    h.transitions[3] = .{ 0.2, 0.2, 0.2, 0.1, 0.2, 0.1, 0, 0 }; // from VI
    h.transitions[4] = .{ 0.35, 0.15, 0.1, 0.2, 0.05, 0.15, 0, 0 }; // from VII
    h.transitions[5] = .{ 0.25, 0.2, 0.2, 0.15, 0.1, 0.1, 0, 0 }; // from v
    return h;
}

// ============================================================
// Multi-scale arc system
// ============================================================

var arcs: synth.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};

// ============================================================
// Slow LFOs for organic movement
// ============================================================

var lfo_filter: synth.SlowLfo = .{ .period_beats = 90, .depth = 0.08 };
var lfo_reverb: synth.SlowLfo = .{ .period_beats = 150, .depth = 0.04 };

// ============================================================
// Layer volumes (for vertical activation)
// ============================================================

var drone_target: f32 = 1.0;
var pad_target: f32 = 1.0;
var melody_target: f32 = 0.5;
var arp_target: f32 = 0.0;

var drone_level: f32 = 1.0;
var pad_level: f32 = 0.3;
var melody_level: f32 = 0.0;
var arp_level: f32 = 0.0;

const LAYER_FADE_RATE: f32 = 0.00003; // ~1.5 sec fade at 48kHz

// ============================================================
// Phrase memory for motif development
// ============================================================

var melody_memory: synth.PhraseMemory = .{};

// ============================================================
// Voice types
// ============================================================

const DroneVoice = synth.Voice(2, 1);
const PadVoice = synth.Voice(3, 4);
const MelodyVoice = synth.Voice(2, 1);
const ArpVoice = synth.Voice(1, 1);

// ============================================================
// Drone layer: long incommensurable loops
// ============================================================

const DRONE_COUNT = 2;
var drones: [DRONE_COUNT]DroneVoice = .{
    .{ .unison_spread = 0.003, .filter = LPF.init(200.0), .pan = -0.3 },
    .{ .unison_spread = 0.003, .filter = LPF.init(180.0), .pan = 0.3 },
};
var drone_beat_counter: [DRONE_COUNT]f32 = .{ 0, 0 };
const drone_beat_len: [DRONE_COUNT]f32 = .{ 23.5, 29.75 }; // long incommensurable
var drone_phrases: [DRONE_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    .{ .anchor = 2, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
};

// ============================================================
// Pad layer: thick chordal voices
// ============================================================

const PAD_COUNT = 3;
var pads: [PAD_COUNT]PadVoice = .{
    .{ .unison_spread = 0.005, .filter = LPF.init(800.0), .pan = -0.4 },
    .{ .unison_spread = 0.005, .filter = LPF.init(700.0), .pan = 0.0 },
    .{ .unison_spread = 0.005, .filter = LPF.init(750.0), .pan = 0.4 },
};
var pad_beat_counter: [PAD_COUNT]f32 = .{ 0, 0, 0 };
const pad_beat_len: [PAD_COUNT]f32 = .{ 13.25, 17.5, 21.75 }; // incommensurable
var pad_note_idx: [PAD_COUNT]u8 = .{ 5, 7, 9 };

// ============================================================
// Melody layer: FM bell tones with phrase memory
// ============================================================

const MELODY_COUNT = 2;
var melodies: [MELODY_COUNT]MelodyVoice = .{
    .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = -0.5 },
    .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = 0.5 },
};
var mel_beat_counter: [MELODY_COUNT]f32 = .{ 0, 0 };
const mel_beat_len: [MELODY_COUNT]f32 = .{ 8.5, 11.25 }; // slow, spacious
var mel_phrases: [MELODY_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 10, .region_low = 8, .region_high = 14, .rest_chance = 0.55, .min_notes = 2, .max_notes = 5, .gravity = 4.0 },
    .{ .anchor = 11, .region_low = 9, .region_high = 14, .rest_chance = 0.6, .min_notes = 2, .max_notes = 4, .gravity = 4.0 },
};

// ============================================================
// Arp layer: sparse high shimmer
// ============================================================

const ARP_COUNT = 3;
var arps: [ARP_COUNT]ArpVoice = .{
    .{ .pan = -0.7 },
    .{ .pan = 0.0 },
    .{ .pan = 0.7 },
};
var arp_beat_counter: [ARP_COUNT]f32 = .{ 0, 0, 0 };
const arp_beat_len: [ARP_COUNT]f32 = .{ 3.75, 5.25, 4.5 }; // much slower
var arp_phrases: [ARP_COUNT]synth.PhraseGenerator = .{
    .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
    .{ .anchor = 15, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
    .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.55, .min_notes = 2, .max_notes = 4, .gravity = 4.5 },
};

// ============================================================
// Sequencer state
// ============================================================

var rng: synth.Rng = synth.Rng.init(12345);
var global_sample: u64 = 0;
var chord_beat_counter: f32 = 0;
const CHORD_CHANGE_BEATS: f32 = 16.0;
var last_macro_quarter: u8 = 0; // tracks macro arc quarters for key modulation

// ============================================================
// Fill buffer
// ============================================================

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = synth.samplesPerBeat(bpm);

    for (0..frames) |i| {
        global_sample += 1;

        // Advance modulation systems
        arcs.advanceSample(bpm);
        key.advanceSample();
        lfo_filter.advanceSample(bpm);
        lfo_reverb.advanceSample(bpm);

        const micro = arcs.micro.tension();
        const meso = arcs.meso.tension();
        const macro = arcs.macro.tension();

        // === Chord progression (Markov, triggered every N beats) ===
        chord_beat_counter += 1.0 / spb;
        if (chord_beat_counter >= CHORD_CHANGE_BEATS) {
            chord_beat_counter -= CHORD_CHANGE_BEATS;
            advanceChord(macro);
        }

        // === Key modulation on macro arc boundaries ===
        const macro_quarter: u8 = @intFromFloat(arcs.macro.beat_count / arcs.macro.section_beats * 4.0);
        if (macro_quarter != last_macro_quarter) {
            last_macro_quarter = macro_quarter;
            if (macro_quarter == 0) {
                // Every full macro cycle, modulate key
                if (rng.float() < 0.5) {
                    key.modulateByFourth();
                } else {
                    key.modulateByFifth();
                }
            }
        }

        // === Vertical layer activation based on macro arc ===
        updateLayerTargets(macro);
        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        melody_level += (melody_target - melody_level) * LAYER_FADE_RATE;
        arp_level += (arp_target - arp_level) * LAYER_FADE_RATE;

        var left: f32 = 0;
        var right: f32 = 0;

        // === Drone layer ===
        for (0..DRONE_COUNT) |d| {
            drone_beat_counter[d] += 1.0 / spb;
            if (drone_beat_counter[d] >= drone_beat_len[d]) {
                drone_beat_counter[d] -= drone_beat_len[d];
                if (drone_phrases[d].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(key.noteToMidi(note_idx));
                    drones[d].filter = LPF.init((160.0 + meso * 80.0) * lfo_filter.modulate());
                    drones[d].trigger(freq, Envelope.init(4.0, 0.5, 0.8, 5.0));
                }
            }
            const sample = drones[d].process() * drone_vol * drone_level;
            const stereo = panStereo(sample, drones[d].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Pad layer (follows chord tones) ===
        for (0..PAD_COUNT) |p| {
            pad_beat_counter[p] += 1.0 / spb;
            if (pad_beat_counter[p] >= pad_beat_len[p]) {
                pad_beat_counter[p] -= pad_beat_len[p];
                triggerPadNote(p, meso);
            }
            const sample = pads[p].process() * pad_vol * pad_level;
            const stereo = panStereo(sample, pads[p].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Melody layer (phrase memory + chord gravity) ===
        for (0..MELODY_COUNT) |m| {
            mel_beat_counter[m] += 1.0 / spb;
            if (mel_beat_counter[m] >= mel_beat_len[m]) {
                mel_beat_counter[m] -= mel_beat_len[m];
                triggerMelodyNote(m, meso, micro);
            }
            const sample = melodies[m].process() * melody_vol * melody_level;
            const stereo = panStereo(sample, melodies[m].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Arp layer ===
        for (0..ARP_COUNT) |a| {
            arp_beat_counter[a] += 1.0 / spb;
            if (arp_beat_counter[a] >= arp_beat_len[a]) {
                arp_beat_counter[a] -= arp_beat_len[a];
                arp_phrases[a].rest_chance = 0.5 * (1.3 - meso * 0.5);
                if (arp_phrases[a].advance(&rng)) |note_idx| {
                    const freq = midiToFreq(key.noteToMidi(note_idx));
                    arps[a].trigger(freq, Envelope.init(0.08, 1.5 + micro * 0.5, 0.0, 2.0));
                }
            }
            const sample = arps[a].process() * arp_vol * arp_level;
            const stereo = panStereo(sample, arps[a].pan);
            left += stereo[0];
            right += stereo[1];
        }

        // === Reverb with LFO modulation ===
        const rev_mix = reverb_mix * lfo_reverb.modulate();
        const dry = 1.0 - rev_mix;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * rev_mix;
        right = right * dry + rev[1] * rev_mix;

        buf[i * 2] = softClip(left);
        buf[i * 2 + 1] = softClip(right);
    }
}

// ============================================================
// Chord & note triggering
// ============================================================

fn advanceChord(macro_tension: f32) void {
    _ = harmony.nextChord(&rng);

    // Update chord-tone gravity for melodic layers
    const degrees = harmony.chordScaleDegrees(key.scale_type);
    for (0..MELODY_COUNT) |m| {
        mel_phrases[m].setChordTones(degrees.tones[0..degrees.count]);
    }
    for (0..ARP_COUNT) |a| {
        arp_phrases[a].setChordTones(degrees.tones[0..degrees.count]);
    }

    // Update pad target notes from chord
    const chord = harmony.chords[harmony.current];
    for (0..@min(PAD_COUNT, chord.len)) |p| {
        // Map chord offset to a scale degree in the pad register
        const si = synth.getScaleIntervals(key.scale_type);
        var best_deg: u8 = pad_note_idx[p];
        var best_dist: u8 = 255;
        // Search nearby octaves for closest voicing (voice leading)
        for (0..3) |oct| {
            for (0..si.len) |s| {
                const deg: u8 = @intCast(@as(usize, si.len) * oct + s);
                const midi = synth.scaleNoteToMidi(key.root, key.scale_type, deg);
                const target_midi = key.root + chord.offsets[p] + @as(u8, @intCast(oct)) * 12;
                const dist = if (midi > target_midi) midi - target_midi else target_midi - midi;
                if (dist < best_dist) {
                    best_dist = dist;
                    best_deg = deg;
                }
            }
        }
        pad_note_idx[p] = best_deg;
    }
    _ = macro_tension;
}

fn triggerPadNote(p: usize, meso: f32) void {
    const freq = midiToFreq(key.noteToMidi(pad_note_idx[p]));
    pads[p].filter = LPF.init((500.0 + meso * 500.0) * lfo_filter.modulate());
    pads[p].trigger(freq, Envelope.init(2.0, 0.3, 0.6, 3.5));
}

fn triggerMelodyNote(m: usize, meso: f32, micro: f32) void {
    // Sometimes recall a stored phrase variation instead of generating new
    if (melody_memory.count > 0 and rng.float() < 0.35) {
        var varied_notes: [synth.PhraseGenerator.MAX_LEN]u8 = undefined;
        if (melody_memory.recallVaried(&rng, &varied_notes, mel_phrases[m].region_low, mel_phrases[m].region_high)) |varied_len| {
            // Use the first note of the varied phrase
            if (varied_len > 0 and varied_notes[0] != 0xFF) {
                const freq = midiToFreq(key.noteToMidi(varied_notes[0]));
                melodies[m].trigger(freq, Envelope.init(0.1, 2.0 + micro * 1.0, 0.0, 2.5));
                return;
            }
        }
    }

    mel_phrases[m].rest_chance = 0.3 * (1.3 - meso * 0.6);
    if (mel_phrases[m].advance(&rng)) |note_idx| {
        const freq = midiToFreq(key.noteToMidi(note_idx));
        melodies[m].trigger(freq, Envelope.init(0.1, 2.0 + micro * 1.0, 0.0, 2.5));

        // Store phrase when it completes (pos wrapped back)
        if (mel_phrases[m].pos == 0 and mel_phrases[m].len > 0) {
            melody_memory.store(&mel_phrases[m].notes, mel_phrases[m].len);
        }
    }
}

// ============================================================
// Vertical layer activation
// ============================================================

fn updateLayerTargets(macro: f32) void {
    // Drone: always present
    drone_target = 0.8 + macro * 0.2;

    // Pad: fades in with macro, always at least a whisper
    pad_target = 0.2 + macro * 0.8;

    // Melody: appears in the middle range of macro, gently
    melody_target = if (macro > 0.35) @min((macro - 0.35) * 1.2, 0.8) else 0.0;

    // Arp: only at high macro tension, stays subtle
    arp_target = if (macro > 0.65) @min((macro - 0.65) * 1.5, 0.6) else 0.0;
}

// ============================================================
// Reset
// ============================================================

pub fn reset() void {
    global_sample = 0;
    rng = synth.Rng.init(12345);

    key = .{ .root = 36, .scale_type = .minor_pentatonic };
    harmony = initHarmony();
    arcs = .{
        .micro = .{ .section_beats = 8, .shape = .rise_fall },
        .meso = .{ .section_beats = 48, .shape = .rise_fall },
        .macro = .{ .section_beats = 256, .shape = .plateau },
    };
    lfo_filter = .{ .period_beats = 90, .depth = 0.08 };
    lfo_reverb = .{ .period_beats = 150, .depth = 0.04 };
    melody_memory = .{};

    drone_target = 1.0;
    pad_target = 1.0;
    melody_target = 0.5;
    arp_target = 0.0;
    drone_level = 1.0;
    pad_level = 0.3;
    melody_level = 0.0;
    arp_level = 0.0;

    chord_beat_counter = 0;
    last_macro_quarter = 0;

    drones = .{
        .{ .unison_spread = 0.003, .filter = LPF.init(200.0), .pan = -0.3 },
        .{ .unison_spread = 0.003, .filter = LPF.init(180.0), .pan = 0.3 },
    };
    drone_beat_counter = .{ 0, 0 };
    drone_phrases = .{
        .{ .anchor = 0, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
        .{ .anchor = 2, .region_low = 0, .region_high = 4, .rest_chance = 0.05, .min_notes = 2, .max_notes = 4 },
    };

    pads = .{
        .{ .unison_spread = 0.005, .filter = LPF.init(800.0), .pan = -0.4 },
        .{ .unison_spread = 0.005, .filter = LPF.init(700.0), .pan = 0.0 },
        .{ .unison_spread = 0.005, .filter = LPF.init(750.0), .pan = 0.4 },
    };
    pad_beat_counter = .{ 0, 0, 0 };
    pad_note_idx = .{ 5, 7, 9 };

    melodies = .{
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = -0.5 },
        .{ .fm_ratio = 2.0, .fm_depth = 1.5, .fm_env_depth = 1.0, .unison_spread = 0.003, .pan = 0.5 },
    };
    mel_beat_counter = .{ 0, 0 };
    mel_phrases = .{
        .{ .anchor = 10, .region_low = 8, .region_high = 14, .rest_chance = 0.55, .min_notes = 2, .max_notes = 5, .gravity = 4.0 },
        .{ .anchor = 11, .region_low = 9, .region_high = 14, .rest_chance = 0.6, .min_notes = 2, .max_notes = 4, .gravity = 4.0 },
    };

    arps = .{
        .{ .pan = -0.7 },
        .{ .pan = 0.0 },
        .{ .pan = 0.7 },
    };
    arp_beat_counter = .{ 0, 0, 0 };
    arp_phrases = .{
        .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
        .{ .anchor = 15, .region_low = 12, .region_high = 17, .rest_chance = 0.5, .min_notes = 2, .max_notes = 5, .gravity = 4.5 },
        .{ .anchor = 14, .region_low = 12, .region_high = 17, .rest_chance = 0.55, .min_notes = 2, .max_notes = 4, .gravity = 4.5 },
    };

    reverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });
}
