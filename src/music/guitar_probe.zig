const std = @import("std");
const dsp = @import("dsp.zig");

const STRING_MODE_COUNT = 28;
const SMS_PARTIAL_COUNT = 24;
const KS_BUFFER_SIZE = 8192;
const WAVEGUIDE_BUFFER_SIZE = 8192;
const FAUST_STRING_BUFFER_SIZE = 8192;
const FAUST_PROMOTED_PLUCK_BRIGHTNESS: f32 = 0.68;
const FAUST_PROMOTED_STRING_DECAY: f32 = 0.7765;
const FAUST_PROMOTED_HIGH_DECAY: f32 = 0.54;
const FAUST_PROMOTED_BRIDGE_COUPLING: f32 = 0.85;
const FAUST_PROMOTED_MUTE: f32 = 0.114;

const BODY_MODE_FREQS = [_]f32{
    101.6,
    118.8,
    204.7,
    281.0,
    354.0,
    438.0,
    557.0,
    704.0,
    883.0,
    1135.0,
    1450.0,
    1840.0,
};

const BODY_MODE_DECAYS = [_]f32{
    0.24,
    0.21,
    0.18,
    0.14,
    0.12,
    0.105,
    0.095,
    0.083,
    0.074,
    0.063,
    0.055,
    0.048,
};

const BODY_MODE_GAINS = [_]f32{
    0.00072,
    0.00095,
    0.00078,
    0.00052,
    0.00043,
    0.00036,
    0.00030,
    0.00025,
    0.00021,
    0.00017,
    0.00013,
    0.00010,
};

const BODY_MODE_COUNT = BODY_MODE_FREQS.len;

const BodyMode = struct {
    y1: f32 = 0.0,
    y2: f32 = 0.0,
    coeff: f32 = 0.0,
    radius_sq: f32 = 0.0,
    gain: f32 = 0.0,
};

const BodyFilterBank = struct {
    modes: [BODY_MODE_COUNT]BodyMode = [_]BodyMode{.{}} ** BODY_MODE_COUNT,
    hpf: dsp.HPF = dsp.hpfInit(42.0),
    lpf: dsp.LPF = dsp.lpfInit(7600.0),
};

const FaustBridgeFilter = struct {
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    h0: f32 = 0.7,
    h1: f32 = 0.15,
    rho: f32 = 0.99784,
};

const FaustPluckStep = struct {
    string_sample: f32 = 0.0,
    bridge_signal: f32 = 0.0,
};

pub const GuitarProbeParams = struct {
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
};

pub const GuitarModal = struct {
    string_phases: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_freqs: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_amps: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_decays: [STRING_MODE_COUNT]f32 = [_]f32{0.999} ** STRING_MODE_COUNT,
    bridge_prev: f32 = 0.0,
    params: GuitarProbeParams = .{},
    body: BodyFilterBank = .{},
    rng: dsp.Rng = dsp.rngInit(0xA78F_23C1),
    pick_hpf: dsp.HPF = dsp.hpfInit(900.0),
    pick_lpf: dsp.LPF = dsp.lpfInit(9200.0),
    out_hpf: dsp.HPF = dsp.hpfInit(36.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9200.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    age: u32 = 999999,
};

pub const GuitarKs = struct {
    buffer: [KS_BUFFER_SIZE]f32 = [_]f32{0.0} ** KS_BUFFER_SIZE,
    write_pos: usize = 0,
    delay_samples: usize = 256,
    frac: f32 = 0.0,
    bridge_prev: f32 = 0.0,
    params: GuitarProbeParams = .{},
    loop_filter: f32 = 0.0,
    loop_filter_coeff: f32 = 0.68,
    feedback: f32 = 0.993,
    body: BodyFilterBank = .{},
    rng: dsp.Rng = dsp.rngInit(0x51D2_BE13),
    pick_hpf: dsp.HPF = dsp.hpfInit(850.0),
    pick_lpf: dsp.LPF = dsp.lpfInit(8600.0),
    out_hpf: dsp.HPF = dsp.hpfInit(34.0),
    out_lpf: dsp.LPF = dsp.lpfInit(8800.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    age: u32 = 999999,
};

pub const GuitarWaveguideRaw = struct {
    string: dsp.WaveguideString(WAVEGUIDE_BUFFER_SIZE) = .{},
    out_hpf: dsp.HPF = dsp.hpfInit(34.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9000.0),
    params: GuitarProbeParams = .{},
    velocity: f32 = 0.8,
};

pub const GuitarFaustPluck = struct {
    buffer: [FAUST_STRING_BUFFER_SIZE]f32 = [_]f32{0.0} ** FAUST_STRING_BUFFER_SIZE,
    write_pos: usize = 0,
    delay_samples: usize = 128,
    frac: f32 = 0.0,
    params: GuitarProbeParams = .{},
    rng: dsp.Rng = dsp.rngInit(0xFA57_921D),
    bridge_filter: FaustBridgeFilter = .{},
    nut_filter: FaustBridgeFilter = .{},
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

pub const GuitarFaustBridgePluck = struct {
    core: GuitarFaustPluck = .{},
    bridge_prev: f32 = 0.0,
    bridge_hpf: dsp.HPF = dsp.hpfInit(92.0),
    bridge_lpf: dsp.LPF = dsp.lpfInit(8600.0),
};

pub const GuitarFaustBodyPluck = struct {
    core: GuitarFaustPluck = .{},
    body: BodyFilterBank = .{},
    bridge_prev: f32 = 0.0,
    body_drive_hpf: dsp.HPF = dsp.hpfInit(48.0),
    body_drive_lpf: dsp.LPF = dsp.lpfInit(2400.0),
};

pub const GuitarContactPickModal = struct {
    core: GuitarModal = .{},
    contact_body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    contact_rng: dsp.Rng = dsp.rngInit(0xC04A_71D5),
    contact_hpf: dsp.HPF = dsp.hpfInit(1300.0),
    contact_lpf: dsp.LPF = dsp.lpfInit(11800.0),
    contact_age: u32 = 999999,
    velocity: f32 = 0.8,
};

pub const GuitarModalPluck = struct {
    vertical: GuitarModal = .{},
    horizontal: GuitarModal = .{},
    body: BodyFilterBank = .{},
    attack_body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    rng: dsp.Rng = dsp.rngInit(0x922D_18A7),
    contact_hpf: dsp.HPF = dsp.hpfInit(1150.0),
    contact_lpf: dsp.LPF = dsp.lpfInit(10800.0),
    thump_lpf: dsp.LPF = dsp.lpfInit(1800.0),
    age: u32 = 999999,
    velocity: f32 = 0.8,
};

pub const GuitarBridgeBodyPluck = struct {
    vertical: GuitarModal = .{},
    horizontal: GuitarModal = .{},
    body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    rng: dsp.Rng = dsp.rngInit(0x7721_B41D),
    contact_hpf: dsp.HPF = dsp.hpfInit(1150.0),
    contact_lpf: dsp.LPF = dsp.lpfInit(10800.0),
    thump_lpf: dsp.LPF = dsp.lpfInit(1800.0),
    bridge_prev: f32 = 0.0,
    age: u32 = 999999,
    velocity: f32 = 0.8,
};

pub const GuitarAdmittancePluck = struct {
    vertical_phases: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    vertical_freqs: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    vertical_amps: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    vertical_decays: [STRING_MODE_COUNT]f32 = [_]f32{0.999} ** STRING_MODE_COUNT,
    vertical_body_gains: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    horizontal_phases: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    horizontal_freqs: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    horizontal_amps: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    horizontal_decays: [STRING_MODE_COUNT]f32 = [_]f32{0.999} ** STRING_MODE_COUNT,
    horizontal_body_gains: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    rng: dsp.Rng = dsp.rngInit(0x2F42_C911),
    bridge_prev: f32 = 0.0,
    bridge_body_lpf: dsp.LPF = dsp.lpfInit(1800.0),
    out_hpf: dsp.HPF = dsp.hpfInit(34.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9200.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    age: u32 = 999999,
};

pub const GuitarTwoPolModal = struct {
    vertical: GuitarModal = .{},
    horizontal: GuitarModal = .{},
    cross_body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    age: u32 = 999999,
};

pub const GuitarCommuted = struct {
    buffer: [KS_BUFFER_SIZE]f32 = [_]f32{0.0} ** KS_BUFFER_SIZE,
    write_pos: usize = 0,
    delay_samples: usize = 256,
    frac: f32 = 0.0,
    bridge_prev: f32 = 0.0,
    params: GuitarProbeParams = .{},
    loop_filter: f32 = 0.0,
    loop_filter_coeff: f32 = 0.58,
    feedback: f32 = 0.991,
    body: BodyFilterBank = .{},
    rng: dsp.Rng = dsp.rngInit(0x891F_47B3),
    pick_hpf: dsp.HPF = dsp.hpfInit(1100.0),
    pick_lpf: dsp.LPF = dsp.lpfInit(10000.0),
    out_hpf: dsp.HPF = dsp.hpfInit(38.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9200.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    age: u32 = 999999,
};

pub const GuitarSmsFit = struct {
    phases: [SMS_PARTIAL_COUNT]f32 = [_]f32{0.0} ** SMS_PARTIAL_COUNT,
    freqs: [SMS_PARTIAL_COUNT]f32 = [_]f32{0.0} ** SMS_PARTIAL_COUNT,
    amps: [SMS_PARTIAL_COUNT]f32 = [_]f32{0.0} ** SMS_PARTIAL_COUNT,
    decays: [SMS_PARTIAL_COUNT]f32 = [_]f32{0.999} ** SMS_PARTIAL_COUNT,
    wobble: [SMS_PARTIAL_COUNT]f32 = [_]f32{0.0} ** SMS_PARTIAL_COUNT,
    body: BodyFilterBank = .{},
    params: GuitarProbeParams = .{},
    rng: dsp.Rng = dsp.rngInit(0x5A31_7C0E),
    noise_hpf: dsp.HPF = dsp.hpfInit(700.0),
    noise_lpf: dsp.LPF = dsp.lpfInit(7600.0),
    out_hpf: dsp.HPF = dsp.hpfInit(34.0),
    out_lpf: dsp.LPF = dsp.lpfInit(9400.0),
    frequency_hz: f32 = 164.814,
    velocity: f32 = 0.8,
    age: u32 = 999999,
};

pub fn guitarModalTrigger(ctx: *GuitarModal, frequency_hz: f32, velocity: f32) void {
    guitarModalTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarModalTriggerWithParams(ctx: *GuitarModal, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0xA78F_23C1);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);
    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.0), bodyDecay(ctx.params, 1.0));
    guitarModalConfigureString(ctx);
    ctx.age = 0;
}

pub fn guitarModalProcess(ctx: *GuitarModal) f32 {
    const string_sample = guitarModalStringProcess(ctx);
    const bridge_force = bridgeForceSample(&ctx.bridge_prev, string_sample, bridgeCoupling(ctx.params, 5.4));
    const pick = guitarPickBurst(&ctx.rng, &ctx.pick_hpf, &ctx.pick_lpf, ctx.age, ctx.velocity, attackGain(ctx.params, pickNoise(ctx.params, 0.072)), attackDecay(ctx.params));
    const body = bodyFilterBankProcess(&ctx.body, bridge_force * 0.44 + string_sample * 0.18 + pick * 0.62);
    const mixed = body * bodyMix(ctx.params, 1.02) + string_sample * stringMix(ctx.params, 0.045) + pick * attackMix(ctx.params, 0.035);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 1.05));
}

pub fn guitarKsTrigger(ctx: *GuitarKs, frequency_hz: f32, velocity: f32) void {
    guitarKsTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarKsTriggerWithParams(ctx: *GuitarKs, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0x51D2_BE13);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);

    const delay_f = std.math.clamp(dsp.SAMPLE_RATE / ctx.frequency_hz, 6.0, @as(f32, @floatFromInt(KS_BUFFER_SIZE - 2)));
    const delay_floor = @floor(delay_f);
    ctx.delay_samples = @intFromFloat(delay_floor);
    ctx.frac = delay_f - delay_floor;

    const brightness = pluckBrightness(ctx.params, 0.30 + ctx.velocity * 0.30);
    ctx.loop_filter_coeff = 0.36 + brightness * 0.24;
    ctx.feedback = std.math.clamp((0.9865 + ctx.velocity * 0.0034 - ctx.frequency_hz * 0.0000022) * stringDecay(ctx.params), 0.965, 0.997);

    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.22), bodyDecay(ctx.params, 1.18));
    guitarKsFillDelay(ctx, brightness);
    ctx.age = 0;
}

pub fn guitarKsProcess(ctx: *GuitarKs) f32 {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarKsProcess: delay_samples={d} is invalid, returning silence", .{ctx.delay_samples});
        return 0.0;
    }

    const read_idx = ctx.write_pos;
    const next_idx = if (read_idx + 1 >= ctx.delay_samples) 0 else read_idx + 1;
    const current = ctx.buffer[read_idx];
    const next = ctx.buffer[next_idx];
    const string_sample = current + (next - current) * ctx.frac;
    const bridge_force = bridgeForceSample(&ctx.bridge_prev, string_sample, bridgeCoupling(ctx.params, 3.6));
    const averaged = (current + next) * 0.5;

    ctx.loop_filter += (averaged - ctx.loop_filter) * ctx.loop_filter_coeff;
    ctx.buffer[read_idx] = dsp.softClip((ctx.loop_filter * 0.92 + string_sample * 0.08) * ctx.feedback);
    ctx.write_pos = next_idx;

    const pick = guitarPickBurst(&ctx.rng, &ctx.pick_hpf, &ctx.pick_lpf, ctx.age, ctx.velocity, attackGain(ctx.params, pickNoise(ctx.params, 0.036)), attackDecay(ctx.params));
    const body = bodyFilterBankProcess(&ctx.body, bridge_force * 0.48 + string_sample * 0.08 + pick * 0.44);
    const mixed = body * bodyMix(ctx.params, 1.08) + string_sample * stringMix(ctx.params, 0.030) + pick * attackMix(ctx.params, 0.030);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 0.78));
}

pub fn guitarWaveguideRawTrigger(ctx: *GuitarWaveguideRaw, frequency_hz: f32, velocity: f32) void {
    guitarWaveguideRawTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarWaveguideRawTriggerWithParams(ctx: *GuitarWaveguideRaw, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    const safe_freq = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);
    dsp.waveguideStringSetFreq(WAVEGUIDE_BUFFER_SIZE, &ctx.string, safe_freq);
    dsp.waveguideStringPluck(WAVEGUIDE_BUFFER_SIZE, &ctx.string, ctx.velocity * 0.64, pluckBrightness(ctx.params, 0.68));
}

pub fn guitarWaveguideRawProcess(ctx: *GuitarWaveguideRaw) f32 {
    const raw = dsp.waveguideStringProcess(WAVEGUIDE_BUFFER_SIZE, &ctx.string);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, raw * stringMix(ctx.params, 0.42)));
    return dsp.softClip(filtered * outputGain(ctx.params, 1.0));
}

pub fn guitarFaustPluckTrigger(ctx: *GuitarFaustPluck, frequency_hz: f32, velocity: f32) void {
    guitarFaustPluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarFaustPluckTriggerWithParams(ctx: *GuitarFaustPluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0xFA57_921D);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);

    const delay_f = std.math.clamp(dsp.SAMPLE_RATE / ctx.frequency_hz, 8.0, @as(f32, @floatFromInt(FAUST_STRING_BUFFER_SIZE - 2)));
    const delay_floor = @floor(delay_f);
    ctx.delay_samples = @intFromFloat(delay_floor);
    ctx.frac = delay_f - delay_floor;
    if (ctx.delay_samples < 8) {
        std.log.warn("guitarFaustPluckTriggerWithParams: delay_samples={d} is invalid, clamping to 8", .{ctx.delay_samples});
        ctx.delay_samples = 8;
    }

    ctx.bridge_filter = faustBridgeFilterInit(faustBridgeBrightness(ctx.params), faustBridgeAbsorption(ctx.params));
    ctx.nut_filter = faustBridgeFilterInit(faustBridgeBrightness(ctx.params), faustBridgeAbsorption(ctx.params));
    ctx.excitation_lpf1 = dsp.lpfInit(faustExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.excitation_lpf2 = dsp.lpfInit(faustExcitationCutoff(ctx.frequency_hz, ctx.params));
    ctx.out_lpf = dsp.lpfInit(faustOutputCutoff(ctx.params));
    ctx.feedback = faustStringFeedback(ctx.params);
    guitarFaustPluckPrimeString(ctx);
    ctx.age = 0;
}

pub fn guitarFaustPluckProcess(ctx: *GuitarFaustPluck) f32 {
    const step = guitarFaustPluckStep(ctx) orelse return 0.0;
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, step.string_sample * stringMix(ctx.params, 0.48)));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 4.8));
}

pub fn guitarFaustBridgePluckTrigger(ctx: *GuitarFaustBridgePluck, frequency_hz: f32, velocity: f32) void {
    guitarFaustBridgePluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarFaustBridgePluckTriggerWithParams(ctx: *GuitarFaustBridgePluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    guitarFaustPluckTriggerWithParams(&ctx.core, frequency_hz, velocity, params);
}

pub fn guitarFaustBridgePluckProcess(ctx: *GuitarFaustBridgePluck) f32 {
    const step = guitarFaustPluckStep(&ctx.core) orelse return 0.0;
    const params = ctx.core.params;
    const bridge_velocity = bridgeForceSample(&ctx.bridge_prev, step.bridge_signal, bridgeCoupling(params, 0.74));
    const bridge = dsp.lpfProcess(&ctx.bridge_lpf, dsp.hpfProcess(&ctx.bridge_hpf, bridge_velocity));
    const dry = step.string_sample * stringMix(params, 0.20);
    const coupled = bridge * stringMix(params, 0.40);
    const filtered = dsp.lpfProcess(&ctx.core.out_lpf, dsp.hpfProcess(&ctx.core.out_hpf, dry + coupled));
    ctx.core.age = nextAge(ctx.core.age);
    return dsp.softClip(filtered * outputGain(params, 4.8));
}

pub fn guitarFaustBodyPluckTrigger(ctx: *GuitarFaustBodyPluck, frequency_hz: f32, velocity: f32) void {
    guitarFaustBodyPluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarFaustBodyPluckTriggerWithParams(ctx: *GuitarFaustBodyPluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    guitarFaustPluckTriggerWithParams(&ctx.core, frequency_hz, velocity, params);
    const safe_params = ctx.core.params;
    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(safe_params, 1.0), bodyGain(safe_params, 2.15), bodyDecay(safe_params, 1.25));
}

pub fn guitarFaustBodyPluckProcess(ctx: *GuitarFaustBodyPluck) f32 {
    const step = guitarFaustPluckStep(&ctx.core) orelse return 0.0;
    const params = ctx.core.params;
    const bridge_velocity = bridgeForceSample(&ctx.bridge_prev, step.bridge_signal, bridgeCoupling(params, 5.2));
    const body_drive = dsp.lpfProcess(&ctx.body_drive_lpf, dsp.hpfProcess(&ctx.body_drive_hpf, bridge_velocity + step.string_sample * 0.10));
    const body = bodyFilterBankProcess(&ctx.body, body_drive * 2.4);
    const dry = step.string_sample * stringMix(params, 0.22);
    const bridge_presence = body_drive * stringMix(params, 0.055);
    const body_signal = body * bodyMix(params, 13.5);
    const filtered = dsp.lpfProcess(&ctx.core.out_lpf, dsp.hpfProcess(&ctx.core.out_hpf, dry + bridge_presence + body_signal));
    ctx.core.age = nextAge(ctx.core.age);
    return dsp.softClip(filtered * outputGain(params, 4.35));
}

fn guitarFaustPluckStep(ctx: *GuitarFaustPluck) ?FaustPluckStep {
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
    const bridge = faustBridgeFilterProcess(&ctx.bridge_filter, string_sample);
    const nut = faustBridgeFilterProcess(&ctx.nut_filter, bridge);
    const steel_string = guitarFaustSteelSmooth(ctx, nut);

    ctx.buffer[read_idx] = std.math.clamp(steel_string * ctx.feedback + excitation, -1.0, 1.0);
    ctx.write_pos = next_idx;

    return .{
        .string_sample = string_sample,
        .bridge_signal = bridge,
    };
}

pub fn guitarContactPickModalTrigger(ctx: *GuitarContactPickModal, frequency_hz: f32, velocity: f32) void {
    guitarContactPickModalTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarContactPickModalTriggerWithParams(ctx: *GuitarContactPickModal, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.velocity = safeVelocity(velocity);
    guitarModalTriggerWithParams(&ctx.core, frequency_hz, ctx.velocity, ctx.params);
    modalScaleString(&ctx.core, 0.96);
    bodyFilterBankConfigureScaled(&ctx.contact_body, bodyFreq(ctx.params, 1.04), bodyGain(ctx.params, 1.25), bodyDecay(ctx.params, 1.0));
    ctx.contact_rng = dsp.rngInit(0xC04A_71D5);
    ctx.contact_age = 0;
}

pub fn guitarContactPickModalProcess(ctx: *GuitarContactPickModal) f32 {
    const modal = guitarModalProcess(&ctx.core);
    const contact = guitarContactPickSample(ctx);
    const body_contact = bodyFilterBankProcess(&ctx.contact_body, contact);
    ctx.contact_age = nextAge(ctx.contact_age);
    return dsp.softClip((modal * stringMix(ctx.params, 0.92) + body_contact * bodyMix(ctx.params, 0.68) + contact * attackMix(ctx.params, 0.08)) * outputGain(ctx.params, 1.0));
}

pub fn guitarModalPluckTrigger(ctx: *GuitarModalPluck, frequency_hz: f32, velocity: f32) void {
    guitarModalPluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarModalPluckTriggerWithParams(ctx: *GuitarModalPluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.velocity = safeVelocity(velocity);
    ctx.rng = dsp.rngInit(0x922D_18A7);

    guitarModalTriggerWithParams(&ctx.vertical, frequency_hz, ctx.velocity * 0.96, ctx.params);
    guitarModalTriggerWithParams(&ctx.horizontal, frequency_hz * 1.004, ctx.velocity * 0.48, ctx.params);
    modalRevoiceReferencePluck(&ctx.vertical, pluckPosition(ctx.params, 0.145), pluckBrightness(ctx.params, 0.82), 0.115, stringDecay(ctx.params) * 0.92, 0.0);
    modalRevoiceReferencePluck(&ctx.horizontal, pluckPosition(ctx.params, 0.185), pluckBrightness(ctx.params, 0.66), 0.058, stringDecay(ctx.params) * 0.72, 0.11);

    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.42), bodyDecay(ctx.params, 1.0));
    bodyFilterBankConfigureScaled(&ctx.attack_body, bodyFreq(ctx.params, 1.035), attackGain(ctx.params, bodyGain(ctx.params, 1.78)), bodyDecay(ctx.params, 1.0));
    ctx.age = 0;
}

pub fn guitarModalPluckProcess(ctx: *GuitarModalPluck) f32 {
    const vertical = guitarModalStringProcess(&ctx.vertical);
    const horizontal = guitarModalStringProcess(&ctx.horizontal);
    const contact = guitarModalPluckContact(ctx);
    const transverse = vertical * 0.34 + horizontal * 0.17;
    const polarization = (vertical - horizontal) * 0.08;
    const body = bodyFilterBankProcess(&ctx.body, transverse + contact * 0.78);
    const attack_body = bodyFilterBankProcess(&ctx.attack_body, contact * 1.06 + polarization);
    const direct = (vertical * 0.075 + horizontal * 0.036) * stringMix(ctx.params, 1.0) + contact * attackMix(ctx.params, 0.032);
    const mixed = body * bodyMix(ctx.params, 0.96) + attack_body * attackMix(ctx.params, 0.58) + direct;
    const filtered = dsp.lpfProcess(&ctx.vertical.out_lpf, dsp.hpfProcess(&ctx.vertical.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 3.55));
}

pub fn guitarBridgeBodyPluckTrigger(ctx: *GuitarBridgeBodyPluck, frequency_hz: f32, velocity: f32) void {
    guitarBridgeBodyPluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarBridgeBodyPluckTriggerWithParams(ctx: *GuitarBridgeBodyPluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.velocity = safeVelocity(velocity);
    ctx.rng = dsp.rngInit(0x7721_B41D);

    guitarModalTriggerWithParams(&ctx.vertical, frequency_hz, ctx.velocity * 0.96, ctx.params);
    guitarModalTriggerWithParams(&ctx.horizontal, frequency_hz * 1.004, ctx.velocity * 0.48, ctx.params);
    modalRevoiceReferencePluck(&ctx.vertical, pluckPosition(ctx.params, 0.145), pluckBrightness(ctx.params, 0.82), 0.115, stringDecay(ctx.params) * 0.92, 0.0);
    modalRevoiceReferencePluck(&ctx.horizontal, pluckPosition(ctx.params, 0.185), pluckBrightness(ctx.params, 0.66), 0.058, stringDecay(ctx.params) * 0.72, 0.11);

    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.42), bodyDecay(ctx.params, 1.0));
    ctx.age = 0;
}

pub fn guitarBridgeBodyPluckProcess(ctx: *GuitarBridgeBodyPluck) f32 {
    const vertical = guitarModalStringProcess(&ctx.vertical);
    const horizontal = guitarModalStringProcess(&ctx.horizontal);
    const contact = guitarBridgeBodyPluckContact(ctx);
    const transverse = vertical * 0.34 + horizontal * 0.17;
    const polarization = (vertical - horizontal) * 0.08;
    const bridge_motion = transverse + polarization * 0.35;
    const bridge_force = bridgeForceSample(&ctx.bridge_prev, bridge_motion, bridgeCoupling(ctx.params, 4.2));
    const body_drive = bridge_force * 0.44 + transverse * 0.18 + polarization * 0.08;
    const body = bodyFilterBankProcess(&ctx.body, body_drive);
    const direct = (vertical * 0.075 + horizontal * 0.036) * stringMix(ctx.params, 1.0) + contact * attackMix(ctx.params, 0.032);
    const mixed = body * bodyMix(ctx.params, 0.96) + direct;
    const filtered = dsp.lpfProcess(&ctx.vertical.out_lpf, dsp.hpfProcess(&ctx.vertical.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 3.55));
}

pub fn guitarAdmittancePluckTrigger(ctx: *GuitarAdmittancePluck, frequency_hz: f32, velocity: f32) void {
    guitarAdmittancePluckTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarAdmittancePluckTriggerWithParams(ctx: *GuitarAdmittancePluck, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0x2F42_C911);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);

    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.34), bodyDecay(ctx.params, 0.96));
    guitarAdmittanceConfigureBank(
        ctx.params,
        &ctx.rng,
        ctx.frequency_hz,
        ctx.velocity * 0.98,
        pluckPosition(ctx.params, 0.152),
        pluckBrightness(ctx.params, 0.78),
        0.122,
        0.93,
        1.0,
        0.0,
        &ctx.vertical_phases,
        &ctx.vertical_freqs,
        &ctx.vertical_amps,
        &ctx.vertical_decays,
        &ctx.vertical_body_gains,
    );
    guitarAdmittanceConfigureBank(
        ctx.params,
        &ctx.rng,
        ctx.frequency_hz * 1.004,
        ctx.velocity * 0.46,
        pluckPosition(ctx.params, 0.205),
        pluckBrightness(ctx.params, 0.58),
        0.066,
        0.76,
        0.62,
        0.19,
        &ctx.horizontal_phases,
        &ctx.horizontal_freqs,
        &ctx.horizontal_amps,
        &ctx.horizontal_decays,
        &ctx.horizontal_body_gains,
    );
    ctx.age = 0;
}

pub fn guitarAdmittancePluckProcess(ctx: *GuitarAdmittancePluck) f32 {
    const vertical = guitarAdmittanceProcessBank(
        &ctx.vertical_phases,
        &ctx.vertical_freqs,
        &ctx.vertical_amps,
        &ctx.vertical_decays,
        &ctx.vertical_body_gains,
        1.0,
    );
    const horizontal = guitarAdmittanceProcessBank(
        &ctx.horizontal_phases,
        &ctx.horizontal_freqs,
        &ctx.horizontal_amps,
        &ctx.horizontal_decays,
        &ctx.horizontal_body_gains,
        0.58,
    );
    const bridge_motion = vertical.bridge_motion * 0.78 + horizontal.bridge_motion * 0.31;
    const raw_bridge_force = bridgeForceSample(&ctx.bridge_prev, bridge_motion, bridgeCoupling(ctx.params, 3.65));
    const bridge_force = dsp.lpfProcess(&ctx.bridge_body_lpf, raw_bridge_force);
    const body_drive = bridge_force * 0.50 + vertical.radiated * 0.095 + horizontal.radiated * 0.038;
    const body_transient = bodyFilterBankProcess(&ctx.body, body_drive);
    const body_harmonic = vertical.radiated * 0.285 + horizontal.radiated * 0.105;
    const direct_string = vertical.direct * 0.058 + horizontal.direct * 0.031;
    const sharp_edge = vertical.edge * 0.010 + horizontal.edge * 0.004;
    const mixed = body_transient * bodyMix(ctx.params, 0.92) + body_harmonic * bodyMix(ctx.params, 0.66) + direct_string * stringMix(ctx.params, 1.0) + sharp_edge * attackMix(ctx.params, 0.24);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 3.25));
}

pub fn guitarTwoPolModalTrigger(ctx: *GuitarTwoPolModal, frequency_hz: f32, velocity: f32) void {
    guitarTwoPolModalTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarTwoPolModalTriggerWithParams(ctx: *GuitarTwoPolModal, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    const safe_velocity = safeVelocity(velocity);
    guitarModalTriggerWithParams(&ctx.vertical, frequency_hz, safe_velocity, ctx.params);
    guitarModalTriggerWithParams(&ctx.horizontal, frequency_hz * 1.006, safe_velocity * 0.56, ctx.params);
    modalRetuneAndDamp(&ctx.horizontal, 1.006, 0.82);
    modalScaleString(&ctx.horizontal, 0.52);
    bodyFilterBankConfigureScaled(&ctx.cross_body, bodyFreq(ctx.params, 0.98), bodyGain(ctx.params, 0.65), bodyDecay(ctx.params, 1.0));
    ctx.age = 0;
}

pub fn guitarTwoPolModalProcess(ctx: *GuitarTwoPolModal) f32 {
    const vertical = guitarModalProcess(&ctx.vertical);
    const horizontal = guitarModalProcess(&ctx.horizontal);
    const cross = bodyFilterBankProcess(&ctx.cross_body, (vertical - horizontal) * 0.16);
    ctx.age = nextAge(ctx.age);
    return dsp.softClip((vertical * stringMix(ctx.params, 0.82) + horizontal * stringMix(ctx.params, 0.48) + cross * bodyMix(ctx.params, 0.32)) * outputGain(ctx.params, 1.0));
}

pub fn guitarCommutedTrigger(ctx: *GuitarCommuted, frequency_hz: f32, velocity: f32) void {
    guitarCommutedTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarCommutedTriggerWithParams(ctx: *GuitarCommuted, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0x891F_47B3);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);

    const delay_f = std.math.clamp(dsp.SAMPLE_RATE / ctx.frequency_hz, 6.0, @as(f32, @floatFromInt(KS_BUFFER_SIZE - 2)));
    const delay_floor = @floor(delay_f);
    ctx.delay_samples = @intFromFloat(delay_floor);
    ctx.frac = delay_f - delay_floor;
    ctx.loop_filter_coeff = 0.42 + ctx.velocity * 0.14;
    ctx.feedback = std.math.clamp((0.986 + ctx.velocity * 0.0036 - ctx.frequency_hz * 0.0000018) * stringDecay(ctx.params), 0.965, 0.997);

    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.30), bodyDecay(ctx.params, 1.25));
    guitarCommutedFillDelay(ctx);
    ctx.age = 0;
}

pub fn guitarCommutedProcess(ctx: *GuitarCommuted) f32 {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarCommutedProcess: delay_samples={d} is invalid, returning silence", .{ctx.delay_samples});
        return 0.0;
    }

    const read_idx = ctx.write_pos;
    const next_idx = if (read_idx + 1 >= ctx.delay_samples) 0 else read_idx + 1;
    const current = ctx.buffer[read_idx];
    const next = ctx.buffer[next_idx];
    const string_sample = current + (next - current) * ctx.frac;
    const bridge_force = bridgeForceSample(&ctx.bridge_prev, string_sample, bridgeCoupling(ctx.params, 3.2));
    const averaged = (current + next) * 0.5;

    ctx.loop_filter += (averaged - ctx.loop_filter) * ctx.loop_filter_coeff;
    ctx.buffer[read_idx] = dsp.softClip((ctx.loop_filter * 0.90 + string_sample * 0.10) * ctx.feedback);
    ctx.write_pos = next_idx;

    const pick = guitarPickBurst(&ctx.rng, &ctx.pick_hpf, &ctx.pick_lpf, ctx.age, ctx.velocity, attackGain(ctx.params, pickNoise(ctx.params, 0.020)), attackDecay(ctx.params));
    const body = bodyFilterBankProcess(&ctx.body, bridge_force * 0.38 + string_sample * 0.12 + pick * 0.72);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, body * bodyMix(ctx.params, 1.02) + string_sample * stringMix(ctx.params, 0.055) + pick * attackMix(ctx.params, 0.030)));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 0.82));
}

pub fn guitarSmsFitTrigger(ctx: *GuitarSmsFit, frequency_hz: f32, velocity: f32) void {
    guitarSmsFitTriggerWithParams(ctx, frequency_hz, velocity, .{});
}

pub fn guitarSmsFitTriggerWithParams(ctx: *GuitarSmsFit, frequency_hz: f32, velocity: f32, params: GuitarProbeParams) void {
    ctx.* = .{};
    ctx.params = sanitizedParams(params);
    ctx.rng = dsp.rngInit(0x5A31_7C0E);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);
    bodyFilterBankConfigureScaled(&ctx.body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.35), bodyDecay(ctx.params, 1.0));
    guitarSmsFitConfigurePartials(ctx);
    ctx.age = 0;
}

pub fn guitarSmsFitProcess(ctx: *GuitarSmsFit) f32 {
    var tonal: f32 = 0.0;
    for (0..SMS_PARTIAL_COUNT) |idx| {
        if (ctx.amps[idx] <= 0.000002) continue;

        const jitter = (dsp.rngFloat(&ctx.rng) * 2.0 - 1.0) * 0.000018;
        ctx.wobble[idx] = ctx.wobble[idx] * 0.9993 + jitter;
        ctx.phases[idx] += ctx.freqs[idx] * (1.0 + ctx.wobble[idx]) * dsp.INV_SR * dsp.TAU;
        if (ctx.phases[idx] > dsp.TAU) ctx.phases[idx] -= dsp.TAU;
        tonal += @sin(ctx.phases[idx]) * ctx.amps[idx];
        ctx.amps[idx] *= ctx.decays[idx];
    }

    const residual = guitarSmsResidualNoise(ctx);
    const body = bodyFilterBankProcess(&ctx.body, tonal * 0.24 + residual * 0.72);
    const mixed = body * bodyMix(ctx.params, 0.72) + tonal * stringMix(ctx.params, 0.18) + residual * attackMix(ctx.params, 0.08);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * outputGain(ctx.params, 3.8));
}

fn guitarModalConfigureString(ctx: *GuitarModal) void {
    const pluck_position = pluckPosition(ctx.params, 0.18);
    const brightness = mutedBrightness(ctx.params, pluckBrightness(ctx.params, 0.52 + ctx.velocity * 0.36));

    for (0..STRING_MODE_COUNT) |idx| {
        const harmonic: f32 = @floatFromInt(idx + 1);
        const stiffness = stiffnessRatio(ctx.params, harmonic, 0.000045);
        const mode_freq = ctx.frequency_hz * harmonic * stiffness;
        const pluck_gain = @abs(@sin(std.math.pi * harmonic * pluck_position));
        const harmonic_rolloff = 1.0 / std.math.pow(f32, harmonic, 0.72 + (1.0 - brightness) * 0.38);
        const air_loss = @exp(-0.0018 * harmonic * harmonic);
        const decay_seconds = std.math.clamp((2.7 / @sqrt(harmonic) + 0.14) * stringDecay(ctx.params) * highDecay(ctx.params, harmonic), 0.06, 4.5);

        ctx.string_freqs[idx] = mode_freq;
        ctx.string_decays[idx] = decayPerSample(decay_seconds);
        ctx.string_phases[idx] = dsp.rngFloat(&ctx.rng) * dsp.TAU;
        ctx.string_amps[idx] = pluck_gain * harmonic_rolloff * air_loss * ctx.velocity * 0.108;

        if (mode_freq >= dsp.SAMPLE_RATE * 0.48) {
            ctx.string_amps[idx] = 0.0;
        }
    }
}

fn guitarModalStringProcess(ctx: *GuitarModal) f32 {
    var string_sample: f32 = 0.0;

    for (0..STRING_MODE_COUNT) |idx| {
        if (ctx.string_amps[idx] <= 0.000002) continue;
        if (ctx.string_freqs[idx] >= dsp.SAMPLE_RATE * 0.48) {
            ctx.string_amps[idx] = 0.0;
            continue;
        }

        ctx.string_phases[idx] += ctx.string_freqs[idx] * dsp.INV_SR * dsp.TAU;
        if (ctx.string_phases[idx] > dsp.TAU) ctx.string_phases[idx] -= dsp.TAU;
        string_sample += @sin(ctx.string_phases[idx]) * ctx.string_amps[idx];
        ctx.string_amps[idx] *= ctx.string_decays[idx];
    }

    return string_sample;
}

fn modalRevoiceReferencePluck(ctx: *GuitarModal, pluck_position: f32, brightness: f32, gain: f32, decay_scale: f32, phase_bias: f32) void {
    const safe_pluck = std.math.clamp(pluck_position, 0.05, 0.45);
    const safe_brightness = mutedBrightness(ctx.params, std.math.clamp(brightness, 0.0, 1.0));
    const safe_decay_scale = std.math.clamp(decay_scale, 0.05, 2.5);
    const rolloff = 0.54 + (1.0 - safe_brightness) * 0.42;
    const air_loss_base = 0.00115 + (1.0 - safe_brightness) * 0.0014;

    for (0..STRING_MODE_COUNT) |idx| {
        const harmonic: f32 = @floatFromInt(idx + 1);
        const stiffness = stiffnessRatio(ctx.params, harmonic, 0.000042);
        const mode_freq = ctx.frequency_hz * harmonic * stiffness;
        const pluck_gain = @abs(@sin(std.math.pi * harmonic * safe_pluck));
        const harmonic_rolloff = 1.0 / std.math.pow(f32, harmonic, rolloff);
        const bridge_force = std.math.clamp(harmonic * 0.28, 0.42, 1.0);
        const air_loss = @exp(-air_loss_base * harmonic * harmonic);
        const decay_seconds = std.math.clamp((2.18 / @sqrt(harmonic) + 0.085) * safe_decay_scale * highDecay(ctx.params, harmonic), 0.065, 2.65);
        const phase_jitter = (dsp.rngFloat(&ctx.rng) - 0.5) * 0.12;

        ctx.string_freqs[idx] = mode_freq;
        ctx.string_decays[idx] = decayPerSample(decay_seconds);
        ctx.string_phases[idx] = std.math.pi * 0.5 + phase_bias * harmonic + phase_jitter;
        ctx.string_amps[idx] = pluck_gain * harmonic_rolloff * bridge_force * air_loss * ctx.velocity * gain;

        if (mode_freq >= dsp.SAMPLE_RATE * 0.48) {
            ctx.string_amps[idx] = 0.0;
        }
    }
}

const AdmittanceBankOutput = struct {
    direct: f32 = 0.0,
    bridge_motion: f32 = 0.0,
    radiated: f32 = 0.0,
    edge: f32 = 0.0,
};

fn guitarAdmittanceConfigureBank(
    params: GuitarProbeParams,
    rng: *dsp.Rng,
    frequency_hz: f32,
    velocity: f32,
    pluck_position: f32,
    brightness: f32,
    gain: f32,
    decay_scale: f32,
    admittance_scale: f32,
    phase_bias: f32,
    phases: *[STRING_MODE_COUNT]f32,
    freqs: *[STRING_MODE_COUNT]f32,
    amps: *[STRING_MODE_COUNT]f32,
    decays: *[STRING_MODE_COUNT]f32,
    body_gains: *[STRING_MODE_COUNT]f32,
) void {
    const safe_pluck = std.math.clamp(pluck_position, 0.05, 0.45);
    const safe_brightness = mutedBrightness(params, std.math.clamp(brightness, 0.0, 1.0));
    const safe_decay_scale = std.math.clamp(decay_scale, 0.05, 2.5);
    const rolloff = 0.58 + (1.0 - safe_brightness) * 0.48;
    const air_loss_base = 0.00088 + (1.0 - safe_brightness) * 0.00115;
    const coupling = std.math.clamp(bridgeCoupling(params, 1.0), 0.0, 4.0);

    for (0..STRING_MODE_COUNT) |idx| {
        const harmonic: f32 = @floatFromInt(idx + 1);
        const stiffness = stiffnessRatio(params, harmonic, 0.000040);
        const mode_freq = frequency_hz * harmonic * stiffness;
        const admittance = bodyAdmittanceMagnitude(params, mode_freq);
        const pluck_gain = @abs(@sin(std.math.pi * harmonic * safe_pluck));
        const harmonic_rolloff = 1.0 / std.math.pow(f32, harmonic, rolloff);
        const bridge_force_weight = std.math.clamp(harmonic * 0.23, 0.34, 1.65);
        const air_loss = @exp(-air_loss_base * harmonic * harmonic);
        const body_loss = std.math.clamp((admittance - 0.74) * coupling * 0.11, 0.0, 0.32);
        const high_loss = 1.0 - std.math.clamp((harmonic - 1.0) * 0.0065, 0.0, 0.18);
        const decay_seconds = std.math.clamp((2.36 / @sqrt(harmonic) + 0.09) * safe_decay_scale * highDecay(params, harmonic) * high_loss * (1.0 - body_loss), 0.052, 3.6);
        const phase_jitter = (dsp.rngFloat(rng) - 0.5) * 0.10;
        const body_response = std.math.clamp(admittance * (0.52 + coupling * 0.48) * admittance_scale, 0.08, 3.20);

        freqs[idx] = mode_freq;
        decays[idx] = decayPerSample(decay_seconds);
        phases[idx] = std.math.pi * 0.5 + phase_bias * harmonic + phase_jitter;
        amps[idx] = pluck_gain * harmonic_rolloff * bridge_force_weight * air_loss * velocity * gain;
        body_gains[idx] = body_response;

        if (mode_freq >= dsp.SAMPLE_RATE * 0.48) {
            amps[idx] = 0.0;
            body_gains[idx] = 0.0;
        }
    }
}

fn guitarAdmittanceProcessBank(
    phases: *[STRING_MODE_COUNT]f32,
    freqs: *[STRING_MODE_COUNT]f32,
    amps: *[STRING_MODE_COUNT]f32,
    decays: *[STRING_MODE_COUNT]f32,
    body_gains: *[STRING_MODE_COUNT]f32,
    polarization_gain: f32,
) AdmittanceBankOutput {
    var out: AdmittanceBankOutput = .{};

    for (0..STRING_MODE_COUNT) |idx| {
        if (amps[idx] <= 0.000002) continue;
        if (freqs[idx] >= dsp.SAMPLE_RATE * 0.48) {
            amps[idx] = 0.0;
            continue;
        }

        phases[idx] += freqs[idx] * dsp.INV_SR * dsp.TAU;
        if (phases[idx] > dsp.TAU) phases[idx] -= dsp.TAU;

        const wave = @sin(phases[idx]);
        const slope = @cos(phases[idx]) * std.math.clamp(freqs[idx] * 0.00018, 0.015, 1.12);
        const amp = amps[idx];
        const body_gain = body_gains[idx] * polarization_gain;
        const radiation_weight = bodyRadiationWeight(freqs[idx]);
        const sample = wave * amp;

        out.direct += sample;
        out.bridge_motion += sample * body_gain;
        out.radiated += sample * body_gain * radiation_weight;
        out.edge += slope * amp * body_gain;
        amps[idx] *= decays[idx];
    }

    return out;
}

fn bodyAdmittanceMagnitude(params: GuitarProbeParams, frequency_hz: f32) f32 {
    var total: f32 = 0.0;
    for (0..BODY_MODE_COUNT) |idx| {
        total += bodyModeAdmittanceProximity(params, idx, frequency_hz) * (BODY_MODE_GAINS[idx] / 0.00095);
    }

    const freq_scale = bodyFreq(params, 1.0);
    const air_center = 118.8 * freq_scale;
    const top_center = 204.7 * freq_scale;
    const air_lift = 1.0 / (1.0 + std.math.pow(f32, (frequency_hz - air_center) / (86.0 * freq_scale), 2.0));
    const top_lift = 1.0 / (1.0 + std.math.pow(f32, (frequency_hz - top_center) / (140.0 * freq_scale), 2.0));
    const high_rolloff = 1.0 / (1.0 + std.math.pow(f32, frequency_hz / 6200.0, 1.35));
    const notch = bodyAdmittanceAntiresonance(params, frequency_hz);
    const magnitude = (0.30 + total * 0.32 + air_lift * 0.13 + top_lift * 0.11) * high_rolloff * notch * bodyGain(params, 1.0);
    return std.math.clamp(magnitude, 0.16, 2.95);
}

fn bodyRadiationWeight(frequency_hz: f32) f32 {
    const low_body = 1.0 / (1.0 + std.math.pow(f32, frequency_hz / 420.0, 2.0));
    const lower_top = 1.0 / (1.0 + std.math.pow(f32, (frequency_hz - 205.0) / 180.0, 2.0));
    const mid_body = 1.0 / (1.0 + std.math.pow(f32, (frequency_hz - 704.0) / 560.0, 2.0));
    const high_rolloff = 1.0 / (1.0 + std.math.pow(f32, frequency_hz / 5200.0, 1.6));
    return std.math.clamp((0.72 + low_body * 0.40 + lower_top * 0.18 + mid_body * 0.14) * high_rolloff, 0.60, 1.46);
}

fn bodyModeAdmittanceProximity(params: GuitarProbeParams, mode_index: usize, frequency_hz: f32) f32 {
    const mode_freq = BODY_MODE_FREQS[mode_index] * bodyFreq(params, 1.0);
    const decay = BODY_MODE_DECAYS[mode_index] * bodyDecay(params, 1.0);
    const width = @max(mode_freq * std.math.clamp(0.024 + decay * 0.24, 0.022, 0.082), 1.0);
    const distance = (frequency_hz - mode_freq) / width;
    return 1.0 / (1.0 + distance * distance);
}

fn bodyAdmittanceAntiresonance(params: GuitarProbeParams, frequency_hz: f32) f32 {
    const notch_freqs = [_]f32{ 151.0, 244.0, 394.0, 625.0, 790.0 };
    var notch: f32 = 1.0;
    for (notch_freqs) |base_freq| {
        const notch_freq = base_freq * bodyFreq(params, 1.0);
        const width = @max(notch_freq * 0.075, 1.0);
        const distance = (frequency_hz - notch_freq) / width;
        notch -= 0.055 / (1.0 + distance * distance);
    }
    return std.math.clamp(notch, 0.76, 1.0);
}

fn guitarKsFillDelay(ctx: *GuitarKs, brightness: f32) void {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarKsFillDelay: delay_samples={d} is invalid, leaving buffer silent", .{ctx.delay_samples});
        return;
    }

    const pluck_position = pluckPosition(ctx.params, 0.16);
    const last_idx_f: f32 = @floatFromInt(ctx.delay_samples - 1);
    var dc: f32 = 0.0;

    for (0..ctx.delay_samples) |idx| {
        const t = @as(f32, @floatFromInt(idx)) / last_idx_f;
        const triangle = if (t < pluck_position) t / pluck_position else (1.0 - t) / (1.0 - pluck_position);
        const taper = @sin(std.math.pi * t);
        const noise = dsp.rngFloat(&ctx.rng) * 2.0 - 1.0;
        const bright_noise = noise * (0.040 + brightness * 0.090);
        const displacement = triangle * (0.82 - brightness * 0.18) + bright_noise;
        ctx.buffer[idx] = displacement * taper * ctx.velocity * 0.42;
        dc += ctx.buffer[idx];
    }

    const dc_offset = dc / @as(f32, @floatFromInt(ctx.delay_samples));
    for (0..ctx.delay_samples) |idx| {
        ctx.buffer[idx] -= dc_offset;
    }
}

fn guitarCommutedFillDelay(ctx: *GuitarCommuted) void {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarCommutedFillDelay: delay_samples={d} is invalid, leaving buffer silent", .{ctx.delay_samples});
        return;
    }

    var excitation_body: BodyFilterBank = .{};
    bodyFilterBankConfigureScaled(&excitation_body, bodyFreq(ctx.params, 1.0), bodyGain(ctx.params, 1.75), bodyDecay(ctx.params, 1.0));
    const pluck_position = pluckPosition(ctx.params, 0.16);
    const last_idx_f: f32 = @floatFromInt(ctx.delay_samples - 1);
    var dc: f32 = 0.0;

    for (0..ctx.delay_samples) |idx| {
        const t = @as(f32, @floatFromInt(idx)) / last_idx_f;
        const triangle = if (t < pluck_position) t / pluck_position else (1.0 - t) / (1.0 - pluck_position);
        const taper = @sin(std.math.pi * t);
        const impulse = if (idx < 960) guitarCommutedExcitation(&ctx.rng, idx, ctx.velocity) else 0.0;
        const shaped = bodyFilterBankProcess(&excitation_body, impulse);
        const string_shape = triangle * taper * bridgeCoupling(ctx.params, 0.34);
        ctx.buffer[idx] = (shaped * 1.35 + string_shape) * ctx.velocity;
        dc += ctx.buffer[idx];
    }

    const dc_offset = dc / @as(f32, @floatFromInt(ctx.delay_samples));
    for (0..ctx.delay_samples) |idx| {
        ctx.buffer[idx] -= dc_offset;
    }
}

fn guitarCommutedExcitation(rng: *dsp.Rng, age: usize, velocity: f32) f32 {
    const age_f: f32 = @floatFromInt(age);
    const snap = (@sin(age_f * 0.43) + @sin(age_f * 1.31) * 0.42) * @exp(-age_f * 0.018);
    const brush = (dsp.rngFloat(rng) * 2.0 - 1.0) * @exp(-age_f * 0.0075);
    const release = @exp(-age_f * 0.0028);
    return (snap * 0.48 + brush * 0.52) * release * (0.42 + velocity * 0.58) * 0.12;
}

fn guitarFaustPluckPrimeString(ctx: *GuitarFaustPluck) void {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarFaustPluckPrimeString: delay_samples={d} is invalid, leaving loop silent", .{ctx.delay_samples});
        return;
    }

    const pluck_from_bridge = std.math.clamp(pluckPosition(ctx.params, 0.168), 0.05, 0.45);
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
    const attack_samples = guitarFaustPluckAttackSamples(ctx.frequency_hz, attackDecay(ctx.params));
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
    return lowpass2 * env * attackGain(ctx.params, 0.080) * (0.35 + ctx.velocity * 0.65);
}

fn guitarFaustPluckAttackSamples(frequency_hz: f32, decay_scale: f32) u32 {
    const max_freq = 3000.0;
    const ratio = std.math.clamp(frequency_hz / max_freq, 0.0, 0.96);
    const sharpness = std.math.clamp(decay_scale, 0.35, 2.5);
    const attack_seconds = 0.002 * sharpness * std.math.pow(f32, 1.0 - ratio, 2.0);
    return @max(@as(u32, @intFromFloat(@round(attack_seconds * dsp.SAMPLE_RATE))), 8);
}

fn guitarFaustSteelSmooth(ctx: *GuitarFaustPluck, input: f32) f32 {
    const stiffness = faustSteelSmooth(ctx.params);
    ctx.stiffness_smooth1 = input * (1.0 - stiffness) + ctx.stiffness_smooth1 * stiffness;
    ctx.stiffness_smooth2 = ctx.stiffness_smooth1 * (1.0 - stiffness) + ctx.stiffness_smooth2 * stiffness;
    return ctx.stiffness_smooth2;
}

fn faustBridgeBrightness(params: GuitarProbeParams) f32 {
    const brightness = pluckBrightness(params, FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - FAUST_PROMOTED_HIGH_DECAY;
    const bridge_offset = params.bridge_coupling_scale - FAUST_PROMOTED_BRIDGE_COUPLING;
    return std.math.clamp(0.4 + (brightness - FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 0.42 + high_decay_offset * 0.10 + bridge_offset * 0.04, 0.06, 0.92);
}

fn faustBridgeAbsorption(params: GuitarProbeParams) f32 {
    const high_decay_offset = params.high_decay_scale - FAUST_PROMOTED_HIGH_DECAY;
    const bridge_offset = params.bridge_coupling_scale - FAUST_PROMOTED_BRIDGE_COUPLING;
    const mute_offset = params.mute_amount - FAUST_PROMOTED_MUTE;
    return std.math.clamp(0.5 - high_decay_offset * 0.18 - bridge_offset * 0.10 + mute_offset * 0.24, 0.08, 0.88);
}

fn faustExcitationCutoff(frequency_hz: f32, params: GuitarProbeParams) f32 {
    const brightness = pluckBrightness(params, FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const ratio = 5.0 + (brightness - FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 4.0;
    return std.math.clamp(frequency_hz * ratio, 80.0, 18000.0);
}

fn faustOutputCutoff(params: GuitarProbeParams) f32 {
    const brightness = pluckBrightness(params, FAUST_PROMOTED_PLUCK_BRIGHTNESS);
    const high_decay_offset = params.high_decay_scale - FAUST_PROMOTED_HIGH_DECAY;
    return std.math.clamp(9800.0 + (brightness - FAUST_PROMOTED_PLUCK_BRIGHTNESS) * 3800.0 + high_decay_offset * 2200.0, 5200.0, 14500.0);
}

fn faustStringFeedback(params: GuitarProbeParams) f32 {
    const string_decay_offset = params.string_decay_scale - FAUST_PROMOTED_STRING_DECAY;
    const high_decay_offset = params.high_decay_scale - FAUST_PROMOTED_HIGH_DECAY;
    const previous_feedback = 0.9975 + (params.string_decay_scale - 1.0) * 0.0005 - params.mute_amount * 0.001;
    return std.math.clamp(previous_feedback + string_decay_offset * 0.00085 + high_decay_offset * 0.00022, 0.99, 0.99935);
}

fn faustSteelSmooth(params: GuitarProbeParams) f32 {
    const high_decay_offset = params.high_decay_scale - FAUST_PROMOTED_HIGH_DECAY;
    return std.math.clamp(0.05 - high_decay_offset * 0.014, 0.025, 0.08);
}

fn faustBridgeFilterInit(brightness: f32, absorption: f32) FaustBridgeFilter {
    const safe_absorption = std.math.clamp(absorption, 0.0, 0.98);
    const t60 = @max((1.0 - safe_absorption) * 20.0, 0.01);
    const safe_brightness = std.math.clamp(brightness, 0.0, 1.0);
    return .{
        .h0 = (1.0 + safe_brightness) * 0.5,
        .h1 = (1.0 - safe_brightness) * 0.25,
        .rho = std.math.pow(f32, 0.001, 1.0 / (320.0 * t60)),
    };
}

fn faustBridgeFilterProcess(filter: *FaustBridgeFilter, input: f32) f32 {
    const output = filter.rho * (filter.h0 * filter.x1 + filter.h1 * (input + filter.x2));
    filter.x2 = filter.x1;
    filter.x1 = input;
    return output;
}

fn guitarContactPickSample(ctx: *GuitarContactPickModal) f32 {
    const decay_scale = attackDecay(ctx.params);
    const max_age: u32 = @intFromFloat(@ceil(2200.0 * decay_scale));
    if (ctx.contact_age > max_age) return 0.0;

    const age_f: f32 = @floatFromInt(ctx.contact_age);
    const scrape_env = @exp(-age_f * (0.0042 / decay_scale));
    const snap_env = @exp(-age_f * (0.021 / decay_scale));
    const raw_noise = dsp.rngFloat(&ctx.contact_rng) * 2.0 - 1.0;
    const scrape = dsp.hpfProcess(&ctx.contact_hpf, dsp.lpfProcess(&ctx.contact_lpf, raw_noise)) * scrape_env;
    const snap = (@sin(age_f * 0.87) + @sin(age_f * 1.93) * 0.32) * snap_env;
    return (scrape * 0.82 + snap * 0.18) * ctx.velocity * attackGain(ctx.params, pickNoise(ctx.params, 0.105));
}

fn guitarModalPluckContact(ctx: *GuitarModalPluck) f32 {
    return guitarPluckContactSample(ctx.params, ctx.velocity, ctx.age, &ctx.rng, &ctx.contact_hpf, &ctx.contact_lpf, &ctx.thump_lpf);
}

fn guitarBridgeBodyPluckContact(ctx: *GuitarBridgeBodyPluck) f32 {
    return guitarPluckContactSample(ctx.params, ctx.velocity, ctx.age, &ctx.rng, &ctx.contact_hpf, &ctx.contact_lpf, &ctx.thump_lpf);
}

fn guitarPluckContactSample(params: GuitarProbeParams, velocity: f32, age: u32, rng: *dsp.Rng, contact_hpf: *dsp.HPF, contact_lpf: *dsp.LPF, thump_lpf: *dsp.LPF) f32 {
    const decay_scale = attackDecay(params);
    const max_age: u32 = @intFromFloat(@ceil(3600.0 * decay_scale));
    if (age > max_age) return 0.0;

    const age_f: f32 = @floatFromInt(age);
    const raw_noise = dsp.rngFloat(rng) * 2.0 - 1.0;
    const filtered_noise = dsp.hpfProcess(contact_hpf, dsp.lpfProcess(contact_lpf, raw_noise));
    const scrape_env = @exp(-age_f * (0.0074 / decay_scale));
    const release_env = @exp(-age_f * (0.038 / decay_scale));
    const thump_env = @exp(-age_f * (0.0028 / decay_scale));
    const release = (@sin(age_f * 0.83) + @sin(age_f * 1.71) * 0.34) * release_env;
    const thump_source = dsp.rngFloat(rng) * 2.0 - 1.0;
    const thump = dsp.lpfProcess(thump_lpf, thump_source) * thump_env;
    return (filtered_noise * scrape_env * 0.72 + release * 0.22 + thump * 0.06) * velocity * attackGain(params, pickNoise(params, 0.12));
}

fn guitarSmsFitConfigurePartials(ctx: *GuitarSmsFit) void {
    const pluck_position = pluckPosition(ctx.params, 0.15);
    const brightness = mutedBrightness(ctx.params, pluckBrightness(ctx.params, 0.64));
    for (0..SMS_PARTIAL_COUNT) |idx| {
        const harmonic: f32 = @floatFromInt(idx + 1);
        const ratio = harmonic * stiffnessRatio(ctx.params, harmonic, 0.000038);
        const freq = ctx.frequency_hz * ratio;
        const pluck_gain = @abs(@sin(std.math.pi * harmonic * pluck_position));
        const spectral_rolloff = 1.0 / std.math.pow(f32, harmonic, 1.12 - brightness * 0.75);
        const jitter_gain = 0.88 + dsp.rngFloat(&ctx.rng) * 0.24;
        const decay_seconds = std.math.clamp((1.9 / @sqrt(harmonic) + 0.055) * stringDecay(ctx.params) * highDecay(ctx.params, harmonic), 0.055, 3.4);

        ctx.freqs[idx] = freq;
        ctx.phases[idx] = dsp.rngFloat(&ctx.rng) * dsp.TAU;
        ctx.decays[idx] = decayPerSample(decay_seconds);
        ctx.amps[idx] = pluck_gain * spectral_rolloff * jitter_gain * ctx.velocity * 0.072;

        if (freq >= dsp.SAMPLE_RATE * 0.48) {
            ctx.amps[idx] = 0.0;
        }
    }
}

fn guitarSmsResidualNoise(ctx: *GuitarSmsFit) f32 {
    if (ctx.age > 12000) return 0.0;

    const age_f: f32 = @floatFromInt(ctx.age);
    const attack_env = @exp(-age_f * (0.0065 / attackDecay(ctx.params)));
    const body_env = @exp(-age_f * 0.0009);
    const raw_noise = dsp.rngFloat(&ctx.rng) * 2.0 - 1.0;
    const colored = dsp.hpfProcess(&ctx.noise_hpf, dsp.lpfProcess(&ctx.noise_lpf, raw_noise));
    const dusty = dsp.lpfProcess(&ctx.noise_lpf, dsp.rngFloat(&ctx.rng) * 2.0 - 1.0);
    return (colored * attack_env * 0.08 + dusty * body_env * 0.018) * ctx.velocity * attackGain(ctx.params, pickNoise(ctx.params, 1.0));
}

fn modalScaleString(ctx: *GuitarModal, scale: f32) void {
    for (0..STRING_MODE_COUNT) |idx| {
        ctx.string_amps[idx] *= scale;
    }
}

fn modalRetuneAndDamp(ctx: *GuitarModal, freq_ratio: f32, decay_scale: f32) void {
    const safe_scale = std.math.clamp(decay_scale, 0.05, 4.0);
    for (0..STRING_MODE_COUNT) |idx| {
        ctx.string_freqs[idx] *= freq_ratio;
        const loss = 1.0 - ctx.string_decays[idx];
        ctx.string_decays[idx] = std.math.clamp(1.0 - loss / safe_scale, 0.0, 0.99998);
    }
}

fn bodyFilterBankConfigure(bank: *BodyFilterBank, freq_scale: f32, gain_scale: f32) void {
    bodyFilterBankConfigureScaled(bank, freq_scale, gain_scale, 1.0);
}

fn bodyFilterBankConfigureScaled(bank: *BodyFilterBank, freq_scale: f32, gain_scale: f32, decay_scale: f32) void {
    const safe_decay_scale = std.math.clamp(decay_scale, 0.25, 3.0);
    bank.* = .{};
    for (0..BODY_MODE_COUNT) |idx| {
        bodyModeConfigure(
            &bank.modes[idx],
            BODY_MODE_FREQS[idx] * freq_scale,
            BODY_MODE_DECAYS[idx] * safe_decay_scale,
            BODY_MODE_GAINS[idx] * gain_scale,
        );
    }
}

fn bodyModeConfigure(mode: *BodyMode, frequency_hz: f32, decay_seconds: f32, gain: f32) void {
    const radius = decayPerSample(decay_seconds);
    const omega = frequency_hz * dsp.INV_SR * dsp.TAU;
    mode.* = .{
        .coeff = 2.0 * radius * @cos(omega),
        .radius_sq = radius * radius,
        .gain = gain,
    };
}

fn bodyFilterBankProcess(bank: *BodyFilterBank, input: f32) f32 {
    var out = input * 0.024;
    for (0..BODY_MODE_COUNT) |idx| {
        out += bodyModeProcess(&bank.modes[idx], input);
    }
    return dsp.lpfProcess(&bank.lpf, dsp.hpfProcess(&bank.hpf, out));
}

fn bodyModeProcess(mode: *BodyMode, input: f32) f32 {
    const y = input * mode.gain + mode.coeff * mode.y1 - mode.radius_sq * mode.y2;
    mode.y2 = mode.y1;
    mode.y1 = y;
    return y;
}

fn bridgeForceSample(previous: *f32, current: f32, scale: f32) f32 {
    const force = (current - previous.*) * scale;
    previous.* = current;
    return dsp.softClip(force);
}

fn sanitizedParams(params: GuitarProbeParams) GuitarProbeParams {
    return .{
        .pluck_position = sanitizedOptionalRange("pluck_position", params.pluck_position, 0.05, 0.45),
        .pluck_brightness = sanitizedOptionalRange("pluck_brightness", params.pluck_brightness, 0.0, 1.0),
        .string_mix_scale = sanitizedScale("string_mix_scale", params.string_mix_scale, 0.0, 6.0),
        .body_mix_scale = sanitizedScale("body_mix_scale", params.body_mix_scale, 0.0, 6.0),
        .attack_mix_scale = sanitizedScale("attack_mix_scale", params.attack_mix_scale, 0.0, 8.0),
        .mute_amount = sanitizedScale("mute_amount", params.mute_amount, 0.0, 1.0),
        .string_decay_scale = sanitizedScale("string_decay_scale", params.string_decay_scale, 0.25, 3.0),
        .body_gain_scale = sanitizedScale("body_gain_scale", params.body_gain_scale, 0.0, 4.0),
        .body_decay_scale = sanitizedScale("body_decay_scale", params.body_decay_scale, 0.25, 3.0),
        .body_freq_scale = sanitizedScale("body_freq_scale", params.body_freq_scale, 0.75, 1.35),
        .pick_noise_scale = sanitizedScale("pick_noise_scale", params.pick_noise_scale, 0.0, 4.0),
        .attack_gain_scale = sanitizedScale("attack_gain_scale", params.attack_gain_scale, 0.0, 4.0),
        .attack_decay_scale = sanitizedScale("attack_decay_scale", params.attack_decay_scale, 0.35, 2.5),
        .bridge_coupling_scale = sanitizedScale("bridge_coupling_scale", params.bridge_coupling_scale, 0.0, 4.0),
        .inharmonicity_scale = sanitizedScale("inharmonicity_scale", params.inharmonicity_scale, 0.0, 3.0),
        .high_decay_scale = sanitizedScale("high_decay_scale", params.high_decay_scale, 0.35, 2.5),
        .output_gain_scale = sanitizedScale("output_gain_scale", params.output_gain_scale, 0.0, 8.0),
    };
}

fn sanitizedOptionalRange(label: []const u8, value: ?f32, min_value: f32, max_value: f32) ?f32 {
    const raw_value = value orelse return null;
    if (!std.math.isFinite(raw_value)) {
        std.log.warn("sanitizedOptionalRange: {s} is non-finite, using instrument default", .{label});
        return null;
    }
    return std.math.clamp(raw_value, min_value, max_value);
}

fn sanitizedScale(label: []const u8, value: f32, min_value: f32, max_value: f32) f32 {
    if (!std.math.isFinite(value)) {
        std.log.warn("sanitizedScale: {s} is non-finite, using 1.0", .{label});
        return 1.0;
    }
    return std.math.clamp(value, min_value, max_value);
}

fn pluckPosition(params: GuitarProbeParams, default_value: f32) f32 {
    return params.pluck_position orelse default_value;
}

fn pluckBrightness(params: GuitarProbeParams, default_value: f32) f32 {
    return params.pluck_brightness orelse default_value;
}

fn mutedBrightness(params: GuitarProbeParams, brightness: f32) f32 {
    return std.math.clamp(brightness * (1.0 - params.mute_amount * 0.54), 0.0, 1.0);
}

fn stringMix(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.string_mix_scale;
}

fn bodyMix(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.body_mix_scale;
}

fn attackMix(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.attack_mix_scale;
}

fn stringDecay(params: GuitarProbeParams) f32 {
    return params.string_decay_scale * (1.0 - params.mute_amount * 0.78);
}

fn bodyGain(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.body_gain_scale;
}

fn bodyDecay(params: GuitarProbeParams, base_decay: f32) f32 {
    return base_decay * params.body_decay_scale * (1.0 - params.mute_amount * 0.58);
}

fn bodyFreq(params: GuitarProbeParams, base_freq: f32) f32 {
    return base_freq * params.body_freq_scale;
}

fn pickNoise(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.pick_noise_scale;
}

fn attackGain(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.attack_gain_scale;
}

fn attackDecay(params: GuitarProbeParams) f32 {
    return params.attack_decay_scale;
}

fn bridgeCoupling(params: GuitarProbeParams, base_scale: f32) f32 {
    return base_scale * params.bridge_coupling_scale;
}

fn stiffnessRatio(params: GuitarProbeParams, harmonic: f32, base_coeff: f32) f32 {
    return 1.0 + base_coeff * params.inharmonicity_scale * harmonic * harmonic;
}

fn highDecay(params: GuitarProbeParams, harmonic: f32) f32 {
    const high_mix = std.math.clamp((harmonic - 1.0) / 11.0, 0.0, 1.0);
    const high_decay = 1.0 + (params.high_decay_scale - 1.0) * high_mix;
    return high_decay * (1.0 - params.mute_amount * high_mix * 0.72);
}

fn outputGain(params: GuitarProbeParams, base_gain: f32) f32 {
    return base_gain * params.output_gain_scale;
}

fn guitarPickBurst(rng: *dsp.Rng, hpf: *dsp.HPF, lpf: *dsp.LPF, age: u32, velocity: f32, gain: f32, decay_scale: f32) f32 {
    const max_age: u32 = @intFromFloat(@ceil(2600.0 * decay_scale));
    if (age > max_age) return 0.0;

    const age_f: f32 = @floatFromInt(age);
    const decay = @exp(-age_f * (0.0085 / decay_scale));
    const noise = dsp.hpfProcess(hpf, dsp.lpfProcess(lpf, dsp.rngFloat(rng) * 2.0 - 1.0));
    const pulse = @sin(age_f * 0.39) * @exp(-age_f * (0.018 / decay_scale));
    return (noise * 0.86 + pulse * 0.14) * decay * gain * (0.46 + velocity * 0.54);
}

fn decayPerSample(decay_seconds: f32) f32 {
    return @exp(-1.0 / @max(decay_seconds * dsp.SAMPLE_RATE, 1.0));
}

fn safeGuitarFrequency(frequency_hz: f32) f32 {
    if (!std.math.isFinite(frequency_hz)) {
        std.log.warn("safeGuitarFrequency: non-finite frequency, using 164.814 Hz", .{});
        return 164.814;
    }
    if (frequency_hz < 40.0) {
        std.log.warn("safeGuitarFrequency: frequency={d} below probe range, clamping to 40 Hz", .{frequency_hz});
        return 40.0;
    }
    if (frequency_hz > 1600.0) {
        std.log.warn("safeGuitarFrequency: frequency={d} above probe range, clamping to 1600 Hz", .{frequency_hz});
        return 1600.0;
    }
    return frequency_hz;
}

fn safeVelocity(velocity: f32) f32 {
    if (!std.math.isFinite(velocity)) {
        std.log.warn("safeVelocity: non-finite velocity, using 0.8", .{});
        return 0.8;
    }
    return std.math.clamp(velocity, 0.0, 1.0);
}

fn nextAge(age: u32) u32 {
    if (age == std.math.maxInt(u32)) return age;
    return age + 1;
}
