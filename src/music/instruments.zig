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

    return struct {
        voices: [n_voices]GuitarVoice = .{GuitarVoice{}} ** n_voices,
        env: dsp.Envelope = dsp.Envelope.init(0.004, 0.36, 0.0, 0.14),
        cab_lpf_l: dsp.LPF = dsp.LPF.init(4500.0),
        cab_lpf_r: dsp.LPF = dsp.LPF.init(4500.0),
        cab_hpf_l: dsp.HPF = dsp.HPF.init(120.0),
        cab_hpf_r: dsp.HPF = dsp.HPF.init(120.0),
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
            }
            return g;
        }

        pub fn setFreqs(self: *Self, freqs: []const f32) void {
            for (0..@min(n_voices, freqs.len)) |i| {
                self.voices[i].freq = freqs[i];
            }
        }

        pub fn triggerEnv(self: *Self, attack: f32, decay: f32, sustain: f32, release: f32) void {
            self.env = dsp.Envelope.init(attack, decay, sustain, release);
            self.env.trigger();
        }

        pub fn setCabinet(self: *Self, lpf_hz: f32, hpf_hz: f32) void {
            self.cab_lpf_l = dsp.LPF.init(lpf_hz);
            self.cab_lpf_r = dsp.LPF.init(lpf_hz);
            self.cab_hpf_l = dsp.HPF.init(hpf_hz);
            self.cab_hpf_r = dsp.HPF.init(hpf_hz);
        }

        pub fn process(self: *Self, extra_drive: f32) [2]f32 {
            const env_val = self.env.process();
            if (env_val <= 0.0001) return .{ 0.0, 0.0 };

            var left: f32 = 0.0;
            var right: f32 = 0.0;

            for (0..n_voices) |idx| {
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

                const stereo = dsp.panStereo(wave, self.voices[idx].pan);
                left += stereo[0];
                right += stereo[1];
            }

            left = self.cab_hpf_l.process(left);
            left = self.cab_lpf_l.process(left);
            right = self.cab_hpf_r.process(right);
            right = self.cab_lpf_r.process(right);

            return .{ left, right };
        }
    };
}

pub const SawBass = struct {
    phase: f32 = 0,
    sub_phase: f32 = 0,
    freq: f32 = dsp.midiToFreq(40),
    env: dsp.Envelope = dsp.Envelope.init(0.002, 0.18, 0.0, 0.08),
    filter: dsp.LPF = dsp.LPF.init(800.0),
    drive: f32 = 0.55,
    sub_mix: f32 = 0.4,
    volume: f32 = 0.55,

    pub fn trigger(self: *SawBass, freq: f32) void {
        self.freq = freq;
        self.env.trigger();
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

        const saw = self.phase / std.math.pi - 1.0;
        const sub = @sin(self.sub_phase);
        var sample = saw * (0.6 + self.drive * 0.35) + sub * self.sub_mix;
        sample = self.filter.process(sample);
        sample *= 1.0 + self.drive * 0.45;
        return sample * env_val * self.volume;
    }
};

pub const Kick = struct {
    phase: f32 = 0,
    pitch_env: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.16, 0.0, 0.1),
    sample_count: f32 = 0,
    base_freq: f32 = 44.0,
    sweep: f32 = 90.0,
    decay_rate: f32 = 0.993,
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
        self.phase += freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
        self.sample_count += 1;
        return @sin(self.phase) * env_val * self.volume;
    }
};

pub const Snare = struct {
    phase: f32 = 0,
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.12, 0.0, 0.06),
    noise_lpf: dsp.LPF = dsp.LPF.init(3400.0),
    body_lpf: dsp.LPF = dsp.LPF.init(2200.0),
    tone_freq: f32 = 190.0,
    noise_mix: f32 = 0.78,
    body_mix: f32 = 0.35,

    pub fn trigger(self: *Snare) void {
        self.env.trigger();
    }

    pub fn triggerGhost(self: *Snare) void {
        self.env = dsp.Envelope.init(0.001, 0.06, 0.0, 0.03);
        self.env.trigger();
    }

    pub fn process(self: *Snare, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;

        self.phase += self.tone_freq * dsp.INV_SR * dsp.TAU;
        if (self.phase > dsp.TAU) self.phase -= dsp.TAU;
        const noise = self.noise_lpf.process(rng_inst.float() * 2.0 - 1.0);
        const tone = self.body_lpf.process(@sin(self.phase));
        return (noise * self.noise_mix + tone * self.body_mix) * env_val;
    }
};

pub const HiHat = struct {
    env: dsp.Envelope = dsp.Envelope.init(0.001, 0.03, 0.0, 0.02),
    hpf: dsp.HPF = dsp.HPF.init(6000.0),
    volume: f32 = 0.45,

    pub fn trigger(self: *HiHat) void {
        self.env.trigger();
    }

    pub fn process(self: *HiHat, rng_inst: *dsp.Rng) f32 {
        const env_val = self.env.process();
        if (env_val <= 0.0001) return 0.0;
        const noise = self.hpf.process(rng_inst.float() * 2.0 - 1.0);
        return noise * env_val * self.volume;
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
    voice: dsp.Voice(3, 4) = .{},
    formant_a: dsp.LPF = dsp.LPF.init(700.0),
    formant_b: dsp.LPF = dsp.LPF.init(1200.0),
    pan: f32 = 0.0,
    vowel_mix: f32 = 0.45,

    pub fn init(unison_spread: f32, pan: f32, vowel_idx: u8) ChoirPart {
        var part: ChoirPart = .{
            .voice = .{ .unison_spread = unison_spread },
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
                self.vowel_mix = 0.34;
            },
            1 => {
                self.formant_a = dsp.LPF.init(540.0);
                self.formant_b = dsp.LPF.init(920.0);
                self.vowel_mix = 0.42;
            },
            2 => {
                self.formant_a = dsp.LPF.init(420.0);
                self.formant_b = dsp.LPF.init(780.0);
                self.vowel_mix = 0.58;
            },
            else => {
                self.formant_a = dsp.LPF.init(760.0);
                self.formant_b = dsp.LPF.init(1520.0);
                self.vowel_mix = 0.48;
            },
        }
    }

    pub fn trigger(self: *ChoirPart, freq: f32, env: dsp.Envelope) void {
        self.voice.trigger(freq, env);
    }

    pub fn process(self: *ChoirPart) f32 {
        const raw = self.voice.processRaw();
        if (raw.env_val <= 0.0001) return 0.0;

        const fa = self.formant_a.process(raw.osc);
        const fb = self.formant_b.process(raw.osc);
        const filtered = fa * (1.0 - self.vowel_mix) + fb * self.vowel_mix;
        return filtered * raw.env_val;
    }
};

pub const PianoVoice = struct {
    carrier_phase: f32 = 0.0,
    detune_phase: f32 = 0.0,
    mod_phase: f32 = 0.0,
    flutter_phase: f32 = 0.0,
    freq: f32 = dsp.midiToFreq(60),
    detune_ratio: f32 = 1.001,
    mod_ratio: f32 = 3.0,
    mod_depth: f32 = 0.5,
    velocity: f32 = 1.0,
    pan: f32 = 0.0,
    env: dsp.Envelope = dsp.Envelope.init(0.01, 1.8, 0.0, 1.5),
    filter: dsp.LPF = dsp.LPF.init(2400.0),
    hammer_age: u32 = 999999,
    active: bool = false,
    unison_mix: f32 = 0.42,
    sub_mix: f32 = 0.12,
    bell_mix: f32 = 0.12,

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
        self.env = env;
        self.env.trigger();
        self.hammer_age = 0;
        self.active = true;
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

        var body = @sin(self.carrier_phase + mod_signal);
        body += @sin(self.detune_phase + mod_signal * 0.6) * self.unison_mix;
        body += @sin(self.carrier_phase * 0.5) * self.sub_mix;
        body += @sin(self.carrier_phase * 2.0 + mod_signal * 0.3) * (0.018 + bell_tone * self.bell_mix);
        body = self.filter.process(body);

        var hammer: f32 = 0.0;
        if (self.hammer_age < 4096) {
            const age: f32 = @floatFromInt(self.hammer_age);
            const decay = @exp(-age * (0.0038 + attack_softness * 0.0024));
            hammer = ((rng_inst.float() * 2.0 - 1.0) * 0.65 + @sin(self.carrier_phase * 5.0) * 0.25) * decay;
            self.hammer_age += 1;
        }

        return (body + hammer * hammer_level) * env_val * self.velocity;
    }
};
