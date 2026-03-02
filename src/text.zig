const std = @import("std");

const sdl = @import("sdl.zig");
const tex = @import("texture.zig");
const gpu = @import("gpu.zig");

const IVec2 = @import("vector.zig").IVec2;

const shared = @import("shared.zig");

pub fn writeAt(text: [:0]const u8, position: IVec2) !void {
    const resources = try shared.getResources();
    const color = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surface = try sdl.ttf.renderTextSolid(resources.monocraftFont, text, color);
    defer sdl.destroySurface(surface);

    const texture = try tex.createStandaloneTexture(resources.renderer, surface);
    defer tex.destroyTexture(texture);

    const rect = sdl.Rect{ .x = position.x, .y = position.y, .w = surface.*.w, .h = surface.*.h };

    try gpu.renderCopy(resources.renderer, texture, null, &rect);
}
