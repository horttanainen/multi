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
        // Retrigger from current level — avoids hard cut-off of previous note.
        // Level is preserved so the attack ramps from wherever we are now.
        self.state = .attack;
    }

    /// Retrigger with new ADSR parameters, keeping current level for smooth transition.
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

pub fn samplesPerBeat(bpm: f32) f32 {
    return SAMPLE_RATE * 60.0 / bpm;
}

// ============================================================
// Voice: multi-oscillator synthesis with unison detuning & FM
// ============================================================
//
// n_unison:    number of detuned copies (1 = mono, 2+ = chorus/thick)
// n_harmonics: additive partials per oscillator (1 = fundamental only)
//
// Set fm_ratio > 0 to enable FM synthesis (modulator per unison osc).

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

        fm_ratio: f32 = 0,
        fm_depth: f32 = 0,
        fm_env_depth: f32 = 0,

        const Self = @This();

        pub fn trigger(self: *Self, freq: f32, env_preset: Envelope) void {
            self.freq = freq;
            // Preserve current level so retriggering doesn't hard-cut the previous note
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

        /// Returns raw oscillator sum (pre-filter) and envelope value.
        /// Use when you need custom filtering (e.g. formant filters for choir).
        pub fn processRaw(self: *Self) RawOutput {
            const env_val = self.env.process();
            if (env_val <= 0.0001) return .{ .osc = 0, .env_val = 0 };

            var sample: f32 = 0;
            const use_fm = self.fm_ratio > 0;

            for (0..n_unison) |u| {
                const osc_freq = if (n_unison > 1) blk: {
                    const u_f: f32 = @floatFromInt(u);
                    const center: f32 = @as(f32, @floatFromInt(n_unison - 1)) / 2.0;
                    break :blk self.freq * (1.0 + (u_f - center) * self.unison_spread);
                } else self.freq;

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

        /// Full processing: oscillators → filter → envelope.
        pub fn process(self: *Self) f32 {
            const raw = self.processRaw();
            if (raw.env_val <= 0.0001) return 0;
            return self.filter.process(raw.osc) * raw.env_val;
        }
    };
}

// ============================================================
// Overdrive: asymmetric tube-style waveshaper
// ============================================================

/// Soft-clip with asymmetry — positive half clips harder, adding even
/// harmonics like a real tube amp. `gain` controls pre-saturation level.
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

// ============================================================
// ElectricGuitar: overdriven multi-voice guitar with cabinet sim
// ============================================================
//
// Wraps N Voice oscillators through overdrive + HPF/LPF cabinet.
// Configurable: gain, cabinet filters, overdrive amount, pan spread.
// Use for power chords, clean rhythm, stabs — anything guitar-like.

pub fn ElectricGuitar(comptime n_voices: u8, comptime n_unison: u8, comptime n_harmonics: u8) type {
    const GuitarVoice = Voice(n_unison, n_harmonics);

    return struct {
        voices: [n_voices]GuitarVoice = .{GuitarVoice{}} ** n_voices,
        env: Envelope = Envelope.init(0.004, 0.36, 0.0, 0.14),
        cab_lpf_l: LPF = LPF.init(4500.0),
        cab_lpf_r: LPF = LPF.init(4500.0),
        cab_hpf_l: HPF = HPF.init(120.0),
        cab_hpf_r: HPF = HPF.init(120.0),
        gain: f32 = 1.0,
        od_amount: f32 = 2.5, // overdrive gain (higher = more distortion)

        const Self = @This();

        pub fn init(pan_spread: f32, unison_spread_val: f32, cab_lpf_hz: f32, cab_hpf_hz: f32) Self {
            var g: Self = .{};
            g.cab_lpf_l = LPF.init(cab_lpf_hz);
            g.cab_lpf_r = LPF.init(cab_lpf_hz);
            g.cab_hpf_l = HPF.init(cab_hpf_hz);
            g.cab_hpf_r = HPF.init(cab_hpf_hz);
            for (0..n_voices) |i| {
                const t: f32 = if (n_voices > 1)
                    (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_voices - 1))) * 2.0 - 1.0
                else
                    0;
                g.voices[i].pan = t * pan_spread;
                g.voices[i].unison_spread = unison_spread_val;
            }
            return g;
        }

        /// Set frequencies for all voices from a chord (array of MIDI notes or frequencies).
        pub fn setFreqs(self: *Self, freqs: []const f32) void {
            for (0..@min(n_voices, freqs.len)) |i| {
                self.voices[i].freq = freqs[i];
            }
        }

        /// Trigger the shared envelope.
        pub fn triggerEnv(self: *Self, attack: f32, decay: f32, sustain: f32, release: f32) void {
            self.env = Envelope.init(attack, decay, sustain, release);
            self.env.trigger();
        }

        /// Set cabinet filter cutoff (call when cue changes).
        pub fn setCabinet(self: *Self, lpf_hz: f32, hpf_hz: f32) void {
            self.cab_lpf_l = LPF.init(lpf_hz);
            self.cab_lpf_r = LPF.init(lpf_hz);
            self.cab_hpf_l = HPF.init(hpf_hz);
            self.cab_hpf_r = HPF.init(hpf_hz);
        }

        /// Process all voices through overdrive + cabinet, returns stereo.
        pub fn process(self: *Self, extra_drive: f32) [2]f32 {
            const env_val = self.env.process();
            if (env_val <= 0.0001) return .{ 0.0, 0.0 };

            var left: f32 = 0.0;
            var right: f32 = 0.0;

            for (0..n_voices) |idx| {
                // Feed shared envelope to each voice
                self.voices[idx].env = .{
                    .state = .sustain,
                    .level = env_val,
                    .attack_rate = 0,
                    .decay_rate = 0,
                    .sustain_level = env_val,
                    .release_rate = 0,
                };

                const raw = self.voices[idx].processRaw();
                if (raw.env_val <= 0.0001) continue;

                var wave = raw.osc * self.gain;
                wave = overdrive(wave, self.od_amount + extra_drive);
                wave *= raw.env_val;

                const stereo = panStereo(wave, self.voices[idx].pan);
                left += stereo[0];
                right += stereo[1];
            }

            // Cabinet simulation
            left = self.cab_hpf_l.process(left);
            left = self.cab_lpf_l.process(left);
            right = self.cab_hpf_r.process(right);
            right = self.cab_lpf_r.process(right);

            return .{ left, right };
        }
    };
}

// ============================================================
// SawBass: saw + sub octave bass with filter
// ============================================================
//
// Mono bass instrument: saw wave + sub-octave sine + resonant LPF.
// Configurable drive, filter cutoff. Used by rock, house, etc.

pub const SawBass = struct {
    phase: f32 = 0,
    sub_phase: f32 = 0,
    freq: f32 = midiToFreq(40),
    env: Envelope = Envelope.init(0.002, 0.18, 0.0, 0.08),
    filter: LPF = LPF.init(800.0),
    drive: f32 = 0.55,
    sub_mix: f32 = 0.4, // sub octave level relative to saw
    volume: f32 = 0.55,

    pub fn trigger(self: *SawBass, freq: f32) void {
        self.freq = freq;
        self.env.trigger();
    }

    pub fn setFilter(self: *SawBass, cutoff: f32) void {
        self.filter = LPF.init(cutoff);
    }

    pub fn process(self: *SawBass) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.phase += self.freq * INV_SR * TAU;
        if (self.phase > TAU) self.phase -= TAU;
        self.sub_phase += self.freq * 0.5 * INV_SR * TAU;
        if (self.sub_phase > TAU) self.sub_phase -= TAU;

        const saw = self.phase / std.math.pi - 1.0;
        const sub = @sin(self.sub_phase);
        var sample = saw * (0.6 + self.drive * 0.35) + sub * self.sub_mix;
        sample = self.filter.process(sample);
        sample *= 1.0 + self.drive * 0.45;
        return sample * env_val * self.volume;
    }
};

// ============================================================
// Kick: synthesized bass drum (sine sweep with pitch envelope)
// ============================================================

pub const Kick = struct {
    phase: f32 = 0,
    pitch_env: f32 = 0,
    env: Envelope = Envelope.init(0.001, 0.16, 0.0, 0.1),
    sample_count: f32 = 0,
    base_freq: f32 = 44.0, // lowest frequency
    sweep: f32 = 90.0, // pitch sweep range
    decay_rate: f32 = 0.993, // pitch envelope decay
    volume: f32 = 1.5,

    pub fn trigger(self: *Kick, accent: f32) void {
        self.env.trigger();
        self.pitch_env = accent;
        self.sample_count = 0;
    }

    pub fn process(self: *Kick) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.pitch_env *= self.decay_rate;
        const freq = self.base_freq + self.pitch_env * self.sweep;
        self.phase += freq * INV_SR * TAU;
        if (self.phase > TAU) self.phase -= TAU;
        self.sample_count += 1;
        return @sin(self.phase) * env_val * self.volume;
    }
};

// ============================================================
// Snare: body tone + filtered noise
// ============================================================

pub const Snare = struct {
    phase: f32 = 0,
    env: Envelope = Envelope.init(0.001, 0.12, 0.0, 0.06),
    noise_lpf: LPF = LPF.init(3400.0),
    body_lpf: LPF = LPF.init(2200.0),
    tone_freq: f32 = 190.0,
    noise_mix: f32 = 0.78,
    body_mix: f32 = 0.35,

    pub fn trigger(self: *Snare) void {
        self.env.trigger();
    }

    /// Trigger a ghost hit (quieter, shorter).
    pub fn triggerGhost(self: *Snare) void {
        self.env = Envelope.init(0.001, 0.06, 0.0, 0.03);
        self.env.trigger();
    }

    pub fn process(self: *Snare, rng_inst: *Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.phase += self.tone_freq * INV_SR * TAU;
        if (self.phase > TAU) self.phase -= TAU;
        const noise = self.noise_lpf.process(rng_inst.float() * 2.0 - 1.0);
        const tone = self.body_lpf.process(@sin(self.phase));
        return (noise * self.noise_mix + tone * self.body_mix) * env_val;
    }
};

// ============================================================
// HiHat: filtered noise burst
// ============================================================

pub const HiHat = struct {
    env: Envelope = Envelope.init(0.001, 0.03, 0.0, 0.02),
    hpf: HPF = HPF.init(6000.0),
    volume: f32 = 0.45,

    pub fn trigger(self: *HiHat) void {
        self.env.trigger();
    }

    pub fn process(self: *HiHat, rng_inst: *Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;
        const noise = self.hpf.process(rng_inst.float() * 2.0 - 1.0);
        return noise * env_val * self.volume;
    }
};

// ============================================================
// PhraseGenerator: coherent melodic phrase builder
// ============================================================
//
// Builds short melodic phrases (3-7 notes) with a directional
// contour (ascending, descending, or arch). When a phrase is
// exhausted, a new one is generated anchored near the last note.

pub const PhraseGenerator = struct {
    pub const MAX_LEN = 8;
    const REST: u8 = 0xFF;

    notes: [MAX_LEN]u8 = .{0} ** MAX_LEN,
    len: u8 = 0,
    pos: u8 = 0,
    anchor: u8 = 10,

    region_low: u8 = 5,
    region_high: u8 = 17,
    rest_chance: f32 = 0.3,
    min_notes: u8 = 3,
    max_notes: u8 = 7,

    // Chord-tone gravity: notes gravitate toward current chord tones.
    // Set chord_tone_count > 0 to enable. Values are scale degree indices.
    chord_tones: [4]u8 = .{0} ** 4,
    chord_tone_count: u8 = 0,
    gravity: f32 = 2.0, // weight multiplier for chord tones (0 = off)

    pub fn build(self: *PhraseGenerator, rng: *Rng) void {
        const range = @as(u32, self.max_notes - self.min_notes) + 1;
        self.len = self.min_notes + @as(u8, @intCast(rng.next() % range));
        self.pos = 0;

        var current = self.anchor;
        const direction = rng.next() % 3;

        for (0..self.len) |i| {
            const progress: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(self.len, 1)));

            const up_bias: f32 = switch (direction) {
                0 => 0.65,
                1 => 0.35,
                else => if (progress < 0.5) 0.7 else 0.3,
            };

            if (rng.float() < self.rest_chance and i > 0) {
                self.notes[i] = REST;
            } else {
                current = self.selectNote(rng, current, up_bias);
                self.notes[i] = current;
            }
        }

        if (current != REST) self.anchor = current;
    }

    /// Returns scale index of next note, or null for rest.
    pub fn advance(self: *PhraseGenerator, rng: *Rng) ?u8 {
        if (self.pos >= self.len) {
            self.build(rng);
        }

        const idx = self.pos;
        self.pos += 1;

        const note = self.notes[idx];
        if (note == REST) return null;
        return note;
    }

    /// Set current chord tones for gravity. Pass scale degree indices.
    pub fn setChordTones(self: *PhraseGenerator, tones: []const u8) void {
        self.chord_tone_count = @intCast(@min(tones.len, 4));
        for (0..self.chord_tone_count) |i| {
            self.chord_tones[i] = tones[i];
        }
    }

    fn selectNote(self: *const PhraseGenerator, rng_ptr: *Rng, current: u8, up_bias: f32) u8 {
        const candidate = biasedScaleStep(rng_ptr, current, self.region_low, self.region_high, up_bias);

        if (self.chord_tone_count == 0) return candidate;
        if (isChordTone(candidate, &self.chord_tones, self.chord_tone_count)) return candidate;

        // Snap to nearest chord tone with probability based on gravity
        if (rng_ptr.float() < self.gravity / (self.gravity + 1.0)) {
            return nearestChordTone(candidate, &self.chord_tones, self.chord_tone_count, self.region_low, self.region_high);
        }
        return candidate;
    }

    fn biasedScaleStep(rng_ptr: *Rng, current: u8, low: u8, high: u8, up_bias: f32) u8 {
        const r = rng_ptr.float();
        var delta: i8 = 0;
        if (r < 0.6) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 1) else @as(i8, -1);
        } else if (r < 0.85) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 2) else @as(i8, -2);
        } else if (r < 0.95) {
            delta = if (rng_ptr.float() < up_bias) @as(i8, 3) else @as(i8, -3);
        }

        const new_raw: i16 = @as(i16, current) + delta;
        return @intCast(std.math.clamp(new_raw, @as(i16, low), @as(i16, high)));
    }

    fn isChordTone(degree: u8, tones: *const [4]u8, count: u8) bool {
        for (0..count) |i| {
            if (degree == tones[i]) return true;
        }
        return false;
    }

    fn nearestChordTone(target: u8, tones: *const [4]u8, count: u8, low: u8, high: u8) u8 {
        var best: u8 = target;
        var best_dist: u8 = 255;
        for (0..count) |i| {
            const ct = tones[i];
            if (ct < low or ct > high) continue;
            const dist = if (ct > target) ct - target else target - ct;
            if (dist < best_dist) {
                best_dist = dist;
                best = ct;
            }
        }
        return best;
    }
};

// ============================================================
// ArcController: tension dynamics over time
// ============================================================
//
// Outputs a 0.0–1.0 tension value that cycles over section_beats.
// Styles use tension to modulate filter cutoff, volume, density, etc.

pub const ArcShape = enum { rise, fall, rise_fall, plateau };

pub const ArcController = struct {
    beat_count: f32 = 0,
    section_beats: f32 = 32,
    shape: ArcShape = .rise_fall,

    pub fn advanceSample(self: *ArcController, bpm_val: f32) void {
        self.beat_count += bpm_val / (SAMPLE_RATE * 60.0);
        while (self.beat_count >= self.section_beats) {
            self.beat_count -= self.section_beats;
        }
    }

    pub fn tension(self: *const ArcController) f32 {
        const p = self.beat_count / self.section_beats;
        return switch (self.shape) {
            .rise => p,
            .fall => 1.0 - p,
            .rise_fall => @sin(p * std.math.pi),
            .plateau => if (p < 0.25) p * 4.0 else if (p > 0.75) (1.0 - p) * 4.0 else 1.0,
        };
    }

    pub fn reset(self: *ArcController) void {
        self.beat_count = 0;
    }
};

// ============================================================
// Scale system: multiple scales with key modulation
// ============================================================

pub const ScaleType = enum {
    minor_pentatonic, // {0, 3, 5, 7, 10}
    major_pentatonic, // {0, 2, 4, 7, 9}
    dorian, // {0, 2, 3, 5, 7, 9, 10}
    mixolydian, // {0, 2, 4, 5, 7, 9, 10}
    natural_minor, // {0, 2, 3, 5, 7, 8, 10}
    harmonic_minor, // {0, 2, 3, 5, 7, 8, 11}
};

const MAX_SCALE_NOTES = 7;

pub const ScaleIntervals = struct {
    intervals: [MAX_SCALE_NOTES]u8,
    len: u8,
};

pub fn getScaleIntervals(scale_type: ScaleType) ScaleIntervals {
    return switch (scale_type) {
        .minor_pentatonic => .{ .intervals = .{ 0, 3, 5, 7, 10, 0, 0 }, .len = 5 },
        .major_pentatonic => .{ .intervals = .{ 0, 2, 4, 7, 9, 0, 0 }, .len = 5 },
        .dorian => .{ .intervals = .{ 0, 2, 3, 5, 7, 9, 10 }, .len = 7 },
        .mixolydian => .{ .intervals = .{ 0, 2, 4, 5, 7, 9, 10 }, .len = 7 },
        .natural_minor => .{ .intervals = .{ 0, 2, 3, 5, 7, 8, 10 }, .len = 7 },
        .harmonic_minor => .{ .intervals = .{ 0, 2, 3, 5, 7, 8, 11 }, .len = 7 },
    };
}

/// Convert scale degree to MIDI note. Degree 0 = root in octave 2.
pub fn scaleNoteToMidi(root: u8, scale_type: ScaleType, degree: u8) u8 {
    const si = getScaleIntervals(scale_type);
    const octave: u8 = degree / si.len;
    const step: u8 = degree % si.len;
    return root + octave * 12 + si.intervals[step];
}

/// How many scale degrees fit in the given MIDI range.
pub fn scaleDegreesInRange(scale_type: ScaleType, octaves: u8) u8 {
    const si = getScaleIntervals(scale_type);
    return si.len * octaves;
}

/// Manages key (root note) with smooth modulation over time.
pub const KeyState = struct {
    root: u8 = 36, // C2 default
    target_root: u8 = 36,
    scale_type: ScaleType = .minor_pentatonic,
    transition_progress: f32 = 1.0, // 1.0 = arrived at target
    transition_speed: f32 = 0.0001, // per-sample increment (~0.2 beats at 72bpm)

    pub fn modulateTo(self: *KeyState, new_root: u8) void {
        self.target_root = new_root;
        self.transition_progress = 0;
    }

    pub fn modulateByFourth(self: *KeyState) void {
        self.modulateTo(self.root + 5);
    }

    pub fn modulateByFifth(self: *KeyState) void {
        self.modulateTo(self.root + 7);
    }

    pub fn advanceSample(self: *KeyState) void {
        if (self.transition_progress >= 1.0) return;
        self.transition_progress += self.transition_speed;
        if (self.transition_progress >= 1.0) {
            self.transition_progress = 1.0;
            self.root = self.target_root;
        }
    }

    /// Returns true during a key transition (old notes should fade out).
    pub fn isTransitioning(self: *const KeyState) bool {
        return self.transition_progress < 1.0;
    }

    pub fn noteToMidi(self: *const KeyState, degree: u8) u8 {
        return scaleNoteToMidi(self.root, self.scale_type, degree);
    }
};

// ============================================================
// ChordMarkov: probabilistic chord progression
// ============================================================

pub const MAX_CHORD_TONES = 4;
pub const MAX_CHORDS = 8;

pub const ChordDef = struct {
    /// Semitone offsets from scale root (e.g. minor triad = {0, 3, 7}).
    offsets: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES,
    len: u8 = 3,
};

pub const ChordMarkov = struct {
    chords: [MAX_CHORDS]ChordDef = .{ChordDef{}} ** MAX_CHORDS,
    num_chords: u8 = 0,
    transitions: [MAX_CHORDS][MAX_CHORDS]f32 = .{.{0} ** MAX_CHORDS} ** MAX_CHORDS,
    current: u8 = 0,

    /// Advance to next chord based on transition probabilities.
    pub fn nextChord(self: *ChordMarkov, rng: *Rng) ChordDef {
        const row = self.transitions[self.current];
        var cumulative: f32 = 0;
        const r = rng.float();
        for (0..self.num_chords) |i| {
            cumulative += row[i];
            if (r < cumulative) {
                self.current = @intCast(i);
                return self.chords[i];
            }
        }
        // Fallback (rounding errors)
        self.current = 0;
        return self.chords[0];
    }

    /// Get current chord's MIDI notes given a root.
    pub fn currentMidiNotes(self: *const ChordMarkov, root: u8) [MAX_CHORD_TONES]u8 {
        const chord = self.chords[self.current];
        var notes: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES;
        for (0..chord.len) |i| {
            notes[i] = root + chord.offsets[i];
        }
        return notes;
    }

    /// Get current chord's scale-degree approximations for PhraseGenerator gravity.
    /// Maps chord semitone offsets to nearest scale degrees.
    pub fn chordScaleDegrees(self: *const ChordMarkov, scale_type: ScaleType) struct { tones: [MAX_CHORD_TONES]u8, count: u8 } {
        const chord = self.chords[self.current];
        const si = getScaleIntervals(scale_type);
        var tones: [MAX_CHORD_TONES]u8 = .{0} ** MAX_CHORD_TONES;
        for (0..chord.len) |ci| {
            // Find nearest scale degree for this semitone offset
            var best_deg: u8 = 0;
            var best_dist: u8 = 255;
            for (0..si.len) |s| {
                const dist = if (si.intervals[s] > chord.offsets[ci])
                    si.intervals[s] - chord.offsets[ci]
                else
                    chord.offsets[ci] - si.intervals[s];
                if (dist < best_dist) {
                    best_dist = dist;
                    best_deg = @intCast(s);
                }
            }
            tones[ci] = best_deg;
        }
        return .{ .tones = tones, .count = chord.len };
    }
};

// ============================================================
// ArcSystem: three nested arcs for multi-scale dynamics
// ============================================================

pub const ArcSystem = struct {
    micro: ArcController = .{ .section_beats = 8, .shape = .rise_fall },
    meso: ArcController = .{ .section_beats = 48, .shape = .rise_fall },
    macro: ArcController = .{ .section_beats = 256, .shape = .rise_fall },

    pub fn advanceSample(self: *ArcSystem, bpm_val: f32) void {
        self.micro.advanceSample(bpm_val);
        self.meso.advanceSample(bpm_val);
        self.macro.advanceSample(bpm_val);
    }

    pub fn reset(self: *ArcSystem) void {
        self.micro.reset();
        self.meso.reset();
        self.macro.reset();
    }
};

// ============================================================
// PhraseMemory: stores phrases for motif development
// ============================================================
//
// Stores recently generated phrases and can recall them with
// transformations (transpose, retrograde, augment) for variation.

pub const PhraseMemory = struct {
    const SIZE = 6;
    const PLEN = PhraseGenerator.MAX_LEN;
    const REST = PhraseGenerator.REST;

    phrases: [SIZE][PLEN]u8 = .{.{0} ** PLEN} ** SIZE,
    lengths: [SIZE]u8 = .{0} ** SIZE,
    count: u8 = 0,
    write_pos: u8 = 0,

    pub fn store(self: *PhraseMemory, notes: *const [PLEN]u8, len: u8) void {
        self.phrases[self.write_pos] = notes.*;
        self.lengths[self.write_pos] = len;
        self.write_pos = (self.write_pos + 1) % SIZE;
        if (self.count < SIZE) self.count += 1;
    }

    /// Recall a stored phrase with random variation applied.
    /// Returns phrase length, fills `out` with notes. Returns null if memory empty.
    pub fn recallVaried(self: *const PhraseMemory, rng: *Rng, out: *[PLEN]u8, region_low: u8, region_high: u8) ?u8 {
        if (self.count == 0) return null;

        const idx = @as(u8, @intCast(rng.next() % self.count));
        const src = self.phrases[idx];
        const len = self.lengths[idx];
        if (len == 0) return null;

        const transform = rng.next() % 4;
        switch (transform) {
            0 => {
                // Transpose: shift all notes by +/-1 or +/-2
                const shift: i8 = switch (rng.next() % 4) {
                    0 => 1,
                    1 => -1,
                    2 => 2,
                    else => -2,
                };
                for (0..len) |i| {
                    if (src[i] == REST) {
                        out[i] = REST;
                    } else {
                        const raw: i16 = @as(i16, src[i]) + shift;
                        out[i] = @intCast(std.math.clamp(raw, @as(i16, region_low), @as(i16, region_high)));
                    }
                }
                return len;
            },
            1 => {
                // Retrograde: reverse note order
                for (0..len) |i| {
                    out[i] = src[len - 1 - i];
                }
                return len;
            },
            2 => {
                // Augment rests: insert rest after each note (half density)
                var out_len: u8 = 0;
                for (0..len) |i| {
                    if (out_len >= PLEN) break;
                    out[out_len] = src[i];
                    out_len += 1;
                    if (out_len < PLEN and src[i] != REST and rng.float() < 0.5) {
                        out[out_len] = REST;
                        out_len += 1;
                    }
                }
                return out_len;
            },
            else => {
                // Ornament: insert passing tones between steps
                var out_len: u8 = 0;
                for (0..len) |i| {
                    if (out_len >= PLEN) break;
                    out[out_len] = src[i];
                    out_len += 1;
                    // Insert passing tone between consecutive non-rest notes
                    if (i + 1 < len and src[i] != REST and src[i + 1] != REST and out_len < PLEN) {
                        const a: i16 = src[i];
                        const b: i16 = src[i + 1];
                        if (@abs(b - a) == 2) {
                            // There's room for a passing tone
                            out[out_len] = @intCast(std.math.clamp(@divTrunc(a + b, 2), @as(i16, region_low), @as(i16, region_high)));
                            out_len += 1;
                        }
                    }
                }
                return out_len;
            },
        }
    }
};

// ============================================================
// CueParams: parameter set that defines a cue "flavor"
// ============================================================

pub const CueParams = struct {
    density: f32 = 0.5, // note density (1 - rest_chance)
    energy: f32 = 0.5, // maps to filter range, attack speed, volume
    harmonic_tension: f32 = 0.3, // biases chord selection toward tension chords
    register_low: u8 = 5, // lowest scale degree for melodies
    register_high: u8 = 17, // highest scale degree
    scale_type: ScaleType = .minor_pentatonic,
    tempo_mult: f32 = 1.0, // relative BPM multiplier
    layer_weights: [6]f32 = .{ 1, 1, 1, 1, 1, 1 }, // per-layer volume targets

    /// Interpolate between two cue parameter sets.
    pub fn lerp(a: CueParams, b: CueParams, t: f32) CueParams {
        var result: CueParams = undefined;
        result.density = a.density + (b.density - a.density) * t;
        result.energy = a.energy + (b.energy - a.energy) * t;
        result.harmonic_tension = a.harmonic_tension + (b.harmonic_tension - a.harmonic_tension) * t;
        result.register_low = if (t < 0.5) a.register_low else b.register_low;
        result.register_high = if (t < 0.5) a.register_high else b.register_high;
        result.scale_type = if (t < 0.5) a.scale_type else b.scale_type;
        result.tempo_mult = a.tempo_mult + (b.tempo_mult - a.tempo_mult) * t;
        for (0..6) |i| {
            result.layer_weights[i] = a.layer_weights[i] + (b.layer_weights[i] - a.layer_weights[i]) * t;
        }
        return result;
    }
};

/// Manages smooth interpolation between two CueParams over time.
pub const CueInterpolator = struct {
    from: CueParams = .{},
    to: CueParams = .{},
    current: CueParams = .{},
    progress: f32 = 1.0, // 1.0 = fully arrived
    speed: f32 = 0.00002, // per-sample (~1 beat at 72bpm to complete)

    pub fn setCue(self: *CueInterpolator, target: CueParams) void {
        self.from = self.current;
        self.to = target;
        self.progress = 0;
    }

    pub fn advanceSample(self: *CueInterpolator) void {
        if (self.progress >= 1.0) return;
        self.progress = @min(self.progress + self.speed, 1.0);
        self.current = CueParams.lerp(self.from, self.to, self.progress);
    }
};

// ============================================================
// SlowLfo: ultra-slow modulation for organic movement
// ============================================================

pub const SlowLfo = struct {
    phase: f32 = 0,
    period_beats: f32 = 120,
    depth: f32 = 0.05,

    pub fn advanceSample(self: *SlowLfo, bpm_val: f32) void {
        self.phase += bpm_val / (SAMPLE_RATE * 60.0) * TAU / self.period_beats;
        if (self.phase > TAU) self.phase -= TAU;
    }

    /// Returns modulation multiplier: 1.0 +/- depth.
    pub fn modulate(self: *const SlowLfo) f32 {
        return 1.0 + @sin(self.phase) * self.depth;
    }

    /// Returns raw bipolar value: -depth to +depth.
    pub fn value(self: *const SlowLfo) f32 {
        return @sin(self.phase) * self.depth;
    }
};
