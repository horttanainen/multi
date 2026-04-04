// Animated paint-swirl background rendered on the GPU each frame.
// Algorithm adapted from Balatro's background shader (originally by localthunk).
const std = @import("std");
const gpu = @import("gpu.zig");
const music = @import("music.zig");
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
    .bass_mode = 3.0,
    .bass_strength = 0.45,
    .texture_mode = 5.0,
    .texture_strength = 0.35,
    .accent_mode = 8.0,
    .accent_strength = 0.28,
    .loudness_mode = 8.0,
    .loudness_strength = 0.22,
    .onset_mode = 10.0,
    .onset_strength = 0.24,
};

const backgroundConfigMenu = @import("backgroundConfigMenu.zig");

pub fn init() void {
    backgroundConfigMenu.randomize();
}

pub fn draw() void {
    var draw_uniforms = uniforms;
    const reactive = music.getReactiveVisual();
    draw_uniforms.resolution = .{ @floatFromInt(window.width), @floatFromInt(window.height) };
    draw_uniforms.time = @floatCast(time.passedTime);
    draw_uniforms.audio_loudness = reactive.loudness;
    draw_uniforms.audio_loudness_att = reactive.loudness_att;
    draw_uniforms.audio_bass = reactive.low;
    draw_uniforms.audio_bass_att = reactive.low_att;
    draw_uniforms.audio_texture = reactive.mid;
    draw_uniforms.audio_texture_att = reactive.mid_att;
    draw_uniforms.audio_accent = reactive.high;
    draw_uniforms.audio_accent_att = reactive.high_att;
    draw_uniforms.audio_onset = reactive.onset;
    gpu.drawPaintBackground(draw_uniforms);
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
