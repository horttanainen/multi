// Animated paint-swirl background rendered on the GPU each frame.
// Algorithm adapted from Balatro's background shader (originally by localthunk).
const std = @import("std");
const gpu = @import("gpu.zig");
const time = @import("time.zig");
const window = @import("window.zig");

var uniforms: gpu.PaintUniforms = undefined;

pub fn init() void {
    const rng = std.crypto.random;

    const base_hue: f32 = rng.float(f32);
    const hue_step: f32 = 0.08 + rng.float(f32) * 0.15;
    const sat: f32 = 0.55 + rng.float(f32) * 0.3;
    const val: f32 = 0.40 + rng.float(f32) * 0.35;

    uniforms = .{
        .resolution = .{ @floatFromInt(window.width), @floatFromInt(window.height) },
        .spin_rotation = rng.float(f32) * std.math.tau,
        .spin_speed = 0.3 + rng.float(f32) * 0.4,
        .offset = .{ (rng.float(f32) - 0.5) * 0.3, (rng.float(f32) - 0.5) * 0.3 },
        .contrast = 1.5 + rng.float(f32) * 1.5,
        .spin_amount = 0.2 + rng.float(f32) * 0.4,
        .pixel_filter = 150.0 + rng.float(f32) * 250.0,
        .time = 0,
        .colour_1 = hsvToRgb(base_hue, sat, val),
        .colour_2 = hsvToRgb(@mod(base_hue + hue_step, 1.0), sat, val),
        .colour_3 = hsvToRgb(@mod(base_hue + 0.45 + rng.float(f32) * 0.15, 1.0), sat * 0.85, val * 1.15),
    };

    std.log.info("background_paint: GPU shader (pixel_filter={d:.0})", .{uniforms.pixel_filter});
}

pub fn draw() void {
    uniforms.resolution = .{ @floatFromInt(window.width), @floatFromInt(window.height) };
    uniforms.time = @floatCast(time.passedTime);
    gpu.drawPaintBackground(uniforms);
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const i: u32 = @intFromFloat(@mod(@floor(h * 6.0), 6.0));
    const f: f32 = h * 6.0 - @floor(h * 6.0);
    const p: f32 = v * (1.0 - s);
    const q: f32 = v * (1.0 - f * s);
    const t: f32 = v * (1.0 - (1.0 - f) * s);
    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}
