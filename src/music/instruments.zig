const dsp = @import("dsp.zig");

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
        .bass => dsp.resonatorBankConfigure(3, &ctx.resonators,
            .{ ctx.base_freq * 0.19, ctx.base_freq * 0.31, ctx.base_freq * 0.46 },
            .{ 0.99945, 0.9991, 0.9988 },
        ),
        .tone => dsp.resonatorBankConfigure(3, &ctx.resonators,
            .{ ctx.base_freq, ctx.base_freq * 1.51, ctx.base_freq * 2.18 },
            .{ 0.9991, 0.9986, 0.9982 },
        ),
        .slap => dsp.resonatorBankConfigure(3, &ctx.resonators,
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
    dsp.resonatorBankConfigure(4, &ctx.resonators,
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
