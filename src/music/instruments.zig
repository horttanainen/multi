const std = @import("std");
const dsp = @import("dsp.zig");

pub fn overdrive(x: f32, gain: f32) f32 {
    const g = x * gain;
    if (g > 0) {
        const t = g * 1.2;
        if (t > 1.0) return 0.85;
        return t * (1.5 - 0.5 * t * t);
    } else {
        const t = g * 0.9;
        if (t < -1.0) return -0.75;
        return t * (1.5 - 0.5 * t * t);
    }
}

pub fn ElectricGuitar(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8) type {
    const GuitarVoice = dsp.Voice(n_unison, n_harmonics);
    const GuitarString = dsp.WaveguideString(4096);

    return struct {
        voices: [n_voices]GuitarVoice = .{GuitarVoice{}} ** n_voices,
        strings: [n_voices]GuitarString = .{GuitarString{}} ** n_voices,
        cab_lpf_l: dsp.LPF = dsp.lpfInit(4500.0),
        cab_lpf_r: dsp.LPF = dsp.lpfInit(4500.0),
        cab_hpf_l: dsp.HPF = dsp.hpfInit(120.0),
        cab_hpf_r: dsp.HPF = dsp.hpfInit(120.0),
        body_lpf_l: dsp.LPF = dsp.lpfInit(2400.0),
        body_lpf_r: dsp.LPF = dsp.lpfInit(2400.0),
        air_hpf_l: dsp.HPF = dsp.hpfInit(2800.0),
        air_hpf_r: dsp.HPF = dsp.hpfInit(2800.0),
        cab_res_a_l: dsp.CombFilter(211) = .{ .feedback = 0.76, .damp = 0.42 },
        cab_res_a_r: dsp.CombFilter(223) = .{ .feedback = 0.75, .damp = 0.44 },
        cab_res_b_l: dsp.CombFilter(137) = .{ .feedback = 0.69, .damp = 0.36 },
        cab_res_b_r: dsp.CombFilter(149) = .{ .feedback = 0.68, .damp = 0.38 },
        mic_delay_l: dsp.DelayLine(64) = .{},
        mic_delay_r: dsp.DelayLine(64) = .{},
        sympathetic_phase: f32 = 0.0,
        body_phase_a: f32 = 0.0,
        body_phase_b: f32 = 0.0,
        pick_age: [n_voices]u32 = .{999999} ** n_voices,
        pick_brightness: [n_voices]f32 = .{0.0} ** n_voices,
        speaker_sag: f32 = 0.0,
        hold_age: [n_voices]u32 = .{999999} ** n_voices,
        hold_samples: [n_voices]u32 = .{0} ** n_voices,
        gain: f32 = 1.0,
        od_amount: f32 = 2.5,
    };
}

pub fn electricGuitarInit(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, pan_spread: f32, unison_spread_val: f32, cab_lpf_hz: f32, cab_hpf_hz: f32) ElectricGuitar(n_voices, n_unison, n_harmonics) {
    var g: ElectricGuitar(n_voices, n_unison, n_harmonics) = .{};
    g.cab_lpf_l = dsp.lpfInit(cab_lpf_hz);
    g.cab_lpf_r = dsp.lpfInit(cab_lpf_hz);
    g.cab_hpf_l = dsp.hpfInit(cab_hpf_hz);
    g.cab_hpf_r = dsp.hpfInit(cab_hpf_hz);
    for (0..n_voices) |i| {
        const t: f32 = if (n_voices > 1)
            (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_voices - 1))) * 2.0 - 1.0
        else
            0;
        g.voices[i].pan = t * pan_spread;
        g.voices[i].unison_spread = unison_spread_val;
        g.voices[i].vibrato_rate_hz = 4.2 + @as(f32, @floatFromInt(i)) * 0.18;
        g.voices[i].vibrato_depth = 0.0014 + @as(f32, @floatFromInt(i)) * 0.0002;
    }
    return g;
}

pub fn electricGuitarSetFreqs(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, ctx: *ElectricGuitar(n_voices, n_unison, n_harmonics), freqs: []const f32) void {
    for (0..@min(n_voices, freqs.len)) |i| {
        ctx.voices[i].freq = freqs[i];
        dsp.waveguideStringSetFreq(4096, &ctx.strings[i], freqs[i] * (1.0 + (@as(f32, @floatFromInt(i)) - 1.0) * 0.0009));
    }
}

pub fn electricGuitarTriggerEnv(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, ctx: *ElectricGuitar(n_voices, n_unison, n_harmonics), attack: f32, decay: f32, sustain: f32, release: f32) void {
    for (0..n_voices) |idx| {
        electricGuitarTriggerVoice(n_voices, n_unison, n_harmonics, ctx, idx, attack, decay, sustain, release, 1.0);
    }
}

pub fn electricGuitarTriggerVoice(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, ctx: *ElectricGuitar(n_voices, n_unison, n_harmonics), voice_idx: usize, attack: f32, decay: f32, sustain: f32, release: f32, pick_strength: f32) void {
    if (voice_idx >= n_voices) {
        std.log.warn("electricGuitarTriggerVoice: voice index {d} out of range", .{voice_idx});
        return;
    }

    ctx.voices[voice_idx].env = dsp.envelopeInit(attack, decay, sustain, release);
    dsp.envelopeTrigger(&ctx.voices[voice_idx].env);
    ctx.pick_age[voice_idx] = 0;
    ctx.hold_age[voice_idx] = 0;
    ctx.hold_samples[voice_idx] = @intFromFloat((0.012 + sustain * 0.22 + decay * 0.08 + pick_strength * 0.01) * dsp.SAMPLE_RATE);
    ctx.pick_brightness[voice_idx] = (0.55 + sustain * 0.35 + (0.02 / @max(attack, 0.002)) * 0.08) * (0.78 + pick_strength * 0.3);
    dsp.waveguideStringPluck(4096, &ctx.strings[voice_idx],
        (0.12 + ctx.pick_brightness[voice_idx] * 0.2 + @as(f32, @floatFromInt(voice_idx)) * 0.012) * (0.82 + pick_strength * 0.26),
        ctx.pick_brightness[voice_idx] * (0.96 - @as(f32, @floatFromInt(voice_idx)) * 0.08),
    );
}

pub fn electricGuitarSetCabinet(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, ctx: *ElectricGuitar(n_voices, n_unison, n_harmonics), lpf_hz: f32, hpf_hz: f32) void {
    ctx.cab_lpf_l = dsp.lpfInit(lpf_hz);
    ctx.cab_lpf_r = dsp.lpfInit(lpf_hz);
    ctx.cab_hpf_l = dsp.hpfInit(hpf_hz);
    ctx.cab_hpf_r = dsp.hpfInit(hpf_hz);
    ctx.body_lpf_l = dsp.lpfInit(@max(1400.0, lpf_hz * 0.48));
    ctx.body_lpf_r = dsp.lpfInit(@max(1400.0, lpf_hz * 0.48));
    ctx.air_hpf_l = dsp.hpfInit(@max(2200.0, lpf_hz * 0.55));
    ctx.air_hpf_r = dsp.hpfInit(@max(2200.0, lpf_hz * 0.55));
    ctx.cab_res_a_l = .{ .feedback = 0.73 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.07), .damp = 0.42 };
    ctx.cab_res_a_r = .{ .feedback = 0.72 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.07), .damp = 0.44 };
    ctx.cab_res_b_l = .{ .feedback = 0.66 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.05), .damp = 0.36 };
    ctx.cab_res_b_r = .{ .feedback = 0.65 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.05), .damp = 0.38 };
}

pub fn electricGuitarProcess(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8, ctx: *ElectricGuitar(n_voices, n_unison, n_harmonics), extra_drive: f32) [2]f32 {
    var left: f32 = 0.0;
    var right: f32 = 0.0;
    var total_env: f32 = 0.0;

    for (0..n_voices) |idx| {
        if (ctx.hold_age[idx] < ctx.hold_samples[idx]) {
            ctx.hold_age[idx] += 1;
        } else if (ctx.voices[idx].env.state == .sustain) {
            dsp.envelopeNoteOff(&ctx.voices[idx].env);
        }

        const raw = dsp.voiceProcessRaw(n_unison, n_harmonics, &ctx.voices[idx]);
        if (raw.env_val <= 0.0001) continue;
        total_env += raw.env_val;

        const string_core = dsp.waveguideStringProcess(4096, &ctx.strings[idx]);
        const string_body = dsp.delayLineTap(4096, &ctx.strings[idx].line, @max(1, ctx.strings[idx].delay_samples / 3));
        var wave = raw.osc * ctx.gain * 0.52;
        wave += string_core * (0.62 + extra_drive * 0.08);
        wave += string_body * 0.18;
        wave += @sin(ctx.voices[idx].phases[0] * 2.01) * 0.12 * raw.env_val;
        wave += @sin(ctx.voices[idx].phases[0] * 3.97) * 0.045 * raw.env_val;
        wave = overdrive(wave, ctx.od_amount + extra_drive);
        wave *= raw.env_val;

        const stereo = dsp.panStereo(wave, ctx.voices[idx].pan);
        left += stereo[0];
        right += stereo[1];

        if (ctx.pick_age[idx] < 4096) {
            const age: f32 = @floatFromInt(ctx.pick_age[idx]);
            const decay = @exp(-age * 0.0045);
            const pick = (@sin(ctx.voices[idx].phases[0] * 11.0) + @sin(ctx.voices[idx].phases[0] * 17.0) * 0.65) * decay * ctx.pick_brightness[idx];
            const pick_pan = ctx.voices[idx].pan * 0.8;
            const pick_stereo = dsp.panStereo(pick, pick_pan);
            left += dsp.hpfProcess(&ctx.air_hpf_l, pick_stereo[0] * 0.16);
            right += dsp.hpfProcess(&ctx.air_hpf_r, pick_stereo[1] * 0.16);
            ctx.pick_age[idx] += 1;
        }
    }

    if (total_env <= 0.0001) return .{ 0.0, 0.0 };

    if (ctx.voices[0].freq > 0.0) {
        ctx.sympathetic_phase += ctx.voices[0].freq * 0.5 * dsp.INV_SR * dsp.TAU;
        if (ctx.sympathetic_phase > dsp.TAU) ctx.sympathetic_phase -= dsp.TAU;
        ctx.body_phase_a += ctx.voices[0].freq * 1.01 * dsp.INV_SR * dsp.TAU;
        if (ctx.body_phase_a > dsp.TAU) ctx.body_phase_a -= dsp.TAU;
        ctx.body_phase_b += ctx.voices[0].freq * 2.03 * dsp.INV_SR * dsp.TAU;
        if (ctx.body_phase_b > dsp.TAU) ctx.body_phase_b -= dsp.TAU;
        const body_env = @min(total_env / @as(f32, @floatFromInt(n_voices)), 1.0);
        const body = (@sin(ctx.sympathetic_phase) * 0.7 + @sin(ctx.body_phase_a) * 0.22 + @sin(ctx.body_phase_b) * 0.12) * body_env * (0.1 + extra_drive * 0.05);
        left += dsp.lpfProcess(&ctx.body_lpf_l, body * 1.04);
        right += dsp.lpfProcess(&ctx.body_lpf_r, body * 0.96);
    }

    const amp_input = (left + right) * 0.5;
    ctx.speaker_sag += (@abs(amp_input) - ctx.speaker_sag) * 0.0035;
    const sag_amount = std.math.clamp(ctx.speaker_sag * 0.32, 0.0, 0.24);
    const amp_gain = 1.08 + extra_drive * 0.28 - sag_amount;
    left = overdrive(left, amp_gain);
    right = overdrive(right, amp_gain * 0.98);

    const cab_a_l = dsp.combFilterProcess(211, &ctx.cab_res_a_l, left * 0.32);
    const cab_a_r = dsp.combFilterProcess(223, &ctx.cab_res_a_r, right * 0.31);
    const cab_b_l = dsp.combFilterProcess(137, &ctx.cab_res_b_l, left * 0.21);
    const cab_b_r = dsp.combFilterProcess(149, &ctx.cab_res_b_r, right * 0.2);
    left += cab_a_l * 0.58 + cab_b_l * 0.34;
    right += cab_a_r * 0.56 + cab_b_r * 0.36;

    const mic_l = dsp.delayLineProcess(64, &ctx.mic_delay_l, left + cab_a_l * 0.22, 7);
    const mic_r = dsp.delayLineProcess(64, &ctx.mic_delay_r, right + cab_a_r * 0.2, 11);
    left = left * 0.82 + mic_l * 0.18;
    right = right * 0.8 + mic_r * 0.2;

    left = dsp.hpfProcess(&ctx.cab_hpf_l, left);
    left = dsp.lpfProcess(&ctx.cab_lpf_l, left);
    right = dsp.hpfProcess(&ctx.cab_hpf_r, right);
    right = dsp.lpfProcess(&ctx.cab_lpf_r, right);

    return .{ left, right };
}

pub const SawBass = struct {
    string: dsp.WaveguideString(4096) = .{},
    phase: f32 = 0,
    sub_phase: f32 = 0,
    overtone_phase: f32 = 0,
    freq: f32 = dsp.midiToFreq(40),
    env: dsp.Envelope = dsp.envelopeInit(0.002, 0.18, 0.0, 0.08),
    filter: dsp.LPF = dsp.lpfInit(800.0),
    drive: f32 = 0.55,
    sub_mix: f32 = 0.4,
    volume: f32 = 0.55,
    pluck_age: u32 = 999999,
};

pub fn sawBassTrigger(ctx: *SawBass, freq: f32) void {
    ctx.freq = freq;
    dsp.envelopeTrigger(&ctx.env);
    ctx.pluck_age = 0;
    dsp.waveguideStringSetFreq(4096, &ctx.string, freq);
    dsp.waveguideStringPluck(4096, &ctx.string, 0.22, 0.28 + ctx.drive * 0.22);
}

pub fn sawBassSetFilter(ctx: *SawBass, cutoff: f32) void {
    ctx.filter = dsp.lpfInit(cutoff);
}

pub fn sawBassProcess(ctx: *SawBass) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.phase += ctx.freq * dsp.INV_SR * dsp.TAU;
    if (ctx.phase > dsp.TAU) ctx.phase -= dsp.TAU;
    ctx.sub_phase += ctx.freq * 0.5 * dsp.INV_SR * dsp.TAU;
    if (ctx.sub_phase > dsp.TAU) ctx.sub_phase -= dsp.TAU;
    ctx.overtone_phase += ctx.freq * 1.997 * dsp.INV_SR * dsp.TAU;
    if (ctx.overtone_phase > dsp.TAU) ctx.overtone_phase -= dsp.TAU;

    const saw = ctx.phase / std.math.pi - 1.0;
    const sub = @sin(ctx.sub_phase);
    const overtone = @sin(ctx.overtone_phase) * (0.14 + ctx.drive * 0.08);
    var sample = saw * (0.34 + ctx.drive * 0.2) + sub * ctx.sub_mix + overtone;
    sample += dsp.waveguideStringProcess(4096, &ctx.string) * (0.62 + ctx.drive * 0.14);
    if (ctx.pluck_age < 2400) {
        const age: f32 = @floatFromInt(ctx.pluck_age);
        const pluck = (@sin(ctx.phase * 7.0) + @sin(ctx.phase * 13.0) * 0.4) * @exp(-age * 0.006);
        sample += pluck * 0.12;
        ctx.pluck_age += 1;
    }
    sample = overdrive(sample, 1.05 + ctx.drive * 0.9);
    sample = dsp.lpfProcess(&ctx.filter, sample);
    sample *= 1.0 + ctx.drive * 0.45;
    return sample * env_val * ctx.volume;
}

pub const Kick = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.16, 0.0, 0.1),
    base_freq: f32 = 44.0,
    sweep: f32 = 90.0,
    decay_rate: f32 = 0.993,
    volume: f32 = 1.5,
    click_age: u32 = 999999,
    click_level: f32 = 0.0,
    body_drive: f32 = 1.15,
    click_phase: f32 = 0.0,
};

pub fn kickTrigger(ctx: *Kick, accent: f32) void {
    dsp.envelopeTrigger(&ctx.env);
    ctx.pitch_env = accent;
    ctx.click_age = 0;
    ctx.click_level = 0.08 + accent * 0.14;
    ctx.click_phase = 0.0;
    kickConfigureResonators(ctx, accent);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.95, 0.42, 0.18 }, 0.8 + accent * 0.4);
}

pub fn kickProcess(ctx: *Kick) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    ctx.pitch_env *= ctx.decay_rate;
    const drift = ctx.pitch_env * ctx.sweep;
    ctx.resonators.freqs[0] = ctx.base_freq + drift;
    ctx.resonators.freqs[1] = (ctx.base_freq + drift * 0.65) * 1.92;
    ctx.resonators.freqs[2] = (ctx.base_freq + drift * 0.35) * 3.08;

    var click: f32 = 0.0;
    if (ctx.click_age < 1400) {
        ctx.click_phase += (ctx.base_freq + drift * 1.6) * dsp.INV_SR * dsp.TAU;
        if (ctx.click_phase > dsp.TAU) ctx.click_phase -= dsp.TAU;
        click = dsp.exciterPulseBurst(ctx.click_phase, ctx.click_age, 0.01, ctx.click_level);
        ctx.click_age += 1;
    }

    var body = dsp.resonatorBankProcess(3, &ctx.resonators);
    body = overdrive(body, ctx.body_drive + ctx.pitch_env * 0.35);
    return (body + click) * env_val * ctx.volume;
}

fn kickConfigureResonators(ctx: *Kick, accent: f32) void {
    dsp.resonatorBankConfigure(3, &ctx.resonators,
        .{
            ctx.base_freq + accent * ctx.sweep,
            (ctx.base_freq + accent * ctx.sweep * 0.65) * 1.92,
            (ctx.base_freq + accent * ctx.sweep * 0.35) * 3.08,
        },
        .{ 0.99965, 0.9992, 0.9988 },
    );
}

pub const Snare = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    env: dsp.Envelope = dsp.envelopeInit(0.001, 0.12, 0.0, 0.06),
    noise_lpf: dsp.LPF = dsp.lpfInit(3400.0),
    noise_hpf: dsp.HPF = dsp.hpfInit(1200.0),
    tone_freq: f32 = 190.0,
    noise_mix: f32 = 0.78,
    body_mix: f32 = 0.35,
    snap_mix: f32 = 0.14,
    strike_age: u32 = 999999,
};

pub fn snareTrigger(ctx: *Snare) void {
    ctx.noise_hpf = dsp.hpfInit(1400.0);
    snareConfigureResonators(ctx, false);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.55, 0.22, 0.12 }, 1.0);
    ctx.strike_age = 0;
    dsp.envelopeTrigger(&ctx.env);
}

pub fn snareTriggerGhost(ctx: *Snare) void {
    ctx.env = dsp.envelopeInit(0.001, 0.06, 0.0, 0.03);
    ctx.noise_hpf = dsp.hpfInit(1800.0);
    snareConfigureResonators(ctx, true);
    dsp.resonatorBankExcite(3, &ctx.resonators, .{ 0.28, 0.12, 0.06 }, 0.7);
    ctx.strike_age = 0;
    dsp.envelopeTrigger(&ctx.env);
}

pub fn snareProcess(ctx: *Snare, rng_inst: *dsp.Rng) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (env_val <= 0.0001) return 0.0;

    const noise = dsp.hpfProcess(&ctx.noise_hpf, dsp.lpfProcess(&ctx.noise_lpf, dsp.rngFloat(rng_inst) * 2.0 - 1.0));
    const tone = dsp.resonatorBankProcess(3, &ctx.resonators);
    var strike_noise: f32 = 0.0;
    if (ctx.strike_age < 2200) {
        strike_noise = dsp.exciterNoiseBurst(rng_inst, &ctx.noise_hpf, &ctx.noise_lpf, ctx.strike_age, 0.0065, 0.24);
        ctx.strike_age += 1;
    }
    const snap = (strike_noise * 0.7 + noise * 0.3) * ctx.snap_mix;
    return (noise * ctx.noise_mix + tone * ctx.body_mix + snap) * env_val;
}

fn snareConfigureResonators(ctx: *Snare, ghost: bool) void {
    dsp.resonatorBankConfigure(3, &ctx.resonators,
        .{
            ctx.tone_freq,
            ctx.tone_freq * 1.84,
            ctx.tone_freq * 2.67,
        },
        if (ghost)
            .{ 0.9982, 0.9978, 0.9972 }
        else
            .{ 0.99915, 0.99875, 0.9981 },
    );
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

pub const PianoVoice = struct {
    strings: [3]dsp.WaveguideString(4096) = .{ dsp.WaveguideString(4096){}, dsp.WaveguideString(4096){}, dsp.WaveguideString(4096){} },
    carrier_phase: f32 = 0.0,
    detune_phase: f32 = 0.0,
    mod_phase: f32 = 0.0,
    flutter_phase: f32 = 0.0,
    resonance_phase_a: f32 = 0.0,
    resonance_phase_b: f32 = 0.0,
    freq: f32 = dsp.midiToFreq(60),
    detune_ratio: f32 = 1.001,
    mod_ratio: f32 = 3.0,
    mod_depth: f32 = 0.5,
    velocity: f32 = 1.0,
    pan: f32 = 0.0,
    env: dsp.Envelope = dsp.envelopeInit(0.01, 1.8, 0.0, 1.5),
    filter: dsp.LPF = dsp.lpfInit(2400.0),
    resonance_filter: dsp.LPF = dsp.lpfInit(1800.0),
    hammer_age: u32 = 999999,
    active: bool = false,
    unison_mix: f32 = 0.42,
    sub_mix: f32 = 0.12,
    bell_mix: f32 = 0.12,
    resonance_mix: f32 = 0.16,
};

pub fn pianoVoiceInit(pan: f32, flutter_phase: f32) PianoVoice {
    return .{
        .pan = pan,
        .flutter_phase = flutter_phase,
    };
}

pub fn pianoVoiceTrigger(ctx: *PianoVoice, freq: f32, velocity: f32, cutoff_hz: f32, env: dsp.Envelope) void {
    ctx.freq = freq;
    ctx.velocity = velocity;
    ctx.filter = dsp.lpfInit(cutoff_hz);
    ctx.resonance_filter = dsp.lpfInit(cutoff_hz * 0.72);
    ctx.env = env;
    dsp.envelopeTrigger(&ctx.env);
    ctx.hammer_age = 0;
    ctx.active = true;
    dsp.waveguideStringSetFreq(4096, &ctx.strings[0], freq);
    dsp.waveguideStringSetFreq(4096, &ctx.strings[1], freq * 1.0009);
    dsp.waveguideStringSetFreq(4096, &ctx.strings[2], freq * 0.9991);
    dsp.waveguideStringPluck(4096, &ctx.strings[0], 0.18 + velocity * 0.22, 0.38);
    dsp.waveguideStringPluck(4096, &ctx.strings[1], 0.16 + velocity * 0.2, 0.34);
    dsp.waveguideStringPluck(4096, &ctx.strings[2], 0.15 + velocity * 0.18, 0.3);
}

pub fn pianoVoiceProcess(ctx: *PianoVoice, rng_inst: *dsp.Rng, wow_amount: f32, bell_tone: f32, attack_softness: f32, hammer_level: f32) f32 {
    const env_val = dsp.envelopeProcess(&ctx.env);
    if (!ctx.active and env_val < 0.001) return 0.0;
    if (env_val < 0.001) ctx.active = false;

    ctx.flutter_phase += 0.00004 * dsp.TAU;
    if (ctx.flutter_phase > dsp.TAU) ctx.flutter_phase -= dsp.TAU;

    const flutter = @sin(ctx.flutter_phase) * (0.0002 + wow_amount * 0.0022);
    const carrier_freq = ctx.freq * (1.0 + flutter);
    const mod_freq = carrier_freq * ctx.mod_ratio;
    ctx.mod_phase += mod_freq * dsp.INV_SR * dsp.TAU;
    if (ctx.mod_phase > dsp.TAU) ctx.mod_phase -= dsp.TAU;

    const fm_amount = 0.12 + bell_tone * 0.95;
    const mod_signal = @sin(ctx.mod_phase) * ctx.mod_depth * env_val * fm_amount;

    ctx.carrier_phase += carrier_freq * dsp.INV_SR * dsp.TAU;
    if (ctx.carrier_phase > dsp.TAU) ctx.carrier_phase -= dsp.TAU;

    ctx.detune_phase += carrier_freq * ctx.detune_ratio * dsp.INV_SR * dsp.TAU;
    if (ctx.detune_phase > dsp.TAU) ctx.detune_phase -= dsp.TAU;
    ctx.resonance_phase_a += carrier_freq * 2.01 * dsp.INV_SR * dsp.TAU;
    if (ctx.resonance_phase_a > dsp.TAU) ctx.resonance_phase_a -= dsp.TAU;
    ctx.resonance_phase_b += carrier_freq * 2.99 * dsp.INV_SR * dsp.TAU;
    if (ctx.resonance_phase_b > dsp.TAU) ctx.resonance_phase_b -= dsp.TAU;

    var body = @sin(ctx.carrier_phase + mod_signal);
    body += @sin(ctx.detune_phase + mod_signal * 0.6) * ctx.unison_mix;
    body += @sin(ctx.carrier_phase * 0.5) * ctx.sub_mix;
    body += @sin(ctx.carrier_phase * 2.0 + mod_signal * 0.3) * (0.018 + bell_tone * ctx.bell_mix);
    body += (dsp.waveguideStringProcess(4096, &ctx.strings[0]) + dsp.waveguideStringProcess(4096, &ctx.strings[1]) * 0.92 + dsp.waveguideStringProcess(4096, &ctx.strings[2]) * 0.88) * 0.42;
    body = dsp.lpfProcess(&ctx.filter, body);

    var resonance = @sin(ctx.resonance_phase_a) * 0.12 + @sin(ctx.resonance_phase_b) * 0.08;
    resonance += @sin(ctx.carrier_phase * 4.07) * 0.04;
    resonance = dsp.lpfProcess(&ctx.resonance_filter, resonance) * (0.4 + env_val * 0.6);

    var hammer: f32 = 0.0;
    if (ctx.hammer_age < 4096) {
        const age: f32 = @floatFromInt(ctx.hammer_age);
        const decay = @exp(-age * (0.0038 + attack_softness * 0.0024));
        const felt = dsp.lpfProcess(&ctx.filter, (dsp.rngFloat(rng_inst) * 2.0 - 1.0) * 0.18 + @sin(ctx.carrier_phase * 5.0) * 0.25);
        hammer = (felt * 1.8 + @sin(ctx.carrier_phase * 9.0) * 0.12) * decay;
        ctx.hammer_age += 1;
    }

    return (body + resonance * ctx.resonance_mix + hammer * hammer_level) * env_val * ctx.velocity;
}
