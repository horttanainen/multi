// Repeatable percussion loops and a finite, phrase-aligned track. The same
// voices/effects continue through section boundaries and live sound changes.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const entropy = @import("music/entropy.zig");
const instruments = @import("music/instruments.zig");

pub const Bus = enum { mix, kick, rumble, low_end, hats, clap, metal, percussion, lead, bass };
pub const Groove = enum { foundation, warehouse, rolling, machine };
pub const Lead = enum { off, razor, hollow, wide, machine, buzz, iron, corrosion, bass_synth };
pub const LeadPattern = enum { original, bassline };
pub const Arrangement = enum { loop, track };
pub const TrackSection = enum { intro, drive, contrast, pressure, breakdown, returning, outro, finished };
pub const TRACK_BARS: u64 = 128;
pub const TrackSectionSpec = struct { section: TrackSection, start_bar: u64, end_bar: u64 };
pub const track_sections = [_]TrackSectionSpec{
    .{ .section = .intro, .start_bar = 0, .end_bar = 8 },
    .{ .section = .drive, .start_bar = 8, .end_bar = 40 },
    .{ .section = .contrast, .start_bar = 40, .end_bar = 56 },
    .{ .section = .pressure, .start_bar = 56, .end_bar = 80 },
    .{ .section = .breakdown, .start_bar = 80, .end_bar = 88 },
    .{ .section = .returning, .start_bar = 88, .end_bar = 120 },
    .{ .section = .outro, .start_bar = 120, .end_bar = TRACK_BARS },
};
pub const Config = struct {
    tempo_scale: f32 = 1.0,
    volume: f32 = 0.86,
    kick_drive: f32 = 2.3,
    kick_decay: f32 = 0.28,
    rumble_level: f32 = 0.52,
    room_mix: f32 = 0.35,
    percussion_level: f32 = 0.65,
    metal_voice: instruments.ElectronicAccentTone = .snare,
    groove: Groove = .warehouse,
    arrangement: Arrangement = .loop,
    lead: Lead = .off,
    lead_level: f32 = 0.75,
    lead_pattern: LeadPattern = .original,
    // Both patterns are expressed around G4; -24 selects the accepted G2 register.
    lead_transpose: i8 = 0,
    bass_level: f32 = 0.65,
    // Audition the original sustained bass part higher without changing its voice.
    bass_octaves: u8 = 0,
    repeat_track: bool = false,
    bus: Bus = .mix,
};

pub var config: Config = .{};
pub var kick_count: u64 = 0;
pub var lead_count: u64 = 0;
pub var bass_count: u64 = 0;
// Closed hats, open hats, claps, metal strikes; counts are independent of solos.
pub var percussion_counts: [4]u64 = .{0} ** 4;
pub var current_bar: u64 = 0;
pub var track_section: TrackSection = .intro;
// First sample of each section (including finished). Null means not reached.
pub var section_frames: [8]?u64 = .{null} ** 8;
pub var frames_rendered: u64 = 0;
// Rumble, hats, clap, metal. Exposed for transition diagnostics.
pub var layer_levels: [4]f32 = .{1.0} ** 4;
pub const BASE_BPM: f32 = 150.0;
const DELAY_SIZE = 48000;
const COMBS = .{ 1559, 1747, 1999, 2131 };
const ALLPASSES = .{ 241, 613 };
const FEEDBACK = .{ 0.82, 0.84, 0.83, 0.81 };
const Room = dsp.StereoReverb(COMBS, ALLPASSES);

var active_config: Config = .{};
var target_config: Config = .{};
var playback_seed: u32 = 0x7EC4_0001;
var sequencer: composition.StepSequencer16 = .{};
var kick: instruments.ElectronicKick = .{};
var kick_drive: dsp.CubicSaturator = .{};
var kick_dc: dsp.HPF = dsp.hpfInit(22.0);
var kick_tone: dsp.LPF = dsp.lpfInit(7500.0);
var room: Room = dsp.stereoReverbInit(COMBS, ALLPASSES, FEEDBACK);
var delay: dsp.DelayLine(DELAY_SIZE) = .{};
var delay_half: f32 = 9600;
var delay_three_quarters: f32 = 14400;
var target_delay_half: f32 = 9600;
var target_delay_three_quarters: f32 = 14400;
var send_filter: dsp.LPF = dsp.lpfInit(900.0);
var rumble_dc: dsp.HPF = dsp.hpfInit(32.0);
var rumble_drive: dsp.CubicSaturator = .{};
var rumble_low1: dsp.LPF = dsp.lpfInit(180.0);
var rumble_low2: dsp.LPF = dsp.lpfInit(180.0);
var rumble_output_dc: dsp.HPF = dsp.hpfInit(20.0);
var ducker: dsp.DuckingEnvelope = .{};
var closed_hat: instruments.HiHat = .{};
var open_hat: instruments.HiHat = .{};
var clap: instruments.ElectronicClap = .{};
var metal: instruments.ElectronicAccent = .{};
var closed_noise: dsp.Rng = dsp.rngInit(1);
var open_noise: dsp.Rng = dsp.rngInit(2);
var clap_noise: dsp.Rng = dsp.rngInit(3);
var metal_noise: dsp.Rng = dsp.rngInit(4);
var steps_elapsed: u64 = 0;
var pending_percussion: ?PercussionStep = null;
var pending_delay: u32 = 0;
var swing_samples: u32 = 0;
var hat_closed_decay: f32 = 0.04;
var hat_open_decay: f32 = 0.22;
var metal_pan: f32 = 0.0;
var layer_targets: [4]f32 = .{1.0} ** 4;
var layer_fade_rate: f32 = 0.0;
var outro_fade_elapsed: f64 = 0.0;
var outro_fade_tempo: f32 = 1.0;
var outro_fade_frames: f64 = 1.0;
var lead: instruments.SyncLead = .{};
var bass_lead: instruments.SynthBass = .{};
var lead_delay: dsp.DelayLine(DELAY_SIZE) = .{};
var lead_layer: [1]f32 = .{1.0};
var lead_target: [1]f32 = .{1.0};
var bass: instruments.SynthBass = .{};

pub const NoteStep = struct {
    note: ?u8 = null,
    velocity: f32 = 0.0,
    gate_steps: f32 = 0.55,
};

// Four-bar G-minor counterline. Held notes overlap slightly so the mono voice
// stays legato; kick ducking provides the pulse while pitch follows its own part.
pub fn bassStep(arrangement: Arrangement, bar: u64, step: u8) NoteStep {
    if (step >= 16) {
        std.log.warn("procedural_hard_techno.bassStep: invalid step={d}", .{step});
        return .{};
    }
    if (arrangement == .track and (bar < 8 or (bar >= 80 and bar < 88) or bar >= 124)) return .{};
    // Establish the root quietly on entrance and simplify the outro.
    if (arrangement == .track and (bar < 12 or bar >= 120)) {
        if (step != 0) return .{};
        return .{ .note = 31, .velocity = 0.65, .gate_steps = 16.02 };
    }
    const notes = [4][16]u8{
        .{ 31, 0, 0, 0, 0, 0, 0, 0, 0, 0, 38, 0, 0, 0, 0, 0 },
        .{ 29, 0, 0, 0, 0, 0, 0, 0, 31, 0, 0, 0, 0, 0, 0, 0 },
        .{ 31, 0, 0, 0, 0, 0, 0, 0, 34, 0, 0, 0, 36, 0, 0, 0 },
        .{ 38, 0, 0, 0, 0, 0, 29, 0, 0, 0, 0, 0, 31, 0, 0, 0 },
    };
    const note = notes[bar % notes.len][step];
    if (note == 0) return .{};
    var next_step: usize = step + 1;
    while (next_step < 16 and notes[bar % notes.len][next_step] == 0) : (next_step += 1) {}
    return .{ .note = note, .velocity = if (step == 0) 0.82 else 0.76, .gate_steps = @as(f32, @floatFromInt(next_step - step)) + 0.02 };
}

// Original four-bar G-minor hook, repeated deliberately. Timbre variants share
// the same notes and accents so listening compares the sound of the instrument.
pub fn leadStep(arrangement: Arrangement, bar: u64, step: u8) NoteStep {
    if (step >= 16) {
        std.log.warn("procedural_hard_techno.leadStep: invalid step={d}", .{step});
        return .{};
    }
    if (arrangement == .track) {
        if (!leadSectionEnabled(bar)) return .{};
        if (bar >= 84 and bar < 88 and step % 4 != 0) return .{};
        if (bar == 87 and step >= 12) return .{};
    }
    const notes = [4][16]u8{
        .{ 67, 0, 67, 70, 0, 0, 67, 0, 65, 0, 67, 67, 0, 0, 74, 0 },
        .{ 67, 0, 67, 70, 0, 0, 67, 0, 65, 0, 67, 0, 70, 0, 69, 0 },
        .{ 67, 0, 67, 70, 0, 0, 67, 0, 65, 0, 67, 67, 0, 0, 74, 0 },
        .{ 70, 0, 0, 69, 0, 0, 67, 0, 65, 0, 67, 0, 0, 0, 62, 0 },
    };
    const note = notes[bar % notes.len][step];
    if (note == 0) return .{};
    var velocity: f32 = if (step % 4 == 0) 0.95 else 0.76;
    if (arrangement == .track and ((bar >= 84 and bar < 88) or bar >= 120)) velocity *= 0.70;
    return .{ .note = note, .velocity = velocity, .gate_steps = if (step == 14) 1.10 else 0.55 };
}

fn leadSectionEnabled(bar: u64) bool {
    return !(bar < 16 or (bar >= 40 and bar < 56) or (bar >= 64 and bar < 72) or
        (bar >= 80 and bar < 84) or bar >= 124);
}

pub fn leadPatternStep(pattern: LeadPattern, arrangement: Arrangement, bar: u64, step: u8) NoteStep {
    if (pattern == .original) return leadStep(arrangement, bar, step);
    if (arrangement == .track and (!leadSectionEnabled(bar) or (bar == 87 and step >= 12))) return .{};
    var event = bassStep(.loop, bar, step);
    const note = event.note orelse return event; // Normal score rest.
    event.note = note + 36;
    if (arrangement == .track and ((bar >= 84 and bar < 88) or bar >= 120)) event.velocity *= 0.70;
    return event;
}

pub const TrackStep = struct {
    section: TrackSection = .finished,
    groove: Groove = .warehouse,
    layers: [4]f32 = .{0.0} ** 4,
    kick_enabled: bool = false,
    fill: bool = false,
};

pub fn arrangementStep(bar: u64, step: u8) TrackStep {
    if (step >= 16) {
        std.log.warn("procedural_hard_techno.arrangementStep: invalid step={d}", .{step});
        return .{};
    }
    if (bar >= TRACK_BARS) return .{};
    var section: ?TrackSection = null;
    for (track_sections) |entry| {
        if (bar >= entry.end_bar) continue;
        section = entry.section;
        break;
    }
    const selected = section orelse {
        std.log.warn("procedural_hard_techno.arrangementStep: no section for bar={d}", .{bar});
        return .{};
    };
    var plan: TrackStep = .{ .section = selected, .layers = .{1.0} ** 4, .kick_enabled = true };
    switch (selected) {
        .intro => {
            plan.layers = if (bar < 4) .{ 0.0, 0.25, 0.0, 0.0 } else .{ 0.65, 0.60, 0.0, 0.0 };
        },
        .drive => {
            if (bar < 16) plan.layers = .{ 1.0, 0.78, 0.75, 0.0 };
            if (bar >= 16 and bar < 32) plan.layers[3] = 0.55;
            plan.fill = bar == 31 or bar == 39;
        },
        .contrast => {
            plan.groove = .machine;
            plan.layers = .{ 0.85, 0.80, 0.90, 1.0 };
            plan.fill = bar == 55;
        },
        .pressure => {
            plan.layers[3] = 0.80;
            if (bar >= 64 and bar < 72) plan.layers = .{ 1.0, 0.90, 0.75, 0.55 };
            plan.fill = bar == 71 or bar == 79;
        },
        .breakdown => {
            plan.kick_enabled = false;
            plan.layers = if (bar < 84) .{ 0.25, 0.45, 0.0, 0.50 } else .{ 0.0, 0.70, 0.65, 0.75 };
            plan.fill = bar >= 86;
            if (bar == 87 and step >= 12) plan.layers = .{0.0} ** 4;
        },
        .returning => {
            // Re-establish the preferred groove before small late-phrase answers.
            plan.layers[3] = if (bar < 104) 0.55 else 1.0;
            plan.fill = bar == 103 or bar == 119;
        },
        .outro => {
            plan.layers = if (bar < 124) .{ 0.70, 0.55, 0.0, 0.40 } else .{ 0.35, 0.0, 0.0, 0.0 };
        },
        .finished => return .{},
    }
    return plan;
}

fn arrangePercussion(event: *PercussionStep, plan: TrackStep, bar: u64, step: u8) void {
    if (plan.section == .finished) {
        event.* = .{};
        return;
    }
    if (plan.section == .intro and bar < 4) event.open = 0.0;
    if (plan.section == .breakdown) {
        event.open = 0.0;
        event.clap = 0.0;
        event.metal = if (step == 2 or step == 10) 0.30 else 0.0;
        if (bar == 87 and step >= 12) {
            event.* = .{};
            return;
        }
    }
    if (plan.fill and step >= 12) {
        event.closed = if (step % 2 == 0) 0.62 else 0.38;
        event.open = 0.0;
        if (step == 14) event.clap = 0.38;
        if (step == 15) event.metal = 0.48;
    }
    // The last two bars of the break build before leaving a beat of space.
    if (plan.section == .breakdown and bar >= 86 and step % 2 == 0) {
        event.clap = 0.22 + @as(f32, @floatFromInt(step)) * 0.018;
    }
    // Unheard voices are not newly triggered, but their existing tails continue.
    if (plan.layers[1] == 0.0) {
        event.closed = 0.0;
        event.open = 0.0;
    }
    if (plan.layers[2] == 0.0) event.clap = 0.0;
    if (plan.layers[3] == 0.0) event.metal = 0.0;
}

pub const PercussionStep = struct {
    closed: f32 = 0.0,
    open: f32 = 0.0,
    clap: f32 = 0.0,
    metal: f32 = 0.0,
    metal_pan: f32 = 0.0,
};

// Deliberate accents and two/four-bar answers. No sample-level RNG participates
// in the score, so changing timbre or soloing a bus cannot change later notes.
pub fn grooveStep(groove: Groove, bar: u64, step: u8) PercussionStep {
    if (step >= 16) {
        std.log.warn("procedural_hard_techno.grooveStep: invalid step={d}", .{step});
        return .{};
    }
    if (groove == .foundation) return .{};
    var event: PercussionStep = .{};
    switch (groove) {
        .foundation => {},
        .warehouse => {
            const closed = [_]f32{ 0.44, 0.22, 0, 0.32, 0.38, 0.20, 0, 0.29, 0.46, 0.23, 0, 0.34, 0.38, 0.22, 0, 0.31 };
            event.closed = closed[step];
            if (step % 4 == 2) event.open = 0.72;
            if (step == 4 or step == 12) event.clap = 0.90;
            if (bar % 2 == 1 and step == 15) event.metal = 0.48;
        },
        .rolling => {
            const closed = [_]f32{ 0.35, 0.18, 0, 0.48, 0.30, 0.56, 0.32, 0.22, 0.36, 0.20, 0, 0.52, 0.29, 0.58, 0.35, 0.26 };
            event.closed = closed[step];
            if (step == 2 or step == 10) event.open = 0.68;
            if (step == 4 or step == 12) event.clap = 0.82;
            if (step == 6 or step == 14) event.metal = 0.36;
            if (bar % 2 == 1 and step == 15) event.clap = 0.22;
        },
        .machine => {
            const closed = [_]f32{ 0.46, 0, 0, 0.62, 0, 0.30, 0, 0, 0.48, 0, 0.26, 0.60, 0, 0.32, 0, 0 };
            event.closed = closed[step];
            if (step == 6 or step == 14) event.open = 0.82;
            if (step == 4 or step == 12) event.clap = 0.92;
            if (step == 3 or step == 10) event.metal = 0.62;
            if (bar % 2 == 1 and step == 15) event.metal = 0.45;
        },
    }
    // A small turnaround, not a section change or a new random composition.
    if (bar % 4 == 3 and step == 15) event.closed = 0.60;
    event.metal_pan = if (bar % 2 == 0) -0.30 else 0.30;
    return event;
}

pub fn reset() void {
    resetWithSeed(entropy.nextSeed(0x7EC4_0001, 0));
}

// Explicit seed reset makes timbre and isolated-bus comparisons repeatable.
// The fixed score consumes no random numbers; noise belongs to the instrument.
pub fn resetWithSeed(seed: u32) void {
    active_config = sanitizeConfig(config);
    target_config = active_config;
    if (config.arrangement == .track and config.groove != .warehouse) {
        std.log.warn("procedural_hard_techno.reset: track mode uses Warehouse/Machine; ignoring loop groove", .{});
        active_config.groove = .warehouse;
    }
    var noise_seed = seed;
    if (noise_seed == 0) {
        std.log.warn("procedural_hard_techno.resetWithSeed: zero noise seed, using default", .{});
        noise_seed = 0x7EC4_0001;
    }
    playback_seed = noise_seed;
    kick = .{ .noise = dsp.rngInit(noise_seed) };
    // Independent nonzero streams leave the accepted kick's noise untouched.
    closed_noise = dsp.rngInit((noise_seed ^ 0x4841_5401) | 1);
    open_noise = dsp.rngInit((noise_seed ^ 0x4841_5402) | 1);
    clap_noise = dsp.rngInit((noise_seed ^ 0x434C_4150) | 1);
    metal_noise = dsp.rngInit((noise_seed ^ 0x4D45_544C) | 1);
    closed_hat = .{ .base_frequency_hz = 4100.0, .noise_mix = 0.82, .curved_decay = true };
    open_hat = .{ .base_frequency_hz = 4300.0, .noise_mix = 0.78, .curved_decay = true };
    clap = .{};
    metal = .{ .tone = active_config.metal_voice };
    metal_pan = 0.0;
    lead = .{ .tone = switch (active_config.lead) {
        .off, .razor, .bass_synth => .razor,
        .hollow => .hollow,
        .wide => .wide,
        .machine => .machine,
        .buzz => .buzz,
        .iron => .iron,
        .corrosion => .corrosion,
    } };
    lead_delay = .{};
    bass_lead = .{};
    lead_layer = .{1.0};
    lead_target = .{1.0};
    lead_count = 0;
    bass = .{};
    bass_count = 0;
    steps_elapsed = 0;
    current_bar = 0;
    track_section = .intro;
    section_frames = .{null} ** 8;
    frames_rendered = 0;
    layer_levels = if (active_config.arrangement == .track) .{0.0} ** 4 else .{1.0} ** 4;
    layer_targets = layer_levels;
    outro_fade_elapsed = 0.0;
    outro_fade_tempo = active_config.tempo_scale;
    pending_percussion = null;
    pending_delay = 0;
    percussion_counts = .{0} ** 4;
    kick_drive = .{};
    kick_dc = dsp.hpfInit(22.0);
    kick_tone = dsp.lpfInit(7500.0);
    room = dsp.stereoReverbInit(COMBS, ALLPASSES, FEEDBACK);
    delay = .{};
    send_filter = dsp.lpfInit(900.0);
    rumble_dc = dsp.hpfInit(32.0);
    rumble_drive = .{};
    rumble_low1 = dsp.lpfInit(180.0);
    rumble_low2 = dsp.lpfInit(180.0);
    rumble_output_dc = dsp.hpfInit(20.0);
    const beat_seconds = 60.0 / (BASE_BPM * active_config.tempo_scale);
    const beat_samples = beat_seconds * dsp.SAMPLE_RATE;
    layer_fade_rate = 1.0 - @exp(-dsp.INV_SR / 0.020);
    outro_fade_frames = @as(f64, beat_samples) * 16.0;
    swing_samples = @intFromFloat(@round(beat_samples * 0.25 * 0.16));
    hat_closed_decay = beat_seconds * 0.10;
    hat_open_decay = beat_seconds * 0.55;
    delay_half = @round(beat_samples * 0.5);
    delay_three_quarters = @round(beat_samples * 0.75);
    target_delay_half = delay_half;
    target_delay_three_quarters = delay_three_quarters;
    ducker = dsp.duckingEnvelopeInit(beat_seconds * 0.10, beat_seconds * 0.20);
    kick_count = 0;
    composition.stepSequencer16Start(&sequencer);
}

pub fn sanitizeConfig(value: Config) Config {
    var result = value;
    result.tempo_scale = bounded("tempo", value.tempo_scale, 0.35, 1.65, 1.0);
    result.volume = bounded("volume", value.volume, 0.0, 1.0, 0.86);
    result.kick_drive = bounded("kick drive", value.kick_drive, 1.0, 8.0, 2.3);
    result.kick_decay = bounded("kick decay", value.kick_decay, 0.08, 0.8, 0.28);
    result.rumble_level = bounded("rumble", value.rumble_level, 0.0, 1.0, 0.52);
    result.room_mix = bounded("room", value.room_mix, 0.0, 1.0, 0.35);
    result.percussion_level = bounded("percussion", value.percussion_level, 0.0, 1.0, 0.65);
    result.lead_level = bounded("lead level", value.lead_level, 0.0, 1.0, 0.75);
    result.lead_transpose = @intFromFloat(bounded("lead transpose", @floatFromInt(value.lead_transpose), -24, 0, 0));
    result.bass_level = bounded("bass level", value.bass_level, 0.0, 1.0, 0.65);
    result.bass_octaves = @intFromFloat(bounded("bass octaves", @floatFromInt(value.bass_octaves), 0, 3, 0));
    return result;
}

// Caller owns synchronization with fillBuffer. Sound changes preserve score,
// oscillator and effect state; changing playback mode or patch restarts the score.
pub fn applyLiveConfig(value: Config) void {
    const next = sanitizeConfig(value);
    config = next;
    if (next.arrangement != active_config.arrangement or next.lead != active_config.lead or
        next.lead_pattern != active_config.lead_pattern or next.metal_voice != active_config.metal_voice)
    {
        resetWithSeed(playback_seed);
        return;
    }
    target_config = next;
    active_config.groove = next.groove;
    active_config.lead_transpose = next.lead_transpose;
    active_config.bass_octaves = next.bass_octaves;
    active_config.bus = next.bus;
    active_config.repeat_track = next.repeat_track;
    if (next.tempo_scale == active_config.tempo_scale) return;
    // Preserve progress within the step when its duration changes; otherwise
    // increasing tempo can emit several overdue notes on consecutive samples.
    sequencer.step_counter *= active_config.tempo_scale / next.tempo_scale;
    // Held bass gates follow the remaining musical duration when tempo changes.
    bass.gate_left = @intFromFloat(@round(@as(f32, @floatFromInt(bass.gate_left)) * active_config.tempo_scale / next.tempo_scale));
    bass_lead.gate_left = @intFromFloat(@round(@as(f32, @floatFromInt(bass_lead.gate_left)) * active_config.tempo_scale / next.tempo_scale));
    active_config.tempo_scale = next.tempo_scale;
    const beat_seconds = 60.0 / (BASE_BPM * next.tempo_scale);
    const beat_samples = beat_seconds * dsp.SAMPLE_RATE;
    target_delay_half = @round(beat_samples * 0.5);
    target_delay_three_quarters = @round(beat_samples * 0.75);
    swing_samples = @intFromFloat(@round(beat_samples * 0.25 * 0.16));
    hat_closed_decay = beat_seconds * 0.10;
    hat_open_decay = beat_seconds * 0.55;
    const timing = dsp.duckingEnvelopeInit(beat_seconds * 0.10, beat_seconds * 0.20);
    ducker.hold_samples = timing.hold_samples;
    ducker.release_coefficient = timing.release_coefficient;
}

fn smoothControls() void {
    inline for (.{ "volume", "kick_drive", "kick_decay", "rumble_level", "room_mix", "percussion_level", "lead_level", "bass_level" }) |name| {
        const current = &@field(active_config, name);
        current.* = approachControl(current.*, @field(target_config, name));
    }
    delay_half = approachControl(delay_half, target_delay_half);
    delay_three_quarters = approachControl(delay_three_quarters, target_delay_three_quarters);
}

fn approachControl(current: f32, target: f32) f32 {
    const next = current + (target - current) * 0.001;
    if (@abs(target - current) < 0.00001 or next == current) return target;
    return next;
}

fn bounded(label: []const u8, value: f32, low: f32, high: f32, fallback: f32) f32 {
    if (!std.math.isFinite(value) or value < low or value > high) {
        std.log.warn("procedural_hard_techno.sanitizeConfig: invalid {s}={d}, using {d}", .{ label, value, fallback });
        return fallback;
    }
    return value;
}

fn advanceClock() void {
    if (active_config.arrangement == .track and track_section == .finished) return;
    const step = composition.stepSequencer16AdvanceSample(&sequencer, BASE_BPM * active_config.tempo_scale) orelse return;
    current_bar = steps_elapsed / 16;
    var groove = active_config.groove;
    var kick_enabled = true;
    var plan: TrackStep = .{};
    if (active_config.arrangement == .track) {
        plan = arrangementStep(current_bar, step);
        track_section = plan.section;
        const section_index = @intFromEnum(track_section);
        if (section_frames[section_index] == null) section_frames[section_index] = frames_rendered;
        layer_targets = plan.layers;
        groove = plan.groove;
        kick_enabled = plan.kick_enabled;
        if (current_bar == 124 and step == 0) outro_fade_elapsed = 0.0;
        if (track_section == .finished) {
            pending_percussion = null;
            return;
        }
    }
    if (kick_enabled and step % 4 == 0) {
        instruments.electronicKickTrigger(&kick, .{ .decay_seconds = active_config.kick_decay });
        dsp.duckingEnvelopeTrigger(&ducker);
        kick_count += 1;
    }
    if (active_config.lead != .off) {
        lead_target[0] = if (active_config.arrangement == .track and current_bar == 87 and step >= 12) 0.0 else 1.0;
        const note_event = leadPatternStep(active_config.lead_pattern, active_config.arrangement, current_bar, step);
        triggerLead(note_event);
    }
    triggerBass(bassStep(active_config.arrangement, current_bar, step));
    var event = grooveStep(groove, current_bar, step);
    if (active_config.arrangement == .track) arrangePercussion(&event, plan, current_bar, step);
    pending_percussion = event;
    pending_delay = if (groove == .rolling and step % 2 == 1) swing_samples else 0;
    steps_elapsed += 1;
}

fn triggerBass(event: NoteStep) void {
    const note = event.note orelse return; // A rest is an ordinary score event.
    const step_seconds = 60.0 / (BASE_BPM * active_config.tempo_scale * 4.0);
    const pitched_note = note + active_config.bass_octaves * 12;
    instruments.synthBassTrigger(&bass, pitched_note, event.velocity, step_seconds * event.gate_steps);
    bass_count += 1;
}

fn triggerLead(event: NoteStep) void {
    const note = event.note orelse return; // A rest is an ordinary score event.
    const step_seconds = 60.0 / (BASE_BPM * active_config.tempo_scale * 4.0);
    const pitched_note: u8 = @intCast(@as(i16, note) + active_config.lead_transpose);
    if (active_config.lead == .bass_synth) {
        instruments.synthBassTrigger(&bass_lead, pitched_note, event.velocity, step_seconds * event.gate_steps);
    } else {
        instruments.syncLeadTrigger(&lead, pitched_note, event.velocity, step_seconds * event.gate_steps);
    }
    lead_count += 1;
}

fn processLead(duck_gain: f32) [2]f32 {
    if (active_config.lead == .off) return .{ 0.0, 0.0 };
    composition.easeLevels(1, &lead_layer, &lead_target, layer_fade_rate);
    if (active_config.lead == .bass_synth) {
        // Match the accepted bass stem at bass_level 0.65, raised by exactly 6 dB,
        // when lead_level is the normal 0.75. Preserve its mono bass processing.
        const gain = (0.30 * 0.65 * std.math.pow(f32, 10, 6.0 / 20.0) / 0.75) * active_config.lead_level;
        const sample = instruments.synthBassProcess(&bass_lead) * gain * (0.20 + 0.80 * duck_gain) * lead_layer[0];
        return .{ sample, sample };
    }
    const dry = instruments.syncLeadProcess(&lead) * 0.24 * active_config.lead_level;
    const left_echo = dsp.delayLineTapFractional(DELAY_SIZE, &lead_delay, delay_half - 1);
    const right_echo = dsp.delayLineTapFractional(DELAY_SIZE, &lead_delay, delay_three_quarters - 1);
    dsp.delayLinePush(DELAY_SIZE, &lead_delay, dry + right_echo * 0.28);
    // Let the hook cut through between kicks while reserving room for each hit.
    const gain = (0.25 + 0.75 * duck_gain) * lead_layer[0];
    const echo_gain: f32 = switch (active_config.lead) {
        .machine, .buzz, .iron, .corrosion => 0.5,
        else => 1.0,
    };
    return .{ (dry + left_echo * 0.20 * echo_gain) * gain, (dry + right_echo * 0.24 * echo_gain) * gain };
}

fn triggerPendingPercussion() void {
    const event = pending_percussion orelse return;
    if (pending_delay > 0) {
        pending_delay -= 1;
        return;
    }
    pending_percussion = null;
    if (event.closed > 0.0) {
        instruments.hiHatChoke(&open_hat);
        instruments.hiHatTriggerWithDecay(&closed_hat, event.closed, hat_closed_decay);
        percussion_counts[0] += 1;
    }
    if (event.open > 0.0) {
        instruments.hiHatTriggerWithDecay(&open_hat, event.open, hat_open_decay);
        percussion_counts[1] += 1;
    }
    if (event.clap > 0.0) {
        instruments.electronicClapTrigger(&clap, event.clap);
        percussion_counts[2] += 1;
    }
    if (event.metal > 0.0) {
        instruments.electronicAccentTrigger(&metal, event.metal);
        metal_pan = event.metal_pan;
        percussion_counts[3] += 1;
    }
}

pub fn fillBuffer(buffer: [*]f32, frames: usize) void {
    // Both buses run, including the kick feed when soloing rumble. Live
    // controls are smoothed per sample, independent of callback chunk size.
    for (0..frames) |frame| {
        smoothControls();
        const kick_gain = 0.58 / (1.0 + (active_config.kick_drive - 1.0) * 0.045);
        // Reserve headroom for the added voice without a nonlinear master
        // limiter. All stems share this gain; bass level zero keeps the old mix.
        const output_gain = active_config.volume * @as(f32, if (active_config.lead == .off) 1.0 else 0.86) /
            (1.0 + active_config.bass_level * 0.25);
        advanceClock();
        if (active_config.arrangement == .track and track_section == .finished and active_config.repeat_track) {
            resetWithSeed(playback_seed);
            advanceClock();
        }
        if (active_config.arrangement == .track and track_section == .finished) {
            buffer[frame * 2] = 0.0;
            buffer[frame * 2 + 1] = 0.0;
            frames_rendered += 1;
            continue;
        }
        var master_fade: f32 = 1.0;
        if (active_config.arrangement == .track) {
            composition.easeLevels(4, &layer_levels, &layer_targets, layer_fade_rate);
            if (current_bar >= 124) {
                master_fade = @floatCast(@max(0.0, 1.0 - outro_fade_elapsed / outro_fade_frames));
                outro_fade_elapsed += @as(f64, active_config.tempo_scale) / outro_fade_tempo;
            }
        }
        triggerPendingPercussion();
        const raw = instruments.electronicKickProcess(&kick);
        const driven = dsp.cubicSaturatorProcess(&kick_drive, raw * active_config.kick_drive);
        const kick_sample = dsp.lpfProcess(&kick_tone, dsp.hpfProcess(&kick_dc, driven));
        const send = dsp.lpfProcess(&send_filter, kick_sample);
        // delayLineTap's zero is the previous sample; subtract one so these
        // taps land at exactly the requested half/three-quarter beat positions.
        const delayed = dsp.delayLineTapFractional(DELAY_SIZE, &delay, delay_half - 1) * 0.75 +
            dsp.delayLineTapFractional(DELAY_SIZE, &delay, delay_three_quarters - 1) * 0.35;
        dsp.delayLinePush(DELAY_SIZE, &delay, send);
        const reverberated = dsp.stereoReverbProcess(COMBS, ALLPASSES, &room, .{ send, send });
        const low_input = dsp.hpfProcess(&rumble_dc, delayed + reverberated[0] * active_config.room_mix * 3.0);
        const rumble = dsp.cubicSaturatorProcess(&rumble_drive, low_input * 5.0);
        const filtered = dsp.lpfProcess(&rumble_low2, dsp.lpfProcess(&rumble_low1, rumble));
        const kick_bus = kick_sample * kick_gain;
        // Nonlinear shaping and ducking can reintroduce DC after the input
        // high-pass. Remove it from the final return as well.
        const duck_gain = dsp.duckingEnvelopeProcess(&ducker);
        const ducked = filtered * duck_gain;
        var rumble_bus = dsp.hpfProcess(&rumble_output_dc, ducked) * 0.30 * active_config.rumble_level;
        if (active_config.arrangement == .track) rumble_bus *= layer_levels[0];
        const closed = dsp.panStereo(instruments.hiHatProcess(&closed_hat, &closed_noise) * 2.0, -0.24);
        const open = dsp.panStereo(instruments.hiHatProcess(&open_hat, &open_noise) * 2.0, 0.20);
        const clap_sample = instruments.electronicClapProcess(&clap, &clap_noise);
        const metal_sample = dsp.panStereo(instruments.electronicAccentProcess(&metal, &metal_noise) * 2.0, metal_pan);
        const lead_bus = processLead(duck_gain);
        // Keep some held tone audible under each kick instead of gating it away.
        const bass_bus = instruments.synthBassProcess(&bass) * active_config.bass_level * 0.30 * (0.20 + 0.80 * duck_gain);
        for (0..2) |channel| {
            var hats_bus = (closed[channel] + open[channel]) * 0.75 * active_config.percussion_level;
            var clap_bus = clap_sample * 0.45 * active_config.percussion_level;
            var metal_bus = metal_sample[channel] * 0.50 * active_config.percussion_level;
            if (active_config.arrangement == .track) {
                hats_bus *= layer_levels[1];
                clap_bus *= layer_levels[2];
                metal_bus *= layer_levels[3];
            }
            const percussion = hats_bus + clap_bus + metal_bus;
            const selected = switch (active_config.bus) {
                .mix => kick_bus + rumble_bus + percussion + lead_bus[channel] + bass_bus,
                .kick => kick_bus,
                .rumble => rumble_bus,
                .low_end => kick_bus + rumble_bus + bass_bus,
                .hats => hats_bus,
                .clap => clap_bus,
                .metal => metal_bus,
                .percussion => percussion,
                .lead => lead_bus[channel],
                .bass => bass_bus,
            };
            buffer[frame * 2 + channel] = selected * output_gain * master_fade;
        }
        frames_rendered += 1;
    }
}
