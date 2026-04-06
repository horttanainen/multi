const std = @import("std");

pub const SAMPLE_RATE: f32 = 48000.0;
pub const INV_SR: f32 = 1.0 / SAMPLE_RATE;
pub const TAU = std.math.tau;

pub const pentatonic_scale = [_]u8{
    36, 39, 41, 43, 46,
    48, 51, 53, 55, 58,
    60, 63, 65, 67, 70,
    72, 75, 77, 79, 82,
};

pub fn midiToFreq(note: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

pub const EnvState = enum { idle, attack, decay, sustain, release };

pub const Envelope = struct {
    state: EnvState = .idle,
    level: f32 = 0,
    attack_rate: f32,
    decay_rate: f32,
    sustain_level: f32,
    release_rate: f32,
};

pub fn envelopeInit(attack_s: f32, decay_s: f32, sustain: f32, release_s: f32) Envelope {
    return .{
        .attack_rate = 1.0 / @max(attack_s * SAMPLE_RATE, 1.0),
        .decay_rate = (1.0 - sustain) / @max(decay_s * SAMPLE_RATE, 1.0),
        .sustain_level = sustain,
        .release_rate = sustain / @max(release_s * SAMPLE_RATE, 1.0),
    };
}

pub fn envelopeTrigger(env: *Envelope) void {
    env.state = .attack;
}

pub fn envelopeRetrigger(env: *Envelope, attack_s: f32, decay_s: f32, sustain: f32, release_s: f32) void {
    env.attack_rate = 1.0 / @max(attack_s * SAMPLE_RATE, 1.0);
    env.decay_rate = (1.0 - sustain) / @max(decay_s * SAMPLE_RATE, 1.0);
    env.sustain_level = sustain;
    env.release_rate = sustain / @max(release_s * SAMPLE_RATE, 1.0);
    env.state = .attack;
}

pub fn envelopeNoteOff(env: *Envelope) void {
    if (env.state != .idle) env.state = .release;
}

pub fn envelopeProcess(env: *Envelope) f32 {
    switch (env.state) {
        .idle => return 0,
        .attack => {
            env.level += env.attack_rate;
            if (env.level >= 1.0) {
                env.level = 1.0;
                env.state = .decay;
            }
        },
        .decay => {
            env.level -= env.decay_rate;
            if (env.level <= env.sustain_level) {
                env.level = env.sustain_level;
                env.state = .sustain;
            }
        },
        .sustain => {},
        .release => {
            env.level -= env.release_rate;
            if (env.level <= 0) {
                env.level = 0;
                env.state = .idle;
            }
        },
    }
    return env.level;
}

pub const LPF = struct {
    prev: f32 = 0,
    alpha: f32,
};

pub fn lpfInit(cutoff_hz: f32) LPF {
    const rc = 1.0 / (TAU * cutoff_hz);
    return .{ .alpha = INV_SR / (rc + INV_SR) };
}

pub fn lpfProcess(filter: *LPF, input: f32) f32 {
    filter.prev += filter.alpha * (input - filter.prev);
    return filter.prev;
}

pub const HPF = struct {
    prev_in: f32 = 0,
    prev_out: f32 = 0,
    alpha: f32,
};

pub fn hpfInit(cutoff_hz: f32) HPF {
    const rc = 1.0 / (TAU * cutoff_hz);
    return .{ .alpha = rc / (rc + INV_SR) };
}

pub fn hpfProcess(filter: *HPF, input: f32) f32 {
    filter.prev_out = filter.alpha * (filter.prev_out + input - filter.prev_in);
    filter.prev_in = input;
    return filter.prev_out;
}

pub fn DelayLine(comptime size: usize) type {
    comptime {
        if (size == 0) @compileError("DelayLine size must be > 0");
    }

    return struct {
        buf: [size]f32 = [_]f32{0} ** size,
        pos: usize = 0,
    };
}

pub fn delayLineReset(comptime size: usize, line: *DelayLine(size)) void {
    line.* = .{};
}

pub fn delayLinePush(comptime size: usize, line: *DelayLine(size), sample: f32) void {
    line.buf[line.pos] = sample;
    line.pos = (line.pos + 1) % size;
}

pub fn delayLineTap(comptime size: usize, line: *const DelayLine(size), delay: usize) f32 {
    const clamped_delay = @min(delay, size - 1);
    const read_pos = (line.pos + size - 1 - clamped_delay) % size;
    return line.buf[read_pos];
}

pub fn delayLineProcess(comptime size: usize, line: *DelayLine(size), sample: f32, delay: usize) f32 {
    const tapped = delayLineTap(size, line, delay);
    delayLinePush(size, line, sample);
    return tapped;
}

pub fn ResonatorBank(comptime n_modes: usize) type {
    comptime {
        if (n_modes == 0) @compileError("ResonatorBank mode count must be > 0");
    }

    return struct {
        phases: [n_modes]f32 = .{0.0} ** n_modes,
        freqs: [n_modes]f32 = .{0.0} ** n_modes,
        amps: [n_modes]f32 = .{0.0} ** n_modes,
        decays: [n_modes]f32 = .{0.999} ** n_modes,
    };
}

pub fn resonatorBankReset(comptime n_modes: usize, bank: *ResonatorBank(n_modes)) void {
    bank.* = .{};
}

pub fn resonatorBankConfigure(comptime n_modes: usize, bank: *ResonatorBank(n_modes), freqs: [n_modes]f32, decays: [n_modes]f32) void {
    bank.freqs = freqs;
    bank.decays = decays;
}

pub fn resonatorBankExcite(comptime n_modes: usize, bank: *ResonatorBank(n_modes), gains: [n_modes]f32, amount: f32) void {
    for (0..n_modes) |idx| {
        bank.amps[idx] += gains[idx] * amount;
    }
}

pub fn resonatorBankProcess(comptime n_modes: usize, bank: *ResonatorBank(n_modes)) f32 {
    var out: f32 = 0.0;
    for (0..n_modes) |idx| {
        if (bank.amps[idx] <= 0.00001) continue;
        bank.phases[idx] += bank.freqs[idx] * INV_SR * TAU;
        if (bank.phases[idx] > TAU) bank.phases[idx] -= TAU;
        out += @sin(bank.phases[idx]) * bank.amps[idx];
        bank.amps[idx] *= bank.decays[idx];
    }
    return out;
}

pub fn WaveguideString(comptime size: usize) type {
    comptime {
        if (size < 8) @compileError("WaveguideString size must be >= 8");
    }

    return struct {
        line: DelayLine(size) = .{},
        damping: LPF = lpfInit(4200.0),
        seed: u32 = 0x1357_9BDF,
        feedback: f32 = 0.992,
        delay_samples: usize = 64,
        excitation: f32 = 0.0,
    };
}

pub fn waveguideStringReset(comptime size: usize, string: *WaveguideString(size)) void {
    string.* = .{};
}

pub fn waveguideStringSetFreq(comptime size: usize, string: *WaveguideString(size), freq: f32) void {
    const safe_freq = @max(freq, 8.0);
    const delay_f = SAMPLE_RATE / safe_freq;
    string.delay_samples = @intFromFloat(std.math.clamp(delay_f, 2.0, @as(f32, @floatFromInt(size - 2))));
}

pub fn waveguideStringPluck(comptime size: usize, string: *WaveguideString(size), amount: f32, brightness: f32) void {
    delayLineReset(size, &string.line);
    string.damping = lpfInit(1200.0 + brightness * 6800.0);
    string.feedback = 0.985 + brightness * 0.01;
    for (0..string.delay_samples) |idx| {
        string.seed ^= string.seed << 13;
        string.seed ^= string.seed >> 17;
        string.seed ^= string.seed << 5;
        const noise = (@as(f32, @floatFromInt(string.seed & 0x7FFF)) / 16384.0) - 1.0;
        string.line.buf[idx] = noise * amount;
    }
    string.line.pos = string.delay_samples % size;
    string.excitation = amount * (0.02 + brightness * 0.03);
}

pub fn waveguideStringProcess(comptime size: usize, string: *WaveguideString(size)) f32 {
    const delayed = delayLineTap(size, &string.line, string.delay_samples);
    const filtered = lpfProcess(&string.damping, delayed);
    const next = softClip(filtered * string.feedback + string.excitation);
    delayLinePush(size, &string.line, next);
    string.excitation *= 0.6;
    return delayed;
}

pub fn exciterNoiseBurst(rng: *Rng, hpf: *HPF, lpf: *LPF, age: u32, decay_rate: f32, gain: f32) f32 {
    const decay = @exp(-@as(f32, @floatFromInt(age)) * decay_rate);
    const noise = hpfProcess(hpf, lpfProcess(lpf, rngFloat(rng) * 2.0 - 1.0));
    return noise * decay * gain;
}

pub fn exciterPulseBurst(phase: f32, age: u32, decay_rate: f32, gain: f32) f32 {
    const decay = @exp(-@as(f32, @floatFromInt(age)) * decay_rate);
    return (@sin(phase * 23.0) + @sin(phase * 41.0) * 0.5) * decay * gain;
}

pub fn CombFilter(comptime size: usize) type {
    return struct {
        buf: [size]f32 = [_]f32{0} ** size,
        pos: usize = 0,
        feedback: f32,
        filter_store: f32 = 0,
        damp: f32 = 0.3,
    };
}

pub fn combFilterProcess(comptime size: usize, filter: *CombFilter(size), input: f32) f32 {
    const out = filter.buf[filter.pos];
    filter.filter_store += (out - filter.filter_store) * (1.0 - filter.damp);
    filter.buf[filter.pos] = input + filter.filter_store * filter.feedback;
    filter.pos = (filter.pos + 1) % size;
    return out;
}

pub fn AllpassFilter(comptime size: usize) type {
    return struct {
        buf: [size]f32 = [_]f32{0} ** size,
        pos: usize = 0,
        feedback: f32 = 0.5,
    };
}

pub fn allpassFilterProcess(comptime size: usize, filter: *AllpassFilter(size), input: f32) f32 {
    const buffered = filter.buf[filter.pos];
    const out = -input * filter.feedback + buffered;
    filter.buf[filter.pos] = input + buffered * filter.feedback;
    filter.pos = (filter.pos + 1) % size;
    return out;
}

pub fn StereoReverb(comptime comb_sizes: [4]usize, comptime allpass_sizes: [2]usize) type {
    const PREDELAY_SAMPLES = 1200;
    const MonoState = struct {
        comb0: CombFilter(comb_sizes[0]) = .{ .feedback = 0.5 },
        comb1: CombFilter(comb_sizes[1]) = .{ .feedback = 0.5 },
        comb2: CombFilter(comb_sizes[2]) = .{ .feedback = 0.5 },
        comb3: CombFilter(comb_sizes[3]) = .{ .feedback = 0.5 },
        ap0: AllpassFilter(allpass_sizes[0]) = .{},
        ap1: AllpassFilter(allpass_sizes[1]) = .{},
        predelay_buf: [PREDELAY_SAMPLES]f32 = [_]f32{0} ** PREDELAY_SAMPLES,
        predelay_pos: usize = 0,
        wet_lpf: LPF = lpfInit(4200.0),
    };

    return struct {
        pub const Mono = MonoState;
        pub const PREDELAY: usize = PREDELAY_SAMPLES;
        left: MonoState,
        right: MonoState,
    };
}

fn stereoReverbInitMono(comptime comb_sizes: [4]usize, comptime allpass_sizes: [2]usize, comb_feedbacks: [4]f32) StereoReverb(comb_sizes, allpass_sizes).Mono {
    return .{
        .comb0 = .{ .feedback = comb_feedbacks[0] },
        .comb1 = .{ .feedback = comb_feedbacks[1] },
        .comb2 = .{ .feedback = comb_feedbacks[2] },
        .comb3 = .{ .feedback = comb_feedbacks[3] },
        .ap0 = .{},
        .ap1 = .{},
    };
}

fn stereoReverbProcessMono(comptime comb_sizes: [4]usize, comptime allpass_sizes: [2]usize, state: *StereoReverb(comb_sizes, allpass_sizes).Mono, input: f32) f32 {
    const delayed_input = state.predelay_buf[state.predelay_pos];
    state.predelay_buf[state.predelay_pos] = input;
    state.predelay_pos = (state.predelay_pos + 1) % StereoReverb(comb_sizes, allpass_sizes).PREDELAY;

    const c = combFilterProcess(comb_sizes[0], &state.comb0, delayed_input) +
        combFilterProcess(comb_sizes[1], &state.comb1, delayed_input) +
        combFilterProcess(comb_sizes[2], &state.comb2, delayed_input) +
        combFilterProcess(comb_sizes[3], &state.comb3, delayed_input);
    const diffused = allpassFilterProcess(allpass_sizes[1], &state.ap1, allpassFilterProcess(allpass_sizes[0], &state.ap0, c * 0.18));
    return lpfProcess(&state.wet_lpf, diffused);
}

pub fn stereoReverbInit(comptime comb_sizes: [4]usize, comptime allpass_sizes: [2]usize, comb_feedbacks: [4]f32) StereoReverb(comb_sizes, allpass_sizes) {
    return .{
        .left = stereoReverbInitMono(comb_sizes, allpass_sizes, comb_feedbacks),
        .right = stereoReverbInitMono(comb_sizes, allpass_sizes, comb_feedbacks),
    };
}

pub fn stereoReverbProcess(comptime comb_sizes: [4]usize, comptime allpass_sizes: [2]usize, reverb: *StereoReverb(comb_sizes, allpass_sizes), input: [2]f32) [2]f32 {
    return .{
        stereoReverbProcessMono(comb_sizes, allpass_sizes, &reverb.left, input[0]),
        stereoReverbProcessMono(comb_sizes, allpass_sizes, &reverb.right, input[1]),
    };
}

pub const Rng = struct {
    state: u32,
};

pub fn rngInit(seed: u32) Rng {
    return .{ .state = seed };
}

pub fn rngNext(rng: *Rng) u32 {
    rng.state ^= rng.state << 13;
    rng.state ^= rng.state >> 17;
    rng.state ^= rng.state << 5;
    return rng.state;
}

pub fn rngFloat(rng: *Rng) f32 {
    return @as(f32, @floatFromInt(rngNext(rng) & 0x7FFFFF)) / @as(f32, 0x7FFFFF);
}

pub fn rngNextScaleNote(rng: *Rng, current: u8, low: u8, high: u8) u8 {
    const r = rngFloat(rng);
    var delta: i8 = 0;
    if (r < 0.35) {
        delta = 1;
    } else if (r < 0.7) {
        delta = -1;
    } else if (r < 0.85) {
        delta = 2;
    } else if (r < 0.95) {
        delta = -2;
    } else {
        delta = 3;
    }
    const new_raw: i16 = @as(i16, current) + delta;
    return @intCast(std.math.clamp(new_raw, @as(i16, low), @as(i16, high)));
}

pub fn softClip(x: f32) f32 {
    if (x > 1.0) return 1.0;
    if (x < -1.0) return -1.0;
    return x * (1.5 - 0.5 * x * x);
}

pub fn panStereo(sample: f32, pan: f32) [2]f32 {
    return .{
        sample * (0.5 - pan * 0.5),
        sample * (0.5 + pan * 0.5),
    };
}

pub fn samplesPerBeat(bpm: f32) f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

pub fn Voice(comptime n_unison: u8, comptime n_harmonics: u8) type {
    comptime {
        if (n_unison == 0) @compileError("n_unison must be > 0");
        if (n_harmonics == 0) @compileError("n_harmonics must be > 0");
    }

    const PHASE_COUNT = @as(usize, n_unison) * @as(usize, n_harmonics);

    return struct {
        phases: [PHASE_COUNT]f32 = .{0} ** PHASE_COUNT,
        mod_phases: [n_unison]f32 = .{0} ** n_unison,
        freq: f32 = 0,
        env: Envelope = envelopeInit(0.01, 1.0, 0.0, 0.5),
        filter: LPF = lpfInit(3000.0),
        pan: f32 = 0,
        unison_spread: f32 = 0.004,
        vibrato_phase: f32 = 0,
        vibrato_rate_hz: f32 = 0,
        vibrato_depth: f32 = 0,
        fm_ratio: f32 = 0,
        fm_depth: f32 = 0,
        fm_env_depth: f32 = 0,
    };
}

pub const VoiceRawOutput = struct { osc: f32, env_val: f32 };

pub fn voiceTrigger(comptime n_unison: u8, comptime n_harmonics: u8, voice: *Voice(n_unison, n_harmonics), freq: f32, env_preset: Envelope) void {
    voice.freq = freq;
    const current_level = voice.env.level;
    voice.env = env_preset;
    voice.env.level = current_level;
    envelopeTrigger(&voice.env);
}

pub fn voiceNoteOff(comptime n_unison: u8, comptime n_harmonics: u8, voice: *Voice(n_unison, n_harmonics)) void {
    envelopeNoteOff(&voice.env);
}

pub fn voiceIsIdle(comptime n_unison: u8, comptime n_harmonics: u8, voice: *const Voice(n_unison, n_harmonics)) bool {
    return voice.env.state == .idle;
}

pub fn voiceProcessRaw(comptime n_unison: u8, comptime n_harmonics: u8, voice: *Voice(n_unison, n_harmonics)) VoiceRawOutput {
    const env_val = envelopeProcess(&voice.env);
    if (env_val <= 0.0001) return .{ .osc = 0, .env_val = 0 };

    var sample: f32 = 0;
    const use_fm = voice.fm_ratio > 0;
    var vibrato_ratio: f32 = 1.0;
    if (voice.vibrato_rate_hz > 0 and voice.vibrato_depth > 0) {
        voice.vibrato_phase += voice.vibrato_rate_hz * INV_SR * TAU;
        if (voice.vibrato_phase > TAU) voice.vibrato_phase -= TAU;
        vibrato_ratio += @sin(voice.vibrato_phase) * voice.vibrato_depth;
    }

    for (0..n_unison) |u| {
        const osc_freq_base = if (n_unison > 1) blk: {
            const u_f: f32 = @floatFromInt(u);
            const center: f32 = @as(f32, @floatFromInt(n_unison - 1)) / 2.0;
            break :blk voice.freq * (1.0 + (u_f - center) * voice.unison_spread);
        } else voice.freq;
        const osc_freq = osc_freq_base * vibrato_ratio;

        var fm_signal: f32 = 0;
        if (use_fm) {
            voice.mod_phases[u] += osc_freq * voice.fm_ratio * INV_SR * TAU;
            if (voice.mod_phases[u] > TAU) voice.mod_phases[u] -= TAU;
            fm_signal = voice.fm_depth * (1.0 + voice.fm_env_depth * env_val) * @sin(voice.mod_phases[u]);
        }

        for (0..n_harmonics) |h| {
            const idx = u * n_harmonics + h;
            const harmonic: f32 = @floatFromInt(h + 1);
            const amp = 1.0 / (harmonic * harmonic);

            voice.phases[idx] += osc_freq * harmonic * INV_SR * TAU;
            if (voice.phases[idx] > TAU) voice.phases[idx] -= TAU;

            if (use_fm) {
                sample += @sin(voice.phases[idx] + fm_signal) * amp;
            } else {
                sample += @sin(voice.phases[idx]) * amp;
            }
        }
    }

    if (n_unison > 1) {
        sample /= @as(f32, @floatFromInt(n_unison));
    }

    return .{ .osc = sample, .env_val = env_val };
}

pub fn voiceProcess(comptime n_unison: u8, comptime n_harmonics: u8, voice: *Voice(n_unison, n_harmonics)) f32 {
    const raw = voiceProcessRaw(n_unison, n_harmonics, voice);
    if (raw.env_val <= 0.0001) return 0;
    return lpfProcess(&voice.filter, raw.osc) * raw.env_val;
}
