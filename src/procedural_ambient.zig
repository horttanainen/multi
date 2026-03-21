// Procedural ambient music style — v2 composition engine.
//
// Uses Markov chord progressions, multi-scale arcs, phrase memory
// with motif development, chord-tone gravity, key modulation,
// vertical layer activation, and slow LFO modulation.
// Cues are parameter sets ("flavors"): dawn, twilight, space, forest.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const layers = @import("music/layers.zig");

const StereoReverb = dsp.StereoReverb;
const softClip = dsp.softClip;

// ============================================================
// Tweakable parameters (written by musicConfigMenu / settings)
// ============================================================

pub const CuePreset = enum(u8) {
    dawn,
    twilight,
    space,
    forest,
};

pub var bpm: f32 = 72.0;
pub var reverb_mix: f32 = 0.6;
pub var drone_vol: f32 = 0.15;
pub var pad_vol: f32 = 0.08;
pub var melody_vol: f32 = 0.04;
pub var arp_vol: f32 = 0.015;
pub var selected_cue: CuePreset = .dawn;

// ============================================================
// Reverb
// ============================================================

const AmbientReverb = StereoReverb(.{ 1759, 1693, 1623, 1548 }, .{ 245, 605 });
var reverb: AmbientReverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });

// ============================================================
// Key state & chord progression
// ============================================================

var key: composition.KeyState = .{ .root = 36, .scale_type = .minor_pentatonic };

var harmony: composition.ChordMarkov = initHarmony();

fn initHarmony() composition.ChordMarkov {
    var h: composition.ChordMarkov = .{};
    // Ambient chords: i, III, iv, VI, VII, v
    h.chords[0] = .{ .offsets = .{ 0, 3, 7, 0 }, .len = 3 }; // i
    h.chords[1] = .{ .offsets = .{ 3, 7, 10, 0 }, .len = 3 }; // III
    h.chords[2] = .{ .offsets = .{ 5, 8, 0, 0 }, .len = 3 }; // iv
    h.chords[3] = .{ .offsets = .{ 8, 0, 3, 0 }, .len = 3 }; // VI
    h.chords[4] = .{ .offsets = .{ 10, 2, 5, 0 }, .len = 3 }; // VII
    h.chords[5] = .{ .offsets = .{ 7, 10, 2, 0 }, .len = 3 }; // v
    h.num_chords = 6;
    //                  i     III    iv    VI    VII    v
    h.transitions[0] = .{ 0.1, 0.25, 0.25, 0.2, 0.1, 0.1, 0, 0 };
    h.transitions[1] = .{ 0.2, 0.1, 0.3, 0.2, 0.1, 0.1, 0, 0 };
    h.transitions[2] = .{ 0.3, 0.15, 0.05, 0.25, 0.15, 0.1, 0, 0 };
    h.transitions[3] = .{ 0.2, 0.2, 0.2, 0.1, 0.2, 0.1, 0, 0 };
    h.transitions[4] = .{ 0.35, 0.15, 0.1, 0.2, 0.05, 0.15, 0, 0 };
    h.transitions[5] = .{ 0.25, 0.2, 0.2, 0.15, 0.1, 0.1, 0, 0 };
    return h;
}

// ============================================================
// Multi-scale arc system
// ============================================================

var arcs: composition.ArcSystem = .{
    .micro = .{ .section_beats = 8, .shape = .rise_fall },
    .meso = .{ .section_beats = 48, .shape = .rise_fall },
    .macro = .{ .section_beats = 256, .shape = .plateau },
};

// ============================================================
// Slow LFOs for organic movement
// ============================================================

var lfo_filter: composition.SlowLfo = .{ .period_beats = 90, .depth = 0.08 };
var lfo_reverb: composition.SlowLfo = .{ .period_beats = 150, .depth = 0.04 };

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

const LAYER_FADE_RATE: f32 = 0.00003;

var drone_layer: layers.AmbientDroneLayer = .{};
var pad_layer: layers.AmbientPadLayer = .{};
var melody_layer: layers.AmbientMelodyLayer = .{};
var arp_layer: layers.AmbientArpLayer = .{};

// ============================================================
// Sequencer state
// ============================================================

var rng: dsp.Rng = dsp.Rng.init(12345);
var global_sample: u64 = 0;
var chord_beat_counter: f32 = 0;
var chord_change_beats: f32 = 16.0;
var last_macro_quarter: u8 = 0;

// Cue-derived parameters
var cue_drone_filter_base: f32 = 160.0;
var cue_drone_filter_range: f32 = 80.0;
var cue_pad_filter_base: f32 = 500.0;
var cue_pad_filter_range: f32 = 500.0;
var cue_melody_recall_chance: f32 = 0.35;
var cue_reverb_boost: f32 = 0.0;
var cue_melody_thresh: f32 = 0.35; // macro threshold for melody layer
var cue_arp_thresh: f32 = 0.65; // macro threshold for arp layer
var cue_drone_env_attack: f32 = 4.0;
var cue_drone_env_release: f32 = 5.0;
var cue_pad_env_attack: f32 = 2.0;
var cue_pad_env_release: f32 = 3.5;
var cue_melody_env_attack: f32 = 0.1;
var cue_melody_env_decay: f32 = 2.0;
var cue_melody_env_release: f32 = 2.5;
var cue_arp_env_decay: f32 = 1.5;
var cue_arp_env_release: f32 = 2.0;

// ============================================================
// Public API
// ============================================================

pub fn triggerCue() void {
    applyCueParams();
}

pub fn fillBuffer(buf: [*]f32, frames: usize) void {
    const spb = dsp.samplesPerBeat(bpm);

    for (0..frames) |i| {
        global_sample += 1;

        arcs.advanceSample(bpm);
        key.advanceSample();
        lfo_filter.advanceSample(bpm);
        lfo_reverb.advanceSample(bpm);

        const micro = arcs.micro.tension();
        const meso = arcs.meso.tension();
        const macro = arcs.macro.tension();

        // === Chord progression ===
        chord_beat_counter += 1.0 / spb;
        if (chord_beat_counter >= chord_change_beats) {
            chord_beat_counter -= chord_change_beats;
            advanceChord();
        }

        // === Key modulation on macro arc boundaries ===
        const macro_quarter: u8 = @intFromFloat(arcs.macro.beat_count / arcs.macro.section_beats * 4.0);
        if (macro_quarter != last_macro_quarter) {
            last_macro_quarter = macro_quarter;
            if (macro_quarter == 0) {
                if (rng.float() < 0.5) {
                    key.modulateByFourth();
                } else {
                    key.modulateByFifth();
                }
            }
        }

        // === Vertical layer activation ===
        updateLayerTargets(macro);
        drone_level += (drone_target - drone_level) * LAYER_FADE_RATE;
        pad_level += (pad_target - pad_level) * LAYER_FADE_RATE;
        melody_level += (melody_target - melody_level) * LAYER_FADE_RATE;
        arp_level += (arp_target - arp_level) * LAYER_FADE_RATE;

        var left: f32 = 0;
        var right: f32 = 0;

        layers.advanceAmbientDroneLayer(&drone_layer, &rng, &key, spb, meso, cue_drone_filter_base, cue_drone_filter_range, lfo_filter.modulate(), cue_drone_env_attack, cue_drone_env_release);
        layers.advanceAmbientPadLayer(&pad_layer, &key, spb, meso, cue_pad_filter_base, cue_pad_filter_range, lfo_filter.modulate(), cue_pad_env_attack, cue_pad_env_release);
        layers.advanceAmbientMelodyLayer(&melody_layer, &rng, &key, spb, meso, micro, cue_melody_recall_chance, cue_melody_env_attack, cue_melody_env_decay, cue_melody_env_release);
        layers.advanceAmbientArpLayer(&arp_layer, &rng, &key, spb, meso, micro, cue_arp_env_decay, cue_arp_env_release);

        const drone_out = layers.mixAmbientDroneLayer(&drone_layer, drone_vol * drone_level);
        left += drone_out[0];
        right += drone_out[1];

        const pad_out = layers.mixAmbientPadLayer(&pad_layer, pad_vol * pad_level);
        left += pad_out[0];
        right += pad_out[1];

        const melody_out = layers.mixAmbientMelodyLayer(&melody_layer, melody_vol * melody_level);
        left += melody_out[0];
        right += melody_out[1];

        const arp_out = layers.mixAmbientArpLayer(&arp_layer, arp_vol * arp_level);
        left += arp_out[0];
        right += arp_out[1];

        // === Reverb ===
        const rev_mix = (reverb_mix + cue_reverb_boost) * lfo_reverb.modulate();
        const dry = 1.0 - rev_mix;
        const rev = reverb.process(.{ left, right });
        left = left * dry + rev[0] * rev_mix;
        right = right * dry + rev[1] * rev_mix;

        buf[i * 2] = softClip(left);
        buf[i * 2 + 1] = softClip(right);
    }
}

// ============================================================
// Cue parameter application
// ============================================================

fn applyCueParams() void {
    switch (selected_cue) {
        .dawn => {
            // Warm, rising, major-leaning, bright filters, gentle melody
            key.scale_type = .major_pentatonic;
            cue_drone_filter_base = 200.0;
            cue_drone_filter_range = 120.0;
            cue_pad_filter_base = 600.0;
            cue_pad_filter_range = 600.0;
            cue_melody_recall_chance = 0.35;
            cue_reverb_boost = 0.05;
            cue_melody_thresh = 0.25; // melody comes in earlier
            cue_arp_thresh = 0.55;
            cue_drone_env_attack = 3.5;
            cue_drone_env_release = 4.0;
            cue_pad_env_attack = 1.5;
            cue_pad_env_release = 3.0;
            cue_melody_env_attack = 0.08;
            cue_melody_env_decay = 2.5;
            cue_melody_env_release = 3.0;
            cue_arp_env_decay = 1.8;
            cue_arp_env_release = 2.5;
            chord_change_beats = 14.0;
            drone_layer.beat_len = .{ 21.5, 27.75 };
            pad_layer.beat_len = .{ 11.25, 15.5, 19.75 };
            melody_layer.beat_len = .{ 7.5, 10.25 };
            arp_layer.beat_len = .{ 3.25, 4.75, 4.0 };
            lfo_filter = .{ .period_beats = 80, .depth = 0.10 };
            lfo_reverb = .{ .period_beats = 130, .depth = 0.05 };
            for (0..layers.AmbientMelodyLayer.COUNT) |m| {
                melody_layer.phrases[m].rest_chance = 0.45;
                melody_layer.phrases[m].region_low = 8;
                melody_layer.phrases[m].region_high = 15;
            }
            for (0..layers.AmbientArpLayer.COUNT) |a| {
                arp_layer.phrases[a].rest_chance = 0.4;
                arp_layer.phrases[a].region_low = 13;
                arp_layer.phrases[a].region_high = 18;
            }
        },
        .twilight => {
            // Dark, descending, minor, very filtered, sparse
            key.scale_type = .natural_minor;
            cue_drone_filter_base = 120.0;
            cue_drone_filter_range = 50.0;
            cue_pad_filter_base = 350.0;
            cue_pad_filter_range = 300.0;
            cue_melody_recall_chance = 0.4;
            cue_reverb_boost = 0.1;
            cue_melody_thresh = 0.45; // melody appears late
            cue_arp_thresh = 0.75; // arp very rare
            cue_drone_env_attack = 5.0;
            cue_drone_env_release = 6.0;
            cue_pad_env_attack = 3.0;
            cue_pad_env_release = 4.5;
            cue_melody_env_attack = 0.2;
            cue_melody_env_decay = 3.0;
            cue_melody_env_release = 3.5;
            cue_arp_env_decay = 2.0;
            cue_arp_env_release = 3.0;
            chord_change_beats = 20.0; // slower chord changes
            drone_layer.beat_len = .{ 27.5, 33.75 };
            pad_layer.beat_len = .{ 17.25, 21.5, 25.75 };
            melody_layer.beat_len = .{ 11.5, 15.25 };
            arp_layer.beat_len = .{ 5.75, 7.25, 6.5 };
            lfo_filter = .{ .period_beats = 120, .depth = 0.06 };
            lfo_reverb = .{ .period_beats = 180, .depth = 0.05 };
            for (0..layers.AmbientMelodyLayer.COUNT) |m| {
                melody_layer.phrases[m].rest_chance = 0.65;
                melody_layer.phrases[m].region_low = 7;
                melody_layer.phrases[m].region_high = 12;
            }
            for (0..layers.AmbientArpLayer.COUNT) |a| {
                arp_layer.phrases[a].rest_chance = 0.6;
                arp_layer.phrases[a].region_low = 11;
                arp_layer.phrases[a].region_high = 15;
            }
        },
        .space => {
            // Very sparse, wide stereo, huge reverb, glacial pace
            key.scale_type = .minor_pentatonic;
            cue_drone_filter_base = 140.0;
            cue_drone_filter_range = 60.0;
            cue_pad_filter_base = 400.0;
            cue_pad_filter_range = 400.0;
            cue_melody_recall_chance = 0.5; // lots of motif recall
            cue_reverb_boost = 0.2; // massive reverb
            cue_melody_thresh = 0.4;
            cue_arp_thresh = 0.5; // arp at moderate tension (shimmer)
            cue_drone_env_attack = 6.0;
            cue_drone_env_release = 8.0;
            cue_pad_env_attack = 4.0;
            cue_pad_env_release = 5.0;
            cue_melody_env_attack = 0.3;
            cue_melody_env_decay = 4.0;
            cue_melody_env_release = 4.0;
            cue_arp_env_decay = 2.5;
            cue_arp_env_release = 3.5;
            chord_change_beats = 24.0; // very slow
            drone_layer.beat_len = .{ 31.5, 37.75 };
            pad_layer.beat_len = .{ 19.25, 23.5, 29.75 };
            melody_layer.beat_len = .{ 13.5, 17.25 };
            arp_layer.beat_len = .{ 4.75, 6.25, 5.5 };
            lfo_filter = .{ .period_beats = 150, .depth = 0.05 };
            lfo_reverb = .{ .period_beats = 200, .depth = 0.06 };
            for (0..layers.AmbientMelodyLayer.COUNT) |m| {
                melody_layer.phrases[m].rest_chance = 0.6;
                melody_layer.phrases[m].region_low = 9;
                melody_layer.phrases[m].region_high = 16;
            }
            for (0..layers.AmbientArpLayer.COUNT) |a| {
                arp_layer.phrases[a].rest_chance = 0.45;
                arp_layer.phrases[a].region_low = 14;
                arp_layer.phrases[a].region_high = 19;
            }
        },
        .forest => {
            // Earthy, mid-register, moderate pace, bird-like melody ornaments
            key.scale_type = .dorian;
            cue_drone_filter_base = 180.0;
            cue_drone_filter_range = 100.0;
            cue_pad_filter_base = 550.0;
            cue_pad_filter_range = 450.0;
            cue_melody_recall_chance = 0.3;
            cue_reverb_boost = 0.0; // natural, less reverb
            cue_melody_thresh = 0.2; // melody comes early
            cue_arp_thresh = 0.4; // arp represents bird calls
            cue_drone_env_attack = 3.0;
            cue_drone_env_release = 4.0;
            cue_pad_env_attack = 1.5;
            cue_pad_env_release = 2.5;
            cue_melody_env_attack = 0.05;
            cue_melody_env_decay = 1.5;
            cue_melody_env_release = 2.0;
            cue_arp_env_decay = 0.8; // shorter, chirpy
            cue_arp_env_release = 1.2;
            chord_change_beats = 12.0; // quicker changes
            drone_layer.beat_len = .{ 19.5, 25.75 };
            pad_layer.beat_len = .{ 11.25, 14.5, 18.75 };
            melody_layer.beat_len = .{ 6.5, 9.25 };
            arp_layer.beat_len = .{ 2.75, 4.25, 3.5 };
            lfo_filter = .{ .period_beats = 70, .depth = 0.09 };
            lfo_reverb = .{ .period_beats = 110, .depth = 0.03 };
            for (0..layers.AmbientMelodyLayer.COUNT) |m| {
                melody_layer.phrases[m].rest_chance = 0.4;
                melody_layer.phrases[m].region_low = 8;
                melody_layer.phrases[m].region_high = 15;
                melody_layer.phrases[m].min_notes = 3;
                melody_layer.phrases[m].max_notes = 6;
            }
            for (0..layers.AmbientArpLayer.COUNT) |a| {
                arp_layer.phrases[a].rest_chance = 0.35;
                arp_layer.phrases[a].region_low = 13;
                arp_layer.phrases[a].region_high = 19;
                arp_layer.phrases[a].min_notes = 3;
                arp_layer.phrases[a].max_notes = 6;
            }
        },
    }
}

// ============================================================
// Chord & note triggering
// ============================================================

fn advanceChord() void {
    _ = harmony.nextChord(&rng);
    const chord = harmony.chords[harmony.current];
    layers.applyAmbientMelodyChord(&melody_layer, &harmony, key.scale_type);
    layers.applyAmbientArpChord(&arp_layer, &harmony, key.scale_type);
    layers.applyAmbientPadChord(&pad_layer, key.root, key.scale_type, chord);
}

// ============================================================
// Vertical layer activation
// ============================================================

fn updateLayerTargets(macro: f32) void {
    drone_target = 0.8 + macro * 0.2;
    pad_target = 0.2 + macro * 0.8;
    melody_target = if (macro > cue_melody_thresh) @min((macro - cue_melody_thresh) * 1.2, 0.8) else 0.0;
    arp_target = if (macro > cue_arp_thresh) @min((macro - cue_arp_thresh) * 1.5, 0.6) else 0.0;
}

// ============================================================
// Reset
// ============================================================

pub fn reset() void {
    global_sample = 0;
    rng = dsp.Rng.init(12345 + @as(u32, @intFromEnum(selected_cue)) * 7);

    key = .{ .root = 36, .scale_type = .minor_pentatonic };
    harmony = initHarmony();
    arcs = .{
        .micro = .{ .section_beats = 8, .shape = .rise_fall },
        .meso = .{ .section_beats = 48, .shape = .rise_fall },
        .macro = .{ .section_beats = 256, .shape = .plateau },
    };
    lfo_filter = .{ .period_beats = 90, .depth = 0.08 };
    lfo_reverb = .{ .period_beats = 150, .depth = 0.04 };
    layers.resetAmbientDroneLayer(&drone_layer);
    layers.resetAmbientPadLayer(&pad_layer);
    layers.resetAmbientMelodyLayer(&melody_layer);
    layers.resetAmbientArpLayer(&arp_layer);

    drone_target = 1.0;
    pad_target = 1.0;
    melody_target = 0.5;
    arp_target = 0.0;
    drone_level = 1.0;
    pad_level = 0.3;
    melody_level = 0.0;
    arp_level = 0.0;

    chord_beat_counter = 0;
    chord_change_beats = 16.0;
    last_macro_quarter = 0;

    reverb = AmbientReverb.init(.{ 0.87, 0.88, 0.89, 0.86 });
    applyCueParams();
}
