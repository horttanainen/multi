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

    pub fn init(attack_s: f32, decay_s: f32, sustain: f32, release_s: f32) Envelope {
        return .{
            .attack_rate = 1.0 / @max(attack_s * SAMPLE_RATE, 1.0),
            .decay_rate = (1.0 - sustain) / @max(decay_s * SAMPLE_RATE, 1.0),
            .sustain_level = sustain,
            .release_rate = sustain / @max(release_s * SAMPLE_RATE, 1.0),
        };
    }

    pub fn trigger(self: *Envelope) void {
        self.state = .attack;
    }

    pub fn retrigger(self: *Envelope, attack_s: f32, decay_s: f32, sustain: f32, release_s: f32) void {
        self.attack_rate = 1.0 / @max(attack_s * SAMPLE_RATE, 1.0);
        self.decay_rate = (1.0 - sustain) / @max(decay_s * SAMPLE_RATE, 1.0);
        self.sustain_level = sustain;
        self.release_rate = sustain / @max(release_s * SAMPLE_RATE, 1.0);
        self.state = .attack;
    }

    pub fn noteOff(self: *Envelope) void {
        if (self.state != .idle) self.state = .release;
    }

    pub fn process(self: *Envelope) f32 {
        switch (self.state) {
            .idle => return 0,
            .attack => {
                self.level += self.attack_rate;
                if (self.level >= 1.0) {
                    self.level = 1.0;
                    self.state = .decay;
                }
            },
            .decay => {
                self.level -= self.decay_rate;
                if (self.level <= self.sustain_level) {
                    self.level = self.sustain_level;
                    self.state = .sustain;
                }
            },
            .sustain => {},
            .release => {
                self.level -= self.release_rate;
                if (self.level <= 0) {
                    self.level = 0;
                    self.state = .idle;
                }
            },
        }
        return self.level;
    }
};

pub const LPF = struct {
    prev: f32 = 0,
    alpha: f32,

    pub fn init(cutoff_hz: f32) LPF {
        const rc = 1.0 / (TAU * cutoff_hz);
        return .{ .alpha = INV_SR / (rc + INV_SR) };
    }

    pub fn process(self: *LPF, input: f32) f32 {
        self.prev += self.alpha * (input - self.prev);
        return self.prev;
    }
};

pub const HPF = struct {
    prev_in: f32 = 0,
    prev_out: f32 = 0,
    alpha: f32,

    pub fn init(cutoff_hz: f32) HPF {
        const rc = 1.0 / (TAU * cutoff_hz);
        return .{ .alpha = rc / (rc + INV_SR) };
    }

    pub fn process(self: *HPF, input: f32) f32 {
        self.prev_out = self.alpha * (self.prev_out + input - self.prev_in);
        self.prev_in = input;
        return self.prev_out;
    }
};

pub fn DelayLine(comptime size: usize) type {
    comptime {
        if (size == 0) @compileError("DelayLine size must be > 0");
    }

    return struct {
        buf: [size]f32 = [_]f32{0} ** size,
        pos: usize = 0,

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }

        pub fn push(self: *@This(), sample: f32) void {
            self.buf[self.pos] = sample;
            self.pos = (self.pos + 1) % size;
        }

        pub fn tap(self: *const @This(), delay: usize) f32 {
            const clamped_delay = @min(delay, size - 1);
            const read_pos = (self.pos + size - 1 - clamped_delay) % size;
            return self.buf[read_pos];
        }

        pub fn process(self: *@This(), sample: f32, delay: usize) f32 {
            const tapped = self.tap(delay);
            self.push(sample);
            return tapped;
        }
    };
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

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }

        pub fn configure(self: *@This(), freqs: [n_modes]f32, decays: [n_modes]f32) void {
            self.freqs = freqs;
            self.decays = decays;
        }

        pub fn excite(self: *@This(), gains: [n_modes]f32, amount: f32) void {
            for (0..n_modes) |idx| {
                self.amps[idx] += gains[idx] * amount;
            }
        }

        pub fn process(self: *@This()) f32 {
            var out: f32 = 0.0;
            for (0..n_modes) |idx| {
                if (self.amps[idx] <= 0.00001) continue;
                self.phases[idx] += self.freqs[idx] * INV_SR * TAU;
                if (self.phases[idx] > TAU) self.phases[idx] -= TAU;
                out += @sin(self.phases[idx]) * self.amps[idx];
                self.amps[idx] *= self.decays[idx];
            }
            return out;
        }
    };
}

pub fn WaveguideString(comptime size: usize) type {
    comptime {
        if (size < 8) @compileError("WaveguideString size must be >= 8");
    }

    return struct {
        line: DelayLine(size) = .{},
        damping: LPF = LPF.init(4200.0),
        seed: u32 = 0x1357_9BDF,
        feedback: f32 = 0.992,
        delay_samples: usize = 64,
        excitation: f32 = 0.0,

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }

        pub fn setFreq(self: *@This(), freq: f32) void {
            const safe_freq = @max(freq, 8.0);
            const delay_f = SAMPLE_RATE / safe_freq;
            self.delay_samples = @intFromFloat(std.math.clamp(delay_f, 2.0, @as(f32, @floatFromInt(size - 2))));
        }

        pub fn pluck(self: *@This(), amount: f32, brightness: f32) void {
            self.line.reset();
            self.damping = LPF.init(1200.0 + brightness * 6800.0);
            self.feedback = 0.985 + brightness * 0.01;
            for (0..self.delay_samples) |idx| {
                self.seed ^= self.seed << 13;
                self.seed ^= self.seed >> 17;
                self.seed ^= self.seed << 5;
                const noise = (@as(f32, @floatFromInt(self.seed & 0x7FFF)) / 16384.0) - 1.0;
                self.line.buf[idx] = noise * amount;
            }
            self.line.pos = self.delay_samples % size;
            self.excitation = amount * (0.02 + brightness * 0.03);
        }

        pub fn process(self: *@This()) f32 {
            const delayed = self.line.tap(self.delay_samples);
            const filtered = self.damping.process(delayed);
            const next = softClip(filtered * self.feedback + self.excitation);
            self.line.push(next);
            self.excitation *= 0.6;
            return delayed;
        }
    };
}

pub fn exciterNoiseBurst(rng: *Rng, hpf: *HPF, lpf: *LPF, age: u32, decay_rate: f32, gain: f32) f32 {
    const decay = @exp(-@as(f32, @floatFromInt(age)) * decay_rate);
    const noise = hpf.process(lpf.process(rng.float() * 2.0 - 1.0));
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

        pub fn process(self: *@This(), input: f32) f32 {
            const out = self.buf[self.pos];
            self.filter_store += (out - self.filter_store) * (1.0 - self.damp);
            self.buf[self.pos] = input + self.filter_store * self.feedback;
            self.pos = (self.pos + 1) % size;
            return out;
        }
    };
}

pub fn AllpassFilter(comptime size: usize) type {
    return struct {
        buf: [size]f32 = [_]f32{0} ** size,
        pos: usize = 0,
        feedback: f32 = 0.5,

        pub fn process(self: *@This(), input: f32) f32 {
            const buffered = self.buf[self.pos];
            const out = -input * self.feedback + buffered;
            self.buf[self.pos] = input + buffered * self.feedback;
            self.pos = (self.pos + 1) % size;
            return out;
        }
    };
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
        wet_lpf: LPF = LPF.init(4200.0),
    };

    return struct {
        left: MonoState,
        right: MonoState,

        pub fn init(comb_feedbacks: [4]f32) @This() {
            return .{
                .left = initMono(comb_feedbacks),
                .right = initMono(comb_feedbacks),
            };
        }

        pub fn process(self: *@This(), input: [2]f32) [2]f32 {
            return .{
                processMono(&self.left, input[0]),
                processMono(&self.right, input[1]),
            };
        }

        fn initMono(comb_feedbacks: [4]f32) MonoState {
            return .{
                .comb0 = .{ .feedback = comb_feedbacks[0] },
                .comb1 = .{ .feedback = comb_feedbacks[1] },
                .comb2 = .{ .feedback = comb_feedbacks[2] },
                .comb3 = .{ .feedback = comb_feedbacks[3] },
                .ap0 = .{},
                .ap1 = .{},
            };
        }

        fn processMono(state: *MonoState, input: f32) f32 {
            const delayed_input = state.predelay_buf[state.predelay_pos];
            state.predelay_buf[state.predelay_pos] = input;
            state.predelay_pos = (state.predelay_pos + 1) % PREDELAY_SAMPLES;

            const c = state.comb0.process(delayed_input) + state.comb1.process(delayed_input) +
                state.comb2.process(delayed_input) + state.comb3.process(delayed_input);
            const diffused = state.ap1.process(state.ap0.process(c * 0.18));
            return state.wet_lpf.process(diffused);
        }
    };
}

pub const Rng = struct {
    state: u32,

    pub fn init(seed: u32) Rng {
        return .{ .state = seed };
    }

    pub fn next(self: *Rng) u32 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 17;
        self.state ^= self.state << 5;
        return self.state;
    }

    pub fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() & 0x7FFFFF)) / @as(f32, 0x7FFFFF);
    }

    pub fn nextScaleNote(self: *Rng, current: u8, low: u8, high: u8) u8 {
        const r = self.float();
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
};

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
        env: Envelope = Envelope.init(0.01, 1.0, 0.0, 0.5),
        filter: LPF = LPF.init(3000.0),
        pan: f32 = 0,
        unison_spread: f32 = 0.004,
        vibrato_phase: f32 = 0,
        vibrato_rate_hz: f32 = 0,
        vibrato_depth: f32 = 0,
        fm_ratio: f32 = 0,
        fm_depth: f32 = 0,
        fm_env_depth: f32 = 0,

        const Self = @This();

        pub fn trigger(self: *Self, freq: f32, env_preset: Envelope) void {
            self.freq = freq;
            const current_level = self.env.level;
            self.env = env_preset;
            self.env.level = current_level;
            self.env.trigger();
        }

        pub fn noteOff(self: *Self) void {
            self.env.noteOff();
        }

        pub fn isIdle(self: *const Self) bool {
            return self.env.state == .idle;
        }

        pub const RawOutput = struct { osc: f32, env_val: f32 };

        pub fn processRaw(self: *Self) RawOutput {
            const env_val = self.env.process();
            if (env_val <= 0.0001) return .{ .osc = 0, .env_val = 0 };

            var sample: f32 = 0;
            const use_fm = self.fm_ratio > 0;
            var vibrato_ratio: f32 = 1.0;
            if (self.vibrato_rate_hz > 0 and self.vibrato_depth > 0) {
                self.vibrato_phase += self.vibrato_rate_hz * INV_SR * TAU;
                if (self.vibrato_phase > TAU) self.vibrato_phase -= TAU;
                vibrato_ratio += @sin(self.vibrato_phase) * self.vibrato_depth;
            }

            for (0..n_unison) |u| {
                const osc_freq_base = if (n_unison > 1) blk: {
                    const u_f: f32 = @floatFromInt(u);
                    const center: f32 = @as(f32, @floatFromInt(n_unison - 1)) / 2.0;
                    break :blk self.freq * (1.0 + (u_f - center) * self.unison_spread);
                } else self.freq;
                const osc_freq = osc_freq_base * vibrato_ratio;

                var fm_signal: f32 = 0;
                if (use_fm) {
                    self.mod_phases[u] += osc_freq * self.fm_ratio * INV_SR * TAU;
                    if (self.mod_phases[u] > TAU) self.mod_phases[u] -= TAU;
                    fm_signal = self.fm_depth * (1.0 + self.fm_env_depth * env_val) * @sin(self.mod_phases[u]);
                }

                for (0..n_harmonics) |h| {
                    const idx = u * n_harmonics + h;
                    const harmonic: f32 = @floatFromInt(h + 1);
                    const amp = 1.0 / (harmonic * harmonic);

                    self.phases[idx] += osc_freq * harmonic * INV_SR * TAU;
                    if (self.phases[idx] > TAU) self.phases[idx] -= TAU;

                    if (use_fm) {
                        sample += @sin(self.phases[idx] + fm_signal) * amp;
                    } else {
                        sample += @sin(self.phases[idx]) * amp;
                    }
                }
            }

            if (n_unison > 1) {
                sample /= @as(f32, @floatFromInt(n_unison));
            }

            return .{ .osc = sample, .env_val = env_val };
        }

        pub fn process(self: *Self) f32 {
            const raw = self.processRaw();
            if (raw.env_val <= 0.0001) return 0;
            return self.filter.process(raw.osc) * raw.env_val;
        }
    };
}
