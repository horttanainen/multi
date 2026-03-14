const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");
const gpu = @import("gpu.zig");
const settings = @import("settings.zig");
const allocator = @import("allocator.zig").allocator;
const sdl = @import("sdl.zig");
const c = sdl.c;

const LUT_SIZE: u32 = 32;
const TEX_W: u32 = LUT_SIZE * LUT_SIZE;
const TEX_H: u32 = LUT_SIZE;

const LutEntry = struct {
    name: []const u8,
    path: []const u8,
};

var entries: std.ArrayList(LutEntry) = .{};
var current_index: usize = 0;

pub fn init() !void {
    // Always have "None" as first entry (identity LUT)
    const none_name = try allocator.dupe(u8, "None");
    errdefer allocator.free(none_name);
    const none_path = try allocator.dupe(u8, "");
    errdefer allocator.free(none_path);
    try entries.append(allocator, .{ .name = none_name, .path = none_path });

    // Generate built-in LUT files if configured or if they don't exist yet.
    generateBuiltinLuts(config.lut.regenerate_builtin_luts_on_startup);

    // Load luts.json
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("luts.json", &jsonBuf) catch |err| {
        std.log.warn("lut: could not read luts.json: {}", .{err});
        return;
    };

    const Entry = struct {
        name: []const u8,
        path: []const u8,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.log.warn("lut: failed to parse luts.json: {}", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const name = allocator.dupe(u8, entry.name) catch continue;
        const path = allocator.dupe(u8, entry.path) catch {
            allocator.free(name);
            continue;
        };
        entries.append(allocator, .{ .name = name, .path = path }) catch {
            allocator.free(name);
            allocator.free(path);
            continue;
        };
        std.debug.print("Loaded LUT '{s}'\n", .{name});
    }

    applyPreferredFromSettings();
}

pub fn cleanup() void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    entries.deinit(allocator);
}

pub fn currentName() [:0]const u8 {
    if (current_index < entries.items.len) {
        // All names from JSON are null-terminated via the bufPrintZ in menu label generation
        // but we need a sentinel-terminated string for text rendering
        return std.fmt.bufPrintZ(&name_buf, "{s}", .{entries.items[current_index].name}) catch |err| {
            std.log.warn("currentName: failed to format LUT name at index {d}: {}", .{ current_index, err });
            return "None";
        };
    }
    std.log.warn("currentName: LUT index {d} is out of bounds for {d} entries", .{ current_index, entries.items.len });
    return "None";
}

var name_buf: [64:0]u8 = undefined;

pub fn entryCount() usize {
    return entries.items.len;
}

pub fn entryName(index: usize) ?[]const u8 {
    if (index >= entries.items.len) {
        std.log.warn("entryName: LUT index {d} is out of bounds for {d} entries", .{ index, entries.items.len });
        return null;
    }
    return entries.items[index].name;
}

pub fn currentIndex() usize {
    return current_index;
}

pub fn select(index: usize) bool {
    if (index >= entries.items.len) {
        std.log.warn("select: LUT index {d} is out of bounds for {d} entries", .{ index, entries.items.len });
        return false;
    }
    if (applyLut(index)) {
        current_index = index;
        return true;
    }
    return false;
}

pub fn selectByName(name: []const u8) bool {
    for (entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) {
            return select(index);
        }
    }
    std.log.warn("selectByName: no LUT named '{s}'", .{name});
    return false;
}

pub fn cycleNext() void {
    if (entries.items.len == 0) return;
    const next_index = (current_index + 1) % entries.items.len;
    if (applyLut(next_index)) {
        current_index = next_index;
    }
}

pub fn cyclePrev() void {
    if (entries.items.len == 0) return;
    const prev_index = (current_index + entries.items.len - 1) % entries.items.len;
    if (applyLut(prev_index)) {
        current_index = prev_index;
    }
}

pub fn reloadCurrent() void {
    if (current_index >= entries.items.len) {
        std.log.warn("reloadCurrent: LUT index {d} is out of bounds for {d} entries", .{ current_index, entries.items.len });
        return;
    }
    _ = applyLut(current_index);
}

fn applyLut(index: usize) bool {
    if (index == 0) {
        gpu.loadLutFromIdentity() catch |err| {
            std.log.warn("applyLut: failed to restore identity LUT: {}", .{err});
            return false;
        };
        return true;
    }
    const entry = entries.items[index];
    const pathZ = std.fmt.bufPrintZ(&path_buf, "{s}", .{entry.path}) catch {
        std.log.warn("lut: path too long for '{s}'", .{entry.name});
        return false;
    };
    gpu.loadLutFromFile(pathZ) catch |err| {
        std.log.warn("lut: failed to load '{s}': {}", .{ entry.path, err });
        return false;
    };
    return true;
}

fn applyPreferredFromSettings() void {
    const preferred = settings.preferredColorGrading() orelse return;
    if (!selectByName(preferred)) {
        std.log.warn("applyPreferredFromSettings: preferred LUT '{s}' was not found", .{preferred});
    }
}

var path_buf: [256:0]u8 = undefined;

// ============================================================
// Example LUT generation
// ============================================================

pub fn regenerateBuiltinLuts() void {
    generateBuiltinLuts(true);
}

fn generateBuiltinLuts(force: bool) void {
    // Create luts/ directory if needed
    std.fs.cwd().makeDir("luts") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.log.warn("lut: failed to create luts/ directory: {}", .{err});
            return;
        },
    };

    generateLut("luts/warm.png", warmTransform, force) catch |err|
        std.log.warn("lut: failed to generate warm.png: {}", .{err});
    generateLut("luts/cool.png", coolTransform, force) catch |err|
        std.log.warn("lut: failed to generate cool.png: {}", .{err});
    generateLut("luts/noir.png", noirTransform, force) catch |err|
        std.log.warn("lut: failed to generate noir.png: {}", .{err});
    generateLut("luts/vibrant.png", vibrantTransform, force) catch |err|
        std.log.warn("lut: failed to generate vibrant.png: {}", .{err});
    generateLut("luts/teal_orange.png", tealOrangeTransform, force) catch |err|
        std.log.warn("lut: failed to generate teal_orange.png: {}", .{err});
    generateLut("luts/bleach_bypass.png", bleachBypassTransform, force) catch |err|
        std.log.warn("lut: failed to generate bleach_bypass.png: {}", .{err});
    generateLut("luts/faded_film.png", fadedFilmTransform, force) catch |err|
        std.log.warn("lut: failed to generate faded_film.png: {}", .{err});
    generateLut("luts/golden_hour.png", goldenHourTransform, force) catch |err|
        std.log.warn("lut: failed to generate golden_hour.png: {}", .{err});
    generateLut("luts/winter_mood.png", winterMoodTransform, force) catch |err|
        std.log.warn("lut: failed to generate winter_mood.png: {}", .{err});
    generateLut("luts/technicolor.png", technicolorTransform, force) catch |err|
        std.log.warn("lut: failed to generate technicolor.png: {}", .{err});
    generateLut("luts/vintage.png", vintageTransform, force) catch |err|
        std.log.warn("lut: failed to generate vintage.png: {}", .{err});
    generateLut("luts/cyberpunk.png", cyberpunkTransform, force) catch |err|
        std.log.warn("lut: failed to generate cyberpunk.png: {}", .{err});
    generateLut("luts/retro.png", retroTransform, force) catch |err|
        std.log.warn("lut: failed to generate retro.png: {}", .{err});
    generateLut("luts/pixel.png", pixelTransform, force) catch |err|
        std.log.warn("lut: failed to generate pixel.png: {}", .{err});
    generateLut("luts/arcade.png", arcadeTransform, force) catch |err|
        std.log.warn("lut: failed to generate arcade.png: {}", .{err});
    generateLut("luts/silent_hill_2.png", silentHill2Transform, force) catch |err|
        std.log.warn("lut: failed to generate silent_hill_2.png: {}", .{err});
    generateLut("luts/mario.png", marioTransform, force) catch |err|
        std.log.warn("lut: failed to generate mario.png: {}", .{err});
}

const ColorTransformFn = *const fn (r: f32, g: f32, b: f32) [3]f32;

fn generateLut(path: []const u8, transform: ColorTransformFn, force: bool) !void {
    // Skip if file already exists
    if (!force) {
        if (std.fs.cwd().access(path, .{})) {
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.warn("generateLut: failed to check whether {s} exists: {}", .{ path, err });
                return err;
            },
        }
    }

    var pixels: [TEX_W * TEX_H * 4]u8 = undefined;
    for (0..TEX_H) |y| {
        for (0..TEX_W) |x| {
            const blue_slice = x / LUT_SIZE;
            const red = x % LUT_SIZE;
            const green = y;

            const rf: f32 = @as(f32, @floatFromInt(red)) / 31.0;
            const gf: f32 = @as(f32, @floatFromInt(green)) / 31.0;
            const bf: f32 = @as(f32, @floatFromInt(blue_slice)) / 31.0;

            const result = transform(rf, gf, bf);

            const idx = (y * TEX_W + x) * 4;
            pixels[idx + 0] = @intFromFloat(std.math.clamp(result[0], 0, 1) * 255.0);
            pixels[idx + 1] = @intFromFloat(std.math.clamp(result[1], 0, 1) * 255.0);
            pixels[idx + 2] = @intFromFloat(std.math.clamp(result[2], 0, 1) * 255.0);
            pixels[idx + 3] = 255;
        }
    }

    const surface = c.SDL_CreateSurface(@intCast(TEX_W), @intCast(TEX_H), c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.warn("lut: failed to create surface for {s}", .{path});
        return error.CreateSurfaceFailed;
    };
    defer c.SDL_DestroySurface(surface);

    const dst: [*]u8 = @ptrCast(surface.*.pixels orelse {
        std.log.warn("generateLut: surface has no pixel data for {s}", .{path});
        return error.NoPixelData;
    });
    const pitch: u32 = @intCast(surface.*.pitch);
    const row_bytes = TEX_W * 4;
    for (0..TEX_H) |row| {
        @memcpy(dst[row * pitch .. row * pitch + row_bytes], pixels[row * row_bytes .. row * row_bytes + row_bytes]);
    }

    const pathZ = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
    if (!c.IMG_SavePNG(surface, pathZ)) {
        std.log.warn("lut: failed to save {s}", .{path});
        return error.SaveFailed;
    }
    std.debug.print("Generated LUT '{s}'\n", .{path});
}

// -- Color transform functions --

fn warmTransform(r: f32, g: f32, b: f32) [3]f32 {
    // Warm tint: boost reds/yellows, reduce blues
    return .{
        std.math.clamp(r * 1.1 + 0.05, 0, 1),
        std.math.clamp(g * 1.02 + 0.02, 0, 1),
        std.math.clamp(b * 0.85, 0, 1),
    };
}

fn coolTransform(r: f32, g: f32, b: f32) [3]f32 {
    // Cool tint: boost blues, reduce warm tones
    return .{
        std.math.clamp(r * 0.88, 0, 1),
        std.math.clamp(g * 0.95 + 0.02, 0, 1),
        std.math.clamp(b * 1.12 + 0.05, 0, 1),
    };
}

fn noirTransform(r: f32, g: f32, b: f32) [3]f32 {
    // High contrast near-monochrome with slight warm tint
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    // S-curve for contrast
    const contrast = if (luma < 0.5)
        2.0 * luma * luma
    else
        1.0 - 2.0 * (1.0 - luma) * (1.0 - luma);
    // Mix 80% mono + 20% original, with warm offset
    const mono_mix: f32 = 0.8;
    return .{
        std.math.clamp(contrast * mono_mix + r * (1.0 - mono_mix) + 0.03, 0, 1),
        std.math.clamp(contrast * mono_mix + g * (1.0 - mono_mix), 0, 1),
        std.math.clamp(contrast * mono_mix + b * (1.0 - mono_mix) - 0.02, 0, 1),
    };
}

fn vibrantTransform(r: f32, g: f32, b: f32) [3]f32 {
    // Boost saturation while keeping channel values in a valid range.
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const sat_boost: f32 = 1.2;
    const rr = std.math.clamp(luma + (r - luma) * sat_boost, 0, 1);
    const gg = std.math.clamp(luma + (g - luma) * sat_boost, 0, 1);
    const bb = std.math.clamp(luma + (b - luma) * sat_boost, 0, 1);

    // Gentle gamma lift to keep the look punchy without producing invalid values.
    return .{
        std.math.clamp(std.math.pow(f32, rr, 0.95), 0, 1),
        std.math.clamp(std.math.pow(f32, gg, 0.95), 0, 1),
        std.math.clamp(std.math.pow(f32, bb, 0.95), 0, 1),
    };
}

fn tealOrangeTransform(r: f32, g: f32, b: f32) [3]f32 {
    const shadows = (1.0 - (r * 0.299 + g * 0.587 + b * 0.114));
    const highlights = @max(r, @max(g, b));
    return .{
        std.math.clamp(r * 1.08 + highlights * 0.05 - shadows * 0.04, 0, 1),
        std.math.clamp(g * 1.0 + b * 0.03, 0, 1),
        std.math.clamp(b * 1.12 + shadows * 0.06 - highlights * 0.03, 0, 1),
    };
}

fn bleachBypassTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const high_contrast = if (luma < 0.5)
        2.0 * luma * luma
    else
        1.0 - 2.0 * (1.0 - luma) * (1.0 - luma);
    const mix: f32 = 0.65;
    return .{
        std.math.clamp(high_contrast * mix + r * (1.0 - mix), 0, 1),
        std.math.clamp(high_contrast * mix + g * (1.0 - mix), 0, 1),
        std.math.clamp(high_contrast * mix + b * (1.0 - mix), 0, 1),
    };
}

fn fadedFilmTransform(r: f32, g: f32, b: f32) [3]f32 {
    return .{
        std.math.clamp(0.08 + r * 0.84, 0, 1),
        std.math.clamp(0.07 + g * 0.82, 0, 1),
        std.math.clamp(0.06 + b * 0.78, 0, 1),
    };
}

fn goldenHourTransform(r: f32, g: f32, b: f32) [3]f32 {
    const warmth = r * 0.35 + g * 0.2;
    return .{
        std.math.clamp(r * 1.12 + 0.04, 0, 1),
        std.math.clamp(g * 1.04 + warmth * 0.05, 0, 1),
        std.math.clamp(b * 0.88 + warmth * 0.02, 0, 1),
    };
}

fn winterMoodTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    return .{
        std.math.clamp(r * 0.9 + luma * 0.02, 0, 1),
        std.math.clamp(g * 0.97 + b * 0.03, 0, 1),
        std.math.clamp(b * 1.1 + 0.03, 0, 1),
    };
}

fn technicolorTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const sat_boost: f32 = 1.28;
    const rr = std.math.clamp(luma + (r - luma) * sat_boost + 0.02, 0, 1);
    const gg = std.math.clamp(luma + (g - luma) * 1.12, 0, 1);
    const bb = std.math.clamp(luma + (b - luma) * sat_boost - 0.01, 0, 1);
    return .{
        std.math.clamp(std.math.pow(f32, rr, 0.92), 0, 1),
        std.math.clamp(std.math.pow(f32, gg, 0.95), 0, 1),
        std.math.clamp(std.math.pow(f32, bb, 0.92), 0, 1),
    };
}

fn vintageTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    return .{
        std.math.clamp(0.1 + luma * 0.2 + r * 0.65, 0, 1),
        std.math.clamp(0.08 + luma * 0.18 + g * 0.55, 0, 1),
        std.math.clamp(0.04 + luma * 0.12 + b * 0.38, 0, 1),
    };
}

fn cyberpunkTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    return .{
        std.math.clamp(luma * 0.12 + r * 1.08 + b * 0.12, 0, 1),
        std.math.clamp(g * 0.82 + b * 0.18, 0, 1),
        std.math.clamp(luma * 0.08 + b * 1.2 + r * 0.06, 0, 1),
    };
}

fn retroTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    return .{
        std.math.clamp(0.06 + luma * 0.08 + r * 0.92, 0, 1),
        std.math.clamp(0.05 + luma * 0.1 + g * 0.88, 0, 1),
        std.math.clamp(0.08 + luma * 0.12 + b * 0.84, 0, 1),
    };
}

fn pixelTransform(r: f32, g: f32, b: f32) [3]f32 {
    const levels: f32 = 5.0;
    const rr = @round(std.math.clamp(r, 0, 1) * (levels - 1.0)) / (levels - 1.0);
    const gg = @round(std.math.clamp(g, 0, 1) * (levels - 1.0)) / (levels - 1.0);
    const bb = @round(std.math.clamp(b, 0, 1) * (levels - 1.0)) / (levels - 1.0);
    return .{ rr, gg, bb };
}

fn arcadeTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const sat_boost: f32 = 1.35;
    const rr = std.math.clamp(luma + (r - luma) * sat_boost + 0.03, 0, 1);
    const gg = std.math.clamp(luma + (g - luma) * sat_boost + 0.02, 0, 1);
    const bb = std.math.clamp(luma + (b - luma) * sat_boost + 0.03, 0, 1);
    return .{
        std.math.clamp(std.math.pow(f32, rr, 0.9), 0, 1),
        std.math.clamp(std.math.pow(f32, gg, 0.9), 0, 1),
        std.math.clamp(std.math.pow(f32, bb, 0.9), 0, 1),
    };
}

fn silentHill2Transform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const fog = 0.08 + luma * 0.18;
    return .{
        std.math.clamp(fog + r * 0.48, 0, 1),
        std.math.clamp(fog + g * 0.62 + 0.02, 0, 1),
        std.math.clamp(fog + b * 0.46, 0, 1),
    };
}

fn marioTransform(r: f32, g: f32, b: f32) [3]f32 {
    const luma = r * 0.299 + g * 0.587 + b * 0.114;
    const rr = std.math.clamp(luma + (r - luma) * 1.4 + 0.04, 0, 1);
    const gg = std.math.clamp(luma + (g - luma) * 1.28 + 0.03, 0, 1);
    const bb = std.math.clamp(luma + (b - luma) * 1.18, 0, 1);
    return .{
        std.math.clamp(std.math.pow(f32, rr, 0.92), 0, 1),
        std.math.clamp(std.math.pow(f32, gg, 0.93), 0, 1),
        std.math.clamp(std.math.pow(f32, bb, 0.97), 0, 1),
    };
}
