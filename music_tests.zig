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
    for ([_]u8{ 28, 31, 43, 55 }) |note| {
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
