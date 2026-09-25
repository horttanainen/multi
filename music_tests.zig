const std = @import("std");
const dsp = @import("src/music/dsp.zig");
const composition = @import("src/music/composition.zig");
const instruments = @import("src/music/instruments.zig");
const procedural_hard_techno = @import("src/procedural_hard_techno.zig");

test "step clock supports immediate start without changing legacy reset timing" {
    var clock: composition.StepSequencer16 = .{};
    composition.stepSequencer16Reset(&clock);
    for (0..4800) |frame| {
        const step = composition.stepSequencer16AdvanceSample(&clock, 150.0);
        if (frame < 4799) {
            try std.testing.expectEqual(null, step);
            continue;
        }
        try std.testing.expectEqual(@as(?u8, 0), step);
    }
    composition.stepSequencer16Start(&clock);
    for (0..96001) |frame| {
        const step = composition.stepSequencer16AdvanceSample(&clock, 150.0);
        if (frame % 4800 != 0) {
            try std.testing.expectEqual(null, step);
            continue;
        }
        try std.testing.expectEqual(@as(?u8, @intCast((frame / 4800) % 16)), step);
    }
    composition.stepSequencer16Reset(&clock);
    try std.testing.expectEqual(null, composition.stepSequencer16AdvanceSample(&clock, 150.0));
}

test "fractional step durations retain their remainder" {
    var clock: composition.StepSequencer16 = .{};
    composition.stepSequencer16Start(&clock);
    var events: usize = 0;
    for (0..480000) |frame| {
        const step = composition.stepSequencer16AdvanceSample(&clock, 139.5) orelse continue;
        const expected = @as(f64, @floatFromInt(events)) * 48000.0 * 60.0 / 139.5 / 4.0;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(frame)) - expected) <= 1.0);
        try std.testing.expectEqual(@as(u8, @intCast(events % 16)), step);
        events += 1;
    }
    try std.testing.expectEqual(@as(usize, 93), events);
}

test "ducking holds the return down and recovers smoothly before the next kick" {
    var envelope = dsp.duckingEnvelopeInit(0.04, 0.08);
    dsp.duckingEnvelopeTrigger(&envelope);
    var previous: f32 = 1.0;
    var gain: f32 = 1.0;
    for (0..19200) |frame| {
        gain = dsp.duckingEnvelopeProcess(&envelope);
        try std.testing.expect(gain >= 0.019 and gain <= 1.0);
        try std.testing.expect(@abs(gain - previous) < 0.021);
        if (frame == 1500) try std.testing.expect(gain < 0.021);
        if (frame == 9600) try std.testing.expect(gain > 0.85);
        previous = gain;
    }
    try std.testing.expect(gain > 0.98);
    dsp.duckingEnvelopeTrigger(&envelope);
    try std.testing.expect(@abs(dsp.duckingEnvelopeProcess(&envelope) - gain) < 0.021);
}

test "antialiased saturation handles constant, tiny, and large input intervals" {
    var saturator: dsp.CubicSaturator = .{ .previous_input = 0.2 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.296), dsp.cubicSaturatorProcess(&saturator, 0.2), 0.000001);
    for ([_]f32{ 0.20000001, 0.19999999, 1.0, 10.0, 10.0, -10.0, -10.0, 0.0, 0.0 }) |input| {
        const sample = dsp.cubicSaturatorProcess(&saturator, input);
        try std.testing.expect(std.math.isFinite(sample));
        try std.testing.expect(@abs(sample) <= 1.000001);
    }
    try std.testing.expectEqual(@as(f32, 0.0), dsp.cubicSaturatorProcess(&saturator, 0.0));
}

const ToneMeter = struct {
    real: f64 = 0.0,
    imaginary: f64 = 0.0,
};

fn measureTone(meter: *ToneMeter, sample: f32, frame: usize, hz: f64) void {
    const phase = std.math.tau * hz * @as(f64, @floatFromInt(frame)) / 48000.0;
    meter.real += sample * @cos(phase);
    meter.imaginary += sample * @sin(phase);
}

fn toneMagnitude(meter: ToneMeter) f64 {
    return @sqrt(meter.real * meter.real + meter.imaginary * meter.imaginary);
}

test "antialiased saturation reduces the folded harmonic of a driven 9 kHz sine" {
    var saturator: dsp.CubicSaturator = .{};
    var naive_alias: ToneMeter = .{};
    var antialiased_alias: ToneMeter = .{};
    var naive_fundamental: ToneMeter = .{};
    var antialiased_fundamental: ToneMeter = .{};
    for (0..5280) |frame| {
        const input: f32 = @floatCast(4.0 * @sin(std.math.tau * 9000.0 * @as(f64, @floatFromInt(frame)) / 48000.0));
        const output = dsp.cubicSaturatorProcess(&saturator, input);
        if (frame < 480) continue; // Exclude startup, then measure whole cycles.
        measureTone(&naive_alias, dsp.softClip(input), frame, 3000.0);
        measureTone(&antialiased_alias, output, frame, 3000.0);
        measureTone(&naive_fundamental, dsp.softClip(input), frame, 9000.0);
        measureTone(&antialiased_fundamental, output, frame, 9000.0);
    }
    const naive_ratio = toneMagnitude(naive_alias) / toneMagnitude(naive_fundamental);
    const antialiased_ratio = toneMagnitude(antialiased_alias) / toneMagnitude(antialiased_fundamental);
    try std.testing.expect(naive_ratio > 0.1);
    try std.testing.expect(antialiased_ratio < naive_ratio * 0.25);
}

fn renderTechno(output: []f32, config: procedural_hard_techno.Config, seed: u32, chunk_frames: usize) void {
    procedural_hard_techno.config = config;
    procedural_hard_techno.resetWithSeed(seed);
    var frame: usize = 0;
    while (frame < output.len / 2) {
        const count = @min(chunk_frames, output.len / 2 - frame);
        procedural_hard_techno.fillBuffer(output.ptr + frame * 2, count);
        frame += count;
    }
}

test "techno score and samples are independent of render buffer boundaries" {
    const first = try std.testing.allocator.alloc(f32, 48000 * 2);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(f32, first.len);
    defer std.testing.allocator.free(second);
    renderTechno(first, .{}, 12345, 1024);
    try std.testing.expectEqual(@as(u64, 3), procedural_hard_techno.kick_count);
    renderTechno(second, .{}, 12345, 61);
    try std.testing.expectEqualSlices(f32, first, second);
    renderTechno(second, .{}, 54321, 1024);
    try std.testing.expectEqual(@as(u64, 3), procedural_hard_techno.kick_count);
    try std.testing.expect(!std.mem.eql(f32, first, second));
}

test "isolated techno buses sum to the mix and rumble retains its kick feed" {
    const mix = try std.testing.allocator.alloc(f32, 48000 * 2);
    defer std.testing.allocator.free(mix);
    const kick = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(kick);
    const rumble = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(rumble);
    const bass = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(bass);
    renderTechno(mix, .{ .bus = .low_end }, 12345, 1024);
    renderTechno(kick, .{ .bus = .kick }, 12345, 127);
    renderTechno(rumble, .{ .bus = .rumble }, 12345, 256);
    renderTechno(bass, .{ .bus = .bass }, 12345, 61);
    var rumble_energy: f64 = 0.0;
    for (mix, kick, rumble, bass) |combined, direct, wet, synth| {
        try std.testing.expectApproxEqAbs(combined, direct + wet + synth, 0.0000002);
        rumble_energy += wet * wet;
    }
    try std.testing.expect(rumble_energy / @as(f64, @floatFromInt(mix.len)) > 0.00001);
    renderTechno(mix, .{ .bus = .kick, .rumble_level = 0.0 }, 12345, 512);
    try std.testing.expectEqualSlices(f32, kick, mix);
    renderTechno(mix, .{ .volume = 0.0 }, 12345, 1024);
    for (mix) |sample| try std.testing.expectEqual(@as(f32, 0.0), sample);
}

test "techno parameter extremes stay finite with headroom through repeated kicks" {
    var samples: [1024]f32 = undefined;
    for ([_]f32{ 0.35, 1.65 }) |tempo| {
        for ([_]f32{ 1.0, 8.0 }) |drive| {
            for ([_]f32{ 0.08, 0.8 }) |decay| {
                procedural_hard_techno.config = .{
                    .tempo_scale = tempo,
                    .volume = 1.0,
                    .kick_drive = drive,
                    .kick_decay = decay,
                    .rumble_level = 1.0,
                    .room_mix = 1.0,
                };
                procedural_hard_techno.resetWithSeed(42);
                var sum: f64 = 0.0;
                for (0..469) |_| { // Five seconds, including room buildup.
                    procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                    for (samples) |sample| {
                        try std.testing.expect(std.math.isFinite(sample));
                        try std.testing.expect(@abs(sample) < 0.99);
                        sum += sample;
                    }
                }
                try std.testing.expect(@abs(sum / @as(f64, @floatFromInt(469 * samples.len))) < 0.01);
            }
        }
    }
}

test "early note-off releases zero-sustain and sustained envelopes in the requested time" {
    for ([_]f32{ 0.0, 0.6 }) |sustain| {
        for ([_]usize{ 100, 1000, 5000 }) |note_off_frame| {
            var env = dsp.envelopeInit(0.01, 0.08, sustain, 0.004);
            dsp.envelopeTrigger(&env);
            for (0..note_off_frame) |_| _ = dsp.envelopeProcess(&env);
            const start_level = env.level;
            dsp.envelopeNoteOff(&env);
            try std.testing.expectEqual(start_level, env.level);
            var previous = env.level;
            for (0..193) |_| {
                dsp.envelopeNoteOff(&env); // Repeated choke must not extend release.
                const level = dsp.envelopeProcess(&env);
                try std.testing.expect(level <= previous and level >= 0.0);
                try std.testing.expect(previous - level <= start_level / 192.0 + 0.000001);
                previous = level;
            }
            try std.testing.expectEqual(dsp.EnvState.idle, env.state);
        }
    }
    var one_shot = dsp.envelopeInit(0.001, 0.03, 0.0, 0.004);
    dsp.envelopeTrigger(&one_shot);
    for (0..1600) |_| _ = dsp.envelopeProcess(&one_shot);
    try std.testing.expectEqual(dsp.EnvState.idle, one_shot.state);
    try std.testing.expectEqual(@as(f32, 0.0), one_shot.level);
}

test "open hat choke fades out without silencing the closed hat" {
    var open: instruments.HiHat = .{ .base_frequency_hz = 4300.0, .curved_decay = true };
    var closed: instruments.HiHat = .{ .base_frequency_hz = 4100.0, .curved_decay = true };
    var open_rng = dsp.rngInit(123);
    var closed_rng = dsp.rngInit(456);
    instruments.hiHatTriggerWithDecay(&open, 0.8, 0.22);
    for (0..2400) |_| _ = instruments.hiHatProcess(&open, &open_rng);
    try std.testing.expect(open.env.level > 0.5);
    instruments.hiHatChoke(&open);
    instruments.hiHatTriggerWithDecay(&closed, 0.7, 0.04);
    var closed_energy: f64 = 0.0;
    for (0..960) |frame| {
        const open_sample = instruments.hiHatProcess(&open, &open_rng);
        const closed_sample = instruments.hiHatProcess(&closed, &closed_rng);
        if (frame >= 193) try std.testing.expectEqual(@as(f32, 0.0), open_sample);
        closed_energy += closed_sample * closed_sample;
    }
    try std.testing.expectEqual(dsp.EnvState.idle, open.env.state);
    try std.testing.expect(closed_energy > 0.001);
}

test "clap retrigger is continuous and its tail reaches silence" {
    var clap: instruments.ElectronicClap = .{};
    var rng = dsp.rngInit(987);
    instruments.electronicClapTrigger(&clap, 0.9);
    var previous: f32 = 0.0;
    for (0..1500) |_| previous = instruments.electronicClapProcess(&clap, &rng);
    instruments.electronicClapTrigger(&clap, 0.4);
    try std.testing.expectEqual(previous, instruments.electronicClapProcess(&clap, &rng));
    for (0..20000) |_| _ = instruments.electronicClapProcess(&clap, &rng);
    try std.testing.expect(!clap.active);
    try std.testing.expectEqual(@as(f32, 0.0), instruments.electronicClapProcess(&clap, &rng));
}

test "electronic accent retriggers retain continuity and decay to silence" {
    for ([_]instruments.ElectronicAccentTone{ .noise_burst, .snare }) |tone| {
        var accent: instruments.ElectronicAccent = .{ .tone = tone };
        var rng = dsp.rngInit(987);
        instruments.electronicAccentTrigger(&accent, 0);
        for (0..2400) |_| try std.testing.expectEqual(@as(f32, 0), instruments.electronicAccentProcess(&accent, &rng));
        instruments.electronicAccentTrigger(&accent, 1);
        var previous: f32 = 0;
        var energy: f64 = 0;
        for (0..4800) |frame| {
            if (frame % 1200 == 1199) {
                instruments.electronicAccentTrigger(&accent, 0.8);
                const next = instruments.electronicAccentProcess(&accent, &rng);
                try std.testing.expect(@abs(next - previous) < 0.08);
                previous = next;
                continue;
            }
            const sample = instruments.electronicAccentProcess(&accent, &rng);
            try std.testing.expect(std.math.isFinite(sample));
            try std.testing.expect(@abs(sample) < 0.5);
            energy += sample * sample;
            previous = sample;
        }
        try std.testing.expect(energy > 0.1);
        for (0..48000) |_| previous = instruments.electronicAccentProcess(&accent, &rng);
        try std.testing.expect(!accent.active);
        try std.testing.expect(@abs(previous) < 0.0000001);
        instruments.electronicAccentTrigger(&accent, 0.6);
        try std.testing.expect(@abs(instruments.electronicAccentProcess(&accent, &rng)) < 0.0000001);
    }
}

test "accent choices are deterministic and leave the other techno voices unchanged" {
    const first = try std.testing.allocator.alloc(f32, 48000 * 4 * 2);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(f32, first.len);
    defer std.testing.allocator.free(second);
    var config: procedural_hard_techno.Config = .{ .lead = .corrosion, .groove = .machine };
    for ([_]procedural_hard_techno.Bus{ .low_end, .hats, .clap, .lead }) |bus| {
        config.bus = bus;
        config.metal_voice = .noise_burst;
        renderTechno(first, config, 12345, 1024);
        config.metal_voice = .snare;
        renderTechno(second, config, 12345, 61);
        try std.testing.expectEqualSlices(f32, first, second);
    }
    config.bus = .metal;
    for ([_]instruments.ElectronicAccentTone{ .noise_burst, .snare }) |tone| {
        config.metal_voice = tone;
        renderTechno(first, config, 12345, 1024);
        const counts = procedural_hard_techno.percussion_counts;
        renderTechno(second, config, 12345, 61);
        try std.testing.expectEqualSlices(f32, first, second);
        try std.testing.expectEqualSlices(u64, &counts, &procedural_hard_techno.percussion_counts);
    }
    config.metal_voice = .noise_burst;
    renderTechno(first, config, 12345, 1024);
    try std.testing.expect(!std.mem.eql(f32, first, second));
}

test "both electronic accents retain headroom with maximum bass and Corrosion levels" {
    var samples: [2048]f32 = undefined;
    for ([_]instruments.ElectronicAccentTone{ .noise_burst, .snare }) |tone| {
        for ([_]f32{ 0.35, 1.65 }) |tempo| {
            procedural_hard_techno.config = .{
                .groove = .machine,
                .metal_voice = tone,
                .tempo_scale = tempo,
                .volume = 1,
                .kick_drive = 8,
                .kick_decay = 0.8,
                .rumble_level = 1,
                .room_mix = 1,
                .percussion_level = 1,
                .lead = .corrosion,
                .lead_level = 1,
                .bass_level = 1,
            };
            procedural_hard_techno.resetWithSeed(98765);
            for (0..1200) |_| { // 25.6 seconds includes repeated overlapping accents.
                procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                for (samples) |sample| {
                    try std.testing.expect(std.math.isFinite(sample));
                    try std.testing.expect(@abs(sample) < 0.99);
                }
            }
        }
    }
}

fn advanceTechno(frames: usize) void {
    var buffer: [1024]f32 = undefined;
    var remaining = frames;
    while (remaining > 0) {
        const count = @min(remaining, buffer.len / 2);
        procedural_hard_techno.fillBuffer(&buffer, count);
        remaining -= count;
    }
}

test "rolling percussion swing delays the off-sixteenth while the kick stays on grid" {
    procedural_hard_techno.config = .{ .groove = .rolling };
    procedural_hard_techno.resetWithSeed(12345);
    advanceTechno(4800);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.percussion_counts[0]);
    advanceTechno(768);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.percussion_counts[0]);
    advanceTechno(1);
    try std.testing.expectEqual(@as(u64, 2), procedural_hard_techno.percussion_counts[0]);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.kick_count);
    advanceTechno(19200 - 5569);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.kick_count);
    advanceTechno(1);
    try std.testing.expectEqual(@as(u64, 2), procedural_hard_techno.kick_count);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.percussion_counts[2]);
}

test "groove stems sum to the stereo mix and soloing preserves score and samples" {
    const mix = try std.testing.allocator.alloc(f32, 48000 * 4 * 2);
    defer std.testing.allocator.free(mix);
    const stem = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(stem);
    const sum = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(sum);
    for ([_]procedural_hard_techno.Groove{ .warehouse, .rolling, .machine }) |groove| {
        renderTechno(mix, .{ .groove = groove }, 12345, 1024);
        const counts = procedural_hard_techno.percussion_counts;
        for (counts) |count| try std.testing.expect(count > 0);
        @memset(sum, 0.0);
        for ([_]procedural_hard_techno.Bus{ .low_end, .hats, .clap, .metal }) |bus| {
            renderTechno(stem, .{ .groove = groove, .bus = bus }, 12345, 97);
            try std.testing.expectEqualSlices(u64, &counts, &procedural_hard_techno.percussion_counts);
            var energy: f64 = 0.0;
            for (sum, stem) |*accumulated, sample| {
                accumulated.* += sample;
                energy += sample * sample;
            }
            try std.testing.expect(energy > 0.01);
        }
        for (mix, sum) |actual, combined| try std.testing.expectApproxEqAbs(actual, combined, 0.0000002);
        renderTechno(stem, .{ .groove = groove }, 12345, 61);
        try std.testing.expectEqualSlices(f32, mix, stem);
        renderTechno(stem, .{ .groove = groove }, 98765, 512);
        try std.testing.expectEqualSlices(u64, &counts, &procedural_hard_techno.percussion_counts);
        try std.testing.expect(!std.mem.eql(f32, mix, stem));
    }
}

test "percussion choices leave the selected low end unchanged" {
    const foundation = try std.testing.allocator.alloc(f32, 48000 * 2);
    defer std.testing.allocator.free(foundation);
    const groove_audio = try std.testing.allocator.alloc(f32, foundation.len);
    defer std.testing.allocator.free(groove_audio);
    renderTechno(foundation, .{ .groove = .foundation }, 12345, 1024);
    for ([_]procedural_hard_techno.Groove{ .warehouse, .rolling, .machine }) |groove| {
        renderTechno(groove_audio, .{ .groove = groove, .bus = .low_end }, 12345, 61);
        try std.testing.expectEqualSlices(f32, foundation, groove_audio);
        renderTechno(groove_audio, .{ .groove = groove, .percussion_level = 0.0 }, 12345, 512);
        try std.testing.expectEqualSlices(f32, foundation, groove_audio);
    }
}

test "all percussion grooves retain headroom at maximum mix levels" {
    var samples: [1024]f32 = undefined;
    for ([_]procedural_hard_techno.Groove{ .warehouse, .rolling, .machine }) |groove| {
        for ([_]f32{ 0.35, 1.65 }) |tempo| {
            procedural_hard_techno.config = .{
                .groove = groove,
                .tempo_scale = tempo,
                .volume = 1.0,
                .kick_drive = 8.0,
                .kick_decay = 0.8,
                .rumble_level = 1.0,
                .room_mix = 1.0,
                .percussion_level = 1.0,
            };
            procedural_hard_techno.resetWithSeed(98765);
            var sum: f64 = 0.0;
            for (0..469) |_| {
                procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                for (samples) |sample| {
                    try std.testing.expect(std.math.isFinite(sample));
                    if (@abs(sample) >= 0.99) std.debug.print("headroom: groove={s} tempo={d} sample={d}\n", .{ @tagName(groove), tempo, sample });
                    try std.testing.expect(@abs(sample) < 0.99);
                    sum += sample;
                }
            }
            try std.testing.expect(@abs(sum / @as(f64, @floatFromInt(469 * samples.len))) < 0.01);
        }
    }
}

test "track sections follow musical boundaries with a quiet break and a clean ending" {
    const bar_frames = 76800;
    const end_frame = 128 * bar_frames;
    procedural_hard_techno.config = .{ .arrangement = .track };
    procedural_hard_techno.resetWithSeed(12345);
    var buffer: [2048]f32 = undefined;
    var opening: [2048]f32 = undefined;
    var frame: usize = 0;
    var previous: [2]f32 = .{ 0.0, 0.0 };
    var drive_energy: f64 = 0.0;
    var break_energy: f64 = 0.0;
    var return_energy: f64 = 0.0;
    while (frame < end_frame + 1024) {
        const count = @min(buffer.len / 2, end_frame + 1024 - frame);
        procedural_hard_techno.fillBuffer(&buffer, count);
        if (frame == 0) opening = buffer;
        for (0..count) |index| {
            const absolute_frame = frame + index;
            const bar = absolute_frame / bar_frames;
            for (0..2) |channel| {
                const sample = buffer[index * 2 + channel];
                try std.testing.expect(std.math.isFinite(sample));
                try std.testing.expect(@abs(sample) < 0.99);
                if (bar >= 16 and bar < 24) drive_energy += sample * sample;
                if (bar >= 80 and bar < 88) break_energy += sample * sample;
                if (bar >= 88 and bar < 96) return_energy += sample * sample;
                if (absolute_frame >= end_frame) try std.testing.expectEqual(@as(f32, 0.0), sample);
                // Exact section boundaries should not abruptly cut ringing audio.
                if (absolute_frame % bar_frames == 0) {
                    try std.testing.expect(@abs(sample - previous[channel]) < 0.03);
                }
                previous[channel] = sample;
            }
        }
        frame += count;
    }
    for ([_]u64{ 0, 8, 40, 56, 80, 88, 120, 128 }, 0..) |bar, index| {
        try std.testing.expectEqual(@as(?u64, bar * bar_frames), procedural_hard_techno.section_frames[index]);
    }
    try std.testing.expectEqual(procedural_hard_techno.TrackSection.finished, procedural_hard_techno.track_section);
    try std.testing.expectEqual(@as(u64, 480), procedural_hard_techno.kick_count);
    try std.testing.expect(break_energy < drive_energy * 0.10);
    try std.testing.expect(return_energy > break_energy * 10.0);
    procedural_hard_techno.resetWithSeed(12345);
    procedural_hard_techno.fillBuffer(&buffer, buffer.len / 2);
    try std.testing.expectEqualSlices(f32, &opening, &buffer);
}

test "full arrangement retains fractional clock remainder across all 128 bars" {
    procedural_hard_techno.config = .{ .arrangement = .track, .tempo_scale = 0.93 };
    procedural_hard_techno.resetWithSeed(54321);
    const frames_per_bar = 48000.0 * 60.0 / 139.5 * 4.0;
    advanceTechno(@as(usize, @intFromFloat(@ceil(128.0 * frames_per_bar))) + 16);
    for ([_]u64{ 0, 8, 40, 56, 80, 88, 120, 128 }, 0..) |bar, index| {
        try std.testing.expect(procedural_hard_techno.section_frames[index] != null);
        const actual = procedural_hard_techno.section_frames[index].?;
        const expected = @as(f64, @floatFromInt(bar)) * frames_per_bar;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(actual)) - expected) <= 2.0);
    }
    try std.testing.expectEqual(@as(u64, 480), procedural_hard_techno.kick_count);
}

test "arrangement targets fade gradually without weakening the returning kick trigger" {
    procedural_hard_techno.config = .{ .arrangement = .track };
    procedural_hard_techno.resetWithSeed(456);
    advanceTechno(4 * 76800); // Rumble enters at bar four.
    const before = procedural_hard_techno.layer_levels[0];
    try std.testing.expectEqual(@as(f32, 0.0), before);
    advanceTechno(1);
    try std.testing.expect(procedural_hard_techno.layer_levels[0] > 0.0);
    try std.testing.expect(procedural_hard_techno.layer_levels[0] - before < 0.001);
    advanceTechno(4800);
    try std.testing.expect(procedural_hard_techno.layer_levels[0] > 0.64);
    const break_plan = procedural_hard_techno.arrangementStep(87, 15);
    try std.testing.expect(!break_plan.kick_enabled);
    for (break_plan.layers) |level| try std.testing.expectEqual(@as(f32, 0.0), level);
    const return_plan = procedural_hard_techno.arrangementStep(88, 0);
    try std.testing.expect(return_plan.kick_enabled);
    try std.testing.expectEqual(procedural_hard_techno.Groove.warehouse, return_plan.groove);
    try std.testing.expectEqual(@as(f32, 1.0), return_plan.layers[0]);
}

test "track reset and sample output are independent of render chunks and later config edits" {
    const first = try std.testing.allocator.alloc(f32, 48000 * 16 * 2);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(f32, first.len);
    defer std.testing.allocator.free(second);
    renderTechno(first, .{ .arrangement = .track }, 12345, 1024);
    const entries = procedural_hard_techno.section_frames;
    const counts = procedural_hard_techno.percussion_counts;
    renderTechno(second, .{ .arrangement = .track }, 12345, 61);
    try std.testing.expectEqualSlices(f32, first, second);
    try std.testing.expectEqualSlices(?u64, &entries, &procedural_hard_techno.section_frames);
    try std.testing.expectEqualSlices(u64, &counts, &procedural_hard_techno.percussion_counts);
    procedural_hard_techno.resetWithSeed(12345);
    procedural_hard_techno.config = .{ .arrangement = .loop, .volume = 0.0 };
    procedural_hard_techno.fillBuffer(second.ptr, second.len / 2);
    try std.testing.expectEqualSlices(f32, first, second);
}

test "sync oscillator retains the master pitch and suppresses folded reset harmonics" {
    var osc: dsp.SyncSaw = .{};
    dsp.syncSawConfigure(&osc, 3750.0, 2.7);
    var naive_alias: ToneMeter = .{};
    var limited_alias: ToneMeter = .{};
    var fundamental: ToneMeter = .{};
    for (0..10080) |frame| {
        const output = dsp.syncSawProcess(&osc);
        try std.testing.expect(std.math.isFinite(output));
        if (frame < 480) continue;
        const master = @mod(@as(f64, @floatFromInt(frame)) * 3750.0 / 48000.0, 1.0);
        const naive: f32 = @floatCast(2.0 * @mod(master * 2.7, 1.0) - 1.0);
        // The ninth master harmonic folds from 33.75 kHz to 14.25 kHz.
        measureTone(&naive_alias, naive, frame, 14250.0);
        measureTone(&limited_alias, output, frame, 14250.0);
        measureTone(&fundamental, output, frame, 3750.0);
    }
    try std.testing.expect(toneMagnitude(fundamental) > 100.0);
    try std.testing.expect(toneMagnitude(naive_alias) > 10.0);
    try std.testing.expect(toneMagnitude(limited_alias) < toneMagnitude(naive_alias) * 0.01);
}

test "sync lead gates reach silence and fast retriggers preserve phase and bounded output" {
    for ([_]instruments.SyncLeadTone{ .razor, .hollow, .wide, .machine, .buzz, .iron, .corrosion }) |tone| {
        var voice: instruments.SyncLead = .{ .tone = tone };
        instruments.syncLeadTrigger(&voice, 67, 0.95, 0.055);
        var energy: f64 = 0.0;
        var sample: f32 = 0.0;
        for (0..24000) |frame| {
            if (frame == 400) {
                const phase = voice.oscillators[0].phase;
                instruments.syncLeadTrigger(&voice, 74, 0.7, 0.03);
                try std.testing.expectEqual(phase, voice.oscillators[0].phase);
            }
            sample = instruments.syncLeadProcess(&voice);
            try std.testing.expect(std.math.isFinite(sample));
            // Deliberate saturation can reach the instrument's unit rails;
            // the separately tested bus gains leave headroom in the final mix.
            try std.testing.expect(@abs(sample) <= 1.0);
            energy += sample * sample;
        }
        try std.testing.expect(energy > 10.0);
        try std.testing.expectEqual(dsp.EnvState.idle, voice.env.state);
        try std.testing.expect(@abs(sample) < 0.000001);
    }
}

test "lead mixes preserve their rhythm balance and sum across chunks seeds and reset" {
    const baseline = try std.testing.allocator.alloc(f32, 307200 * 2);
    defer std.testing.allocator.free(baseline);
    const mix = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(mix);
    const stem = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(stem);
    const repeat = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(repeat);
    renderTechno(baseline, .{ .lead = .razor, .lead_level = 0.0 }, 12345, 1024);
    for ([_]procedural_hard_techno.Lead{ .razor, .hollow, .wide, .machine, .buzz, .iron, .corrosion }) |tone| {
        renderTechno(mix, .{ .lead = tone }, 12345, 1024);
        try std.testing.expectEqual(@as(u64, 30), procedural_hard_techno.lead_count);
        renderTechno(stem, .{ .lead = tone, .bus = .lead }, 12345, 61);
        var energy: f64 = 0.0;
        for (mix, baseline, stem) |combined, drums, synth| {
            try std.testing.expectApproxEqAbs(combined, drums + synth, 0.0000002);
            try std.testing.expect(@abs(combined) < 0.99);
            energy += synth * synth;
        }
        try std.testing.expect(energy > 50.0);
        renderTechno(repeat, .{ .lead = tone }, 12345, 97);
        try std.testing.expectEqualSlices(f32, mix, repeat);
        renderTechno(repeat, .{ .lead = tone, .bus = .lead }, 98765, 1024);
        try std.testing.expectEqualSlices(f32, stem, repeat);
        renderTechno(repeat, .{ .lead = tone, .lead_level = 0.0 }, 12345, 1024);
        try std.testing.expectEqualSlices(f32, baseline, repeat);
    }
}

test "rough lead saturation removes DC and a zero velocity note stays silent" {
    for ([_]instruments.SyncLeadTone{ .machine, .buzz, .iron, .corrosion }) |tone| {
        var voice: instruments.SyncLead = .{ .tone = tone };
        instruments.syncLeadTrigger(&voice, 67, 0.0, 0.055);
        for (0..9600) |_| try std.testing.expectEqual(@as(f32, 0.0), instruments.syncLeadProcess(&voice));
        instruments.syncLeadTrigger(&voice, 67, 1.0, 0.8);
        var sum: f64 = 0.0;
        for (0..33600) |frame| {
            const sample = instruments.syncLeadProcess(&voice);
            try std.testing.expect(std.math.isFinite(sample));
            try std.testing.expect(@abs(sample) <= 1.0);
            if (frame >= 4800) sum += sample;
        }
        try std.testing.expect(@abs(sum / 28800.0) < 0.002);
    }
}

test "lead enters on the intended bar and preserves the finite track ending" {
    procedural_hard_techno.config = .{ .arrangement = .track, .lead = .wide, .bus = .lead };
    procedural_hard_techno.resetWithSeed(12345);
    advanceTechno(16 * 76800);
    try std.testing.expectEqual(@as(u64, 0), procedural_hard_techno.lead_count);
    advanceTechno(1);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.lead_count);
    advanceTechno(112 * 76800 - 1);
    var ending: [2048]f32 = undefined;
    procedural_hard_techno.fillBuffer(&ending, ending.len / 2);
    for (ending) |sample| try std.testing.expectEqual(@as(f32, 0.0), sample);
    try std.testing.expectEqual(@as(u64, 480), procedural_hard_techno.kick_count);
    try std.testing.expectEqual(@as(?u64, 128 * 76800), procedural_hard_techno.section_frames[7]);
    try std.testing.expect(procedural_hard_techno.lead_count > 500);
    procedural_hard_techno.resetWithSeed(12345);
    procedural_hard_techno.fillBuffer(&ending, ending.len / 2);
    for (ending) |sample| try std.testing.expectEqual(@as(f32, 0.0), sample);
}

test "lead and maximum drum levels retain headroom at both tempo extremes" {
    var samples: [2048]f32 = undefined;
    for ([_]procedural_hard_techno.Lead{ .razor, .hollow, .wide, .machine, .buzz, .iron, .corrosion }) |tone| {
        for ([_]f32{ 0.35, 1.65 }) |tempo| {
            procedural_hard_techno.config = .{
                .lead = tone,
                .lead_level = 1.0,
                .bass_level = 1.0,
                .tempo_scale = tempo,
                .kick_drive = 8.0,
                .kick_decay = 0.8,
                .rumble_level = 1.0,
                .percussion_level = 1.0,
                .room_mix = 1.0,
                .volume = 1.0,
            };
            procedural_hard_techno.resetWithSeed(98765);
            var sum: f64 = 0.0;
            for (0..300) |_| {
                procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                for (samples) |sample| {
                    try std.testing.expect(std.math.isFinite(sample));
                    try std.testing.expect(@abs(sample) < 0.99);
                    sum += sample;
                }
            }
            try std.testing.expect(@abs(sum / @as(f64, @floatFromInt(300 * samples.len))) < 0.01);
        }
    }
}

test "fractional delay interpolates while integer taps preserve their output" {
    var line: dsp.DelayLine(8) = .{};
    for (0..12) |index| dsp.delayLinePush(8, &line, @floatFromInt(index));
    for (0..8) |index| {
        try std.testing.expectEqual(dsp.delayLineTap(8, &line, index), dsp.delayLineTapFractional(8, &line, @floatFromInt(index)));
    }
    try std.testing.expectEqual(@as(f32, 8.5), dsp.delayLineTapFractional(8, &line, 2.5));
    try std.testing.expectEqual(@as(f32, 4.0), dsp.delayLineTapFractional(8, &line, 100));
}

test "live tempo changes preserve step progress and runtime track repetition restarts" {
    procedural_hard_techno.config = .{ .lead = .corrosion, .tempo_scale = 0.35 };
    procedural_hard_techno.resetWithSeed(12345);
    advanceTechno(12000);
    var next = procedural_hard_techno.config;
    next.tempo_scale = 1.65;
    procedural_hard_techno.applyLiveConfig(next);
    advanceTechno(64);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.lead_count);
    try std.testing.expectEqual(@as(u64, 12064), procedural_hard_techno.frames_rendered);

    procedural_hard_techno.config = .{ .lead = .corrosion, .arrangement = .track, .repeat_track = true };
    procedural_hard_techno.resetWithSeed(12345);
    advanceTechno(128 * 76800 + 4800);
    try std.testing.expectEqual(@as(u64, 4800), procedural_hard_techno.frames_rendered);
    try std.testing.expectEqual(@as(u64, 1), procedural_hard_techno.kick_count);
    try std.testing.expectEqual(procedural_hard_techno.TrackSection.intro, procedural_hard_techno.track_section);
}

test "bass gates and retriggers preserve phase and settle to silence" {
    for ([_]u8{ 28, 31, 43, 55, 62, 74 }) |note| {
        var bass: instruments.SynthBass = .{};
        instruments.synthBassTrigger(&bass, note, 0.0, 0.04);
        for (0..4800) |_| try std.testing.expectEqual(@as(f32, 0), instruments.synthBassProcess(&bass));
        instruments.synthBassTrigger(&bass, note, 1.0, 0.07);
        var energy: f64 = 0;
        var previous: f32 = 0;
        for (0..48000) |frame| {
            var uninterrupted: f32 = 0;
            if (frame == 1700 or frame == 2900) {
                var continuing = bass;
                uninterrupted = instruments.synthBassProcess(&continuing);
                const phase = bass.oscillator.phase;
                instruments.synthBassTrigger(&bass, if (frame == 1700) 38 else note, 0.7, 0.06);
                try std.testing.expectEqual(phase, bass.oscillator.phase);
            }
            const sample = instruments.synthBassProcess(&bass);
            try std.testing.expect(std.math.isFinite(sample));
            try std.testing.expect(@abs(sample) < 1.0);
            // Compare the boundary with an uninterrupted copy of the waveform;
            // ordinary slopes depend on pitch and are not retrigger clicks.
            try std.testing.expect(@abs(sample - previous) < 0.12);
            if (frame == 1700 or frame == 2900) try std.testing.expectApproxEqAbs(uninterrupted, sample, 0.002);
            if (frame > 40000) try std.testing.expect(@abs(sample) < 0.000001);
            energy += sample * sample;
            previous = sample;
        }
        try std.testing.expect(energy > 1.0);
        try std.testing.expectEqual(dsp.EnvState.idle, bass.envelope.state);
    }
}

test "bass transposition preserves its held score and routing while raising pitch" {
    const first = try std.testing.allocator.alloc(f32, 307200 * 2);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(f32, first.len);
    defer std.testing.allocator.free(second);
    for ([_]u8{ 0, 1, 2, 3 }) |octaves| {
        const config: procedural_hard_techno.Config = .{ .lead = .corrosion, .bass_octaves = octaves, .bus = .bass };
        renderTechno(first, config, 12345, 1024);
        try std.testing.expectEqual(@as(u64, 10), procedural_hard_techno.bass_count);
        renderTechno(second, config, 12345, 61);
        try std.testing.expectEqualSlices(f32, first, second);
        const frequency: f64 = dsp.midiToFreq(31 + octaves * 12);
        var fundamental: ToneMeter = .{};
        var octave_below: ToneMeter = .{};
        var held_energy: f64 = 0;
        // The first G note holds for a second: inspect well beyond the rejected
        // lead's 55 ms gate and verify the transposed fundamental in real output.
        for (9600..24000) |frame| {
            const sample = first[frame * 2];
            try std.testing.expectEqual(sample, first[frame * 2 + 1]);
            measureTone(&fundamental, sample, frame, frequency);
            measureTone(&octave_below, sample, frame, frequency * 0.5);
            held_energy += sample * sample;
        }
        try std.testing.expect(held_energy > 0.1);
        try std.testing.expect(toneMagnitude(fundamental) > 10);
        try std.testing.expect(toneMagnitude(fundamental) > toneMagnitude(octave_below) * 5);
    }
    // A pitch change in the bass does not touch any other voice or its gain.
    for ([_]procedural_hard_techno.Bus{ .kick, .rumble, .percussion, .lead }) |bus| {
        renderTechno(first, .{ .lead = .corrosion, .bus = bus }, 12345, 1024);
        renderTechno(second, .{ .lead = .corrosion, .bus = bus, .bass_octaves = 3 }, 12345, 61);
        try std.testing.expectEqualSlices(f32, first, second);
    }
}

test "transposed sustained bass keeps headroom at maximum mix and tempo limits" {
    var samples: [2048]f32 = undefined;
    for ([_]u8{ 1, 2, 3 }) |octaves| {
        for ([_]f32{ 0.35, 1.65 }) |tempo| {
            procedural_hard_techno.config = .{
                .lead = .corrosion,
                .bass_octaves = octaves,
                .tempo_scale = tempo,
                .volume = 1,
                .lead_level = 1,
                .bass_level = 1,
                .percussion_level = 1,
                .kick_drive = 8,
                .kick_decay = 0.8,
                .room_mix = 1,
                .rumble_level = 1,
                .groove = .machine,
            };
            procedural_hard_techno.resetWithSeed(12345);
            for (0..1200) |_| {
                procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                for (samples) |sample| {
                    try std.testing.expect(std.math.isFinite(sample));
                    try std.testing.expect(@abs(sample) < 0.99);
                }
            }
        }
    }
}

test "selected bass lead is the accepted one octave bass at six dB higher gain" {
    const reference = try std.testing.allocator.alloc(f32, 307200 * 2);
    defer std.testing.allocator.free(reference);
    const selected = try std.testing.allocator.alloc(f32, reference.len);
    defer std.testing.allocator.free(selected);
    renderTechno(reference, .{ .lead = .corrosion, .bass_octaves = 1, .bus = .bass }, 12345, 1024);
    renderTechno(selected, .{ .lead = .bass_synth, .lead_pattern = .bassline, .lead_transpose = -24, .bus = .lead }, 12345, 61);
    try std.testing.expectEqual(@as(u64, 10), procedural_hard_techno.lead_count);
    const boost = std.math.pow(f32, 10, 6.0 / 20.0);
    for (reference, selected) |bass_sample, lead_sample| {
        try std.testing.expectApproxEqAbs(bass_sample * boost, lead_sample, 0.0000001);
    }
}

test "both lead voices share either phrase with independent unchanged backing" {
    const baseline = try std.testing.allocator.alloc(f32, 307200 * 2);
    defer std.testing.allocator.free(baseline);
    const mix = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(mix);
    const stem = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(stem);
    const repeated = try std.testing.allocator.alloc(f32, baseline.len);
    defer std.testing.allocator.free(repeated);
    renderTechno(baseline, .{ .lead = .corrosion, .lead_level = 0 }, 12345, 1024);
    for ([_]procedural_hard_techno.Lead{ .corrosion, .bass_synth }) |tone| {
        for ([_]procedural_hard_techno.LeadPattern{ .original, .bassline }) |pattern| {
            var cfg: procedural_hard_techno.Config = .{ .lead = tone, .lead_pattern = pattern, .lead_transpose = -24 };
            renderTechno(mix, cfg, 12345, 1024);
            try std.testing.expectEqual(@as(u64, if (pattern == .bassline) 10 else 30), procedural_hard_techno.lead_count);
            renderTechno(repeated, cfg, 12345, 61);
            try std.testing.expectEqualSlices(f32, mix, repeated);
            cfg.bus = .lead;
            renderTechno(stem, cfg, 12345, 97);
            renderTechno(repeated, cfg, 67890, 61);
            try std.testing.expectEqualSlices(f32, stem, repeated);
            for (mix, baseline, stem) |combined, backing, voice| {
                try std.testing.expectApproxEqAbs(combined, backing + voice, 0.0000002);
            }
            cfg.bus = .mix;
            cfg.lead_level = 0;
            renderTechno(repeated, cfg, 12345, 61);
            try std.testing.expectEqualSlices(f32, baseline, repeated);
        }
    }
}

test "selected bass lead preserves the reference through live tempo changes" {
    const reference = try std.testing.allocator.alloc(f32, 192000);
    defer std.testing.allocator.free(reference);
    const selected = try std.testing.allocator.alloc(f32, reference.len);
    defer std.testing.allocator.free(selected);
    for ([_][2]f32{ .{ 1.65, 0.35 }, .{ 0.35, 1.65 } }) |tempos| {
        for ([_]bool{ false, true }) |is_lead| {
            var cfg: procedural_hard_techno.Config = .{
                .lead = if (is_lead) .bass_synth else .corrosion,
                .lead_pattern = .bassline,
                .lead_transpose = -24,
                .bass_octaves = 1,
                .bus = if (is_lead) .lead else .bass,
                .tempo_scale = tempos[0],
            };
            procedural_hard_techno.config = cfg;
            procedural_hard_techno.resetWithSeed(12345);
            advanceTechno(@intFromFloat(19200.0 / tempos[0]));
            const frames = procedural_hard_techno.frames_rendered;
            cfg.tempo_scale = tempos[1];
            procedural_hard_techno.applyLiveConfig(cfg);
            try std.testing.expectEqual(frames, procedural_hard_techno.frames_rendered);
            const output = if (is_lead) selected else reference;
            var offset: usize = 0;
            while (offset < output.len) {
                const count = @min(2048, output.len - offset);
                procedural_hard_techno.fillBuffer(output[offset..].ptr, count / 2);
                offset += count;
            }
        }
        for (reference, selected) |bass_sample, lead_sample| {
            try std.testing.expectApproxEqAbs(bass_sample * std.math.pow(f32, 10, 6.0 / 20.0), lead_sample, 0.0000001);
        }
    }
}

test "sustained and original lead patterns retain headroom across registers and tempos" {
    var samples: [2048]f32 = undefined;
    for ([_]procedural_hard_techno.Lead{ .corrosion, .bass_synth }) |tone| {
        for ([_]procedural_hard_techno.LeadPattern{ .original, .bassline }) |pattern| {
            for ([_]i8{ -24, 0 }) |transpose| {
                for ([_]f32{ 0.35, 1.65 }) |tempo| {
                    procedural_hard_techno.config = .{
                        .lead = tone,
                        .lead_pattern = pattern,
                        .lead_transpose = transpose,
                        .tempo_scale = tempo,
                        .volume = 1,
                        .lead_level = 1,
                        .bass_level = 1,
                        .percussion_level = 1,
                        .kick_drive = 8,
                        .kick_decay = 0.8,
                        .room_mix = 1,
                        .rumble_level = 1,
                        .groove = .machine,
                    };
                    procedural_hard_techno.resetWithSeed(12345);
                    for (0..900) |_| {
                        procedural_hard_techno.fillBuffer(&samples, samples.len / 2);
                        for (samples) |sample| {
                            try std.testing.expect(std.math.isFinite(sample));
                            try std.testing.expect(@abs(sample) < 0.99);
                        }
                    }
                }
            }
        }
    }
}

test "bass score holds an independent counterline through each phrase with arranged rests" {
    var notes: usize = 0;
    var independent: usize = 0;
    for (0..4) |bar| {
        for (0..16) |step| {
            const event = procedural_hard_techno.bassStep(.loop, bar, @intCast(step));
            const note = event.note orelse continue;
            try std.testing.expect(note >= 29 and note <= 38);
            try std.testing.expect(event.gate_steps >= 4 and event.gate_steps <= 10.03);
            // A held note reaches the next pitch change without a release gap.
            const next_step: usize = step + @as(usize, @intFromFloat(event.gate_steps));
            if (next_step < 16) try std.testing.expect(procedural_hard_techno.bassStep(.loop, bar, @intCast(next_step)).note != null);
            notes += 1;
            if (procedural_hard_techno.leadStep(.loop, bar, @intCast(step)).note == null) independent += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 10), notes);
    try std.testing.expect(independent > 0);
    var track_notes: usize = 0;
    for (0..132) |bar| {
        for (0..16) |step| {
            const event = procedural_hard_techno.bassStep(.track, bar, @intCast(step));
            if (bar < 8 or (bar >= 80 and bar < 88) or bar >= 124) try std.testing.expectEqual(null, event.note);
            if (event.note != null) track_notes += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 258), track_notes);
}

test "bass is additive, mono and chunk independent with shared linear headroom" {
    const frames = 307200;
    const mix = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(mix);
    const muted = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(muted);
    const stem = try std.testing.allocator.alloc(f32, mix.len);
    defer std.testing.allocator.free(stem);
    renderTechno(mix, .{ .lead = .corrosion }, 12345, 1024);
    try std.testing.expectEqual(@as(u64, 10), procedural_hard_techno.bass_count);
    renderTechno(muted, .{ .lead = .corrosion, .bass_level = 0 }, 12345, 97);
    renderTechno(stem, .{ .lead = .corrosion, .bus = .bass }, 12345, 61);
    var energy: f64 = 0;
    for (mix, muted, stem) |combined, original, bass| {
        try std.testing.expectApproxEqAbs(combined, original / 1.1625 + bass, 0.0000002);
        energy += bass * bass;
    }
    try std.testing.expect(energy > 50);
    for (0..frames) |frame| try std.testing.expectEqual(stem[frame * 2], stem[frame * 2 + 1]);
    renderTechno(muted, .{ .lead = .corrosion, .bus = .bass }, 54321, 1024);
    try std.testing.expectEqualSlices(f32, stem, muted);
    for ([_]procedural_hard_techno.Bus{ .kick, .rumble, .percussion, .lead }) |bus| {
        renderTechno(mix, .{ .lead = .corrosion, .bus = bus }, 12345, 1024);
        renderTechno(muted, .{ .lead = .corrosion, .bus = bus, .bass_level = 0 }, 12345, 61);
        for (mix, muted) |actual, original| try std.testing.expectApproxEqAbs(actual, original / 1.1625, 0.0000001);
    }
}

test "live bass level reaches silence without restarting the phrase" {
    var samples: [2048]f32 = undefined;
    procedural_hard_techno.config = .{ .lead = .corrosion, .bus = .bass };
    procedural_hard_techno.resetWithSeed(12345);
    for (0..20) |_| procedural_hard_techno.fillBuffer(&samples, 1024);
    const frames = procedural_hard_techno.frames_rendered;
    var config = procedural_hard_techno.config;
    config.bass_level = 0;
    procedural_hard_techno.applyLiveConfig(config);
    try std.testing.expectEqual(frames, procedural_hard_techno.frames_rendered);
    for (0..30) |_| procedural_hard_techno.fillBuffer(&samples, 1024);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    config.bass_level = 1;
    procedural_hard_techno.applyLiveConfig(config);
    var energy: f64 = 0;
    for (0..60) |_| {
        procedural_hard_techno.fillBuffer(&samples, 1024);
        for (samples) |sample| energy += sample * sample;
    }
    try std.testing.expect(energy > 1);
    try std.testing.expect(procedural_hard_techno.bass_count > 0);
}

test "held bass stays audible and legato pitch changes do not restart its envelopes" {
    var bass: instruments.SynthBass = .{};
    instruments.synthBassTrigger(&bass, 31, 0.82, 0.75);
    var late_energy: f64 = 0;
    var previous: f32 = 0;
    for (0..60000) |frame| {
        if (frame == 24000) {
            const phase = bass.oscillator.phase;
            const amplitude = bass.envelope.level;
            const filter = bass.filter_envelope;
            instruments.synthBassTrigger(&bass, 38, 0.76, 0.5);
            try std.testing.expectEqual(phase, bass.oscillator.phase);
            try std.testing.expectEqual(amplitude, bass.envelope.level);
            try std.testing.expectEqual(filter, bass.filter_envelope);
            try std.testing.expectEqual(dsp.EnvState.sustain, bass.envelope.state);
        }
        const sample = instruments.synthBassProcess(&bass);
        try std.testing.expect(std.math.isFinite(sample));
        try std.testing.expect(@abs(sample) < 1);
        if (frame == 24000) try std.testing.expect(@abs(sample - previous) < 0.02);
        if (frame >= 36000 and frame < 48000) late_energy += sample * sample;
        if (frame > 59000) try std.testing.expect(@abs(sample) < 0.000001);
        previous = sample;
    }
    // The last quarter-second of the held note must contain substantial tone.
    try std.testing.expect(late_energy / 12000.0 > 0.01);
    try std.testing.expectEqual(dsp.EnvState.idle, bass.envelope.state);
}

test "held bass follows tempo changes in both directions and releases at the arranged rest" {
    var buffer: [2048]f32 = undefined;
    for ([_][2]f32{ .{ 0.35, 1.65 }, .{ 1.65, 0.35 } }) |tempos| {
        procedural_hard_techno.config = .{ .arrangement = .track, .bus = .bass, .tempo_scale = 1.65 };
        procedural_hard_techno.resetWithSeed(12345);
        var chunks: usize = 0;
        // Reach the final whole-bar note at the faster tempo to keep the test short.
        while (procedural_hard_techno.current_bar < 123) : (chunks += 1) {
            try std.testing.expect(chunks < 6000);
            procedural_hard_techno.fillBuffer(&buffer, 1024);
        }
        var next = procedural_hard_techno.config;
        next.tempo_scale = tempos[0];
        procedural_hard_techno.applyLiveConfig(next);
        const first_beat: usize = @intFromFloat(48000.0 * 0.4 / tempos[0]);
        advanceTechno(first_beat);
        next.tempo_scale = tempos[1];
        procedural_hard_techno.applyLiveConfig(next);
        const second_beat: usize = @intFromFloat(48000.0 * 0.4 / tempos[1]);
        advanceTechno(second_beat);
        var energy: f64 = 0;
        var measured: usize = 0;
        while (measured < second_beat) {
            const count: usize = @min(1024, second_beat - measured);
            procedural_hard_techno.fillBuffer(&buffer, count);
            for (buffer[0 .. count * 2]) |sample| energy += sample * sample;
            measured += count;
        }
        try std.testing.expectEqual(@as(u64, 123), procedural_hard_techno.current_bar);
        // Slowing down must retain the held tone through the longer bar.
        try std.testing.expect(energy / @as(f64, @floatFromInt(measured * 2)) > 0.00001);
        while (procedural_hard_techno.current_bar < 124) : (chunks += 1) {
            try std.testing.expect(chunks < 6500);
            procedural_hard_techno.fillBuffer(&buffer, 1024);
        }
        advanceTechno(24000);
        procedural_hard_techno.fillBuffer(&buffer, 1024);
        // Speeding up must not leave the old, longer gate ringing into the rest.
        for (buffer) |sample| try std.testing.expect(@abs(sample) < 0.000001);
    }
}

fn renderTechnoWindow(output: []f32, cfg: procedural_hard_techno.Config, start_frame: usize, chunk_frames: usize) void {
    procedural_hard_techno.config = cfg;
    procedural_hard_techno.resetWithSeed(12345);
    advanceTechno(start_frame);
    var offset: usize = 0;
    while (offset < output.len) {
        const frames = @min(chunk_frames, (output.len - offset) / 2);
        procedural_hard_techno.fillBuffer(output[offset..].ptr, frames);
        offset += frames * 2;
    }
}

test "lead teases preserve held phrasing and leave complete bass solo passages" {
    var count: usize = 0;
    for (0..128) |bar| {
        for (0..16) |step| {
            const event = procedural_hard_techno.transitionLeadStep(.bassline, bar, @intCast(step));
            if (event.note == null) continue;
            count += 1;
            try std.testing.expect(event.gate_steps >= 4.0);
            try std.testing.expect(!(bar < 12 or (bar >= 40 and bar < 52) or
                (bar >= 64 and bar < 70) or bar == 71 or (bar >= 80 and bar < 84) or bar >= 124));
            if (bar == 70) try std.testing.expect(step == 0 or step == 8);
        }
    }
    try std.testing.expectEqual(@as(usize, 221), count);
    // The short tease ends naturally before the withheld phrase/return.
    const last_tease = procedural_hard_techno.transitionLeadStep(.bassline, 70, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 4.02), last_tease.gate_steps, 0.0001);
}

test "filtered entrances darken the preview and restore the gain-only voice exactly" {
    const frames = 6 * 76800;
    const filtered = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(filtered);
    const gain_only = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(gain_only);
    const repeated = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(repeated);
    var cfg: procedural_hard_techno.Config = .{
        .arrangement = .track,
        .transitions = .filtered,
        .lead = .bass_synth,
        .lead_pattern = .bassline,
        .lead_transpose = -24,
        .bus = .lead,
    };
    renderTechnoWindow(filtered, cfg, 12 * 76800, 1024);
    renderTechnoWindow(repeated, cfg, 12 * 76800, 61);
    try std.testing.expectEqualSlices(f32, filtered, repeated);
    cfg.transitions = .gain;
    renderTechnoWindow(gain_only, cfg, 12 * 76800, 97);
    var filtered_energy: f64 = 0;
    var gain_energy: f64 = 0;
    var filtered_changes: f64 = 0;
    var gain_changes: f64 = 0;
    for (filtered[0 .. 2 * 76800 * 2], gain_only[0 .. 2 * 76800 * 2], 0..) |a, b, index| {
        filtered_energy += a * a;
        gain_energy += b * b;
        if (index < 2) continue;
        const filtered_delta = a - filtered[index - 2];
        const gain_delta = b - gain_only[index - 2];
        filtered_changes += filtered_delta * filtered_delta;
        gain_changes += gain_delta * gain_delta;
    }
    try std.testing.expect(filtered_energy > 0.0);
    try std.testing.expect(filtered_energy < gain_energy);
    // Normalize sample-to-sample variation by energy: filtering must reduce
    // brightness beyond merely lowering the preview's volume.
    try std.testing.expect(filtered_changes / filtered_energy < 0.8 * gain_changes / gain_energy);
    // One bar after reveal, no residual filtering or gain difference remains.
    try std.testing.expectEqualSlices(f32, gain_only[5 * 76800 * 2 ..], filtered[5 * 76800 * 2 ..]);
}

test "bass features preserve the original voice and recover its background level" {
    const frames = 2 * 76800;
    const original = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(original);
    const featured = try std.testing.allocator.alloc(f32, frames * 2);
    defer std.testing.allocator.free(featured);
    var cfg: procedural_hard_techno.Config = .{
        .arrangement = .track,
        .lead = .bass_synth,
        .lead_pattern = .bassline,
        .lead_transpose = -24,
        .bus = .bass,
    };
    for ([_]usize{ 40, 58 }) |bar| {
        cfg.transitions = .off;
        renderTechnoWindow(original, cfg, bar * 76800, 1024);
        cfg.transitions = .filtered;
        renderTechnoWindow(featured, cfg, bar * 76800, 97);
        const gain: f32 = if (bar == 40) std.math.pow(f32, 10.0, 2.0 / 20.0) else 1.0;
        var energy: f64 = 0;
        for (original, featured) |a, b| {
            try std.testing.expectApproxEqAbs(a * gain, b, 0.000001);
            energy += a * a;
        }
        try std.testing.expect(energy > 1.0);
    }
}

test "live tempo changes retain musical fade position and held lead continuity" {
    var sample: [2]f32 = undefined;
    for ([_][2]f32{ .{ 0.35, 1.65 }, .{ 1.65, 0.35 } }) |tempos| {
        var cfg: procedural_hard_techno.Config = .{
            .arrangement = .track,
            .transitions = .filtered,
            .lead = .bass_synth,
            .lead_pattern = .bassline,
            .lead_transpose = -24,
            .bus = .lead,
            .tempo_scale = tempos[0],
        };
        procedural_hard_techno.config = cfg;
        procedural_hard_techno.resetWithSeed(12345);
        advanceTechno(@intFromFloat(13.37 * 76800.0 / tempos[0]));
        const before = procedural_hard_techno.transition_levels;
        const notes_before = procedural_hard_techno.lead_count;
        procedural_hard_techno.fillBuffer(&sample, 1);
        const last = sample[0];
        cfg.tempo_scale = tempos[1];
        procedural_hard_techno.applyLiveConfig(cfg);
        procedural_hard_techno.fillBuffer(&sample, 1);
        try std.testing.expectEqual(notes_before, procedural_hard_techno.lead_count);
        try std.testing.expectApproxEqAbs(before.lead_gain, procedural_hard_techno.transition_levels.lead_gain, 0.0001);
        try std.testing.expectApproxEqAbs(before.lead_cutoff_hz, procedural_hard_techno.transition_levels.lead_cutoff_hz, 0.1);
        try std.testing.expect(@abs(last - sample[0]) < 0.005);
    }
}

test "arranged transitions keep headroom and drop timing at both tempo limits" {
    var buffer: [2048]f32 = undefined;
    for ([_]f32{ 0.35, 1.65 }) |tempo| {
        procedural_hard_techno.config = .{
            .arrangement = .track,
            .transitions = .filtered,
            .lead = .bass_synth,
            .lead_pattern = .bassline,
            .lead_transpose = -24,
            .tempo_scale = tempo,
            .volume = 1.0,
            .lead_level = 1.0,
            .bass_level = 1.0,
            .percussion_level = 1.0,
            .rumble_level = 1.0,
            .room_mix = 1.0,
            .kick_drive = 8.0,
            .kick_decay = 0.8,
        };
        procedural_hard_techno.resetWithSeed(12345);
        const frames_per_bar = 76800.0 / @as(f64, tempo);
        const frames: usize = @intFromFloat(@ceil(128.0 * frames_per_bar) + 4800);
        var rendered: usize = 0;
        var peak: f32 = 0;
        while (rendered < frames) {
            const count: usize = @min(1024, frames - rendered);
            procedural_hard_techno.fillBuffer(&buffer, count);
            for (buffer[0 .. count * 2]) |value| {
                try std.testing.expect(std.math.isFinite(value));
                peak = @max(peak, @abs(value));
            }
            rendered += count;
        }
        try std.testing.expect(peak < 0.99);
        try std.testing.expectEqual(@as(u64, 480), procedural_hard_techno.kick_count);
        try std.testing.expectEqual(@as(u64, 221), procedural_hard_techno.lead_count);
        try std.testing.expectEqual(@as(u64, 258), procedural_hard_techno.bass_count);
        const returning = procedural_hard_techno.section_frames[@intFromEnum(procedural_hard_techno.TrackSection.returning)].?;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(returning)) - 88.0 * frames_per_bar) < 4.0);
        procedural_hard_techno.fillBuffer(&buffer, 1024);
        for (buffer) |value| try std.testing.expectEqual(@as(f32, 0.0), value);
    }
}
