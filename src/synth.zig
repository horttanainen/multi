// Shared synthesis engine: DSP primitives for procedural music generators.
// Each music style imports this module for envelopes, filters, oscillators,
// reverb, scale utilities, and PRNG — similar to how menu.zig provides
// the framework that individual menus configure.
const std = @import("std");

pub const SAMPLE_RATE: f32 = 48000.0;
pub const INV_SR: f32 = 1.0 / SAMPLE_RATE;
pub const TAU = std.math.tau;

// ============================================================
// Scale utilities
// ============================================================

// C minor pentatonic across 4 octaves (MIDI notes)
pub const pentatonic_scale = [_]u8{
    36, 39, 41, 43, 46, // C2
    48, 51, 53, 55, 58, // C3
    60, 63, 65, 67, 70, // C4
    72, 75, 77, 79, 82, // C5
};

pub fn midiToFreq(note: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

// ============================================================
// ADSR Envelope
// ============================================================

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

// ============================================================
// One-pole low-pass filter
// ============================================================

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

// ============================================================
// One-pole high-pass filter
// ============================================================

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

// ============================================================
// Comb and allpass filters for reverb
// ============================================================

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

// ============================================================
// Xorshift PRNG (deterministic, no allocator)
// ============================================================

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

    // Markov-style note selection: biased toward stepwise motion in scale
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

// ============================================================
// Utilities
// ============================================================

pub fn softClip(x: f32) f32 {
    if (x > 1.0) return 1.0;
    if (x < -1.0) return -1.0;
    return x * (1.5 - 0.5 * x * x);
}

/// Pan a mono sample to stereo. pan: -1.0 (left) to 1.0 (right).
pub fn panStereo(sample: f32, pan: f32) [2]f32 {
    return .{
        sample * (0.5 - pan * 0.5),
        sample * (0.5 + pan * 0.5),
    };
}
