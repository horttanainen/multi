const std = @import("std");
const dsp = @import("dsp.zig");

const MS_TO_SAMPLES: f32 = dsp.SAMPLE_RATE / 1000.0;

pub const TimingProfile = struct {
    base_latency_ms: f32,
    step_random_ms: f32,
    strong_step_scale: f32,
    offbeat_drag_min_ms: f32,
    offbeat_drag_max_ms: f32,
    pickup_rush_min_ms: f32,
    pickup_rush_max_ms: f32,
    backbeat_bias_min_ms: f32,
    backbeat_bias_max_ms: f32,
    voice_bias_ms: f32,
    voice_slope_ms: f32,
    clock_initial_ms: f32,
    clock_drift_step_ms: f32,
    clock_drift_base_ms: f32,
    clock_drift_meso_ms: f32,
    clock_smoothing: f32,
    residual_anchor_ms: f32,
    residual_note_ms: f32,
    max_delay_ms: f32,
};

pub const PitchProfile = struct {
    voice_bias_cents: f32,
    residual_anchor_cents: f32,
    residual_note_cents: f32,
    slip_chance: f32,
    slip_cents: f32,
};

pub const PerformerProfile = struct {
    timing: TimingProfile,
    pitch: PitchProfile,
};

pub const ACOUSTIC_GUITAR_PROFILE: PerformerProfile = .{
    .timing = .{
        .base_latency_ms = 9.0,
        .step_random_ms = 1.2,
        .strong_step_scale = 0.35,
        .offbeat_drag_min_ms = -2.2,
        .offbeat_drag_max_ms = 3.4,
        .pickup_rush_min_ms = 0.5,
        .pickup_rush_max_ms = 2.8,
        .backbeat_bias_min_ms = -1.2,
        .backbeat_bias_max_ms = 2.2,
        .voice_bias_ms = 1.4,
        .voice_slope_ms = 0.18,
        .clock_initial_ms = 1.5,
        .clock_drift_step_ms = 0.7,
        .clock_drift_base_ms = 3.0,
        .clock_drift_meso_ms = 2.5,
        .clock_smoothing = 0.22,
        .residual_anchor_ms = 0.45,
        .residual_note_ms = 0.95,
        .max_delay_ms = 22.0,
    },
    .pitch = .{
        .voice_bias_cents = 1.8,
        .residual_anchor_cents = 0.55,
        .residual_note_cents = 1.1,
        .slip_chance = 0.025,
        .slip_cents = 5.0,
    },
};

pub const BANJO_PROFILE: PerformerProfile = .{
    .timing = .{
        .base_latency_ms = 9.0,
        .step_random_ms = 1.35,
        .strong_step_scale = 0.35,
        .offbeat_drag_min_ms = -1.8,
        .offbeat_drag_max_ms = 3.8,
        .pickup_rush_min_ms = 0.8,
        .pickup_rush_max_ms = 3.2,
        .backbeat_bias_min_ms = -1.0,
        .backbeat_bias_max_ms = 2.5,
        .voice_bias_ms = 1.55,
        .voice_slope_ms = 0.2,
        .clock_initial_ms = 1.8,
        .clock_drift_step_ms = 0.85,
        .clock_drift_base_ms = 3.2,
        .clock_drift_meso_ms = 2.8,
        .clock_smoothing = 0.24,
        .residual_anchor_ms = 0.55,
        .residual_note_ms = 1.15,
        .max_delay_ms = 22.0,
    },
    .pitch = .{
        .voice_bias_cents = 1.8,
        .residual_anchor_cents = 0.8,
        .residual_note_cents = 1.5,
        .slip_chance = 0.045,
        .slip_cents = 5.0,
    },
};

pub const ELECTRIC_GUITAR_PROFILE: PerformerProfile = .{
    .timing = .{
        .base_latency_ms = 8.0,
        .step_random_ms = 0.95,
        .strong_step_scale = 0.3,
        .offbeat_drag_min_ms = -1.6,
        .offbeat_drag_max_ms = 2.6,
        .pickup_rush_min_ms = 0.4,
        .pickup_rush_max_ms = 2.0,
        .backbeat_bias_min_ms = -0.9,
        .backbeat_bias_max_ms = 1.8,
        .voice_bias_ms = 1.05,
        .voice_slope_ms = 0.14,
        .clock_initial_ms = 1.1,
        .clock_drift_step_ms = 0.55,
        .clock_drift_base_ms = 2.4,
        .clock_drift_meso_ms = 2.0,
        .clock_smoothing = 0.2,
        .residual_anchor_ms = 0.35,
        .residual_note_ms = 0.75,
        .max_delay_ms = 18.0,
    },
    .pitch = .{
        .voice_bias_cents = 1.25,
        .residual_anchor_cents = 0.45,
        .residual_note_cents = 0.9,
        .slip_chance = 0.018,
        .slip_cents = 4.0,
    },
};

pub fn Performer(comptime step_count: usize, comptime voice_count: usize) type {
    return struct {
        step_bias_ms: [step_count]f32 = [_]f32{0.0} ** step_count,
        voice_bias_ms: [voice_count]f32 = [_]f32{0.0} ** voice_count,
        voice_pitch_bias_cents: [voice_count]f32 = [_]f32{0.0} ** voice_count,
        clock_bias_ms: f32 = 0.0,
        clock_target_ms: f32 = 0.0,
    };
}

pub fn reset(comptime step_count: usize, comptime voice_count: usize, performer: *Performer(step_count, voice_count), rng: *dsp.Rng, profile: PerformerProfile) void {
    if (step_count == 0) {
        std.log.warn("human_performance.reset: step_count is zero", .{});
        return;
    }
    if (voice_count == 0) {
        std.log.warn("human_performance.reset: voice_count is zero", .{});
        return;
    }

    const offbeat_drag = randomRange(rng, profile.timing.offbeat_drag_min_ms, profile.timing.offbeat_drag_max_ms);
    const pickup_rush = randomRange(rng, profile.timing.pickup_rush_min_ms, profile.timing.pickup_rush_max_ms);
    const backbeat_bias = randomRange(rng, profile.timing.backbeat_bias_min_ms, profile.timing.backbeat_bias_max_ms);

    for (0..step_count) |step| {
        var bias = randomRange(rng, -profile.timing.step_random_ms, profile.timing.step_random_ms);
        if (step % 4 == 0) {
            bias *= profile.timing.strong_step_scale;
        }
        if (step % 4 == 2) {
            bias += offbeat_drag;
        }
        if (step == 4 or step == 12) {
            bias += backbeat_bias;
        }
        if (step + 1 == step_count) {
            bias -= pickup_rush;
        }
        performer.step_bias_ms[step] = bias;
    }

    const center_voice = (@as(f32, @floatFromInt(voice_count)) - 1.0) * 0.5;
    for (0..voice_count) |voice_idx| {
        const voice_pos: f32 = @floatFromInt(voice_idx);
        performer.voice_bias_ms[voice_idx] = randomRange(rng, -profile.timing.voice_bias_ms, profile.timing.voice_bias_ms) +
            (voice_pos - center_voice) * randomRange(rng, -profile.timing.voice_slope_ms, profile.timing.voice_slope_ms);
        performer.voice_pitch_bias_cents[voice_idx] = randomRange(rng, -profile.pitch.voice_bias_cents, profile.pitch.voice_bias_cents);
    }

    performer.clock_bias_ms = randomRange(rng, -profile.timing.clock_initial_ms, profile.timing.clock_initial_ms);
    performer.clock_target_ms = performer.clock_bias_ms;
}

pub fn advanceClock(comptime step_count: usize, comptime voice_count: usize, performer: *Performer(step_count, voice_count), rng: *dsp.Rng, profile: PerformerProfile, meso: f32) void {
    const drift_range = profile.timing.clock_drift_base_ms + meso * profile.timing.clock_drift_meso_ms;
    performer.clock_target_ms = std.math.clamp(
        performer.clock_target_ms + randomRange(rng, -profile.timing.clock_drift_step_ms, profile.timing.clock_drift_step_ms),
        -drift_range,
        drift_range,
    );
    performer.clock_bias_ms += (performer.clock_target_ms - performer.clock_bias_ms) * profile.timing.clock_smoothing;
}

pub fn timingDelaySamples(comptime step_count: usize, comptime voice_count: usize, performer: *const Performer(step_count, voice_count), rng: *dsp.Rng, profile: PerformerProfile, step: u8, voice_idx: usize, is_anchor: bool) f32 {
    if (step_count == 0) {
        std.log.warn("human_performance.timingDelaySamples: step_count is zero", .{});
        return 0.0;
    }
    if (voice_idx >= voice_count) {
        std.log.warn("human_performance.timingDelaySamples: voice_idx={d} out of bounds for {d} voices", .{ voice_idx, voice_count });
        return 0.0;
    }

    const step_idx = @min(@as(usize, @intCast(step)), step_count - 1);
    const residual_ms = if (is_anchor) profile.timing.residual_anchor_ms else profile.timing.residual_note_ms;
    const ms = std.math.clamp(
        profile.timing.base_latency_ms + performer.clock_bias_ms + performer.step_bias_ms[step_idx] + performer.voice_bias_ms[voice_idx] + randomRange(rng, -residual_ms, residual_ms),
        0.0,
        profile.timing.max_delay_ms,
    );
    return ms * MS_TO_SAMPLES;
}

pub fn pitchCents(comptime step_count: usize, comptime voice_count: usize, performer: *const Performer(step_count, voice_count), rng: *dsp.Rng, profile: PerformerProfile, voice_idx: usize, is_anchor: bool) f32 {
    if (voice_idx >= voice_count) {
        std.log.warn("human_performance.pitchCents: voice_idx={d} out of bounds for {d} voices", .{ voice_idx, voice_count });
        return 0.0;
    }

    const residual_cents = if (is_anchor) profile.pitch.residual_anchor_cents else profile.pitch.residual_note_cents;
    var cents = performer.voice_pitch_bias_cents[voice_idx] + randomRange(rng, -residual_cents, residual_cents);
    if (!is_anchor and dsp.rngFloat(rng) < profile.pitch.slip_chance) {
        cents += randomRange(rng, -profile.pitch.slip_cents, profile.pitch.slip_cents);
    }
    return cents;
}

fn randomRange(rng: *dsp.Rng, min_value: f32, max_value: f32) f32 {
    return min_value + (max_value - min_value) * dsp.rngFloat(rng);
}
