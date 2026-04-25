const std = @import("std");
const dsp = @import("dsp.zig");

const STRING_MODE_COUNT = 28;
const KS_BUFFER_SIZE = 8192;
const WAVEGUIDE_BUFFER_SIZE = 8192;

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

pub const GuitarModal = struct {
    string_phases: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_freqs: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_amps: [STRING_MODE_COUNT]f32 = [_]f32{0.0} ** STRING_MODE_COUNT,
    string_decays: [STRING_MODE_COUNT]f32 = [_]f32{0.999} ** STRING_MODE_COUNT,
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
    velocity: f32 = 0.8,
};

pub fn guitarModalTrigger(ctx: *GuitarModal, frequency_hz: f32, velocity: f32) void {
    ctx.* = .{};
    ctx.rng = dsp.rngInit(0xA78F_23C1);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);
    bodyFilterBankConfigure(&ctx.body, 1.0, 1.0);
    guitarModalConfigureString(ctx);
    ctx.age = 0;
}

pub fn guitarModalProcess(ctx: *GuitarModal) f32 {
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

    const pick = guitarPickBurst(&ctx.rng, &ctx.pick_hpf, &ctx.pick_lpf, ctx.age, ctx.velocity, 0.072);
    const body = bodyFilterBankProcess(&ctx.body, string_sample * 0.31 + pick * 0.72);
    const mixed = body * 0.84 + string_sample * 0.13 + pick * 0.045;
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * 0.86);
}

pub fn guitarKsTrigger(ctx: *GuitarKs, frequency_hz: f32, velocity: f32) void {
    ctx.* = .{};
    ctx.rng = dsp.rngInit(0x51D2_BE13);
    ctx.frequency_hz = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);

    const delay_f = std.math.clamp(dsp.SAMPLE_RATE / ctx.frequency_hz, 6.0, @as(f32, @floatFromInt(KS_BUFFER_SIZE - 2)));
    const delay_floor = @floor(delay_f);
    ctx.delay_samples = @intFromFloat(delay_floor);
    ctx.frac = delay_f - delay_floor;

    const brightness = 0.44 + ctx.velocity * 0.42;
    ctx.loop_filter_coeff = 0.50 + brightness * 0.30;
    ctx.feedback = std.math.clamp(0.9905 + ctx.velocity * 0.0048 - ctx.frequency_hz * 0.0000016, 0.984, 0.997);

    bodyFilterBankConfigure(&ctx.body, 1.0, 0.9);
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
    const averaged = (current + next) * 0.5;

    ctx.loop_filter += (averaged - ctx.loop_filter) * ctx.loop_filter_coeff;
    ctx.buffer[read_idx] = dsp.softClip(ctx.loop_filter * ctx.feedback);
    ctx.write_pos = next_idx;

    const pick = guitarPickBurst(&ctx.rng, &ctx.pick_hpf, &ctx.pick_lpf, ctx.age, ctx.velocity, 0.056);
    const body = bodyFilterBankProcess(&ctx.body, string_sample * 0.36 + pick * 0.58);
    const mixed = body * 0.78 + string_sample * 0.20 + pick * 0.045;
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, mixed));
    ctx.age = nextAge(ctx.age);
    return dsp.softClip(filtered * 0.9);
}

pub fn guitarWaveguideRawTrigger(ctx: *GuitarWaveguideRaw, frequency_hz: f32, velocity: f32) void {
    ctx.* = .{};
    const safe_freq = safeGuitarFrequency(frequency_hz);
    ctx.velocity = safeVelocity(velocity);
    dsp.waveguideStringSetFreq(WAVEGUIDE_BUFFER_SIZE, &ctx.string, safe_freq);
    dsp.waveguideStringPluck(WAVEGUIDE_BUFFER_SIZE, &ctx.string, ctx.velocity * 0.64, 0.68);
}

pub fn guitarWaveguideRawProcess(ctx: *GuitarWaveguideRaw) f32 {
    const raw = dsp.waveguideStringProcess(WAVEGUIDE_BUFFER_SIZE, &ctx.string);
    const filtered = dsp.lpfProcess(&ctx.out_lpf, dsp.hpfProcess(&ctx.out_hpf, raw * 0.42));
    return dsp.softClip(filtered);
}

fn guitarModalConfigureString(ctx: *GuitarModal) void {
    const pluck_position = 0.18;
    const brightness = 0.52 + ctx.velocity * 0.36;

    for (0..STRING_MODE_COUNT) |idx| {
        const harmonic: f32 = @floatFromInt(idx + 1);
        const stiffness = 1.0 + 0.000045 * harmonic * harmonic;
        const mode_freq = ctx.frequency_hz * harmonic * stiffness;
        const pluck_gain = @abs(@sin(std.math.pi * harmonic * pluck_position));
        const harmonic_rolloff = 1.0 / std.math.pow(f32, harmonic, 0.72 + (1.0 - brightness) * 0.38);
        const air_loss = @exp(-0.0018 * harmonic * harmonic);
        const decay_seconds = std.math.clamp(2.7 / @sqrt(harmonic) + 0.14, 0.11, 2.9);

        ctx.string_freqs[idx] = mode_freq;
        ctx.string_decays[idx] = decayPerSample(decay_seconds);
        ctx.string_phases[idx] = dsp.rngFloat(&ctx.rng) * dsp.TAU;
        ctx.string_amps[idx] = pluck_gain * harmonic_rolloff * air_loss * ctx.velocity * 0.108;

        if (mode_freq >= dsp.SAMPLE_RATE * 0.48) {
            ctx.string_amps[idx] = 0.0;
        }
    }
}

fn guitarKsFillDelay(ctx: *GuitarKs, brightness: f32) void {
    if (ctx.delay_samples < 2) {
        std.log.warn("guitarKsFillDelay: delay_samples={d} is invalid, leaving buffer silent", .{ctx.delay_samples});
        return;
    }

    const pluck_position = 0.19;
    const last_idx_f: f32 = @floatFromInt(ctx.delay_samples - 1);

    for (0..ctx.delay_samples) |idx| {
        const t = @as(f32, @floatFromInt(idx)) / last_idx_f;
        const triangle = if (t < pluck_position) t / pluck_position else (1.0 - t) / (1.0 - pluck_position);
        const taper = @sin(std.math.pi * t);
        const noise = dsp.rngFloat(&ctx.rng) * 2.0 - 1.0;
        const bright_noise = noise * (0.20 + brightness * 0.36);
        const displacement = triangle * (0.76 - brightness * 0.28) + bright_noise;
        ctx.buffer[idx] = displacement * taper * ctx.velocity * 0.54;
    }
}

fn bodyFilterBankConfigure(bank: *BodyFilterBank, freq_scale: f32, gain_scale: f32) void {
    bank.* = .{};
    for (0..BODY_MODE_COUNT) |idx| {
        bodyModeConfigure(
            &bank.modes[idx],
            BODY_MODE_FREQS[idx] * freq_scale,
            BODY_MODE_DECAYS[idx],
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

fn guitarPickBurst(rng: *dsp.Rng, hpf: *dsp.HPF, lpf: *dsp.LPF, age: u32, velocity: f32, gain: f32) f32 {
    if (age > 2600) return 0.0;

    const age_f: f32 = @floatFromInt(age);
    const decay = @exp(-age_f * 0.0085);
    const noise = dsp.hpfProcess(hpf, dsp.lpfProcess(lpf, dsp.rngFloat(rng) * 2.0 - 1.0));
    const pulse = @sin(age_f * 0.39) * @exp(-age_f * 0.018);
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
