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
        cab_lpf_l: dsp.LPF = dsp.LPF.init(4500.0),
        cab_lpf_r: dsp.LPF = dsp.LPF.init(4500.0),
        cab_hpf_l: dsp.HPF = dsp.HPF.init(120.0),
        cab_hpf_r: dsp.HPF = dsp.HPF.init(120.0),
        body_lpf_l: dsp.LPF = dsp.LPF.init(2400.0),
        body_lpf_r: dsp.LPF = dsp.LPF.init(2400.0),
        air_hpf_l: dsp.HPF = dsp.HPF.init(2800.0),
        air_hpf_r: dsp.HPF = dsp.HPF.init(2800.0),
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

        const Self = @This();

        pub fn init(pan_spread: f32, unison_spread_val: f32, cab_lpf_hz: f32, cab_hpf_hz: f32) Self {
            var g: Self = .{};
            g.cab_lpf_l = dsp.LPF.init(cab_lpf_hz);
            g.cab_lpf_r = dsp.LPF.init(cab_lpf_hz);
            g.cab_hpf_l = dsp.HPF.init(cab_hpf_hz);
            g.cab_hpf_r = dsp.HPF.init(cab_hpf_hz);
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

        pub fn setFreqs(self: *Self, freqs: []const f32) void {
            for (0..@min(n_voices, freqs.len)) |i| {
                self.voices[i].freq = freqs[i];
                self.strings[i].setFreq(freqs[i] * (1.0 + (@as(f32, @floatFromInt(i)) - 1.0) * 0.0009));
            }
        }

        pub fn triggerEnv(self: *Self, attack: f32, decay: f32, sustain: f32, release: f32) void {
            for (0..n_voices) |idx| {
                self.triggerVoice(idx, attack, decay, sustain, release, 1.0);
            }
        }

        pub fn triggerVoice(self: *Self, voice_idx: usize, attack: f32, decay: f32, sustain: f32, release: f32, pick_strength: f32) void {
            if (voice_idx >= n_voices) {
                std.log.warn("ElectricGuitar.triggerVoice: voice index {d} out of range", .{voice_idx});
                return;
            }

            self.voices[voice_idx].env = dsp.Envelope.init(attack, decay, sustain, release);
            self.voices[voice_idx].env.trigger();
            self.pick_age[voice_idx] = 0;
            self.hold_age[voice_idx] = 0;
            self.hold_samples[voice_idx] = @intFromFloat((0.012 + sustain * 0.22 + decay * 0.08 + pick_strength * 0.01) * dsp.SAMPLE_RATE);
            self.pick_brightness[voice_idx] = (0.55 + sustain * 0.35 + (0.02 / @max(attack, 0.002)) * 0.08) * (0.78 + pick_strength * 0.3);
            self.strings[voice_idx].pluck(
                (0.12 + self.pick_brightness[voice_idx] * 0.2 + @as(f32, @floatFromInt(voice_idx)) * 0.012) * (0.82 + pick_strength * 0.26),
                self.pick_brightness[voice_idx] * (0.96 - @as(f32, @floatFromInt(voice_idx)) * 0.08),
            );
        }

        pub fn setCabinet(self: *Self, lpf_hz: f32, hpf_hz: f32) void {
            self.cab_lpf_l = dsp.LPF.init(lpf_hz);
            self.cab_lpf_r = dsp.LPF.init(lpf_hz);
            self.cab_hpf_l = dsp.HPF.init(hpf_hz);
            self.cab_hpf_r = dsp.HPF.init(hpf_hz);
            self.body_lpf_l = dsp.LPF.init(@max(1400.0, lpf_hz * 0.48));
            self.body_lpf_r = dsp.LPF.init(@max(1400.0, lpf_hz * 0.48));
            self.air_hpf_l = dsp.HPF.init(@max(2200.0, lpf_hz * 0.55));
            self.air_hpf_r = dsp.HPF.init(@max(2200.0, lpf_hz * 0.55));
            self.cab_res_a_l = .{ .feedback = 0.73 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.07), .damp = 0.42 };
            self.cab_res_a_r = .{ .feedback = 0.72 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.07), .damp = 0.44 };
            self.cab_res_b_l = .{ .feedback = 0.66 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.05), .damp = 0.36 };
            self.cab_res_b_r = .{ .feedback = 0.65 + std.math.clamp((lpf_hz - 2400.0) / 12000.0, 0.0, 0.05), .damp = 0.38 };
        }

        pub fn process(self: *Self, extra_drive: f32) [2]f32 {
            var left: f32 = 0.0;
            var right: f32 = 0.0;
            var total_env: f32 = 0.0;

            for (0..n_voices) |idx| {
                if (self.hold_age[idx] < self.hold_samples[idx]) {
                    self.hold_age[idx] += 1;
                } else if (self.voices[idx].env.state == .sustain) {
                    self.voices[idx].env.noteOff();
                }

                const raw = self.voices[idx].processRaw();
                if (raw.env_val <= 0.0001) continue;
                total_env += raw.env_val;

                const string_core = self.strings[idx].process();
                const string_body = self.strings[idx].line.tap(@max(1, self.strings[idx].delay_samples / 3));
                var wave = raw.osc * self.gain * 0.52;
                wave += string_core * (0.62 + extra_drive * 0.08);
                wave += string_body * 0.18;
                wave += @sin(self.voices[idx].phases[0] * 2.01) * 0.12 * raw.env_val;
                wave += @sin(self.voices[idx].phases[0] * 3.97) * 0.045 * raw.env_val;
                wave = overdrive(wave, self.od_amount + extra_drive);
                wave *= raw.env_val;

                const stereo = dsp.panStereo(wave, self.voices[idx].pan);
                left += stereo[0];
                right += stereo[1];

                if (self.pick_age[idx] < 4096) {
                    const age: f32 = @floatFromInt(self.pick_age[idx]);
                    const decay = @exp(-age * 0.0045);
                    const pick = (@sin(self.voices[idx].phases[0] * 11.0) + @sin(self.voices[idx].phases[0] * 17.0) * 0.65) * decay * self.pick_brightness[idx];
                    const pick_pan = self.voices[idx].pan * 0.8;
                    const pick_stereo = dsp.panStereo(pick, pick_pan);
                    left += self.air_hpf_l.process(pick_stereo[0] * 0.16);
                    right += self.air_hpf_r.process(pick_stereo[1] * 0.16);
                    self.pick_age[idx] += 1;
                }
            }

            if (total_env <= 0.0001) return .{ 0.0, 0.0 };

            if (self.voices[0].freq > 0.0) {
                self.sympathetic_phase += self.voices[0].freq * 0.5 * dsp.INV_SR * dsp.TAU;
                if (self.sympathetic_phase > dsp.TAU) self.sympathetic_phase -= dsp.TAU;
                self.body_phase_a += self.voices[0].freq * 1.01 * dsp.INV_SR * dsp.TAU;
                if (self.body_phase_a > dsp.TAU) self.body_phase_a -= dsp.TAU;
                self.body_phase_b += self.voices[0].freq * 2.03 * dsp.INV_SR * dsp.TAU;
                if (self.body_phase_b > dsp.TAU) self.body_phase_b -= dsp.TAU;
                const body_env = @min(total_env / @as(f32, @floatFromInt(n_voices)), 1.0);
                const body = (@sin(self.sympathetic_phase) * 0.7 + @sin(self.body_phase_a) * 0.22 + @sin(self.body_phase_b) * 0.12) * body_env * (0.1 + extra_drive * 0.05);
                left += self.body_lpf_l.process(body * 1.04);
                right += self.body_lpf_r.process(body * 0.96);
            }

            const amp_input = (left + right) * 0.5;
            self.speaker_sag += (@abs(amp_input) - self.speaker_sag) * 0.0035;
            const sag_amount = std.math.clamp(self.speaker_sag * 0.32, 0.0, 0.24);
            const amp_gain = 1.08 + extra_drive * 0.28 - sag_amount;
            left = overdrive(left, amp_gain);
            right = overdrive(right, amp_gain * 0.98);

            const cab_a_l = self.cab_res_a_l.process(left * 0.32);
            const cab_a_r = self.cab_res_a_r.process(right * 0.31);
            const cab_b_l = self.cab_res_b_l.process(left * 0.21);
            const cab_b_r = self.cab_res_b_r.process(right * 0.2);
            left += cab_a_l * 0.58 + cab_b_l * 0.34;
            right += cab_a_r * 0.56 + cab_b_r * 0.36;

            const mic_l = self.mic_delay_l.process(left + cab_a_l * 0.22, 7);
            const mic_r = self.mic_delay_r.process(right + cab_a_r * 0.2, 11);
            left = left * 0.82 + mic_l * 0.18;
            right = right * 0.8 + mic_r * 0.2;

            left = self.cab_hpf_l.process(left);
            left = self.cab_lpf_l.process(left);
            right = self.cab_hpf_r.process(right);
            right = self.cab_lpf_r.process(right);

            return .{ left, right };
        }
    };
}

pub const SawBass = struct {
    string: dsp.WaveguideString(4096) = .{},
    phase: f32 = 0,
    sub_phase: f32 = 0,
    overtone_phase: f32 = 0,
    freq: f32 = dsp.midiToFreq(40),
    env: dsp.Envelope = dsp.Envelope.init(0.002, 0.18, 0.0, 0.08),
    filter: dsp.LPF = dsp.LPF.init(800.0),
    drive: f32 = 0.55,
    sub_mix: f32 = 0.4,
    volume: f32 = 0.55,
    pluck_age: u32 = 999999,

    pub fn trigger(self: *SawBass, freq: f32) void {
        self.freq = freq;
        self.env.trigger();
        self.pluck_age = 0;
        self.string.setFreq(freq);
        self.string.pluck(0.22, 0.28 + self.drive * 0.22);
    }

    pub fn setFilter(self: *SawBass, cutoff: f32) void {
        self.filter = dsp.LPF.init(cutoff);
    }

    pub fn process(self: *SawBass) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.phase += self.freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
        self.sub_phase += self.freq * 0.5 * dsp.INV_SR * dsp.TAU;
        if (self.sub_phase > dsp.TAU) self.sub_phase -= dsp.TAU;
        self.overtone_phase += self.freq * 1.997 * dsp.INV_SR * dsp.TAU;
        if (self.overtone_phase > dsp.TAU) self.overtone_phase -= dsp.TAU;

        const saw = self.phase / std.math.pi - 1.0;
        const sub = @sin(self.sub_phase);
        const overtone = @sin(self.overtone_phase) * (0.14 + self.drive * 0.08);
        var sample = saw * (0.34 + self.drive * 0.2) + sub * self.sub_mix + overtone;
        sample += self.string.process() * (0.62 + self.drive * 0.14);
        if (self.pluck_age < 2400) {
            const age: f32 = @floatFromInt(self.pluck_age);
            const pluck = (@sin(self.phase * 7.0) + @sin(self.phase * 13.0) * 0.4) * @exp(-age * 0.006);
            sample += pluck * 0.12;
            self.pluck_age += 1;
        }
        sample = overdrive(sample, 1.05 + self.drive * 0.9);
        sample = self.filter.process(sample);
        sample *= 1.0 + self.drive * 0.45;
        return sample * env_val * self.volume;
    }
};

pub const Kick = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.16, 0.0, 0.1),
    base_freq: f32 = 44.0,
    sweep: f32 = 90.0,
    decay_rate: f32 = 0.993,
    volume: f32 = 1.5,
    click_age: u32 = 999999,
    click_level: f32 = 0.0,
    body_drive: f32 = 1.15,
    click_phase: f32 = 0.0,

    pub fn trigger(self: *Kick, accent: f32) void {
        self.env.trigger();
        self.pitch_env = accent;
        self.click_age = 0;
        self.click_level = 0.08 + accent * 0.14;
        self.click_phase = 0.0;
        self.configureResonators(accent);
        self.resonators.excite(.{ 0.95, 0.42, 0.18 }, 0.8 + accent * 0.4);
    }

    pub fn process(self: *Kick) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.pitch_env *= self.decay_rate;
        const drift = self.pitch_env * self.sweep;
        self.resonators.freqs[0] = self.base_freq + drift;
        self.resonators.freqs[1] = (self.base_freq + drift * 0.65) * 1.92;
        self.resonators.freqs[2] = (self.base_freq + drift * 0.35) * 3.08;

        var click: f32 = 0.0;
        if (self.click_age < 1400) {
            self.click_phase += (self.base_freq + drift * 1.6) * dsp.INV_SR * dsp.TAU;
            if (self.click_phase > dsp.TAU) self.click_phase -= dsp.TAU;
            click = dsp.exciterPulseBurst(self.click_phase, self.click_age, 0.01, self.click_level);
            self.click_age += 1;
        }

        var body = self.resonators.process();
        body = overdrive(body, self.body_drive + self.pitch_env * 0.35);
        return (body + click) * env_val * self.volume;
    }

    fn configureResonators(self: *Kick, accent: f32) void {
        self.resonators.configure(
            .{
                self.base_freq + accent * self.sweep,
                (self.base_freq + accent * self.sweep * 0.65) * 1.92,
                (self.base_freq + accent * self.sweep * 0.35) * 3.08,
            },
            .{ 0.99965, 0.9992, 0.9988 },
        );
    }
};

pub const Snare = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.12, 0.0, 0.06),
    noise_lpf: dsp.LPF = dsp.LPF.init(3400.0),
    noise_hpf: dsp.HPF = dsp.HPF.init(1200.0),
    tone_freq: f32 = 190.0,
    noise_mix: f32 = 0.78,
    body_mix: f32 = 0.35,
    snap_mix: f32 = 0.14,
    strike_age: u32 = 999999,

    pub fn trigger(self: *Snare) void {
        self.noise_hpf = dsp.HPF.init(1400.0);
        self.configureResonators(false);
        self.resonators.excite(.{ 0.55, 0.22, 0.12 }, 1.0);
        self.strike_age = 0;
        self.env.trigger();
    }

    pub fn triggerGhost(self: *Snare) void {
        self.env = dsp.Envelope.init(0.001, 0.06, 0.0, 0.03);
        self.noise_hpf = dsp.HPF.init(1800.0);
        self.configureResonators(true);
        self.resonators.excite(.{ 0.28, 0.12, 0.06 }, 0.7);
        self.strike_age = 0;
        self.env.trigger();
    }

    pub fn process(self: *Snare, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        const noise = self.noise_hpf.process(self.noise_lpf.process(rng_inst.float() * 2.0 - 1.0));
        const tone = self.resonators.process();
        var strike_noise: f32 = 0.0;
        if (self.strike_age < 2200) {
            strike_noise = dsp.exciterNoiseBurst(rng_inst, &self.noise_hpf, &self.noise_lpf, self.strike_age, 0.0065, 0.24);
            self.strike_age += 1;
        }
        const snap = (strike_noise * 0.7 + noise * 0.3) * self.snap_mix;
        return (noise * self.noise_mix + tone * self.body_mix + snap) * env_val;
    }

    fn configureResonators(self: *Snare, ghost: bool) void {
        self.resonators.configure(
            .{
                self.tone_freq,
                self.tone_freq * 1.84,
                self.tone_freq * 2.67,
            },
            if (ghost)
                .{ 0.9982, 0.9978, 0.9972 }
            else
                .{ 0.99915, 0.99875, 0.9981 },
        );
    }
};

pub const HiHat = struct {
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.03, 0.0, 0.02),
    hpf: dsp.HPF = dsp.HPF.init(6000.0),
    volume: f32 = 0.45,
    phases: [6]f32 = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },

    pub fn trigger(self: *HiHat) void {
        self.env.trigger();
    }

    pub fn process(self: *HiHat, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;
        const ratios = [_]f32{ 1.0, 1.41, 1.73, 2.37, 3.11, 4.35 };
        var metal: f32 = 0.0;
        for (0..self.phases.len) |idx| {
            self.phases[idx] += 6200.0 * ratios[idx] * dsp.INV_SR * dsp.TAU;
            if (self.phases[idx] > dsp.TAU) self.phases[idx] -= dsp.TAU;
            metal += @sin(self.phases[idx]) * (0.22 - @as(f32, @floatFromInt(idx)) * 0.02);
        }
        const noise = self.hpf.process(rng_inst.float() * 2.0 - 1.0);
        return (noise * 0.62 + metal * 0.38) * env_val * self.volume;
    }
};

pub const DjembeStroke = enum { bass, tone, slap };

pub const Djembe = struct {
    resonators: dsp.ResonatorBank(3) = .{},
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.12, 0.0, 0.06),
    noise_lpf: dsp.LPF = dsp.LPF.init(1800.0),
    noise_hpf: dsp.HPF = dsp.HPF.init(400.0),
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

    pub fn triggerBass(self: *Djembe, vel: f32) void {
        self.velocity = vel;
        self.current_freq = self.base_freq * 0.19;
        self.pitch_env = 1.0;
        self.pitch_decay = 0.9985;
        self.noise_mix = 0.08;
        self.body_mix = 0.95;
        self.harmonic_mix = 0.22;
        self.noise_lpf = dsp.LPF.init(600.0);
        self.configureResonators(.bass);
        self.resonators.excite(.{ 0.95, 0.28, 0.12 }, vel);
        self.strike_age = 0;
        self.env.retrigger(0.001, 0.22, 0.0, 0.12);
    }

    pub fn triggerTone(self: *Djembe, vel: f32) void {
        self.velocity = vel;
        self.current_freq = self.base_freq;
        self.pitch_env = 0.4;
        self.pitch_decay = 0.9992;
        self.noise_mix = 0.18;
        self.body_mix = 0.82;
        self.harmonic_mix = 0.12;
        self.noise_lpf = dsp.LPF.init(2400.0);
        self.configureResonators(.tone);
        self.resonators.excite(.{ 0.72, 0.24, 0.1 }, vel);
        self.strike_age = 0;
        self.env.retrigger(0.001, 0.11, 0.0, 0.055);
    }

    pub fn triggerSlap(self: *Djembe, vel: f32) void {
        self.velocity = vel;
        self.current_freq = self.base_freq * 2.3;
        self.pitch_env = 0.8;
        self.pitch_decay = 0.9975;
        self.noise_mix = 0.58;
        self.body_mix = 0.32;
        self.harmonic_mix = 0.06;
        self.noise_lpf = dsp.LPF.init(5500.0);
        self.noise_hpf = dsp.HPF.init(1200.0);
        self.configureResonators(.slap);
        self.resonators.excite(.{ 0.35, 0.14, 0.08 }, vel * 0.8);
        self.strike_age = 0;
        self.env.retrigger(0.001, 0.04, 0.0, 0.02);
    }

    pub fn triggerGhost(self: *Djembe, vel: f32, stroke: DjembeStroke) void {
        switch (stroke) {
            .tone => self.triggerTone(vel * 0.3),
            .slap => self.triggerSlap(vel * 0.25),
            .bass => self.triggerBass(vel * 0.25),
        }
        self.env.retrigger(0.001, 0.04, 0.0, 0.02);
    }

    pub fn process(self: *Djembe, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.pitch_env *= self.pitch_decay;
        const freq = self.current_freq * (1.0 + self.pitch_env * 0.35);

        self.harmonic_phase += freq * 1.506 * dsp.INV_SR * dsp.TAU;
        if (self.harmonic_phase > dsp.TAU) self.harmonic_phase -= dsp.TAU;

        self.resonators.freqs[0] = freq;
        self.resonators.freqs[1] = freq * 1.51;
        self.resonators.freqs[2] = freq * 2.18;
        const body = self.resonators.process() + @sin(self.harmonic_phase) * self.harmonic_mix * 0.2;
        const raw_noise = rng_inst.float() * 2.0 - 1.0;
        var noise = self.noise_hpf.process(self.noise_lpf.process(raw_noise));
        if (self.strike_age < 2400) {
            noise += dsp.exciterNoiseBurst(rng_inst, &self.noise_hpf, &self.noise_lpf, self.strike_age, 0.006, 0.18);
            self.strike_age += 1;
        }

        return (body * self.body_mix + noise * self.noise_mix) * env_val * self.velocity * self.volume;
    }

    fn configureResonators(self: *Djembe, stroke: DjembeStroke) void {
        switch (stroke) {
            .bass => self.resonators.configure(
                .{ self.base_freq * 0.19, self.base_freq * 0.31, self.base_freq * 0.46 },
                .{ 0.99945, 0.9991, 0.9988 },
            ),
            .tone => self.resonators.configure(
                .{ self.base_freq, self.base_freq * 1.51, self.base_freq * 2.18 },
                .{ 0.9991, 0.9986, 0.9982 },
            ),
            .slap => self.resonators.configure(
                .{ self.base_freq * 2.3, self.base_freq * 3.1, self.base_freq * 4.26 },
                .{ 0.9982, 0.9978, 0.9972 },
            ),
        }
    }
};

pub const Dunun = struct {
    phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.18, 0.0, 0.1),
    body_lpf: dsp.LPF = dsp.LPF.init(250.0),
    base_freq: f32 = 82.0,
    sweep: f32 = 40.0,
    decay_rate: f32 = 0.9988,
    volume: f32 = 1.0,
    bell_phase: f32 = 0,
    bell_freq: f32 = 0,
    bell_env: dsp.Envelope = dsp.Envelope.init(0.001, 0.025, 0.0, 0.012),
    bell_volume: f32 = 0.35,

    pub fn triggerDrum(self: *Dunun, vel: f32) void {
        self.env.retrigger(0.001, 0.18, 0.0, 0.1);
        self.pitch_env = vel;
    }

    pub fn triggerBell(self: *Dunun) void {
        self.bell_env.retrigger(0.001, 0.025, 0.0, 0.012);
    }

    pub fn process(self: *Dunun, rng_inst: *dsp.Rng) [2]f32 {
        var drum_s: f32 = 0.0;
        const drum_env = self.env.process();
        if (drum_env > 0.0001) {
            self.pitch_env *= self.decay_rate;
            const freq = self.base_freq + self.pitch_env * self.sweep;
            self.phase += freq * dsp.INV_SR * dsp.TAU;
            if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
            drum_s = self.body_lpf.process(@sin(self.phase)) * drum_env * self.volume;
        }

        var bell_s: f32 = 0.0;
        const bell_env = self.bell_env.process();
        if (bell_env > 0.0001) {
            self.bell_phase += self.bell_freq * dsp.INV_SR * dsp.TAU;
            if (self.bell_phase > dsp.TAU) self.bell_phase -= dsp.TAU;
            const tone = @sin(self.bell_phase) * 0.6 + @sin(self.bell_phase * 2.71) * 0.3;
            bell_s = tone * bell_env * self.bell_volume + (rng_inst.float() * 2.0 - 1.0) * bell_env * 0.04;
        }

        return .{ drum_s, bell_s };
    }
};

// Japanese taiko instruments

pub const TaikoStroke = enum { don, ka, ghost };

pub const Odaiko = struct {
    phase: f32 = 0,
    sub_phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.002, 1.2, 0.0, 0.8),
    body_lpf: dsp.LPF = dsp.LPF.init(120.0),
    base_freq: f32 = 48.0,
    sweep: f32 = 55.0,
    decay_rate: f32 = 0.9997,
    volume: f32 = 1.4,
    velocity: f32 = 0.0,

    pub fn triggerDon(self: *Odaiko, vel: f32) void {
        self.velocity = vel;
        self.pitch_env = vel;
        self.body_lpf = dsp.LPF.init(100.0 + vel * 60.0);
        self.env.retrigger(0.002, 1.2, 0.0, 0.8);
    }

    pub fn triggerGhost(self: *Odaiko, vel: f32) void {
        self.velocity = vel * 0.3;
        self.pitch_env = vel * 0.2;
        self.body_lpf = dsp.LPF.init(80.0);
        self.env.retrigger(0.003, 0.4, 0.0, 0.2);
    }

    pub fn process(self: *Odaiko) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.pitch_env *= self.decay_rate;
        const freq = self.base_freq + self.pitch_env * self.sweep;
        self.phase += freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
        self.sub_phase += freq * 0.5 * dsp.INV_SR * dsp.TAU;
        if (self.sub_phase > dsp.TAU) self.sub_phase -= dsp.TAU;

        const body = @sin(self.phase) * 0.75 + @sin(self.sub_phase) * 0.35;
        return self.body_lpf.process(body) * env_val * self.velocity * self.volume;
    }
};

pub const Nagado = struct {
    phase: f32 = 0,
    overtone_phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.28, 0.0, 0.14),
    body_lpf: dsp.LPF = dsp.LPF.init(600.0),
    noise_lpf: dsp.LPF = dsp.LPF.init(2400.0),
    noise_hpf: dsp.HPF = dsp.HPF.init(800.0),
    base_freq: f32 = 140.0,
    noise_mix: f32 = 0.12,
    body_mix: f32 = 0.88,
    velocity: f32 = 0.0,
    pitch_decay: f32 = 0.999,
    volume: f32 = 0.85,

    pub fn triggerDon(self: *Nagado, vel: f32) void {
        self.velocity = vel;
        self.pitch_env = 0.6;
        self.pitch_decay = 0.9992;
        self.noise_mix = 0.12;
        self.body_mix = 0.88;
        self.body_lpf = dsp.LPF.init(self.base_freq * 3.5);
        self.noise_lpf = dsp.LPF.init(1800.0);
        self.env.retrigger(0.001, 0.28, 0.0, 0.14);
    }

    pub fn triggerKa(self: *Nagado, vel: f32) void {
        self.velocity = vel;
        self.pitch_env = 0.3;
        self.pitch_decay = 0.998;
        self.noise_mix = 0.72;
        self.body_mix = 0.18;
        self.body_lpf = dsp.LPF.init(4200.0);
        self.noise_lpf = dsp.LPF.init(6500.0);
        self.noise_hpf = dsp.HPF.init(1800.0);
        self.env.retrigger(0.001, 0.035, 0.0, 0.018);
    }

    pub fn triggerGhost(self: *Nagado, vel: f32) void {
        self.triggerDon(vel * 0.25);
        self.env.retrigger(0.001, 0.06, 0.0, 0.03);
    }

    pub fn process(self: *Nagado, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.pitch_env *= self.pitch_decay;
        const freq = self.base_freq * (1.0 + self.pitch_env * 0.25);
        self.phase += freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
        self.overtone_phase += freq * 1.58 * dsp.INV_SR * dsp.TAU;
        if (self.overtone_phase > dsp.TAU) self.overtone_phase -= dsp.TAU;

        const body = self.body_lpf.process(@sin(self.phase) + @sin(self.overtone_phase) * 0.18);
        const raw_noise = rng_inst.float() * 2.0 - 1.0;
        const noise = self.noise_hpf.process(self.noise_lpf.process(raw_noise));

        return (body * self.body_mix + noise * self.noise_mix) * env_val * self.velocity * self.volume;
    }
};

pub const Shime = struct {
    phase: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.035, 0.0, 0.018),
    body_lpf: dsp.LPF = dsp.LPF.init(1200.0),
    noise_lpf: dsp.LPF = dsp.LPF.init(4500.0),
    base_freq: f32 = 420.0,
    volume: f32 = 0.6,
    velocity: f32 = 0.0,

    pub fn triggerDon(self: *Shime, vel: f32) void {
        self.velocity = vel;
        self.body_lpf = dsp.LPF.init(self.base_freq * 2.5);
        self.env.retrigger(0.001, 0.045, 0.0, 0.022);
    }

    pub fn triggerKa(self: *Shime, vel: f32) void {
        self.velocity = vel;
        self.body_lpf = dsp.LPF.init(5500.0);
        self.env.retrigger(0.001, 0.02, 0.0, 0.01);
    }

    pub fn triggerRoll(self: *Shime, vel: f32) void {
        self.velocity = vel * 0.55;
        self.body_lpf = dsp.LPF.init(self.base_freq * 2.0);
        self.env.retrigger(0.001, 0.015, 0.0, 0.008);
    }

    pub fn process(self: *Shime, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.phase += self.base_freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;

        const body = self.body_lpf.process(@sin(self.phase)) * 0.45;
        const noise = self.noise_lpf.process(rng_inst.float() * 2.0 - 1.0) * 0.55;
        return (body + noise) * env_val * self.velocity * self.volume;
    }
};

pub const Atarigane = struct {
    resonators: dsp.ResonatorBank(4) = .{},
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.08, 0.0, 0.04),
    hpf: dsp.HPF = dsp.HPF.init(1200.0),
    noise_lpf: dsp.LPF = dsp.LPF.init(7200.0),
    base_freq: f32 = 920.0,
    volume: f32 = 0.35,
    velocity: f32 = 0.0,
    muted: bool = false,
    strike_age: u32 = 999999,

    pub fn triggerOpen(self: *Atarigane, vel: f32) void {
        self.velocity = vel;
        self.muted = false;
        self.configureModes();
        self.resonators.excite(.{ 0.7, 0.42, 0.28, 0.16 }, vel);
        self.env.retrigger(0.001, 0.12, 0.0, 0.06);
        self.strike_age = 0;
    }

    pub fn triggerMuted(self: *Atarigane, vel: f32) void {
        self.velocity = vel;
        self.muted = true;
        self.configureModes();
        self.resonators.excite(.{ 0.45, 0.24, 0.12, 0.06 }, vel * 0.8);
        self.env.retrigger(0.001, 0.025, 0.0, 0.012);
        self.strike_age = 0;
    }

    pub fn process(self: *Atarigane, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        var tone = self.resonators.process();
        if (self.strike_age < 2800) {
            tone += dsp.exciterNoiseBurst(rng_inst, &self.hpf, &self.noise_lpf, self.strike_age, if (self.muted) 0.015 else 0.007, 0.18);
            self.strike_age += 1;
        }
        tone = self.hpf.process(tone);

        if (self.muted) tone *= 0.4;
        return tone * env_val * self.velocity * self.volume;
    }

    fn configureModes(self: *Atarigane) void {
        self.resonators.configure(
            .{
                self.base_freq,
                self.base_freq * 2.31,
                self.base_freq * 3.89,
                self.base_freq * 5.12,
            },
            .{
                if (self.muted) 0.9974 else 0.9992,
                if (self.muted) 0.9971 else 0.9988,
                if (self.muted) 0.9968 else 0.9984,
                if (self.muted) 0.9964 else 0.998,
            },
        );
    }
};

pub const SineDrone = struct {
    phases: [2]f32 = .{ 0.0, 0.0 },
    freq: f32 = dsp.midiToFreq(36),
    detune_ratio: f32 = 1.002,
    primary_mix: f32 = 1.0,
    secondary_mix: f32 = 0.5,
    volume: f32 = 0.02,
    filter: dsp.LPF = dsp.LPF.init(120.0),

    pub fn init(freq: f32, cutoff_hz: f32, detune_ratio: f32, primary_mix: f32, secondary_mix: f32, volume: f32) SineDrone {
        return .{
            .freq = freq,
            .detune_ratio = detune_ratio,
            .primary_mix = primary_mix,
            .secondary_mix = secondary_mix,
            .volume = volume,
            .filter = dsp.LPF.init(cutoff_hz),
        };
    }

    pub fn process(self: *SineDrone) f32 {
        self.phases[0] += self.freq * dsp.INV_SR * dsp.TAU;
        if (self.phases[0] > dsp.TAU) self.phases[0] -= dsp.TAU;
        self.phases[1] += self.freq * self.detune_ratio * dsp.INV_SR * dsp.TAU;
        if (self.phases[1] > dsp.TAU) self.phases[1] -= dsp.TAU;

        var sample = @sin(self.phases[0]) * self.primary_mix + @sin(self.phases[1]) * self.secondary_mix;
        sample = self.filter.process(sample);
        return sample * self.volume;
    }
};

pub const ChoirPart = struct {
    voice: dsp.Voice(3, 4) = .{ .vibrato_rate_hz = 5.1, .vibrato_depth = 0.0045 },
    formant_a: dsp.LPF = dsp.LPF.init(700.0),
    formant_b: dsp.LPF = dsp.LPF.init(1200.0),
    formant_c: dsp.LPF = dsp.LPF.init(2400.0),
    breath_hpf: dsp.HPF = dsp.HPF.init(1800.0),
    chest_lpf: dsp.LPF = dsp.LPF.init(320.0),
    vibrato_phase: f32 = 0.0,
    pan: f32 = 0.0,
    vowel_mix: f32 = 0.45,
    breath_mix: f32 = 0.08,
    chest_mix: f32 = 0.18,

    pub fn init(unison_spread: f32, pan: f32, vowel_idx: u8) ChoirPart {
        var part: ChoirPart = .{
            .voice = .{ .unison_spread = unison_spread, .vibrato_rate_hz = 5.1, .vibrato_depth = 0.0045 },
            .pan = pan,
        };
        part.setVowel(vowel_idx);
        return part;
    }

    pub fn setVowel(self: *ChoirPart, vowel_idx: u8) void {
        switch (vowel_idx) {
            0 => {
                self.formant_a = dsp.LPF.init(620.0);
                self.formant_b = dsp.LPF.init(1180.0);
                self.formant_c = dsp.LPF.init(2450.0);
                self.vowel_mix = 0.34;
                self.breath_mix = 0.06;
            },
            1 => {
                self.formant_a = dsp.LPF.init(540.0);
                self.formant_b = dsp.LPF.init(920.0);
                self.formant_c = dsp.LPF.init(2280.0);
                self.vowel_mix = 0.42;
                self.breath_mix = 0.08;
            },
            2 => {
                self.formant_a = dsp.LPF.init(420.0);
                self.formant_b = dsp.LPF.init(780.0);
                self.formant_c = dsp.LPF.init(2050.0);
                self.vowel_mix = 0.58;
                self.breath_mix = 0.11;
            },
            else => {
                self.formant_a = dsp.LPF.init(760.0);
                self.formant_b = dsp.LPF.init(1520.0);
                self.formant_c = dsp.LPF.init(2680.0);
                self.vowel_mix = 0.48;
                self.breath_mix = 0.07;
            },
        }
    }

    pub fn trigger(self: *ChoirPart, freq: f32, env: dsp.Envelope) void {
        self.voice.trigger(freq, env);
    }

    pub fn process(self: *ChoirPart) f32 {
        const raw = self.voice.processRaw();
        if (raw.env_val <= 0.0001) return 0.0;

        self.vibrato_phase += 0.000013 * dsp.TAU;
        if (self.vibrato_phase > dsp.TAU) self.vibrato_phase -= dsp.TAU;

        const vibrato = @sin(self.vibrato_phase) * 0.018;
        const source = raw.osc + @sin(self.voice.phases[0] * 0.5 + vibrato) * 0.08;
        const fa = self.formant_a.process(source);
        const fb = self.formant_b.process(source);
        const fc = self.formant_c.process(source);
        const chest = self.chest_lpf.process(source) * self.chest_mix;
        const breath = self.breath_hpf.process(@sin(self.voice.phases[0] * 9.0) * 0.2 + source * 0.1) * self.breath_mix;
        const filtered = fa * (1.0 - self.vowel_mix) + fb * self.vowel_mix + fc * 0.22 + chest + breath;
        return filtered * raw.env_val;
    }
};

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
    env: dsp.Envelope = dsp.Envelope.init(0.01, 1.8, 0.0, 1.5),
    filter: dsp.LPF = dsp.LPF.init(2400.0),
    resonance_filter: dsp.LPF = dsp.LPF.init(1800.0),
    hammer_age: u32 = 999999,
    active: bool = false,
    unison_mix: f32 = 0.42,
    sub_mix: f32 = 0.12,
    bell_mix: f32 = 0.12,
    resonance_mix: f32 = 0.16,

    pub fn init(pan: f32, flutter_phase: f32) PianoVoice {
        return .{
            .pan = pan,
            .flutter_phase = flutter_phase,
        };
    }

    pub fn trigger(self: *PianoVoice, freq: f32, velocity: f32, cutoff_hz: f32, env: dsp.Envelope) void {
        self.freq = freq;
        self.velocity = velocity;
        self.filter = dsp.LPF.init(cutoff_hz);
        self.resonance_filter = dsp.LPF.init(cutoff_hz * 0.72);
        self.env = env;
        self.env.trigger();
        self.hammer_age = 0;
        self.active = true;
        self.strings[0].setFreq(freq);
        self.strings[1].setFreq(freq * 1.0009);
        self.strings[2].setFreq(freq * 0.9991);
        self.strings[0].pluck(0.18 + velocity * 0.22, 0.38);
        self.strings[1].pluck(0.16 + velocity * 0.2, 0.34);
        self.strings[2].pluck(0.15 + velocity * 0.18, 0.3);
    }

    pub fn process(self: *PianoVoice, rng_inst: *dsp.Rng, wow_amount: f32, bell_tone: f32, attack_softness: f32, hammer_level: f32) f32 {
        const env_val = self.env.process();
        if (!self.active and env_val < 0.001) return 0.0;
        if (env_val < 0.001) self.active = false;

        self.flutter_phase += 0.00004 * dsp.TAU;
        if (self.flutter_phase > dsp.TAU) self.flutter_phase -= dsp.TAU;

        const flutter = @sin(self.flutter_phase) * (0.0002 + wow_amount * 0.0022);
        const carrier_freq = self.freq * (1.0 + flutter);
        const mod_freq = carrier_freq * self.mod_ratio;
        self.mod_phase += mod_freq * dsp.INV_SR * dsp.TAU;
        if (self.mod_phase > dsp.TAU) self.mod_phase -= dsp.TAU;

        const fm_amount = 0.12 + bell_tone * 0.95;
        const mod_signal = @sin(self.mod_phase) * self.mod_depth * env_val * fm_amount;

        self.carrier_phase += carrier_freq * dsp.INV_SR * dsp.TAU;
        if (self.carrier_phase > dsp.TAU) self.carrier_phase -= dsp.TAU;

        self.detune_phase += carrier_freq * self.detune_ratio * dsp.INV_SR * dsp.TAU;
        if (self.detune_phase > dsp.TAU) self.detune_phase -= dsp.TAU;
        self.resonance_phase_a += carrier_freq * 2.01 * dsp.INV_SR * dsp.TAU;
        if (self.resonance_phase_a > dsp.TAU) self.resonance_phase_a -= dsp.TAU;
        self.resonance_phase_b += carrier_freq * 2.99 * dsp.INV_SR * dsp.TAU;
        if (self.resonance_phase_b > dsp.TAU) self.resonance_phase_b -= dsp.TAU;

        var body = @sin(self.carrier_phase + mod_signal);
        body += @sin(self.detune_phase + mod_signal * 0.6) * self.unison_mix;
        body += @sin(self.carrier_phase * 0.5) * self.sub_mix;
        body += @sin(self.carrier_phase * 2.0 + mod_signal * 0.3) * (0.018 + bell_tone * self.bell_mix);
        body += (self.strings[0].process() + self.strings[1].process() * 0.92 + self.strings[2].process() * 0.88) * 0.42;
        body = self.filter.process(body);

        var resonance = @sin(self.resonance_phase_a) * 0.12 + @sin(self.resonance_phase_b) * 0.08;
        resonance += @sin(self.carrier_phase * 4.07) * 0.04;
        resonance = self.resonance_filter.process(resonance) * (0.4 + env_val * 0.6);

        var hammer: f32 = 0.0;
        if (self.hammer_age < 4096) {
            const age: f32 = @floatFromInt(self.hammer_age);
            const decay = @exp(-age * (0.0038 + attack_softness * 0.0024));
            const felt = self.filter.process((rng_inst.float() * 2.0 - 1.0) * 0.18 + @sin(self.carrier_phase * 5.0) * 0.25);
            hammer = (felt * 1.8 + @sin(self.carrier_phase * 9.0) * 0.12) * decay;
            self.hammer_age += 1;
        }

        return (body + resonance * self.resonance_mix + hammer * hammer_level) * env_val * self.velocity;
    }
};
