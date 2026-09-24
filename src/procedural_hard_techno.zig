// Phase 1: centered kick and kick-fed rumble. Arrangement/percussion will use
// this same sample clock in later phases; this proof deliberately repeats.
const std = @import("std");
const dsp = @import("music/dsp.zig");
const composition = @import("music/composition.zig");
const entropy = @import("music/entropy.zig");
const instruments = @import("music/instruments.zig");

pub const Bus = enum { mix, kick, rumble };
pub const Config = struct {
    tempo_scale: f32 = 1.0,
    volume: f32 = 0.86,
    kick_drive: f32 = 2.3,
    kick_decay: f32 = 0.28,
    rumble_level: f32 = 0.52,
    room_mix: f32 = 0.35,
    bus: Bus = .mix,
};

pub var config: Config = .{};
pub var kick_count: u64 = 0;
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
    var noise_seed = seed;
    if (noise_seed == 0) {
        std.log.warn("procedural_hard_techno.resetWithSeed: zero noise seed, using default", .{});
        noise_seed = 0x7EC4_0001;
    }
    kick = .{ .noise = dsp.rngInit(noise_seed) };
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
    if (step % 4 != 0) return;
    instruments.electronicKickTrigger(&kick, .{ .decay_seconds = active_config.kick_decay });
    dsp.duckingEnvelopeTrigger(&ducker);
    kick_count += 1;
}

pub fn fillBuffer(buffer: [*]f32, frames: usize) void {
    // Configuration is snapshotted by reset; no live controls in the offline
    // proof. Both buses always run, including the kick feed when soloing rumble.
    const kick_gain = 0.58 / (1.0 + (active_config.kick_drive - 1.0) * 0.045);
    for (0..frames) |frame| {
        advanceClock();
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
        const selected = switch (active_config.bus) {
            .mix => kick_bus + rumble_bus,
            .kick => kick_bus,
            .rumble => rumble_bus,
        };
        const output = selected * active_config.volume;
        buffer[frame * 2] = output;
        buffer[frame * 2 + 1] = output;
    }
}
