const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");
const box2d = @import("box2dnative.zig");

const AutoArrayHashMap = std.AutoArrayHashMap;

const camera = @import("camera.zig");
const time = @import("time.zig");
const polygon = @import("polygon.zig");
const box = @import("box.zig");
const State = box.State;

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const vec = @import("vector.zig");

const conv = @import("conversion.zig");

pub const Sprite = struct {
    texture: *sdl.Texture,
    surface: *sdl.Surface,
    sizeM: vec.Vec2,
    sizeP: vec.IVec2,
    imgPath: []const u8,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    pos: vec.IVec2,
};

pub fn drawWithOptions(sprite: Sprite, pos: vec.IVec2, angle: f32, highlight: bool, flip: bool) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    const rect = sdl.Rect{
        .x = pos.x,
        .y = pos.y,
        .w = sprite.sizeP.x,
        .h = sprite.sizeP.y,
    };

    try sdl.setTextureColorMod(sprite.texture, 255, 255, 255);
    if (highlight) {
        try sdl.setTextureColorMod(sprite.texture, 100, 100, 100);
    }
    try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, angle * 180.0 / PI, null, if (flip) sdl.RendererFlip.horizontal else sdl.RendererFlip.none);
}

pub fn createFromImg(imagePath: []const u8) !Sprite {
    const imgPath = try shared.allocator.dupe(u8, imagePath);

    const imgPathZ = try shared.allocator.dupeZ(u8, imagePath);
    defer shared.allocator.free(imgPathZ);
    const surface = try image.load(imgPathZ);

    const resources = try shared.getResources();
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const sizeM = conv.p2m(.{ .x = size.x, .y = size.y });

    const sprite = Sprite{
        .surface = surface,
        .imgPath = imgPath,
        .texture = texture,
        .sizeM = .{
            .x = sizeM.x,
            .y = sizeM.y,
        },
        .sizeP = .{
            .x = size.x,
            .y = size.y,
        },
    };

    return sprite;
}

pub fn cleanup(sprite: Sprite) void {
    shared.allocator.free(sprite.imgPath);
}
