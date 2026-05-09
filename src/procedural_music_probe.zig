const std = @import("std");
const dsp = @import("music/dsp.zig");
const entropy = @import("music/entropy.zig");
const procedural_americana_guitar = @import("procedural_americana_guitar.zig");

const SAMPLE_RATE_U32: u32 = 48000;
const CHANNEL_COUNT: u16 = 2;
const BYTES_PER_SAMPLE: u16 = 2;
const BYTES_PER_FRAME: u32 = CHANNEL_COUNT * BYTES_PER_SAMPLE;
const DEFAULT_OUT_PATH = "artifacts/procedural_renders/procedural_music_probe.wav";
const DEFAULT_SEED: u64 = 0xA6A1_6A01_0000_0001;

const StyleName = enum {
    americana_guitar,
};

const RenderConfig = struct {
    style: StyleName = .americana_guitar,
    duration_seconds: f32 = 24.0,
    out_path: []const u8 = DEFAULT_OUT_PATH,
    tempo_scale: f32 = 1.0,
    reverb_mix: f32 = 0.35,
    guitar_volume: f32 = 0.86,
    guitar_cue: procedural_americana_guitar.CuePreset = .open_road,
    seed: u64 = DEFAULT_SEED,
    fixed_seed: bool = true,
};

const RenderStats = struct {
    samples: u64 = 0,
    finite_samples: u64 = 0,
    non_finite_samples: u64 = 0,
    sum_sq: f64 = 0.0,
    peak_abs: f32 = 0.0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var show_help = false;
    const cfg = parseConfig(args, &show_help) catch |err| {
        printUsage();
        return err;
    };
    if (show_help) {
        printUsage();
        return;
    }

    const total_frames = try frameCount(cfg.duration_seconds);
    _ = entropy.configureFixedSeed(cfg.fixed_seed, cfg.seed);
    applyStyleSettings(cfg);

    try ensureParentDir(cfg.out_path);
    const file = try std.fs.cwd().createFile(cfg.out_path, .{ .truncate = true });
    defer file.close();

    try writeWavHeader(file, total_frames);
    const stats = try writeStyleFrames(file, cfg.style, total_frames);

    if (stats.non_finite_samples > 0) {
        std.log.warn("procedural_music_probe: replaced {d} non-finite samples with silence", .{stats.non_finite_samples});
    }

    std.log.info(
        "procedural_music_probe: wrote {s} style={s} cue={s} duration_seconds={d:.3} frames={d} rms={d:.5} peak={d:.5}",
        .{
            cfg.out_path,
            styleLabel(cfg.style),
            guitarCueLabel(cfg.guitar_cue),
            cfg.duration_seconds,
            total_frames,
            renderRms(stats),
            stats.peak_abs,
        },
    );
}

fn parseConfig(args: []const []const u8, show_help: *bool) !RenderConfig {
    var cfg: RenderConfig = .{};
    var style_set = false;
    var idx: usize = 1;

    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help.* = true;
            return cfg;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            if (style_set) {
                std.log.err("procedural_music_probe: unexpected positional argument '{s}'", .{arg});
                return error.InvalidArgument;
            }
            cfg.style = try parseStyleArg(arg);
            style_set = true;
            idx += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--style")) {
            const value = try optionValue(args, idx, arg);
            cfg.style = try parseStyleArg(value);
            style_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--duration")) {
            const value = try optionValue(args, idx, arg);
            cfg.duration_seconds = try parsePositiveFloatArg("duration", value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            cfg.out_path = try optionValue(args, idx, arg);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tempo")) {
            const value = try optionValue(args, idx, arg);
            cfg.tempo_scale = try parseBoundedFloatArg("tempo", value, 0.35, 1.65);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reverb")) {
            const value = try optionValue(args, idx, arg);
            cfg.reverb_mix = try parseBoundedFloatArg("reverb", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--volume")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_volume = try parseBoundedFloatArg("volume", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cue")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_cue = try parseGuitarCueArg(value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            const value = try optionValue(args, idx, arg);
            cfg.seed = try parseSeedArg(value);
            cfg.fixed_seed = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--random-seed")) {
            cfg.fixed_seed = false;
            idx += 1;
            continue;
        }

        std.log.err("procedural_music_probe: unknown option '{s}'", .{arg});
        return error.InvalidArgument;
    }

    return cfg;
}

fn optionValue(args: []const []const u8, option_idx: usize, option_name: []const u8) ![]const u8 {
    if (option_idx + 1 >= args.len) {
        std.log.err("procedural_music_probe: option {s} requires a value", .{option_name});
        return error.InvalidArgument;
    }
    return args[option_idx + 1];
}

fn parseStyleArg(arg: []const u8) !StyleName {
    const style = parseStyleName(arg) orelse {
        std.log.err("procedural_music_probe: unknown style '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return style;
}

fn parseStyleName(name: []const u8) ?StyleName {
    if (std.mem.eql(u8, name, "americana-guitar") or std.mem.eql(u8, name, "americana_guitar")) {
        return .americana_guitar;
    }
    return null;
}

fn parseGuitarCueArg(arg: []const u8) !procedural_americana_guitar.CuePreset {
    const cue = parseGuitarCueName(arg) orelse {
        std.log.err("procedural_music_probe: unknown guitar cue '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return cue;
}

fn parseGuitarCueName(name: []const u8) ?procedural_americana_guitar.CuePreset {
    if (std.mem.eql(u8, name, "open-road") or std.mem.eql(u8, name, "open_road")) return .open_road;
    if (std.mem.eql(u8, name, "low-drone") or std.mem.eql(u8, name, "low_drone")) return .low_drone;
    if (std.mem.eql(u8, name, "rolling-travis") or std.mem.eql(u8, name, "rolling_travis")) return .rolling_travis;
    if (std.mem.eql(u8, name, "high-lonesome") or std.mem.eql(u8, name, "high_lonesome")) return .high_lonesome;
    return null;
}

fn parsePositiveFloatArg(label: []const u8, arg: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("procedural_music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed <= 0.0) {
        std.log.err("procedural_music_probe: {s} must be finite and > 0 (got {d})", .{ label, parsed });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseBoundedFloatArg(label: []const u8, arg: []const u8, min_value: f32, max_value: f32) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("procedural_music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed < min_value or parsed > max_value) {
        std.log.err("procedural_music_probe: {s}={d} outside supported range {d}..{d}", .{ label, parsed, min_value, max_value });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseSeedArg(arg: []const u8) !u64 {
    return std.fmt.parseInt(u64, arg, 0) catch |err| {
        std.log.err("procedural_music_probe: invalid seed='{s}': {}", .{ arg, err });
        return error.InvalidArgument;
    };
}

fn applyStyleSettings(cfg: RenderConfig) void {
    switch (cfg.style) {
        .americana_guitar => {
            procedural_americana_guitar.bpm = cfg.tempo_scale;
            procedural_americana_guitar.reverb_mix = cfg.reverb_mix;
            procedural_americana_guitar.guitar_vol = cfg.guitar_volume;
            procedural_americana_guitar.selected_cue = cfg.guitar_cue;
        },
    }
}

fn resetStyle(style: StyleName) void {
    switch (style) {
        .americana_guitar => procedural_americana_guitar.reset(),
    }
}

fn fillStyleBuffer(style: StyleName, buf: [*]f32, frames: usize) void {
    switch (style) {
        .americana_guitar => procedural_americana_guitar.fillBuffer(buf, frames),
    }
}

fn frameCount(duration_seconds: f32) !u32 {
    const max_frames = (std.math.maxInt(u32) - 36) / BYTES_PER_FRAME;
    const frame_count_float = @ceil(duration_seconds * dsp.SAMPLE_RATE);
    if (frame_count_float > @as(f32, @floatFromInt(max_frames))) {
        std.log.err("procedural_music_probe: duration={d} is too long for a PCM WAV file", .{duration_seconds});
        return error.InvalidArgument;
    }
    return @intFromFloat(frame_count_float);
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.fs.cwd().makePath(parent);
}

fn writeWavHeader(file: std.fs.File, total_frames: u32) !void {
    const data_size = total_frames * BYTES_PER_FRAME;
    const riff_size = 36 + data_size;
    const byte_rate = SAMPLE_RATE_U32 * BYTES_PER_FRAME;
    const block_align: u16 = CHANNEL_COUNT * BYTES_PER_SAMPLE;
    const bits_per_sample: u16 = BYTES_PER_SAMPLE * 8;

    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    writeU32Le(header[4..8], riff_size);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    writeU32Le(header[16..20], 16);
    writeU16Le(header[20..22], 1);
    writeU16Le(header[22..24], CHANNEL_COUNT);
    writeU32Le(header[24..28], SAMPLE_RATE_U32);
    writeU32Le(header[28..32], byte_rate);
    writeU16Le(header[32..34], block_align);
    writeU16Le(header[34..36], bits_per_sample);
    @memcpy(header[36..40], "data");
    writeU32Le(header[40..44], data_size);

    try file.writeAll(&header);
}

fn writeStyleFrames(file: std.fs.File, style: StyleName, total_frames: u32) !RenderStats {
    const CHUNK_FRAMES = 1024;
    var samples: [CHUNK_FRAMES * 2]f32 = undefined;
    var bytes: [CHUNK_FRAMES * BYTES_PER_FRAME]u8 = undefined;
    var stats: RenderStats = .{};

    resetStyle(style);

    var frames_written: u32 = 0;
    while (frames_written < total_frames) {
        const remaining = total_frames - frames_written;
        const chunk_frames: u32 = @min(remaining, CHUNK_FRAMES);
        fillStyleBuffer(style, &samples, chunk_frames);

        var byte_idx: usize = 0;
        for (0..chunk_frames) |frame_idx| {
            const sample_idx = frame_idx * 2;
            const left = sanitizeSample(&stats, samples[sample_idx]);
            const right = sanitizeSample(&stats, samples[sample_idx + 1]);
            writeI16Le(bytes[byte_idx .. byte_idx + 2], floatToPcm16(left));
            writeI16Le(bytes[byte_idx + 2 .. byte_idx + 4], floatToPcm16(right));
            byte_idx += BYTES_PER_FRAME;
        }

        try file.writeAll(bytes[0..byte_idx]);
        frames_written += chunk_frames;
    }

    return stats;
}

fn sanitizeSample(stats: *RenderStats, sample: f32) f32 {
    stats.samples += 1;
    if (!std.math.isFinite(sample)) {
        stats.non_finite_samples += 1;
        return 0.0;
    }

    stats.finite_samples += 1;
    const abs_sample = @abs(sample);
    stats.peak_abs = @max(stats.peak_abs, abs_sample);
    const sample_f64: f64 = sample;
    stats.sum_sq += sample_f64 * sample_f64;
    return std.math.clamp(sample, -1.0, 1.0);
}

fn floatToPcm16(sample: f32) i16 {
    const clipped = std.math.clamp(sample, -1.0, 1.0);
    return @intFromFloat(clipped * 32767.0);
}

fn renderRms(stats: RenderStats) f64 {
    if (stats.finite_samples == 0) return 0.0;
    return @sqrt(stats.sum_sq / @as(f64, @floatFromInt(stats.finite_samples)));
}

fn writeU16Le(out: []u8, value: u16) void {
    out[0] = @intCast(value & 0x00FF);
    out[1] = @intCast((value >> 8) & 0x00FF);
}

fn writeU32Le(out: []u8, value: u32) void {
    out[0] = @intCast(value & 0x000000FF);
    out[1] = @intCast((value >> 8) & 0x000000FF);
    out[2] = @intCast((value >> 16) & 0x000000FF);
    out[3] = @intCast((value >> 24) & 0x000000FF);
}

fn writeI16Le(out: []u8, value: i16) void {
    const bits: u16 = @bitCast(value);
    writeU16Le(out, bits);
}

fn styleLabel(style: StyleName) []const u8 {
    return switch (style) {
        .americana_guitar => "americana-guitar",
    };
}

fn guitarCueLabel(cue: procedural_americana_guitar.CuePreset) []const u8 {
    return switch (cue) {
        .open_road => "open-road",
        .low_drone => "low-drone",
        .rolling_travis => "rolling-travis",
        .high_lonesome => "high-lonesome",
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zig build procedural-music-probe -- [style] [options]
        \\
        \\Styles:
        \\  americana-guitar
        \\
        \\Options:
        \\  --duration SECONDS
        \\  --out PATH
        \\  --tempo SCALE       0.35..1.65, default 1.0
        \\  --reverb VALUE      0..1, scaled inside the guitar style
        \\  --volume VALUE      0..1
        \\  --cue NAME          open-road, low-drone, rolling-travis, high-lonesome
        \\  --seed VALUE        decimal or 0x-prefixed fixed seed
        \\  --random-seed       use session randomness instead of fixed seed
        \\
    , .{});
}
