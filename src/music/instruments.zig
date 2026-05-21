const std = @import("std");
const dsp = @import("dsp.zig");

const GUITAR_FAUST_STRING_BUFFER_SIZE = 8192;
const GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS: f32 = 0.68;
const GUITAR_FAUST_PROMOTED_STRING_DECAY: f32 = 0.7765;
const GUITAR_FAUST_PROMOTED_HIGH_DECAY: f32 = 0.54;
const GUITAR_FAUST_PROMOTED_BRIDGE_COUPLING: f32 = 0.85;
const GUITAR_FAUST_PROMOTED_MUTE: f32 = 0.114;
const GUITAR_FAUST_ELECTRIC_DEFAULT_PLUCK_POSITION: f32 = 0.8;
const GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS: f32 = 0.8;
const GUITAR_FAUST_ELECTRIC_BRIDGE_ABSORPTION: f32 = 0.6;
const GUITAR_FAUST_ELECTRIC_STIFFNESS: f32 = 0.05;

pub const GuitarParams = struct {
    pluck_position: ?f32 = null,
    pluck_brightness: ?f32 = null,
    string_mix_scale: f32 = 1.0,
    body_mix_scale: f32 = 1.0,
    attack_mix_scale: f32 = 1.0,
    mute_amount: f32 = 0.0,
    string_decay_scale: f32 = 1.0,
    body_gain_scale: f32 = 1.0,
    body_decay_scale: f32 = 1.0,
    body_freq_scale: f32 = 1.0,
    pick_noise_scale: f32 = 1.0,
    attack_gain_scale: f32 = 1.0,
    attack_decay_scale: f32 = 1.0,
    bridge_coupling_scale: f32 = 1.0,
    inharmonicity_scale: f32 = 1.0,
    high_decay_scale: f32 = 1.0,
    output_gain_scale: f32 = 1.0,
    rng_seed: ?u32 = null,
};

pub const GuitarProbeParams = GuitarParams;

pub const GUITAR_FAUST_PROMOTED_PARAMS: GuitarParams = .{
    .pluck_position = 0.1678,
    .pluck_brightness = GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS,
    .string_mix_scale = 1.35,
    .body_mix_scale = 1.55,
    .attack_mix_scale = 0.55,
    .mute_amount = GUITAR_FAUST_PROMOTED_MUTE,
    .string_decay_scale = GUITAR_FAUST_PROMOTED_STRING_DECAY,
    .body_gain_scale = 1.55,
    .body_decay_scale = 1.22,
    .body_freq_scale = 0.8752,
    .pick_noise_scale = 0.6683,
    .attack_gain_scale = 0.6903,
    .attack_decay_scale = 0.5456,
    .bridge_coupling_scale = GUITAR_FAUST_PROMOTED_BRIDGE_COUPLING,
    .inharmonicity_scale = 0.4292,
    .high_decay_scale = GUITAR_FAUST_PROMOTED_HIGH_DECAY,
    .output_gain_scale = 0.9934,
};

const GuitarFaustBridgeFilter = struct {
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    h0: f32 = 0.7,
    h1: f32 = 0.15,
    rho: f32 = 0.99784,
};

pub const GuitarFaustPluckStep = struct {
    string_sample: f32 = 0.0,
    bridge_signal: f32 = 0.0,
};

pub const GuitarFaustPluck = struct {
    buffer: [GUITAR_FAUST_STRING_BUFFER_SIZE]f32 = [_]f32{0.0} ** GUITAR_FAUST_STRING_BUFFER_SIZE,
    write_pos: usize = 0,
    delay_samples: usize = 128,
    frac: f32 = 0.0,
    params: GuitarParams = .{},
    rng: dsp.Rng = dsp.rngInit(0xFA57_921D),
    bridge_filter: GuitarFaustBridgeFilter = .{},
    nut_filter: GuitarFaustBridgeFilter = .{},
    excitation_lpf1: dsp.LPF = dsp.lpfInit(1800.0),
    excitation_lpf2: dsp.LPF = dsp.lpfInit(1800.0),
    stiffness_smooth1: f32 = 0.0,
    stiffness_smooth2: f32 = 0.0,
    out_hpf: dsp.HPF = dsp.hpfInit(32.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9800.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    feedback: f32 = 0.9968,
    age: u32 = 999999,
};

pub const GuitarFaustElectricStep = struct {
    pickup_sample: f32 = 0.0,
    nut_wave: f32 = 0.0,
    bridge_wave: f32 = 0.0,
};

pub const GuitarFaustElectric = struct {
    nut_buffer: [GUITAR_FAUST_STRING_BUFFER_SIZE]f32 = [_]f32{0.0} ** GUITAR_FAUST_STRING_BUFFER_SIZE,
    bridge_buffer: [GUITAR_FAUST_STRING_BUFFER_SIZE]f32 = [_]f32{0.0} ** GUITAR_FAUST_STRING_BUFFER_SIZE,
    nut_write_pos: usize = 0,
    bridge_write_pos: usize = 0,
    nut_delay_samples: usize = 128,
    bridge_delay_samples: usize = 128,
    nut_frac: f32 = 0.0,
    bridge_frac: f32 = 0.0,
    params: GuitarParams = .{},
    rng: dsp.Rng = dsp.rngInit(0xE1EC_7A21),
    bridge_filter: GuitarFaustBridgeFilter = .{},
    nut_filter: GuitarFaustBridgeFilter = .{},
    excitation_lpf1: dsp.LPF = dsp.lpfInit(1800.0),
    excitation_lpf2: dsp.LPF = dsp.lpfInit(1800.0),
    stiffness_smooth1: f32 = 0.0,
    stiffness_smooth2: f32 = 0.0,
    out_hpf: dsp.HPF = dsp.hpfInit(54.0),
    out_lpf: dsp.LPF = dsp.lpfInit(12800.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    mute: f32 = 1.0,
    age: u32 = 999999,
};

pub fn guitarFaustPluckTrigger(ctx: *GuitarFaustPluck, frequency_hz: f32, velocity: f32) void {
    guitarFaustPluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarFaustPluckTriggerWithParams(ctx: *GuitarFaustPluck, frequency_hz: f32, velocity: f32, params: GuitarParams) void {
    ctx.* = .{};
    ctx.params = guitarParamsSanitized(params);
    ctx.rng = dsp.rngInit(ctx.params.rng_seed orelse 0xFA57_921D);
    ctx.frequency_hz = guitarFrequencySafe(frequency_hz);
    ctx.velocity = guitarVelocitySafe(velocity);

    const delay_f = std.math.clamp(dsp.SAMPLE_RATE / ctx.frequency_hz, 8.0, @as(f32, @floatFromInt(GUITAR_FAUST_STRING_BUFFER_SIZE - 2)));
    const delay_floor = @floor(delay_f);
    ctx.delay_samples = @intFromFloat(delay_floor);
    ctx.frac = delay_f - delay_floor;
    if (ctx.delay_samples < 8) {
        std.log.warn("guitarFaustPluckTriggerWithParams: delay_samples={d} is invalid, clamping to 8", .{ctx.delay_samples});
        ctx.delay_samples = 8;
    }

    ctx.bridge_filter = guitarFaustBridgeFilterInit(guitarFaustBridgeBrightness(ctx.params), guitarFaustBridgeAbsorption(ctx.params));
    ctx.nut_filter = guitarFaustBridgeFilterInit(guitarFaustBridgeBrightness(ctx.params), guitarFaustBridgeAbsorption(ctx.params));
    ctx.excitation_lpf1 = dsp.lpfInit(guitarFaustExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.excitation_lpf2 = dsp.lpfInit(guitarFaustExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.out_lpf = dsp.lpfInit(guitarFaustOutputCutoff(ctx.params));
    ctx.feedback = guitarFaustStringFeedback(ctx.params);
    guitarFaustPluckPrimeString(ctx);
    ctx.age = 0;
}

pub fn guitarFaustPluckProcess(ctx: *GuitarFaustPluck) f32 {
    const step = guitarFaustPluckStep(ctx) orelse return 0.0;
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, step.string_sample * guitarStringMix(ctx.params, 0.48)));
    ctx.age = guitarNextAge(ctx.age);
    return dsp.softClip(filtered * guitarOutputGain(ctx.params, 4.8));
}

pub fn guitarFaustElectricTrigger(ctx: *GuitarFaustElectric, frequency_hz: f32, velocity: f32) void {
    guitarFaustElectricTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarFaustElectricTriggerWithParams(ctx: *GuitarFaustElectric, frequency_hz: f32, velocity: f32, params: GuitarParams) void {
    ctx.* = .{};
    ctx.params = guitarElectricParamsSanitized(params);
    ctx.rng = dsp.rngInit(ctx.params.rng_seed orelse 0xE1EC_7A21);
    ctx.frequency_hz = guitarFrequencySafe(frequency_hz);
    ctx.velocity = guitarVelocitySafe(velocity);

    const period_samples = dsp.SAMPLE_RATE / ctx.frequency_hz;
    const pluck_position = guitarFaustElectricPluckPosition(ctx.params);
    guitarFaustElectricConfigureDelay(&ctx.nut_delay_samples, &ctx.nut_frac, period_samples * pluck_position);
    guitarFaustElectricConfigureDelay(&ctx.bridge_delay_samples, &ctx.bridge_frac, period_samples * (1.0 - pluck_position));

    const bridge_brightness = guitarFaustElectricBridgeBrightness(ctx.params);
    const bridge_absorption = guitarFaustElectricBridgeAbsorption(ctx.params);
    ctx.bridge_filter = guitarFaustBridgeFilterInit(bridge_brightness, bridge_absorption);
    ctx.nut_filter = guitarFaustBridgeFilterInit(bridge_brightness, bridge_absorption);
    ctx.excitation_lpf1 = dsp.lpfInit(guitarFaustElectricExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.excitation_lpf2 = dsp.lpfInit(guitarFaustElectricExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.out_lpf = dsp.lpfInit(guitarFaustElectricOutputCutoff(ctx.params));
    ctx.mute = guitarFaustElectricMuteCoefficient(ctx.params);
    ctx.age = 0;
}

pub fn guitarFaustElectricProcess(ctx: *GuitarFaustElectric) f32 {
    const step = guitarFaustElectricStep(ctx) orelse return 0.0;
    const string_sample = step.pickup_sample * guitarStringMix(ctx.params, 0.36);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, string_sample));
    ctx.age = guitarNextAge(ctx.age);
    return dsp.softClip(filtered * guitarOutputGain(ctx.params, 12.0));
}

pub fn guitarFaustPluckStep(ctx: *GuitarFaustPluck) ?GuitarFaustPluckStep {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarFaustPluckStep: delay_samples={d} is invalid, returning silence", .{ctx.delay_samples});
        return null;
    }

    const read_idx = ctx.write_pos;
    const next_idx = if (read_idx + 1 >= ctx.delay_samples) 0 else read_idx + 1;
    const current = ctx.buffer[read_idx];
    const next = ctx.buffer[next_idx];
    const string_sample = current + (next - current) * ctx.frac;
    const excitation = guitarFaustPluckExcitation(ctx);
    const bridge = guitarFaustBridgeFilterProcess(&ctx.bridge_filter, string_sample);
    const nut = guitarFaustBridgeFilterProcess(&ctx.nut_filter, bridge);
    const steel_string = guitarFaustSteelSmooth(ctx, nut);

    ctx.buffer[read_idx] = std.math.clamp(steel_string * ctx.feedback + excitation, -1.0, 1.0);
    ctx.write_pos = next_idx;

    return .{
        .string_sample = string_sample,
        .bridge_signal = bridge,
    };
}

pub fn guitarFaustElectricStep(ctx: *GuitarFaustElectric) ?GuitarFaustElectricStep {
    if (ctx.nut_delay_samples < 2) {
        std.log.warn("guitarFaustElectricStep: nut_delay_samples={d} is invalid, returning silence", .{ctx.nut_delay_samples});
        return null;
    }
    if (ctx.bridge_delay_samples < 2) {
        std.log.warn("guitarFaustElectricStep: bridge_delay_samples={d} is invalid, returning silence", .{ctx.bridge_delay_samples});
        return null;
    }

    const nut_wave = guitarFaustElectricDelayRead(&ctx.nut_buffer, ctx.nut_write_pos, ctx.nut_delay_samples, ctx.nut_frac);
    const bridge_wave = guitarFaustElectricDelayRead(&ctx.bridge_buffer, ctx.bridge_write_pos, ctx.bridge_delay_samples, ctx.bridge_frac);
    const excitation = guitarFaustElectricExcitation(ctx);
    const pickup_sample = nut_wave + bridge_wave + excitation * ctx.params.attack_mix_scale * 0.5;
    const to_nut = bridge_wave + excitation;
    const to_bridge = guitarFaustElectricSteelSmooth(ctx, nut_wave + excitation) * ctx.mute;
    const nut_reflection = -guitarFaustBridgeFilterProcess(&ctx.nut_filter, to_nut);
    const bridge_reflection = -guitarFaustBridgeFilterProcess(&ctx.bridge_filter, to_bridge) * ctx.mute;

    guitarFaustElectricDelayWrite(&ctx.nut_buffer, &ctx.nut_write_pos, ctx.nut_delay_samples, nut_reflection);
    guitarFaustElectricDelayWrite(&ctx.bridge_buffer, &ctx.bridge_write_pos, ctx.bridge_delay_samples, bridge_reflection);

    return .{
        .pickup_sample = pickup_sample,
        .nut_wave = nut_wave,
        .bridge_wave = bridge_wave,
    };
}

pub fn guitarNextAge(age: u32) u32 {
    if (age == std.math.maxInt(u32)) return age;
    return age + 1;
}

fn guitarFaustPluckPrimeString(ctx: *GuitarFaustPluck) void {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarFaustPluckPrimeString: delay_samples={d} is invalid, leaving loop silent", .{ctx.delay_samples});
        return;
    }

    const pluck_from_bridge = std.math.clamp(guitarPluckPosition(ctx.params, 0.168), 0.05, 0.45);
    const pluck_t = std.math.clamp(1.0 - pluck_from_bridge, 0.08, 0.92);
    const last_idx_f: f32 = @floatFromInt(ctx.delay_samples - 1);
    var dc: f32 = 0.0;

    for (0..ctx.delay_samples) |idx| {
        const t = @as(f32, @floatFromInt(idx)) / last_idx_f;
        const triangle = if (t < pluck_t) t / pluck_t else (1.0 - t) / (1.0 - pluck_t);
        const noise = (dsp.rngFloat(&ctx.rng) * 2.0 - 1.0) * 0.035;
        const sample = (triangle * 0.070 + noise * 0.22) * ctx.velocity;
        ctx.buffer[idx] = sample;
        dc += sample;
    }

    const dc_offset = dc / @as(f32, @floatFromInt(ctx.delay_samples));
    for (0..ctx.delay_samples) |idx| {
        ctx.buffer[idx] -= dc_offset;
    }
}

fn guitarFaustPluckExcitation(ctx: *GuitarFaustPluck) f32 {
    const attack_samples = guitarFaustPluckAttackSamples(ctx.frequency_hz, guitarAttackDecay(ctx.params));
    const release_samples = attack_samples;
    const total_samples = attack_samples + release_samples;
    if (ctx.age >= total_samples) return 0.0;

    const age_f: f32 = @floatFromInt(ctx.age);
    const attack_f: f32 = @floatFromInt(attack_samples);
    const release_f: f32 = @floatFromInt(release_samples);
    const env = if (ctx.age < attack_samples) age_f / attack_f else @max(0.0, 1.0 - (age_f - attack_f) / release_f);
    const noise = dsp.rngFloat(&ctx.rng) * 2.0 - 1.0;
    const lowpass1 = dsp.lpfProcess(&ctx.excitation_lpf1, noise);
    const lowpass2 = dsp.lpfProcess(&ctx.excitation_lpf2, lowpass1);
    return lowpass2 * env * guitarAttackGain(ctx.params, 0.080) * (0.35 + ctx.velocity * 0.65);
}

fn guitarFaustElectricExcitation(ctx: *GuitarFaustElectric) f32 {
    const attack_samples = guitarFaustElectricAttackSamples(ctx.frequency_hz, guitarAttackDecay(ctx.params));
    const release_samples = attack_samples;
    const total_samples = attack_samples + release_samples;
    if (ctx.age >= total_samples) return 0.0;

    const age_f: f32 = @floatFromInt(ctx.age);
    const attack_f: f32 = @floatFromInt(attack_samples);
    const release_f: f32 = @floatFromInt(release_samples);
    const env = if (ctx.age < attack_samples) age_f / attack_f else @max(0.0, 1.0 - (age_f - attack_f) / release_f);
    const noise = dsp.rngFloat(&ctx.rng) * 2.0 - 1.0;
    const lowpass1 = dsp.lpfProcess(&ctx.excitation_lpf1, noise);
    const lowpass2 = dsp.lpfProcess(&ctx.excitation_lpf2, lowpass1);
    return lowpass2 * env * guitarAttackGain(ctx.params, 0.12) * ctx.velocity;
}

fn guitarFaustPluckAttackSamples(frequency_hz: f32, decay_scale: f32) u32 {
    const max_freq = 3000.0;
    const ratio = std.math.clamp(frequency_hz / max_freq, 0.0, 0.96);
    const sharpness = std.math.clamp(decay_scale, 0.35, 2.5);
    const attack_seconds = 0.002 * sharpness * std.math.pow(f32, 1.0 - ratio, 2.0);
    return @max(@as(u32, @intFromFloat(@round(attack_seconds * dsp.SAMPLE_RATE))), 8);
}

fn guitarFaustElectricAttackSamples(frequency_hz: f32, decay_scale: f32) u32 {
    const max_freq = 2000.0;
    const ratio = std.math.clamp(frequency_hz / max_freq, 0.0, 0.96);
    const sharpness = std.math.clamp(decay_scale, 0.35, 2.5);
    const attack_seconds = 0.002 * sharpness * std.math.pow(f32, 1.0 - ratio, 2.0);
    return @max(@as(u32, @intFromFloat(@round(attack_seconds * dsp.SAMPLE_RATE))), 4);
}

fn guitarFaustSteelSmooth(ctx: *GuitarFaustPluck, input: f32) f32 {
    const stiffness = guitarFaustSteelSmoothAmount(ctx.params);
    ctx.stiffness_smooth1 = input * (1.0 - stiffness) + ctx.stiffness_smooth1 * stiffness;
    ctx.stiffness_smooth2 = ctx.stiffness_smooth1 * (1.0 - stiffness) + ctx.stiffness_smooth2 * stiffness;
    return ctx.stiffness_smooth2;
}

fn guitarFaustElectricSteelSmooth(ctx: *GuitarFaustElectric, input: f32) f32 {
    const stiffness = guitarFaustElectricSteelSmoothAmount(ctx.params);
    ctx.stiffness_smooth1 = input * (1.0 - stiffness) + ctx.stiffness_smooth1 * stiffness;
    ctx.stiffness_smooth2 = ctx.stiffness_smooth1 * (1.0 - stiffness) + ctx.stiffness_smooth2 * stiffness;
    return ctx.stiffness_smooth2;
}

fn guitarFaustBridgeBrightness(params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    const bridge_offset = params.bridge_coupling_scale - GUITAR_FAUST_PROMOTED_BRIDGE_COUPLING;
    return std.math.clamp(0.4 + (brightness - GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 0.42 + high_decay_offset * 0.10 + bridge_offset * 0.04, 0.06, 0.92);
}

fn guitarFaustBridgeAbsorption(params: GuitarParams) f32 {
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    const bridge_offset = params.bridge_coupling_scale - GUITAR_FAUST_PROMOTED_BRIDGE_COUPLING;
    const mute_offset = params.mute_amount - GUITAR_FAUST_PROMOTED_MUTE;
    return std.math.clamp(0.5 - high_decay_offset * 0.18 - bridge_offset * 0.10 + mute_offset * 0.24, 0.08, 0.88);
}

fn guitarFaustElectricPluckPosition(params: GuitarParams) f32 {
    return std.math.clamp(guitarPluckPosition(params, GUITAR_FAUST_ELECTRIC_DEFAULT_PLUCK_POSITION), 0.05, 0.95);
}

fn guitarFaustElectricBridgeBrightness(params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - 1.0;
    const bridge_offset = params.bridge_coupling_scale - 1.0;
    return std.math.clamp(
        GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS + (brightness - GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS) * 0.18 + high_decay_offset * 0.05 + bridge_offset * 0.03,
        0.55,
        0.95,
    );
}

fn guitarFaustElectricBridgeAbsorption(params: GuitarParams) f32 {
    const string_decay_offset = params.string_decay_scale - 1.0;
    const high_decay_offset = params.high_decay_scale - 1.0;
    return std.math.clamp(GUITAR_FAUST_ELECTRIC_BRIDGE_ABSORPTION - string_decay_offset * 0.08 - high_decay_offset * 0.03 + params.mute_amount * 0.18, 0.28, 0.84);
}

fn guitarFaustExcitationCutoff(frequency_hz: f32, params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const ratio = 5.0 + (brightness - GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 4.0;
    return std.math.clamp(frequency_hz * ratio, 80.0, 18000.0);
}

fn guitarFaustElectricExcitationCutoff(frequency_hz: f32, params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS);
    const ratio = 5.0 + (brightness - GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS) * 3.5;
    return std.math.clamp(frequency_hz * ratio, 90.0, 19000.0);
}

fn guitarFaustOutputCutoff(params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    return std.math.clamp(9800.0 + (brightness - GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 3800.0 + high_decay_offset * 2200.0, 5200.0, 14500.0);
}

fn guitarFaustElectricOutputCutoff(params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - 1.0;
    return std.math.clamp(12500.0 + (brightness - GUITAR_FAUST_ELECTRIC_DEFAULT_BRIGHTNESS) * 3000.0 + high_decay_offset * 1600.0, 6500.0, 18000.0);
}

fn guitarFaustStringFeedback(params: GuitarParams) f32 {
    const string_decay_offset = params.string_decay_scale - GUITAR_FAUST_PROMOTED_STRING_DECAY;
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    const previous_feedback = 0.9975 + (params.string_decay_scale - 1.0) * 0.0005 - params.mute_amount * 0.001;
    return std.math.clamp(previous_feedback + string_decay_offset * 0.00085 + high_decay_offset * 0.00022, 0.99, 0.99935);
}

fn guitarFaustSteelSmoothAmount(params: GuitarParams) f32 {
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    return std.math.clamp(0.05 - high_decay_offset * 0.014, 0.025, 0.08);
}

fn guitarFaustElectricSteelSmoothAmount(params: GuitarParams) f32 {
    const high_decay_offset = params.high_decay_scale - 1.0;
    return std.math.clamp(GUITAR_FAUST_ELECTRIC_STIFFNESS - high_decay_offset * 0.01, 0.02, 0.09);
}

fn guitarFaustElectricMuteCoefficient(params: GuitarParams) f32 {
    return std.math.clamp(1.0 - params.mute_amount * 0.86, 0.0, 1.0);
}

fn guitarFaustBridgeFilterInit(brightness: f32, absorption: f32) GuitarFaustBridgeFilter {
    const safe_absorption = std.math.clamp(absorption, 0.0, 0.98);
    const t60 = @max((1.0 - safe_absorption) * 20.0, 0.01);
    const safe_brightness = std.math.clamp(brightness, 0.0, 1.0);
    return .{
        .h0 = (1.0 + safe_brightness) * 0.5,
        .h1 = (1.0 - safe_brightness) * 0.25,
        .rho = std.math.pow(f32, 0.001, 1.0 / (320.0 * t60)),
    };
}

fn guitarFaustBridgeFilterProcess(filter: *GuitarFaustBridgeFilter, input: f32) f32 {
    const output = filter.rho * (filter.h0 * filter.x1 + filter.h1 * (input + filter.x2));
    filter.x2 = filter.x1;
    filter.x1 = input;
    return output;
}

fn guitarFaustElectricConfigureDelay(delay_samples: *usize, frac: *f32, delay_f: f32) void {
    if (!std.math.isFinite(delay_f)) {
        std.log.warn("guitarFaustElectricConfigureDelay: non-finite delay, using 32 samples", .{});
        delay_samples.* = 32;
        frac.* = 0.0;
        return;
    }

    const max_delay: f32 = @floatFromInt(GUITAR_FAUST_STRING_BUFFER_SIZE - 2);
    const clamped_delay = std.math.clamp(delay_f, 3.0, max_delay);
    const delay_floor = @floor(clamped_delay);
    delay_samples.* = @intFromFloat(delay_floor);
    frac.* = clamped_delay - delay_floor;
    if (delay_samples.* < 3) {
        std.log.warn("guitarFaustElectricConfigureDelay: delay_samples={d} is invalid, clamping to 3", .{delay_samples.*});
        delay_samples.* = 3;
        frac.* = 0.0;
    }
}

fn guitarFaustElectricDelayRead(buffer: *const [GUITAR_FAUST_STRING_BUFFER_SIZE]f32, write_pos: usize, delay_samples: usize, frac: f32) f32 {
    const read_idx = write_pos;
    const next_idx = if (read_idx + 1 >= delay_samples) 0 else read_idx + 1;
    const current = buffer[read_idx];
    const next = buffer[next_idx];
    return current + (next - current) * frac;
}

fn guitarFaustElectricDelayWrite(buffer: *[GUITAR_FAUST_STRING_BUFFER_SIZE]f32, write_pos: *usize, delay_samples: usize, sample: f32) void {
    buffer[write_pos.*] = std.math.clamp(sample, -1.0, 1.0);
    write_pos.* = if (write_pos.* + 1 >= delay_samples) 0 else write_pos.* + 1;
}

fn guitarParamsSanitized(params: GuitarParams) GuitarParams {
    return .{
        .pluck_position = guitarOptionalRangeSanitized("pluck_position", params.pluck_position, 0.05, 0.45),
        .pluck_brightness = guitarOptionalRangeSanitized("pluck_brightness", params.pluck_brightness, 0.0, 1.0),
        .string_mix_scale = guitarScaleSanitized("string_mix_scale", params.string_mix_scale, 0.0, 6.0),
        .body_mix_scale = guitarScaleSanitized("body_mix_scale", params.body_mix_scale, 0.0, 6.0),
        .attack_mix_scale = guitarScaleSanitized("attack_mix_scale", params.attack_mix_scale, 0.0, 8.0),
        .mute_amount = guitarScaleSanitized("mute_amount", params.mute_amount, 0.0, 1.0),
        .string_decay_scale = guitarScaleSanitized("string_decay_scale", params.string_decay_scale, 0.25, 3.0),
        .body_gain_scale = guitarScaleSanitized("body_gain_scale", params.body_gain_scale, 0.0, 4.0),
        .body_decay_scale = guitarScaleSanitized("body_decay_scale", params.body_decay_scale, 0.25, 3.0),
        .body_freq_scale = guitarScaleSanitized("body_freq_scale", params.body_freq_scale, 0.75, 1.35),
        .pick_noise_scale = guitarScaleSanitized("pick_noise_scale", params.pick_noise_scale, 0.0, 4.0),
        .attack_gain_scale = guitarScaleSanitized("attack_gain_scale", params.attack_gain_scale, 0.0, 4.0),
        .attack_decay_scale = guitarScaleSanitized("attack_decay_scale", params.attack_decay_scale, 0.35, 2.5),
        .bridge_coupling_scale = guitarScaleSanitized("bridge_coupling_scale", params.bridge_coupling_scale, 0.0, 4.0),
        .inharmonicity_scale = guitarScaleSanitized("inharmonicity_scale", params.inharmonicity_scale, 0.0, 3.0),
        .high_decay_scale = guitarScaleSanitized("high_decay_scale", params.high_decay_scale, 0.35, 2.5),
        .output_gain_scale = guitarScaleSanitized("output_gain_scale", params.output_gain_scale, 0.0, 8.0),
        .rng_seed = params.rng_seed,
    };
}

fn guitarElectricParamsSanitized(params: GuitarParams) GuitarParams {
    var sanitized = guitarParamsSanitized(params);
    sanitized.pluck_position = guitarOptionalRangeSanitized("electric_pluck_position", params.pluck_position, 0.05, 0.95);
    return sanitized;
}

fn guitarOptionalRangeSanitized(label: []const u8, value: ?f32, min_value: f32, max_value: f32) ?f32 {
    const raw_value = value orelse return null;
    if (!std.math.isFinite(raw_value)) {
        std.log.warn("guitarOptionalRangeSanitized: {s} is non-finite, using instrument default", .{label});
        return null;
    }
    return std.math.clamp(raw_value, min_value, max_value);
}

fn guitarScaleSanitized(label: []const u8, value: f32, min_value: f32, max_value: f32) f32 {
    if (!std.math.isFinite(value)) {
        std.log.warn("guitarScaleSanitized: {s} is non-finite, using 1.0", .{label});
        return 1.0;
    }
    return std.math.clamp(value, min_value, max_value);
}

fn guitarPluckPosition(params: GuitarParams, default_value: f32) f32 {
    return params.pluck_position orelse default_value;
}

fn guitarPluckBrightness(params: GuitarParams, default_value: f32) f32 {
    return params.pluck_brightness orelse default_value;
}

fn guitarStringMix(params: GuitarParams, base_gain: f32) f32 {
    return base_gain * params.string_mix_scale;
}

fn guitarAttackGain(params: GuitarParams, base_gain: f32) f32 {
    return base_gain * params.attack_gain_scale;
}

fn guitarAttackDecay(params: GuitarParams) f32 {
    return params.attack_decay_scale;
}

fn guitarOutputGain(params: GuitarParams, base_gain: f32) f32 {
    return base_gain * params.output_gain_scale;
}

fn guitarFrequencySafe(frequency_hz: f32) f32 {
    if (!std.math.isFinite(frequency_hz)) {
        std.log.warn("guitarFrequencySafe: non-finite frequency, using 164.814 Hz", .{});
        return 164.814;
    }
    if (frequency_hz < 40.0) {
        std.log.warn("guitarFrequencySafe: frequency={d} below instrument range, clamping to 40 Hz", .{frequency_hz});
        return 40.0;
    }
    if (frequency_hz > 1600.0) {
        std.log.warn("guitarFrequencySafe: frequency={d} above instrument range, clamping to 1600 Hz", .{frequency_hz});
        return 1600.0;
    }
    return frequency_hz;
}

fn guitarVelocitySafe(velocity: f32) f32 {
    if (!std.math.isFinite(velocity)) {
        std.log.warn("guitarVelocitySafe: non-finite velocity, using 0.8", .{});
        return 0.8;
    }
    return std.math.clamp(velocity, 0.0, 1.0);
}

pub const HiHat = struct {
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.03, 0.0, 0.02),
    hpf: dsp.HPF = dsp.hpfInit(6000.0),
    volume: f32 = 0.45,
    phases: [6]f32 = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
};

pub fn hiHatTrigger(ctx: *HiHat) void {
    dsp.envelopeTrigger(&ctx.env);
}

pub fn hiHatProcess(ctx: *HiHat, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;
    const ratios = [_]f32{ 1.0, 1.41, 1.73, 2.37, 3.11, 4.35 };
    var metal: f32 = 0.0;
    for (0..ctx.phases.len) |idx| {
        ctx.phases[idx] += 6200.0 * ratios[idx] * dsp.INV_SR * dsp.TAU;
        if (ctx.phases[idx] > dsp.TAU) ctx.phases[idx] -= dsp.TAU;
        metal += @sin(ctx.phases[idx]) * (0.22 - @as(f32, @floatFromInt(idx)) * 0.02);
    }
    const noise = dsp.hpfProcess(&ctx.hpf, dsp.rngFloat(rng_inst) * 2.0 - 1.0);
    return (noise * 0.62 + metal * 0.38) * env_val * ctx.volume;
}

pub const DjembeStroke = enum { bass, tone, slap };

pub const Djembe = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.12, 0.0, 0.06),
    noise_lpf: dsp.LPF = dsp.lpfInit(1800.0),
    noise_hpf: dsp.HPF = dsp.hpfInit(400.0),
    base_freq: f32 = 350.0,
    current_freq: f32 = 350.0,
    noise_mix: f32 = 0.2,
    body_mix: f32 = 0.8,
    velocity: f32 = 0.0,
    pitch_decay: f32 = 0.997,
    volume: f32 = 0.7,
    harmonic_phase: f32 = 0,
    harmonic_mix: f32 = 0.15,
    strike_age: u32 = 999999,
};

pub fn djembeTriggerBass(ctx: *Djembe, vel: f32) void {
    ctx.velocity = vel;
    ctx.current_freq = ctx.base_freq * 0.19;
    ctx.pitch_env = 1.0;
    ctx.pitch_decay = 0.9985;
    ctx.noise_mix = 0.08;
    ctx.body_mix = 0.95;
    ctx.harmonic_mix = 0.22;
    ctx.noise_lpf = dsp.lpfInit(600.0);
    djembeConfigureResonators(ctx, .bass);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.95, 0.28, 0.12 }, vel);
    ctx.strike_age = 0;
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.22, 0.0, 0.12);
}

pub fn djembeTriggerTone(ctx: *Djembe, vel: f32) void {
    ctx.velocity = vel;
    ctx.current_freq = ctx.base_freq;
    ctx.pitch_env = 0.4;
    ctx.pitch_decay = 0.9992;
    ctx.noise_mix = 0.18;
    ctx.body_mix = 0.82;
    ctx.harmonic_mix = 0.12;
    ctx.noise_lpf = dsp.lpfInit(2400.0);
    djembeConfigureResonators(ctx, .tone);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.72, 0.24, 0.1 }, vel);
    ctx.strike_age = 0;
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.11, 0.0, 0.055);
}

pub fn djembeTriggerSlap(ctx: *Djembe, vel: f32) void {
    ctx.velocity = vel;
    ctx.current_freq = ctx.base_freq * 2.3;
    ctx.pitch_env = 0.8;
    ctx.pitch_decay = 0.9975;
    ctx.noise_mix = 0.58;
    ctx.body_mix = 0.32;
    ctx.harmonic_mix = 0.06;
    ctx.noise_lpf = dsp.lpfInit(5500.0);
    ctx.noise_hpf = dsp.hpfInit(1200.0);
    djembeConfigureResonators(ctx, .slap);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.35, 0.14, 0.08 }, vel * 0.8);
    ctx.strike_age = 0;
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.04, 0.0, 0.02);
}

pub fn djembeTriggerGhost(ctx: *Djembe, vel: f32, stroke: DjembeStroke) void {
    switch (stroke) {
        .tone => djembeTriggerTone(ctx, vel * 0.3),
        .slap => djembeTriggerSlap(ctx, vel * 0.25),
        .bass => djembeTriggerBass(ctx, vel * 0.25),
    }
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.04, 0.0, 0.02);
}

pub fn djembeProcess(ctx: *Djembe, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.pitch_env *= ctx.pitch_decay;
    const freq = ctx.current_freq * (1.0 + ctx.pitch_env * 0.35);

    ctx.harmonic_phase += freq * 1.506 * dsp.INV_SR * dsp.TAU;
    if (ctx.harmonic_phase > dsp.TAU) ctx.harmonic_phase -= dsp.TAU;

    ctx.resonators.freqs[0] = freq;
    ctx.resonators.freqs[1] = freq * 1.51;
    ctx.resonators.freqs[2] = freq * 2.18;
    const body = dsp.resonatorBankProcess(3, &ctx.resonators) + @sin(ctx.harmonic_phase) * ctx.harmonic_mix * 0.2;
    const raw_noise = dsp.rngFloat(rng_inst) * 2.0 - 1.0;
    var noise = dsp.hpfProcess(&ctx.noise_hpf, dsp.lpfProcess(&ctx.noise_lpf, raw_noise));
    if (ctx.strike_age < 2400) {
        noise += dsp.exciterNoiseBurst(rng_inst, &ctx.noise_hpf, &ctx.noise_lpf, ctx.strike_age, 0.006, 0.18);
        ctx.strike_age += 1;
    }

    return (body * ctx.body_mix + noise * ctx.noise_mix) * env_val * ctx.velocity * ctx.volume;
}

fn djembeConfigureResonators(ctx: *Djembe, stroke: DjembeStroke) void {
    switch (stroke) {
        .bass => dsp.resonatorBankConfigure(
            3,
            &ctx.resonators,
            .{ ctx.base_freq * 0.19, ctx.base_freq * 0.31, ctx.base_freq * 0.46 },
            .{ 0.99945, 0.9991, 0.9988 },
        ),
        .tone => dsp.resonatorBankConfigure(
            3,
            &ctx.resonators,
            .{ ctx.base_freq, ctx.base_freq * 1.51, ctx.base_freq * 2.18 },
            .{ 0.9991, 0.9986, 0.9982 },
        ),
        .slap => dsp.resonatorBankConfigure(
            3,
            &ctx.resonators,
            .{ ctx.base_freq * 2.3, ctx.base_freq * 3.1, ctx.base_freq * 4.26 },
            .{ 0.9982, 0.9978, 0.9972 },
        ),
    }
}

pub const Dunun = struct {
    phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.18, 0.0, 0.1),
    body_lpf: dsp.LPF = dsp.lpfInit(250.0),
    base_freq: f32 = 82.0,
    sweep: f32 = 40.0,
    decay_rate: f32 = 0.9988,
    volume: f32 = 1.0,
    bell_phase: f32 = 0,
    bell_freq: f32 = 0,
    bell_env: dsp.Envelope = dsp.envelopeInit(0.001, 0.025, 0.0, 0.012),
    bell_volume: f32 = 0.35,
};

pub fn dununTriggerDrum(ctx: *Dunun, vel: f32) void {
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.18, 0.0, 0.1);
    ctx.pitch_env = vel;
}

pub fn dununTriggerBell(ctx: *Dunun) void {
    dsp.envelopeRetrigger(&ctx.bell_env, 0.001, 0.025, 0.0, 0.012);
}

pub fn dununProcess(ctx: *Dunun, rng_inst: *dsp.Rng) [2]f32 {
    var drum_s: f32 = 0.0;
    const drum_env = dsp.envelopeProcess(&ctx.env);
    if (drum_env > 0.0001) {
        ctx.pitch_env *= ctx.decay_rate;
        const freq = ctx.base_freq + ctx.pitch_env * ctx.sweep;
        ctx.phase += freq * dsp.INV_SR * dsp.TAU;
        if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
        drum_s = dsp.lpfProcess(&ctx.body_lpf, @sin(ctx.phase)) * drum_env * ctx.volume;
    }

    var bell_s: f32 = 0.0;
    const bell_env = dsp.envelopeProcess(&ctx.bell_env);
    if (bell_env > 0.0001) {
        ctx.bell_phase += ctx.bell_freq * dsp.INV_SR * dsp.TAU;
        if (ctx.bell_phase > dsp.TAU) ctx.bell_phase -= dsp.TAU;
        const tone = @sin(ctx.bell_phase) * 0.6 + @sin(ctx.bell_phase * 2.71) * 0.3;
        bell_s = tone * bell_env * ctx.bell_volume + (dsp.rngFloat(rng_inst) * 2.0 - 1.0) * bell_env * 0.04;
    }

    return .{ drum_s, bell_s };
}

// Japanese taiko instruments

pub const TaikoStroke = enum { don, ka, ghost };
const ODAIKO_MODE_COUNT = 8;
const NAGADO_MODE_COUNT = 6;
const SHIME_MODE_COUNT = 11;
const ATARIGANE_MODE_COUNT = 10;

const OdaikoStroke = enum { don, ka, ghost };

fn ModalDrumBody(comptime n_modes: usize) type {
    return struct {
        resonators: dsp.ResonatorBank(n_modes) = .{},
        strike_env: dsp.Envelope = dsp.envelopeInit(0.001, 0.02, 0.0, 0.008),
        body_lpf: dsp.LPF = dsp.lpfInit(1000.0),
        body_hpf: dsp.HPF = dsp.hpfInit(20.0),
        noise_lpf: dsp.LPF = dsp.lpfInit(5000.0),
        noise_lpf2: dsp.LPF = dsp.lpfInit(20000.0),
        noise_hpf: dsp.HPF = dsp.hpfInit(400.0),
        body_mix: f32 = 0.85,
        noise_mix: f32 = 0.2,
        velocity: f32 = 0.0,
        velocity_floor: f32 = 0.55,
        velocity_sensitivity: f32 = 0.45,
        volume: f32 = 1.0,
        strike_age: u32 = 999999,
        strike_noise_samples: u32 = 1000,
        strike_noise_decay: f32 = 0.012,
        strike_cluster_count: u32 = 1,
        strike_cluster_spacing: u32 = 0,
        strike_cluster_rolloff: f32 = 0.55,
    };
}

fn ModalDrumBodyConfig(comptime n_modes: usize) type {
    return struct {
        mode_freqs: [n_modes]f32,
        mode_t60s: [n_modes]f32,
        mode_gains: [n_modes]f32,
        body_lpf_hz: f32,
        body_hpf_hz: f32,
        noise_lpf_hz: f32,
        noise_lpf2_hz: f32,
        noise_hpf_hz: f32,
        body_mix: f32,
        noise_mix: f32,
        strike_attack_s: f32,
        strike_decay_s: f32,
        strike_release_s: f32,
        strike_noise_samples: u32,
        strike_noise_decay: f32,
        strike_cluster_count: u32,
        strike_cluster_spacing: u32,
        strike_cluster_rolloff: f32,
        velocity_floor: f32,
        velocity_sensitivity: f32,
        volume: f32,
    };
}

fn modalDrumBodyTrigger(comptime n_modes: usize, ctx: *ModalDrumBody(n_modes), config: ModalDrumBodyConfig(n_modes), vel: f32) void {
    ctx.velocity = vel;
    ctx.body_lpf = dsp.lpfInit(config.body_lpf_hz);
    ctx.body_hpf = dsp.hpfInit(config.body_hpf_hz);
    ctx.noise_lpf = dsp.lpfInit(config.noise_lpf_hz);
    ctx.noise_lpf2 = dsp.lpfInit(config.noise_lpf2_hz);
    ctx.noise_hpf = dsp.hpfInit(config.noise_hpf_hz);
    ctx.body_mix = config.body_mix;
    ctx.noise_mix = config.noise_mix;
    ctx.strike_noise_samples = config.strike_noise_samples;
    ctx.strike_noise_decay = config.strike_noise_decay;
    ctx.strike_cluster_count = config.strike_cluster_count;
    ctx.strike_cluster_spacing = config.strike_cluster_spacing;
    ctx.strike_cluster_rolloff = config.strike_cluster_rolloff;
    ctx.velocity_floor = config.velocity_floor;
    ctx.velocity_sensitivity = config.velocity_sensitivity;
    ctx.volume = config.volume;

    var mode_decays: [n_modes]f32 = undefined;
    for (0..n_modes) |idx| {
        mode_decays[idx] = modalDecayFromT60(config.mode_t60s[idx]);
    }

    dsp.resonatorBankConfigure(n_modes, &ctx.resonators, config.mode_freqs, mode_decays);
    dsp.resonatorBankExcite(n_modes, &ctx.resonators, config.mode_gains, vel);
    dsp.envelopeRetrigger(&ctx.strike_env, config.strike_attack_s, config.strike_decay_s, 0.0, config.strike_release_s);
    ctx.strike_age = 0;
}

fn modalDrumBodyProcess(comptime n_modes: usize, ctx: *ModalDrumBody(n_modes), rng_inst: *dsp.Rng, extra_body: f32) f32 {
    const strike_env = dsp.envelopeProcess(&ctx.strike_env);
    const modal_body = dsp.resonatorBankProcess(n_modes, &ctx.resonators) * ctx.body_mix;
    const body = dsp.lpfProcess(&ctx.body_lpf, dsp.hpfProcess(&ctx.body_hpf, modal_body + extra_body));
    var noise: f32 = 0.0;
    if (ctx.strike_age < ctx.strike_noise_samples) {
        const noise_lpf1 = dsp.lpfProcess(&ctx.noise_lpf, dsp.rngFloat(rng_inst) * 2.0 - 1.0);
        const raw_noise = dsp.hpfProcess(&ctx.noise_hpf, dsp.lpfProcess(&ctx.noise_lpf2, noise_lpf1));
        noise = raw_noise * modalDrumStrikeClusterEnv(ctx) * ctx.noise_mix * strike_env;
        ctx.strike_age += 1;
    }

    return (body + noise) * (ctx.velocity_floor + ctx.velocity * ctx.velocity_sensitivity) * ctx.volume;
}

fn modalDrumStrikeClusterEnv(ctx: anytype) f32 {
    var out: f32 = 0.0;
    var idx: u32 = 0;
    var offset: u32 = 0;
    var weight: f32 = 1.0;
    while (idx < ctx.strike_cluster_count) : (idx += 1) {
        if (ctx.strike_age >= offset) {
            const age = ctx.strike_age - offset;
            out += @exp(-@as(f32, @floatFromInt(age)) * ctx.strike_noise_decay) * weight;
        }
        offset += ctx.strike_cluster_spacing;
        weight *= ctx.strike_cluster_rolloff;
    }
    return out;
}

fn modalDecayFromT60(t60_s: f32) f32 {
    const safe_t60 = @max(t60_s, dsp.INV_SR);
    return std.math.pow(f32, 0.001, 1.0 / (safe_t60 * dsp.SAMPLE_RATE));
}

pub const Odaiko = struct {
    phase: f32 = 0,
    sub_phase: f32 = 0,
    pitch_env: f32 = 0,
    body: ModalDrumBody(ODAIKO_MODE_COUNT) = .{
        .body_lpf = dsp.lpfInit(420.0),
        .body_hpf = dsp.hpfInit(18.0),
        .noise_lpf = dsp.lpfInit(900.0),
        .noise_lpf2 = dsp.lpfInit(1500.0),
        .noise_hpf = dsp.hpfInit(80.0),
        .body_mix = 0.78,
        .noise_mix = 0.10,
        .velocity_floor = 0.42,
        .velocity_sensitivity = 0.58,
        .volume = 0.60,
    },
    carrier_env: dsp.Envelope = dsp.envelopeInit(0.002, 1.2, 0.0, 0.8),
    rng: dsp.Rng = dsp.rngInit(0x0DA1_4001),
    base_freq: f32 = 48.0,
    sweep: f32 = 55.0,
    decay_rate: f32 = 0.99962,
    carrier_mix: f32 = 0.0,
    volume: f32 = 1.4,
};

pub fn odaikoTriggerDon(ctx: *Odaiko, vel: f32) void {
    ctx.pitch_env = vel * 1.42;
    ctx.decay_rate = 0.99932;
    ctx.carrier_mix = 0.86;
    modalDrumBodyTrigger(ODAIKO_MODE_COUNT, &ctx.body, odaikoBodyConfig(ctx.base_freq, .don, ctx.volume), vel);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.001, 0.82, 0.0, 0.30);
}

pub fn odaikoTriggerKa(ctx: *Odaiko, vel: f32) void {
    ctx.pitch_env = vel * 0.035;
    ctx.decay_rate = 0.9989;
    ctx.carrier_mix = 0.035;
    modalDrumBodyTrigger(ODAIKO_MODE_COUNT, &ctx.body, odaikoBodyConfig(ctx.base_freq, .ka, ctx.volume), vel * 0.82);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.001, 0.055, 0.0, 0.018);
}

pub fn odaikoTriggerGhost(ctx: *Odaiko, vel: f32) void {
    ctx.pitch_env = vel * 0.12;
    ctx.decay_rate = 0.9988;
    ctx.carrier_mix = 0.16;
    modalDrumBodyTrigger(ODAIKO_MODE_COUNT, &ctx.body, odaikoBodyConfig(ctx.base_freq, .ghost, ctx.volume), vel * 0.55);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.003, 0.22, 0.0, 0.070);
}

pub fn odaikoProcess(ctx: *Odaiko) f32 {
    const carrier_env = dsp.envelopeProcess(&ctx.carrier_env);

    ctx.pitch_env *= ctx.decay_rate;
    const freq = ctx.base_freq + ctx.pitch_env * ctx.sweep;
    ctx.phase += freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
    ctx.sub_phase += freq * 0.5 * dsp.INV_SR * dsp.TAU;
    if (ctx.sub_phase > dsp.TAU) ctx.sub_phase -= dsp.TAU;

    const carrier_body = (@sin(ctx.phase) * 0.72 + @sin(ctx.sub_phase) * 0.42) * ctx.carrier_mix * carrier_env;
    return modalDrumBodyProcess(ODAIKO_MODE_COUNT, &ctx.body, &ctx.rng, carrier_body);
}

fn odaikoBodyConfig(base_freq: f32, stroke: OdaikoStroke, volume: f32) ModalDrumBodyConfig(ODAIKO_MODE_COUNT) {
    return switch (stroke) {
        .don => .{
            .mode_freqs = .{
                base_freq * 0.72,
                base_freq,
                base_freq * 1.42,
                base_freq * 1.93,
                base_freq * 2.58,
                base_freq * 3.45,
                base_freq * 4.32,
                base_freq * 5.10,
            },
            .mode_t60s = .{ 1.60, 2.20, 1.15, 0.62, 0.34, 0.20, 0.14, 0.10 },
            .mode_gains = .{ 0.42, 1.08, 0.72, 0.46, 0.29, 0.18, 0.105, 0.055 },
            .body_lpf_hz = 840.0,
            .body_hpf_hz = 16.0,
            .noise_lpf_hz = 2400.0,
            .noise_lpf2_hz = 3200.0,
            .noise_hpf_hz = 105.0,
            .body_mix = 0.86,
            .noise_mix = 0.58,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.014,
            .strike_release_s = 0.005,
            .strike_noise_samples = 620,
            .strike_noise_decay = 0.038,
            .strike_cluster_count = 3,
            .strike_cluster_spacing = 12,
            .strike_cluster_rolloff = 0.30,
            .velocity_floor = 0.42,
            .velocity_sensitivity = 0.58,
            .volume = volume * 0.52,
        },
        .ka => .{
            .mode_freqs = .{
                base_freq * 5.8,
                base_freq * 7.2,
                base_freq * 9.1,
                base_freq * 11.4,
                base_freq * 14.2,
                base_freq * 17.6,
                base_freq * 21.5,
                base_freq * 26.0,
            },
            .mode_t60s = .{ 0.085, 0.080, 0.070, 0.058, 0.046, 0.036, 0.028, 0.022 },
            .mode_gains = .{ 0.34, 0.48, 0.54, 0.44, 0.32, 0.22, 0.14, 0.080 },
            .body_lpf_hz = 3400.0,
            .body_hpf_hz = 190.0,
            .noise_lpf_hz = 3200.0,
            .noise_lpf2_hz = 4200.0,
            .noise_hpf_hz = 360.0,
            .body_mix = 0.52,
            .noise_mix = 0.82,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.018,
            .strike_release_s = 0.004,
            .strike_noise_samples = 720,
            .strike_noise_decay = 0.040,
            .strike_cluster_count = 2,
            .strike_cluster_spacing = 18,
            .strike_cluster_rolloff = 0.42,
            .velocity_floor = 0.48,
            .velocity_sensitivity = 0.42,
            .volume = volume * 0.95,
        },
        .ghost => .{
            .mode_freqs = .{
                base_freq * 0.76,
                base_freq,
                base_freq * 1.45,
                base_freq * 1.98,
                base_freq * 2.64,
                base_freq * 3.50,
                base_freq * 4.40,
                base_freq * 5.25,
            },
            .mode_t60s = .{ 0.18, 0.26, 0.18, 0.12, 0.082, 0.056, 0.040, 0.030 },
            .mode_gains = .{ 0.075, 0.35, 0.25, 0.15, 0.085, 0.046, 0.026, 0.014 },
            .body_lpf_hz = 260.0,
            .body_hpf_hz = 24.0,
            .noise_lpf_hz = 620.0,
            .noise_lpf2_hz = 820.0,
            .noise_hpf_hz = 105.0,
            .body_mix = 0.48,
            .noise_mix = 0.045,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.018,
            .strike_release_s = 0.006,
            .strike_noise_samples = 620,
            .strike_noise_decay = 0.018,
            .strike_cluster_count = 1,
            .strike_cluster_spacing = 0,
            .strike_cluster_rolloff = 0.55,
            .velocity_floor = 0.28,
            .velocity_sensitivity = 0.42,
            .volume = volume * 0.85,
        },
    };
}

pub const Nagado = struct {
    phase: f32 = 0.0,
    sub_phase: f32 = 0.0,
    body: ModalDrumBody(NAGADO_MODE_COUNT) = .{
        .body_lpf = dsp.lpfInit(600.0),
        .noise_lpf = dsp.lpfInit(2400.0),
        .noise_hpf = dsp.hpfInit(800.0),
        .body_mix = 0.88,
        .noise_mix = 0.12,
        .velocity_floor = 0.55,
        .velocity_sensitivity = 0.45,
        .volume = 0.85,
    },
    carrier_env: dsp.Envelope = dsp.envelopeInit(0.001, 0.42, 0.0, 0.18),
    base_freq: f32 = 140.0,
    carrier_mix: f32 = 0.0,
    volume: f32 = 0.85,
    pitch_env: f32 = 0.0,
    pitch_decay: f32 = 0.99935,
};

pub fn nagadoTriggerDon(ctx: *Nagado, vel: f32) void {
    ctx.carrier_mix = 0.42;
    ctx.pitch_env = vel * 0.32;
    ctx.pitch_decay = 0.99945;
    modalDrumBodyTrigger(NAGADO_MODE_COUNT, &ctx.body, nagadoBodyConfig(ctx.base_freq, .don, ctx.volume), vel);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.001, 0.48, 0.0, 0.18);
}

pub fn nagadoTriggerKa(ctx: *Nagado, vel: f32) void {
    ctx.carrier_mix = 0.08;
    ctx.pitch_env = vel * 0.12;
    ctx.pitch_decay = 0.9988;
    modalDrumBodyTrigger(NAGADO_MODE_COUNT, &ctx.body, nagadoBodyConfig(ctx.base_freq, .ka, ctx.volume), vel);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.001, 0.08, 0.0, 0.025);
}

pub fn nagadoTriggerGhost(ctx: *Nagado, vel: f32) void {
    ctx.carrier_mix = 0.26;
    ctx.pitch_env = vel * 0.08;
    ctx.pitch_decay = 0.9992;
    modalDrumBodyTrigger(NAGADO_MODE_COUNT, &ctx.body, nagadoBodyConfig(ctx.base_freq, .ghost, ctx.volume), vel * 0.25);
    dsp.envelopeRetrigger(&ctx.carrier_env, 0.001, 0.18, 0.0, 0.06);
}

pub fn nagadoProcess(ctx: *Nagado, rng_inst: *dsp.Rng) f32 {
    const carrier_env = dsp.envelopeProcess(&ctx.carrier_env);

    ctx.pitch_env *= ctx.pitch_decay;
    const carrier_freq = ctx.base_freq * (1.0 + ctx.pitch_env * 0.18);
    ctx.phase += carrier_freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
    ctx.sub_phase += carrier_freq * 0.74 * dsp.INV_SR * dsp.TAU;
    if (ctx.sub_phase > dsp.TAU) ctx.sub_phase -= dsp.TAU;

    const carrier_body = (@sin(ctx.phase) * 0.76 + @sin(ctx.sub_phase) * 0.24) * ctx.carrier_mix * carrier_env;
    return modalDrumBodyProcess(NAGADO_MODE_COUNT, &ctx.body, rng_inst, carrier_body);
}

fn nagadoBodyConfig(base_freq: f32, stroke: TaikoStroke, volume: f32) ModalDrumBodyConfig(NAGADO_MODE_COUNT) {
    return switch (stroke) {
        .don => .{
            .mode_freqs = .{ base_freq, base_freq * 1.47, base_freq * 2.09, base_freq * 2.58, base_freq * 3.24, base_freq * 4.02 },
            .mode_t60s = .{ 1.40, 0.52, 0.25, 0.16, 0.11, 0.08 },
            .mode_gains = .{ 1.05, 0.64, 0.38, 0.24, 0.14, 0.08 },
            .body_lpf_hz = base_freq * 4.4,
            .body_hpf_hz = 18.0,
            .noise_lpf_hz = 2200.0,
            .noise_lpf2_hz = 20000.0,
            .noise_hpf_hz = 650.0,
            .body_mix = 0.95,
            .noise_mix = 0.09,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.055,
            .strike_release_s = 0.02,
            .strike_noise_samples = 2200,
            .strike_noise_decay = 0.0065,
            .strike_cluster_count = 1,
            .strike_cluster_spacing = 0,
            .strike_cluster_rolloff = 0.55,
            .velocity_floor = 0.55,
            .velocity_sensitivity = 0.45,
            .volume = volume,
        },
        .ka => .{
            .mode_freqs = .{ base_freq * 1.72, base_freq * 2.38, base_freq * 3.07, base_freq * 4.19, base_freq * 5.58, base_freq * 7.06 },
            .mode_t60s = .{ 0.13, 0.10, 0.074, 0.056, 0.044, 0.036 },
            .mode_gains = .{ 0.48, 0.43, 0.31, 0.22, 0.14, 0.09 },
            .body_lpf_hz = 4200.0,
            .body_hpf_hz = 35.0,
            .noise_lpf_hz = 6500.0,
            .noise_lpf2_hz = 20000.0,
            .noise_hpf_hz = 1800.0,
            .body_mix = 0.42,
            .noise_mix = 0.66,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.028,
            .strike_release_s = 0.012,
            .strike_noise_samples = 1200,
            .strike_noise_decay = 0.012,
            .strike_cluster_count = 1,
            .strike_cluster_spacing = 0,
            .strike_cluster_rolloff = 0.55,
            .velocity_floor = 0.55,
            .velocity_sensitivity = 0.45,
            .volume = volume,
        },
        .ghost => .{
            .mode_freqs = .{ base_freq, base_freq * 1.47, base_freq * 2.09, base_freq * 2.58, base_freq * 3.24, base_freq * 4.02 },
            .mode_t60s = .{ 0.22, 0.14, 0.097, 0.070, 0.054, 0.045 },
            .mode_gains = .{ 0.48, 0.26, 0.14, 0.072, 0.036, 0.02 },
            .body_lpf_hz = base_freq * 4.2,
            .body_hpf_hz = 18.0,
            .noise_lpf_hz = 1700.0,
            .noise_lpf2_hz = 20000.0,
            .noise_hpf_hz = 700.0,
            .body_mix = 0.68,
            .noise_mix = 0.07,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.035,
            .strike_release_s = 0.014,
            .strike_noise_samples = 900,
            .strike_noise_decay = 0.011,
            .strike_cluster_count = 1,
            .strike_cluster_spacing = 0,
            .strike_cluster_rolloff = 0.55,
            .velocity_floor = 0.55,
            .velocity_sensitivity = 0.45,
            .volume = volume,
        },
    };
}

pub const Shime = struct {
    body: ModalDrumBody(SHIME_MODE_COUNT) = .{
        .body_lpf = dsp.lpfInit(1200.0),
        .noise_lpf = dsp.lpfInit(4500.0),
        .noise_hpf = dsp.hpfInit(400.0),
        .body_mix = 0.86,
        .noise_mix = 0.2,
        .velocity_floor = 0.62,
        .velocity_sensitivity = 0.38,
        .volume = 0.56,
    },
    base_freq: f32 = 420.0,
    volume: f32 = 0.6,
};

pub fn shimeTriggerDon(ctx: *Shime, vel: f32) void {
    modalDrumBodyTrigger(SHIME_MODE_COUNT, &ctx.body, shimeBodyConfig(ctx.base_freq, .don, ctx.volume), vel);
}

pub fn shimeTriggerKa(ctx: *Shime, vel: f32) void {
    modalDrumBodyTrigger(SHIME_MODE_COUNT, &ctx.body, shimeBodyConfig(ctx.base_freq, .ka, ctx.volume), vel);
}

pub fn shimeTriggerRoll(ctx: *Shime, vel: f32) void {
    modalDrumBodyTrigger(SHIME_MODE_COUNT, &ctx.body, shimeBodyConfig(ctx.base_freq, .ghost, ctx.volume), vel);
}

pub fn shimeProcess(ctx: *Shime, rng_inst: *dsp.Rng) f32 {
    return modalDrumBodyProcess(SHIME_MODE_COUNT, &ctx.body, rng_inst, 0.0);
}

fn shimeBodyConfig(base_freq: f32, stroke: TaikoStroke, volume: f32) ModalDrumBodyConfig(SHIME_MODE_COUNT) {
    return switch (stroke) {
        .don => .{
            .mode_freqs = .{
                base_freq * 0.98,
                base_freq * 1.32,
                base_freq * 1.78,
                base_freq * 2.23,
                base_freq * 2.74,
                base_freq * 3.31,
                base_freq * 4.05,
                base_freq * 4.82,
                base_freq * 5.65,
                base_freq * 6.55,
                base_freq * 7.55,
            },
            .mode_t60s = .{ 0.060, 0.085, 0.16, 0.22, 0.30, 0.28, 0.22, 0.16, 0.11, 0.075, 0.050 },
            .mode_gains = .{ 0.025, 0.070, 0.25, 0.42, 0.58, 0.55, 0.42, 0.28, 0.15, 0.070, 0.030 },
            .body_lpf_hz = 4200.0,
            .body_hpf_hz = base_freq * 0.88,
            .noise_lpf_hz = 3600.0,
            .noise_lpf2_hz = 4300.0,
            .noise_hpf_hz = 720.0,
            .body_mix = 0.48,
            .noise_mix = 0.95,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.032,
            .strike_release_s = 0.006,
            .strike_noise_samples = 1450,
            .strike_noise_decay = 0.032,
            .strike_cluster_count = 4,
            .strike_cluster_spacing = 96,
            .strike_cluster_rolloff = 0.58,
            .velocity_floor = 0.56,
            .velocity_sensitivity = 0.44,
            .volume = volume * 2.60,
        },
        .ka => .{
            .mode_freqs = .{
                base_freq * 1.38,
                base_freq * 1.86,
                base_freq * 2.34,
                base_freq * 2.92,
                base_freq * 3.64,
                base_freq * 4.42,
                base_freq * 5.28,
                base_freq * 6.18,
                base_freq * 7.22,
                base_freq * 8.36,
                base_freq * 9.62,
            },
            .mode_t60s = .{ 0.065, 0.090, 0.10, 0.085, 0.065, 0.050, 0.038, 0.029, 0.022, 0.017, 0.013 },
            .mode_gains = .{ 0.055, 0.22, 0.34, 0.34, 0.28, 0.21, 0.15, 0.095, 0.060, 0.034, 0.018 },
            .body_lpf_hz = 4000.0,
            .body_hpf_hz = base_freq * 0.96,
            .noise_lpf_hz = 4100.0,
            .noise_lpf2_hz = 4700.0,
            .noise_hpf_hz = 880.0,
            .body_mix = 0.34,
            .noise_mix = 0.98,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.016,
            .strike_release_s = 0.004,
            .strike_noise_samples = 760,
            .strike_noise_decay = 0.050,
            .strike_cluster_count = 3,
            .strike_cluster_spacing = 78,
            .strike_cluster_rolloff = 0.48,
            .velocity_floor = 0.54,
            .velocity_sensitivity = 0.46,
            .volume = volume * 2.30,
        },
        .ghost => .{
            .mode_freqs = .{
                base_freq * 0.98,
                base_freq * 1.32,
                base_freq * 1.78,
                base_freq * 2.23,
                base_freq * 2.74,
                base_freq * 3.31,
                base_freq * 4.05,
                base_freq * 4.82,
                base_freq * 5.65,
                base_freq * 6.55,
                base_freq * 7.55,
            },
            .mode_t60s = .{ 0.060, 0.075, 0.072, 0.060, 0.046, 0.036, 0.028, 0.022, 0.017, 0.013, 0.010 },
            .mode_gains = .{ 0.035, 0.12, 0.19, 0.18, 0.14, 0.10, 0.067, 0.043, 0.027, 0.016, 0.009 },
            .body_lpf_hz = 3600.0,
            .body_hpf_hz = base_freq * 0.84,
            .noise_lpf_hz = 3500.0,
            .noise_lpf2_hz = 4100.0,
            .noise_hpf_hz = 760.0,
            .body_mix = 0.30,
            .noise_mix = 0.80,
            .strike_attack_s = 0.001,
            .strike_decay_s = 0.010,
            .strike_release_s = 0.003,
            .strike_noise_samples = 540,
            .strike_noise_decay = 0.060,
            .strike_cluster_count = 3,
            .strike_cluster_spacing = 64,
            .strike_cluster_rolloff = 0.42,
            .velocity_floor = 0.52,
            .velocity_sensitivity = 0.40,
            .volume = volume * 1.78,
        },
    };
}

pub const Atarigane = struct {
    resonators: dsp.ResonatorBank(ATARIGANE_MODE_COUNT) = .{},
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.08, 0.0, 0.04),
    hpf: dsp.HPF = dsp.hpfInit(1200.0),
    noise_lpf: dsp.LPF = dsp.lpfInit(7200.0),
    base_freq: f32 = 920.0,
    volume: f32 = 0.35,
    velocity: f32 = 0.0,
    muted: bool = false,
    strike_age: u32 = 999999,
};

pub fn atariganeTriggerOpen(ctx: *Atarigane, vel: f32) void {
    ctx.velocity = vel;
    ctx.muted = false;
    atariganeConfigureModes(ctx);
    dsp.resonatorBankExcite(ATARIGANE_MODE_COUNT, &ctx.resonators, .{ 0.34, 0.24, 0.18, 0.13, 0.095, 0.068, 0.048, 0.034, 0.024, 0.016 }, vel);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.055, 0.0, 0.02);
    ctx.strike_age = 0;
}

pub fn atariganeTriggerMuted(ctx: *Atarigane, vel: f32) void {
    ctx.velocity = vel;
    ctx.muted = true;
    atariganeConfigureModes(ctx);
    dsp.resonatorBankExcite(ATARIGANE_MODE_COUNT, &ctx.resonators, .{ 0.24, 0.16, 0.11, 0.074, 0.05, 0.034, 0.022, 0.014, 0.009, 0.006 }, vel * 0.8);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.018, 0.0, 0.008);
    ctx.strike_age = 0;
}

pub fn atariganeProcess(ctx: *Atarigane, rng_inst: *dsp.Rng) f32 {
    const strike_env = dsp.envelopeProcess(&ctx.env);

    var tone = dsp.resonatorBankProcess(ATARIGANE_MODE_COUNT, &ctx.resonators);
    if (ctx.strike_age < atariganeStrikeNoiseSamples(ctx.muted)) {
        const noise_gain: f32 = if (ctx.muted) 0.12 else 0.08;
        tone += dsp.exciterNoiseBurst(rng_inst, &ctx.hpf, &ctx.noise_lpf, ctx.strike_age, if (ctx.muted) 0.024 else 0.011, noise_gain) * strike_env;
        ctx.strike_age += 1;
    }
    tone = dsp.hpfProcess(&ctx.hpf, tone);

    if (ctx.muted) tone *= 0.55;
    return tone * ctx.volume;
}

fn atariganeConfigureModes(ctx: *Atarigane) void {
    dsp.resonatorBankConfigure(
        ATARIGANE_MODE_COUNT,
        &ctx.resonators,
        .{
            ctx.base_freq,
            ctx.base_freq * 1.58,
            ctx.base_freq * 2.19,
            ctx.base_freq * 2.74,
            ctx.base_freq * 3.68,
            ctx.base_freq * 4.63,
            ctx.base_freq * 5.89,
            ctx.base_freq * 7.21,
            ctx.base_freq * 8.96,
            ctx.base_freq * 10.83,
        },
        .{
            if (ctx.muted) 0.9986 else 0.99986,
            if (ctx.muted) 0.9984 else 0.9998,
            if (ctx.muted) 0.9981 else 0.99972,
            if (ctx.muted) 0.9978 else 0.99962,
            if (ctx.muted) 0.9975 else 0.99952,
            if (ctx.muted) 0.9972 else 0.9994,
            if (ctx.muted) 0.9969 else 0.99925,
            if (ctx.muted) 0.9966 else 0.99905,
            if (ctx.muted) 0.9963 else 0.99885,
            if (ctx.muted) 0.996 else 0.99865,
        },
    );
}

fn atariganeStrikeNoiseSamples(muted: bool) u32 {
    return if (muted) 1200 else 2600;
}

pub const SineDrone = struct {
    phases: [2]f32 = .{ 0.0, 0.0 },
    freq: f32 = dsp.midiToFreq(36),
    detune_ratio: f32 = 1.002,
    primary_mix: f32 = 1.0,
    secondary_mix: f32 = 0.5,
    volume: f32 = 0.02,
    filter: dsp.LPF = dsp.lpfInit(120.0),
};

pub fn sineDroneInit(freq: f32, cutoff_hz: f32, detune_ratio: f32, primary_mix: f32, secondary_mix: f32, volume: f32) SineDrone {
    return .{
        .freq = freq,
        .detune_ratio = detune_ratio,
        .primary_mix = primary_mix,
        .secondary_mix = secondary_mix,
        .volume = volume,
        .filter = dsp.lpfInit(cutoff_hz),
    };
}

pub fn sineDroneProcess(ctx: *SineDrone) f32 {
    ctx.phases[0] += ctx.freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phases[0] > dsp.TAU) ctx.phases[0] -= dsp.TAU;
    ctx.phases[1] += ctx.freq * ctx.detune_ratio * dsp.INV_SR * dsp.TAU;
    if (ctx.phases[1] > dsp.TAU) ctx.phases[1] -= dsp.TAU;

    var sample = @sin(ctx.phases[0]) * ctx.primary_mix + @sin(ctx.phases[1]) * ctx.secondary_mix;
    sample = dsp.lpfProcess(&ctx.filter, sample);
    return sample * ctx.volume;
}

pub const ChoirPart = struct {
    voice: dsp.Voice(3, 4) = .{ .vibrato_rate_hz = 5.1, .vibrato_depth = 0.0045 },
    formant_a: dsp.LPF = dsp.lpfInit(700.0),
    formant_b: dsp.LPF = dsp.lpfInit(1200.0),
    formant_c: dsp.LPF = dsp.lpfInit(2400.0),
    breath_hpf: dsp.HPF = dsp.hpfInit(1800.0),
    chest_lpf: dsp.LPF = dsp.lpfInit(320.0),
    vibrato_phase: f32 = 0.0,
    pan: f32 = 0.0,
    vowel_mix: f32 = 0.45,
    breath_mix: f32 = 0.08,
    chest_mix: f32 = 0.18,
};

pub fn choirPartInit(unison_spread: f32, pan: f32, vowel_idx: u8) ChoirPart {
    var part: ChoirPart = .{
        .voice = .{ .unison_spread = unison_spread, .vibrato_rate_hz = 5.1, .vibrato_depth = 0.0045 },
        .pan = pan,
    };
    choirPartSetVowel(&part, vowel_idx);
    return part;
}

pub fn choirPartSetVowel(ctx: *ChoirPart, vowel_idx: u8) void {
    switch (vowel_idx) {
        0 => {
            ctx.formant_a = dsp.lpfInit(620.0);
            ctx.formant_b = dsp.lpfInit(1180.0);
            ctx.formant_c = dsp.lpfInit(2450.0);
            ctx.vowel_mix = 0.34;
            ctx.breath_mix = 0.06;
        },
        1 => {
            ctx.formant_a = dsp.lpfInit(540.0);
            ctx.formant_b = dsp.lpfInit(920.0);
            ctx.formant_c = dsp.lpfInit(2280.0);
            ctx.vowel_mix = 0.42;
            ctx.breath_mix = 0.08;
        },
        2 => {
            ctx.formant_a = dsp.lpfInit(420.0);
            ctx.formant_b = dsp.lpfInit(780.0);
            ctx.formant_c = dsp.lpfInit(2050.0);
            ctx.vowel_mix = 0.58;
            ctx.breath_mix = 0.11;
        },
        else => {
            ctx.formant_a = dsp.lpfInit(760.0);
            ctx.formant_b = dsp.lpfInit(1520.0);
            ctx.formant_c = dsp.lpfInit(2680.0);
            ctx.vowel_mix = 0.48;
            ctx.breath_mix = 0.07;
        },
    }
}

pub fn choirPartTrigger(ctx: *ChoirPart, freq: f32, env: dsp.Envelope) void {
    dsp.voiceTrigger(3, 4, &ctx.voice, freq, env);
}

pub fn choirPartProcess(ctx: *ChoirPart) f32 {
    const raw = dsp.voiceProcessRaw(3, 4, &ctx.voice);
    if (raw.env_val <= 0.0001) return 0.0;

    ctx.vibrato_phase += 0.000013 * dsp.TAU;
    if (ctx.vibrato_phase > dsp.TAU) ctx.vibrato_phase -= dsp.TAU;

    const vibrato = @sin(ctx.vibrato_phase) * 0.018;
    const source = raw.osc + @sin(ctx.voice.phases[0] * 0.5 + vibrato) * 0.08;
    const fa = dsp.lpfProcess(&ctx.formant_a, source);
    const fb = dsp.lpfProcess(&ctx.formant_b, source);
    const fc = dsp.lpfProcess(&ctx.formant_c, source);
    const chest = dsp.lpfProcess(&ctx.chest_lpf, source) * ctx.chest_mix;
    const breath = dsp.hpfProcess(&ctx.breath_hpf, @sin(ctx.voice.phases[0] * 9.0) * 0.2 + source * 0.1) * ctx.breath_mix;
    const filtered = fa * (1.0 - ctx.vowel_mix) + fb * ctx.vowel_mix + fc * 0.22 + chest + breath;
    return filtered * raw.env_val;
}
