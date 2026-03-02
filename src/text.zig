const std = @import("std");

const sdl = @import("sdl.zig");
const tex = @import("texture.zig");
const gpu = @import("gpu.zig");

const IVec2 = @import("vector.zig").IVec2;

const monocraftSrc = "fonts/monocraft.ttf";

var font: ?*sdl.Font = null;

pub fn init() !void {
    try sdl.ttf.init();
    font = try sdl.ttf.openFont(monocraftSrc, 24);
}

pub fn cleanup() void {
    if (font) |f| {
        sdl.ttf.closeFont(f);
        font = null;
    }
    sdl.ttf.quit();
}

pub fn writeAt(text: [:0]const u8, position: IVec2) !void {
    const f = font orelse @panic("Font uninitialized");
    const color = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surface = try sdl.ttf.renderTextSolid(f, text, color);
    defer sdl.destroySurface(surface);

    const texture = try tex.createStandaloneTexture(surface);
    defer tex.destroyTexture(texture);

    const rect = sdl.Rect{ .x = position.x, .y = position.y, .w = surface.*.w, .h = surface.*.h };

    try gpu.renderCopy(texture, null, &rect);
}
