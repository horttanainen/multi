const std = @import("std");
const dsp = @import("src/music/dsp.zig");
const composition = @import("src/music/composition.zig");
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
    renderTechno(mix, .{}, 12345, 1024);
    renderTechno(kick, .{ .bus = .kick }, 12345, 127);
    renderTechno(rumble, .{ .bus = .rumble }, 12345, 256);
    var rumble_energy: f64 = 0.0;
    for (mix, kick, rumble) |combined, direct, wet| {
        try std.testing.expectApproxEqAbs(combined, direct + wet, 0.0000001);
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
