// Animated paint-swirl background rendered on the GPU each frame.
// Algorithm adapted from Balatro's background shader (originally by localthunk).
const std = @import("std");
const gpu = @import("gpu.zig");
const time = @import("time.zig");
const window = @import("window.zig");

pub var uniforms: gpu.PaintUniforms = .{
    .resolution = .{ 0, 0 },
    .spin_rotation = 0,
    .spin_speed = 0,
    .offset = .{ 0, 0 },
    .contrast = 2,
    .spin_amount = 0.4,
    .pixel_filter = 250,
    .time = 0,
    .colour_1 = .{ 0.5, 0.3, 0.3 },
    .colour_2 = .{ 0.3, 0.5, 0.3 },
    .colour_3 = .{ 0.3, 0.3, 0.5 },
};

pub fn init() void {
    randomize();
}

pub fn randomize() void {
    const rng = std.crypto.random;

    const base_hue: f32 = rng.float(f32);
    const hue_step: f32 = 0.08 + rng.float(f32) * 0.15;
    const sat: f32 = 0.55 + rng.float(f32) * 0.3;
    const val: f32 = 0.40 + rng.float(f32) * 0.35;

    // Preserve algorithm selections and structure across randomization
    const prev_swirl = uniforms.swirl_type;
    const prev_noise = uniforms.noise_type;
    const prev_color = uniforms.color_mode;
    const prev_offset_z = uniforms.offset_z;
    const prev_swirl_count = uniforms.swirl_count;
    const prev_swirl_segments = uniforms.swirl_segments;
    const prev_c1 = uniforms.swirl_center_1;
    const prev_c2 = uniforms.swirl_center_2;
    const prev_c3 = uniforms.swirl_center_3;
    const prev_c4 = uniforms.swirl_center_4;

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
        .swirl_type = prev_swirl,
        .noise_type = prev_noise,
        .color_mode = prev_color,
        .noise_scale = 0.5 + rng.float(f32) * 2.0,
        .noise_octaves = @floatFromInt(rng.intRangeAtMost(u8, 2, 10)),
        .offset_z = prev_offset_z,
        .color_intensity = 0.5 + rng.float(f32) * 1.5,
        .swirl_segments = prev_swirl_segments,
        .swirl_count = prev_swirl_count,
        .swirl_center_1 = prev_c1,
        .swirl_center_2 = prev_c2,
        .swirl_center_3 = prev_c3,
        .swirl_center_4 = prev_c4,
        .noise_speed = 0.1 + rng.float(f32) * 1.0,
        .noise_amplitude = 0.5 + rng.float(f32) * 1.5,
        .color_speed = rng.float(f32) * 0.5,
        .swirl_falloff = 1.0 + rng.float(f32) * 4.0,
    };

    std.log.info("background_paint: GPU shader (pixel_filter={d:.0})", .{uniforms.pixel_filter});
}

pub fn draw() void {
    uniforms.resolution = .{ @floatFromInt(window.width), @floatFromInt(window.height) };
    uniforms.time = @floatCast(time.passedTime);
    gpu.drawPaintBackground(uniforms);
}

pub fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
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

pub fn rgbToHsv(rgb: [3]f32) [3]f32 {
    const r = rgb[0];
    const g = rgb[1];
    const b = rgb[2];
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;

    var h: f32 = 0;
    if (delta > 0.00001) {
        if (max_c == r) {
            h = @mod((g - b) / delta, 6.0) / 6.0;
        } else if (max_c == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
        if (h < 0) h += 1.0;
    }

    const s: f32 = if (max_c > 0.00001) delta / max_c else 0;
    return .{ h, s, max_c };
}
