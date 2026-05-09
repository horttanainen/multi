const std = @import("std");
const dsp = @import("dsp.zig");

const GUITAR_FAUST_STRING_BUFFER_SIZE = 8192;
const GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS: f32 = 0.68;
const GUITAR_FAUST_PROMOTED_STRING_DECAY: f32 = 0.7765;
const GUITAR_FAUST_PROMOTED_HIGH_DECAY: f32 = 0.54;
const GUITAR_FAUST_PROMOTED_BRIDGE_COUPLING: f32 = 0.85;
const GUITAR_FAUST_PROMOTED_MUTE: f32 = 0.114;

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

fn guitarFaustPluckAttackSamples(frequency_hz: f32, decay_scale: f32) u32 {
    const max_freq = 3000.0;
    const ratio = std.math.clamp(frequency_hz / max_freq, 0.0, 0.96);
    const sharpness = std.math.clamp(decay_scale, 0.35, 2.5);
    const attack_seconds = 0.002 * sharpness * std.math.pow(f32, 1.0 - ratio, 2.0);
    return @max(@as(u32, @intFromFloat(@round(attack_seconds * dsp.SAMPLE_RATE))), 8);
}

fn guitarFaustSteelSmooth(ctx: *GuitarFaustPluck, input: f32) f32 {
    const stiffness = guitarFaustSteelSmoothAmount(ctx.params);
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

fn guitarFaustExcitationCutoff(frequency_hz: f32, params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const ratio = 5.0 + (brightness - GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 4.0;
    return std.math.clamp(frequency_hz * ratio, 80.0, 18000.0);
}

fn guitarFaustOutputCutoff(params: GuitarParams) f32 {
    const brightness = guitarPluckBrightness(params, GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - GUITAR_FAUST_PROMOTED_HIGH_DECAY;
    return std.math.clamp(9800.0 + (brightness - GUITAR_FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 3800.0 + high_decay_offset * 2200.0, 5200.0, 14500.0);
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

pub const Odaiko = struct {
    phase: f32 = 0,
    sub_phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.002, 1.2, 0.0, 0.8),
    body_lpf: dsp.LPF = dsp.lpfInit(120.0),
    base_freq: f32 = 48.0,
    sweep: f32 = 55.0,
    decay_rate: f32 = 0.9997,
    volume: f32 = 1.4,
    velocity: f32 = 0.0,
};

pub fn odaikoTriggerDon(ctx: *Odaiko, vel: f32) void {
    ctx.velocity = vel;
    ctx.pitch_env = vel;
    ctx.body_lpf = dsp.lpfInit(100.0 + vel * 60.0);
    dsp.envelopeRetrigger(&ctx.env, 0.002, 1.2, 0.0, 0.8);
}

pub fn odaikoTriggerGhost(ctx: *Odaiko, vel: f32) void {
    ctx.velocity = vel * 0.3;
    ctx.pitch_env = vel * 0.2;
    ctx.body_lpf = dsp.lpfInit(80.0);
    dsp.envelopeRetrigger(&ctx.env, 0.003, 0.4, 0.0, 0.2);
}

pub fn odaikoProcess(ctx: *Odaiko) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.pitch_env *= ctx.decay_rate;
    const freq = ctx.base_freq + ctx.pitch_env * ctx.sweep;
    ctx.phase += freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
    ctx.sub_phase += freq * 0.5 * dsp.INV_SR * dsp.TAU;
    if (ctx.sub_phase > dsp.TAU) ctx.sub_phase -= dsp.TAU;

    const body = @sin(ctx.phase) * 0.75 + @sin(ctx.sub_phase) * 0.35;
    return dsp.lpfProcess(&ctx.body_lpf, body) * env_val * ctx.velocity * ctx.volume;
}

pub const Nagado = struct {
    phase: f32 = 0,
    overtone_phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.28, 0.0, 0.14),
    body_lpf: dsp.LPF = dsp.lpfInit(600.0),
    noise_lpf: dsp.LPF = dsp.lpfInit(2400.0),
    noise_hpf: dsp.HPF = dsp.hpfInit(800.0),
    base_freq: f32 = 140.0,
    noise_mix: f32 = 0.12,
    body_mix: f32 = 0.88,
    velocity: f32 = 0.0,
    pitch_decay: f32 = 0.999,
    volume: f32 = 0.85,
};

pub fn nagadoTriggerDon(ctx: *Nagado, vel: f32) void {
    ctx.velocity = vel;
    ctx.pitch_env = 0.6;
    ctx.pitch_decay = 0.9992;
    ctx.noise_mix = 0.12;
    ctx.body_mix = 0.88;
    ctx.body_lpf = dsp.lpfInit(ctx.base_freq * 3.5);
    ctx.noise_lpf = dsp.lpfInit(1800.0);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.28, 0.0, 0.14);
}

pub fn nagadoTriggerKa(ctx: *Nagado, vel: f32) void {
    ctx.velocity = vel;
    ctx.pitch_env = 0.3;
    ctx.pitch_decay = 0.998;
    ctx.noise_mix = 0.72;
    ctx.body_mix = 0.18;
    ctx.body_lpf = dsp.lpfInit(4200.0);
    ctx.noise_lpf = dsp.lpfInit(6500.0);
    ctx.noise_hpf = dsp.hpfInit(1800.0);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.035, 0.0, 0.018);
}

pub fn nagadoTriggerGhost(ctx: *Nagado, vel: f32) void {
    nagadoTriggerDon(ctx, vel * 0.25);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.06, 0.0, 0.03);
}

pub fn nagadoProcess(ctx: *Nagado, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.pitch_env *= ctx.pitch_decay;
    const freq = ctx.base_freq * (1.0 + ctx.pitch_env * 0.25);
    ctx.phase += freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
    ctx.overtone_phase += freq * 1.58 * dsp.INV_SR * dsp.TAU;
    if (ctx.overtone_phase > dsp.TAU) ctx.overtone_phase -= dsp.TAU;

    const body = dsp.lpfProcess(&ctx.body_lpf, @sin(ctx.phase) + @sin(ctx.overtone_phase) * 0.18);
    const raw_noise = dsp.rngFloat(rng_inst) * 2.0 - 1.0;
    const noise = dsp.hpfProcess(&ctx.noise_hpf, dsp.lpfProcess(&ctx.noise_lpf, raw_noise));

    return (body * ctx.body_mix + noise * ctx.noise_mix) * env_val * ctx.velocity * ctx.volume;
}

pub const Shime = struct {
    phase: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.035, 0.0, 0.018),
    body_lpf: dsp.LPF = dsp.lpfInit(1200.0),
    noise_lpf: dsp.LPF = dsp.lpfInit(4500.0),
    base_freq: f32 = 420.0,
    volume: f32 = 0.6,
    velocity: f32 = 0.0,
};

pub fn shimeTriggerDon(ctx: *Shime, vel: f32) void {
    ctx.velocity = vel;
    ctx.body_lpf = dsp.lpfInit(ctx.base_freq * 2.5);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.045, 0.0, 0.022);
}

pub fn shimeTriggerKa(ctx: *Shime, vel: f32) void {
    ctx.velocity = vel;
    ctx.body_lpf = dsp.lpfInit(5500.0);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.02, 0.0, 0.01);
}

pub fn shimeTriggerRoll(ctx: *Shime, vel: f32) void {
    ctx.velocity = vel * 0.55;
    ctx.body_lpf = dsp.lpfInit(ctx.base_freq * 2.0);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.015, 0.0, 0.008);
}

pub fn shimeProcess(ctx: *Shime, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.phase += ctx.base_freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;

    const body = dsp.lpfProcess(&ctx.body_lpf, @sin(ctx.phase)) * 0.45;
    const noise = dsp.lpfProcess(&ctx.noise_lpf, dsp.rngFloat(rng_inst) * 2.0 - 1.0) * 0.55;
    return (body + noise) * env_val * ctx.velocity * ctx.volume;
}

pub const Atarigane = struct {
    resonators: dsp.ResonatorBank(4) = .{},
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
    dsp.resonatorBankExcite(4, &ctx.resonators, .{ 0.7, 0.42, 0.28, 0.16 }, vel);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.12, 0.0, 0.06);
    ctx.strike_age = 0;
}

pub fn atariganeTriggerMuted(ctx: *Atarigane, vel: f32) void {
    ctx.velocity = vel;
    ctx.muted = true;
    atariganeConfigureModes(ctx);
    dsp.resonatorBankExcite(4, &ctx.resonators, .{ 0.45, 0.24, 0.12, 0.06 }, vel * 0.8);
    dsp.envelopeRetrigger(&ctx.env, 0.001, 0.025, 0.0, 0.012);
    ctx.strike_age = 0;
}

pub fn atariganeProcess(ctx: *Atarigane, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    var tone = dsp.resonatorBankProcess(4, &ctx.resonators);
    if (ctx.strike_age < 2800) {
        tone += dsp.exciterNoiseBurst(rng_inst, &ctx.hpf, &ctx.noise_lpf, ctx.strike_age, if (ctx.muted) 0.015 else 0.007, 0.18);
        ctx.strike_age += 1;
    }
    tone = dsp.hpfProcess(&ctx.hpf, tone);

    if (ctx.muted) tone *= 0.4;
    return tone * env_val * ctx.velocity * ctx.volume;
}

fn atariganeConfigureModes(ctx: *Atarigane) void {
    dsp.resonatorBankConfigure(
        4,
        &ctx.resonators,
        .{
            ctx.base_freq,
            ctx.base_freq * 2.31,
            ctx.base_freq * 3.89,
            ctx.base_freq * 5.12,
        },
        .{
            if (ctx.muted) 0.9974 else 0.9992,
            if (ctx.muted) 0.9971 else 0.9988,
            if (ctx.muted) 0.9968 else 0.9984,
            if (ctx.muted) 0.9964 else 0.998,
        },
    );
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
