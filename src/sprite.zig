const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const camera = @import("camera.zig");
const time = @import("time.zig");
const polygon = @import("polygon.zig");
const box = @import("box2d.zig");
const config = @import("config.zig");

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const vec = @import("vector.zig");

const conv = @import("conversion.zig");

pub const Sprite = struct {
    texture: *sdl.Texture,
    surface: *sdl.Surface,
    scale: vec.Vec2,
    sizeM: vec.Vec2,
    sizeP: vec.IVec2,
    offset: vec.IVec2,
    imgPath: []const u8,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    pos: vec.IVec2,
};

pub fn drawWithOptions(sprite: Sprite, pos: vec.IVec2, angle: f32, highlight: bool, flip: bool, fog: f32) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    const rect = sdl.Rect{
        .x = pos.x + sprite.offset.x,
        .y = pos.y + sprite.offset.y,
        .w = sprite.sizeP.x,
        .h = sprite.sizeP.y,
    };

    try sdl.setTextureColorMod(sprite.texture, 255, 255, 255);
    if (fog > 0) {
        try sdl.setTextureColorMod(
            sprite.texture,
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
        );
    }

    if (highlight) {
        try sdl.setTextureColorMod(sprite.texture, 100, 100, 100);
    }
    try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, angle * 180.0 / PI, null, if (flip) sdl.RendererFlip.horizontal else sdl.RendererFlip.none);
}

pub fn createFromImg(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2) !Sprite {
    const imgPath = try shared.allocator.dupe(u8, imagePath);

    const imgPathZ = try shared.allocator.dupeZ(u8, imagePath);
    defer shared.allocator.free(imgPathZ);
    const surface = try image.load(imgPathZ);

    const resources = try shared.getResources();
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);

    size.x = @intFromFloat(@as(f32, @floatFromInt(size.x)) * scale.x);
    size.y = @intFromFloat(@as(f32, @floatFromInt(size.y)) * scale.y);
    const sizeM = conv.p2m(.{ .x = size.x, .y = size.y });

    const sprite = Sprite{
        .surface = surface,
        .imgPath = imgPath,
        .texture = texture,
        .scale = scale,
        .offset = offset,
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

pub fn removeCircleFromSurface(sprite: Sprite, centerWorld: vec.Vec2, radiusWorld: f32, entityPos: vec.Vec2, rotation: f32) !void {
    const surface = sprite.surface.*;
    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const bytesPerPixel: usize = 4; // Assume RGBA format

    // Transform explosion center from world space (meters) to sprite local space (pixels)
    // 1. Translate to entity-relative coordinates (meters)
    const relativeWorld = vec.Vec2{
        .x = centerWorld.x - entityPos.x,
        .y = centerWorld.y - entityPos.y,
    };

    // 2. Rotate by inverse of entity rotation (meters)
    const cosA = @cos(-rotation);
    const sinA = @sin(-rotation);
    const rotatedLocal = vec.Vec2{
        .x = relativeWorld.x * cosA - relativeWorld.y * sinA,
        .y = relativeWorld.x * sinA + relativeWorld.y * cosA,
    };

    // 3. Convert to sprite pixel coordinates (entity center is at sprite center)
    const rotatedLocalPixels = conv.m2Pixel(.{ .x = rotatedLocal.x, .y = rotatedLocal.y });
    const centerPixelF = vec.Vec2{
        .x = @as(f32, @floatFromInt(rotatedLocalPixels.x)) / sprite.scale.x + @as(f32, @floatFromInt(width)) / 2.0,
        .y = @as(f32, @floatFromInt(rotatedLocalPixels.y)) / sprite.scale.y + @as(f32, @floatFromInt(height)) / 2.0,
    };

    const radiusPixels = (radiusWorld * config.met2pix) / sprite.scale.x; 

    // 4. Calculate bounding box for iteration efficiency
    const minX: usize = @max(0, @as(i32, @intFromFloat(@floor(centerPixelF.x - radiusPixels))));
    const maxX: usize = @min(width - 1, @as(usize, @intFromFloat(@ceil(centerPixelF.x + radiusPixels))));
    const minY: usize = @max(0, @as(i32, @intFromFloat(@floor(centerPixelF.y - radiusPixels))));
    const maxY: usize = @min(height - 1, @as(usize, @intFromFloat(@ceil(centerPixelF.y + radiusPixels))));

    // 5. Remove pixels within the circle
    var y = minY;
    while (y <= maxY) : (y += 1) {
        var x = minX;
        while (x <= maxX) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - centerPixelF.x;
            const dy = @as(f32, @floatFromInt(y)) - centerPixelF.y;
            const distSq = dx * dx + dy * dy;

            if (distSq <= radiusPixels * radiusPixels) {
                const pixelIndex = y * pitch + x * bytesPerPixel;
                // Set alpha to 0 (assuming RGBA)
                if (bytesPerPixel == 4) {
                    pixels[pixelIndex + 3] = 0;
                }
            }
        }
    }
}

pub fn updateTextureFromSurface(sprite: *Sprite) !void {
    const resources = try shared.getResources();

    // Destroy old texture
    sdl.destroyTexture(sprite.texture);

    // Create new texture from modified surface
    sprite.texture = try sdl.createTextureFromSurface(resources.renderer, sprite.surface);
}
