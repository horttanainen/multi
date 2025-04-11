const std = @import("std");

const sdl = @import("zsdl");
const ttf = @import("zsdl_ttf");

const IVec2 = @import("vector.zig").IVec2;

const shared = @import("shared.zig");

pub fn writeAt(text: [:0]const u8, position: IVec2) !void {
    const resources = try shared.getResources();
    const color = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surface = try ttf.Font.renderTextSolid(resources.monocraftFont, text, color);

    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    const rect = sdl.Rect{ .x = position.x, .y = position.y, .w = surface.*.w, .h = surface.*.h };

    try sdl.renderCopy(resources.renderer, texture, null, &rect);
}
