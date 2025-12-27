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

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

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

pub fn drawWithOptions(sprite: Sprite, pos: vec.IVec2, angle: f32, highlight: bool, flip: bool, fog: f32, maybeColor: ?Color) !void {
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

    if (maybeColor) |color| {
        try sdl.setTextureColorMod(
            sprite.texture,
            color.r,
            color.g,
            color.b,
        );
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

fn iterateCircleOnSurface(
    sprite: Sprite,
    centerWorld: vec.Vec2,
    radiusWorld: f32,
    entityPos: vec.Vec2,
    rotation: f32,
    comptime Context: type,
    context: Context,
    comptime pixelOp: fn (ctx: Context, pixels: [*]u8, pixelIndex: usize, bytesPerPixel: usize) void,
) void {
    const surface = sprite.surface.*;
    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const bytesPerPixel: usize = 4; // Assume RGBA format

    // Transform from world space (meters) to sprite local space (pixels)
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

    // 5. Iterate over pixels within the circle
    var y = minY;
    while (y <= maxY) : (y += 1) {
        var x = minX;
        while (x <= maxX) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - centerPixelF.x;
            const dy = @as(f32, @floatFromInt(y)) - centerPixelF.y;
            const distSq = dx * dx + dy * dy;

            if (distSq <= radiusPixels * radiusPixels) {
                const pixelIndex = y * pitch + x * bytesPerPixel;
                pixelOp(context, pixels, pixelIndex, bytesPerPixel);
            }
        }
    }
}

pub fn removeCircleFromSurface(sprite: Sprite, centerWorld: vec.Vec2, radiusWorld: f32, entityPos: vec.Vec2, rotation: f32) !void {
    const removePixel = struct {
        fn op(_: void, pixels: [*]u8, pixelIndex: usize, bytesPerPixel: usize) void {
            if (bytesPerPixel == 4) {
                pixels[pixelIndex + 3] = 0; // Set alpha to 0
            }
        }
    }.op;

    iterateCircleOnSurface(sprite, centerWorld, radiusWorld, entityPos, rotation, void, {}, removePixel);
}

pub fn colorCircleOnSurface(sprite: Sprite, centerWorld: vec.Vec2, radiusWorld: f32, entityPos: vec.Vec2, rotation: f32, color: Color) !void {
    const colorPixel = struct {
        fn op(col: Color, pixels: [*]u8, pixelIndex: usize, bytesPerPixel: usize) void {
            // Only color pixels that are not fully transparent
            if (bytesPerPixel == 4 and pixels[pixelIndex + 3] > 0) {
                pixels[pixelIndex + 0] = col.b; // B (SDL uses BGRA format)
                pixels[pixelIndex + 1] = col.g; // G
                pixels[pixelIndex + 2] = col.r; // R
                // Keep the original alpha
            }
        }
    }.op;

    iterateCircleOnSurface(sprite, centerWorld, radiusWorld, entityPos, rotation, Color, color, colorPixel);
}

pub fn updateTextureFromSurface(sprite: *Sprite) !void {
    const resources = try shared.getResources();

    // Destroy old texture
    sdl.destroyTexture(sprite.texture);

    // Create new texture from modified surface
    sprite.texture = try sdl.createTextureFromSurface(resources.renderer, sprite.surface);
}

pub const SpriteTile = struct {
    sprite: Sprite,
    offsetPos: vec.Vec2, // Offset position in meters relative to original sprite center
};

// SDL_CreateRGBSurfaceWithFormat is not exposed by zsdl, so we declare it here
const SDL_CreateRGBSurfaceWithFormat = @extern(*const fn (
    flags: c_int,
    width: c_int,
    height: c_int,
    depth: c_int,
    format: u32,
) callconv(.c) ?*sdl.Surface, .{ .name = "SDL_CreateRGBSurfaceWithFormat" });

pub fn splitIntoTiles(originalSprite: Sprite, maxTileSize: u32) ![]SpriteTile {
    const width: u32 = @intCast(originalSprite.surface.w);
    const height: u32 = @intCast(originalSprite.surface.h);

    var tiles = std.array_list.Managed(SpriteTile).init(allocator);
    defer tiles.deinit();

    // If sprite is already small enough, return single tile
    if (width <= maxTileSize and height <= maxTileSize) {
        try tiles.append(SpriteTile{
            .sprite = originalSprite,
            .offsetPos = vec.zero,
        });
        return tiles.toOwnedSlice();
    }

    // Calculate number of tiles needed
    const tilesX = (width + maxTileSize - 1) / maxTileSize;
    const tilesY = (height + maxTileSize - 1) / maxTileSize;

    const resources = try shared.getResources();

    // Create tiles
    var tileY: u32 = 0;
    while (tileY < tilesY) : (tileY += 1) {
        var tileX: u32 = 0;
        while (tileX < tilesX) : (tileX += 1) {
            const startX = tileX * maxTileSize;
            const startY = tileY * maxTileSize;
            const tileWidth = @min(maxTileSize, width - startX);
            const tileHeight = @min(maxTileSize, height - startY);

            // Create new surface for this tile using the same format as the original
            const format: u32 = if (originalSprite.surface.format) |fmt| @intFromEnum(fmt.*) else 373694468; // fallback to RGBA8888
            const tileSurface = SDL_CreateRGBSurfaceWithFormat(
                0,
                @intCast(tileWidth),
                @intCast(tileHeight),
                32,
                format,
            ) orelse {
                std.debug.print("Could not SDL_CreateRGBSurfaceWithFormat. Continuing to next tile", .{});
                continue;
            };

            // Copy pixels from original surface to tile surface
            const srcRect = sdl.Rect{
                .x = @intCast(startX),
                .y = @intCast(startY),
                .w = @intCast(tileWidth),
                .h = @intCast(tileHeight),
            };
            try sdl.blitSurface(originalSprite.surface, &srcRect, tileSurface, null);

            // Create texture from tile surface
            const tileTexture = try sdl.createTextureFromSurface(resources.renderer, tileSurface);

            // Calculate tile offset in meters from original sprite center
            // Tile center in unscaled pixels
            const tileCenterX = @as(f32, @floatFromInt(startX)) + @as(f32, @floatFromInt(tileWidth)) / 2.0;
            const tileCenterY = @as(f32, @floatFromInt(startY)) + @as(f32, @floatFromInt(tileHeight)) / 2.0;
            const spriteCenterX = @as(f32, @floatFromInt(width)) / 2.0;
            const spriteCenterY = @as(f32, @floatFromInt(height)) / 2.0;

            // Offset in scaled pixels, then convert to meters
            const offsetPixels = vec.IVec2{
                .x = @as(i32, @intFromFloat((tileCenterX - spriteCenterX) * originalSprite.scale.x)),
                .y = @as(i32, @intFromFloat((tileCenterY - spriteCenterY) * originalSprite.scale.y)),
            };
            const offsetMetersB2d = conv.p2m(offsetPixels);
            const offsetMeters = vec.Vec2{ .x = offsetMetersB2d.x, .y = offsetMetersB2d.y };

            // Calculate tile size in pixels and meters
            const tileSizeP = vec.IVec2{
                .x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(tileWidth)) * originalSprite.scale.x)),
                .y = @as(i32, @intFromFloat(@as(f32, @floatFromInt(tileHeight)) * originalSprite.scale.y)),
            };
            const tileSizeMB2d = conv.p2m(tileSizeP);
            const tileSizeM = vec.Vec2{ .x = tileSizeMB2d.x, .y = tileSizeMB2d.y };

            // Duplicate imgPath for this tile
            const imgPath = try allocator.dupe(u8, originalSprite.imgPath);

            const tileSprite = Sprite{
                .surface = tileSurface,
                .imgPath = imgPath,
                .texture = tileTexture,
                .scale = originalSprite.scale,
                .offset = originalSprite.offset,
                .sizeM = tileSizeM,
                .sizeP = tileSizeP,
            };

            try tiles.append(SpriteTile{
                .sprite = tileSprite,
                .offsetPos = offsetMeters,
            });
        }
    }

    return tiles.toOwnedSlice();
}
