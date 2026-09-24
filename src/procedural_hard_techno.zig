// A fixed low-end foundation with repeatable percussion grooves. Long-form
// arrangement and game integration remain separate milestones.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const entropy = @import("music/entropy.zig");
const instruments = @import("music/instruments.zig");

pub const Bus = enum { mix, kick, rumble, low_end, hats, clap, metal, percussion };
pub const Groove = enum { foundation, warehouse, rolling, machine };
pub const Config = struct {
    tempo_scale: f32 = 1.0,
    volume: f32 = 0.86,
    kick_drive: f32 = 2.3,
    kick_decay: f32 = 0.28,
    rumble_level: f32 = 0.52,
    room_mix: f32 = 0.35,
    percussion_level: f32 = 0.65,
    groove: Groove = .warehouse,
    bus: Bus = .mix,
};

pub var config: Config = .{};
pub var kick_count: u64 = 0;
// Closed hats, open hats, claps, metal strikes; counts are independent of solos.
pub var percussion_counts: [4]u64 = .{0} ** 4;
pub const BASE_BPM: f32 = 150.0;
const DELAY_SIZE = 48000;
const COMBS = .{ 1559, 1747, 1999, 2131 };
const ALLPASSES = .{ 241, 613 };
const FEEDBACK = .{ 0.82, 0.84, 0.83, 0.81 };
const Room = dsp.StereoReverb(COMBS, ALLPASSES);

var active_config: Config = .{};
var sequencer: composition.StepSequencer16 = .{};
var kick: instruments.ElectronicKick = .{};
var kick_drive: dsp.CubicSaturator = .{};
var kick_dc: dsp.HPF = dsp.hpfInit(22.0);
var kick_tone: dsp.LPF = dsp.lpfInit(7500.0);
var room: Room = dsp.stereoReverbInit(COMBS, ALLPASSES, FEEDBACK);
var delay: dsp.DelayLine(DELAY_SIZE) = .{};
var delay_half: usize = 9600;
var delay_three_quarters: usize = 14400;
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
var metal: instruments.Atarigane = .{};
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
    active_config = config;
    active_config.tempo_scale = bounded("tempo", config.tempo_scale, 0.35, 1.65, 1.0);
    active_config.volume = bounded("volume", config.volume, 0.0, 1.0, 0.86);
    active_config.kick_drive = bounded("kick drive", config.kick_drive, 1.0, 8.0, 2.3);
    active_config.kick_decay = bounded("kick decay", config.kick_decay, 0.08, 0.8, 0.28);
    active_config.rumble_level = bounded("rumble", config.rumble_level, 0.0, 1.0, 0.52);
    active_config.room_mix = bounded("room", config.room_mix, 0.0, 1.0, 0.35);
    active_config.percussion_level = bounded("percussion", config.percussion_level, 0.0, 1.0, 0.65);
    var noise_seed = seed;
    if (noise_seed == 0) {
        std.log.warn("procedural_hard_techno.resetWithSeed: zero noise seed, using default", .{});
        noise_seed = 0x7EC4_0001;
    }
    kick = .{ .noise = dsp.rngInit(noise_seed) };
    // Independent nonzero streams leave the accepted kick's noise untouched.
    closed_noise = dsp.rngInit((noise_seed ^ 0x4841_5401) | 1);
    open_noise = dsp.rngInit((noise_seed ^ 0x4841_5402) | 1);
    clap_noise = dsp.rngInit((noise_seed ^ 0x434C_4150) | 1);
    metal_noise = dsp.rngInit((noise_seed ^ 0x4D45_544C) | 1);
    closed_hat = .{ .base_frequency_hz = 4100.0, .noise_mix = 0.82, .curved_decay = true };
    open_hat = .{ .base_frequency_hz = 4300.0, .noise_mix = 0.78, .curved_decay = true };
    clap = .{};
    metal = .{ .base_freq = 510.0, .volume = 0.90 };
    metal_pan = 0.0;
    steps_elapsed = 0;
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
    swing_samples = @intFromFloat(@round(beat_samples * 0.25 * 0.16));
    hat_closed_decay = beat_seconds * 0.10;
    hat_open_decay = beat_seconds * 0.55;
    delay_half = @intFromFloat(@round(beat_samples * 0.5));
    delay_three_quarters = @intFromFloat(@round(beat_samples * 0.75));
    ducker = dsp.duckingEnvelopeInit(beat_seconds * 0.10, beat_seconds * 0.20);
    kick_count = 0;
    composition.stepSequencer16Start(&sequencer);
}

fn bounded(label: []const u8, value: f32, low: f32, high: f32, fallback: f32) f32 {
    if (!std.math.isFinite(value) or value < low or value > high) {
        std.log.warn("procedural_hard_techno.reset: invalid {s}={d}, using {d}", .{ label, value, fallback });
        return fallback;
    }
    return value;
}

fn advanceClock() void {
    const step = composition.stepSequencer16AdvanceSample(&sequencer, BASE_BPM * active_config.tempo_scale) orelse return;
    if (step % 4 == 0) {
        instruments.electronicKickTrigger(&kick, .{ .decay_seconds = active_config.kick_decay });
        dsp.duckingEnvelopeTrigger(&ducker);
        kick_count += 1;
    }
    pending_percussion = grooveStep(active_config.groove, steps_elapsed / 16, step);
    pending_delay = if (active_config.groove == .rolling and step % 2 == 1) swing_samples else 0;
    steps_elapsed += 1;
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
        instruments.atariganeDamp(&metal, 0.65);
        instruments.atariganeTriggerChi(&metal, event.metal);
        metal_pan = event.metal_pan;
        percussion_counts[3] += 1;
    }
}

pub fn fillBuffer(buffer: [*]f32, frames: usize) void {
    // Configuration is snapshotted by reset; no live controls in the offline
    // proof. Both buses always run, including the kick feed when soloing rumble.
    const kick_gain = 0.58 / (1.0 + (active_config.kick_drive - 1.0) * 0.045);
    for (0..frames) |frame| {
        advanceClock();
        triggerPendingPercussion();
        const raw = instruments.electronicKickProcess(&kick);
        const driven = dsp.cubicSaturatorProcess(&kick_drive, raw * active_config.kick_drive);
        const kick_sample = dsp.lpfProcess(&kick_tone, dsp.hpfProcess(&kick_dc, driven));
        const send = dsp.lpfProcess(&send_filter, kick_sample);
        // delayLineTap's zero is the previous sample; subtract one so these
        // taps land at exactly the requested half/three-quarter beat positions.
        const delayed = dsp.delayLineTap(DELAY_SIZE, &delay, delay_half - 1) * 0.75 +
            dsp.delayLineTap(DELAY_SIZE, &delay, delay_three_quarters - 1) * 0.35;
        dsp.delayLinePush(DELAY_SIZE, &delay, send);
        const reverberated = dsp.stereoReverbProcess(COMBS, ALLPASSES, &room, .{ send, send });
        const low_input = dsp.hpfProcess(&rumble_dc, delayed + reverberated[0] * active_config.room_mix * 3.0);
        const rumble = dsp.cubicSaturatorProcess(&rumble_drive, low_input * 5.0);
        const filtered = dsp.lpfProcess(&rumble_low2, dsp.lpfProcess(&rumble_low1, rumble));
        const kick_bus = kick_sample * kick_gain;
        // Nonlinear shaping and ducking can reintroduce DC after the input
        // high-pass. Remove it from the final return as well.
        const ducked = filtered * dsp.duckingEnvelopeProcess(&ducker);
        const rumble_bus = dsp.hpfProcess(&rumble_output_dc, ducked) * 0.30 * active_config.rumble_level;
        const closed = dsp.panStereo(instruments.hiHatProcess(&closed_hat, &closed_noise) * 2.0, -0.24);
        const open = dsp.panStereo(instruments.hiHatProcess(&open_hat, &open_noise) * 2.0, 0.20);
        const clap_sample = instruments.electronicClapProcess(&clap, &clap_noise);
        const metal_sample = dsp.panStereo(instruments.atariganeProcess(&metal, &metal_noise) * 2.0, metal_pan);
        for (0..2) |channel| {
            const hats_bus = (closed[channel] + open[channel]) * 0.75 * active_config.percussion_level;
            const clap_bus = clap_sample * 0.45 * active_config.percussion_level;
            const metal_bus = metal_sample[channel] * 0.50 * active_config.percussion_level;
            const percussion = hats_bus + clap_bus + metal_bus;
            const selected = switch (active_config.bus) {
                .mix => kick_bus + rumble_bus + percussion,
                .kick => kick_bus,
                .rumble => rumble_bus,
                .low_end => kick_bus + rumble_bus,
                .hats => hats_bus,
                .clap => clap_bus,
                .metal => metal_bus,
                .percussion => percussion,
            };
            buffer[frame * 2 + channel] = selected * active_config.volume;
        }
    }
}
