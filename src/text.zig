const std = @import("std");

const sdl = @import("sdl.zig");
const tex = @import("texture.zig");
const gpu = @import("gpu.zig");

const IVec2 = @import("vector.zig").IVec2;

const monocraftSrc = "fonts/monocraft.ttf";

pub const Font = enum { small, medium, large };

var fonts: [3]?*sdl.Font = .{ null, null, null };

const font_sizes = [3]f32{ 24, 36, 48 };

pub fn init() !void {
    try sdl.ttf.init();
    inline for (0..3) |i| {
        fonts[i] = try sdl.ttf.openFont(monocraftSrc, font_sizes[i]);
    }
}

pub fn cleanup() void {
    inline for (0..3) |i| {
        if (fonts[i]) |f| {
            sdl.ttf.closeFont(f);
            fonts[i] = null;
        }
    }
    sdl.ttf.quit();
}

fn getFont(size: Font) *sdl.Font {
    return fonts[@intFromEnum(size)] orelse @panic("Font uninitialized");
}

pub fn measure(size: Font, t: [:0]const u8) !IVec2 {
    const color = sdl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const surface = try sdl.ttf.renderTextSolid(getFont(size), t, color);
    defer sdl.destroySurface(surface);
    return IVec2{ .x = surface.*.w, .y = surface.*.h };
}

pub fn write(size: Font, t: [:0]const u8, position: IVec2) !void {
    const color = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surface = try sdl.ttf.renderTextSolid(getFont(size), t, color);
    defer sdl.destroySurface(surface);

    const texture = try tex.createStandaloneTexture(surface);
    defer tex.destroyTexture(texture);

    const rect = sdl.Rect{ .x = position.x, .y = position.y, .w = surface.*.w, .h = surface.*.h };
    try gpu.renderCopy(texture, null, &rect);
}

pub fn writeCenter(size: Font, t: [:0]const u8, center: IVec2) !void {
    try writeCenterWithAlpha(size, t, center, 255);
}

pub fn writeCenterWithAlpha(size: Font, t: [:0]const u8, center: IVec2, alpha: u8) !void {
    const color = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surface = try sdl.ttf.renderTextSolid(getFont(size), t, color);
    defer sdl.destroySurface(surface);

    const texture = try tex.createStandaloneTexture(surface);
    defer tex.destroyTexture(texture);

    try tex.setTextureAlphaMod(texture, alpha);

    const rect = sdl.Rect{
        .x = center.x - @divFloor(surface.*.w, 2),
        .y = center.y - @divFloor(surface.*.h, 2),
        .w = surface.*.w,
        .h = surface.*.h,
    };
    try gpu.renderCopy(texture, null, &rect);
}
