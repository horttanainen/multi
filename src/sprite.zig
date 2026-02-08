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
const uuid = @import("uuid.zig");
const timer = @import("sdl_timer.zig");
const thread_safe = @import("thread_safe_array_list.zig");

// SDL_LockSurface/SDL_UnlockSurface are not exposed by zsdl
pub const SDL_LockSurface = @extern(*const fn (surface: *sdl.Surface) callconv(.c) c_int, .{ .name = "SDL_LockSurface" });
pub const SDL_UnlockSurface = @extern(*const fn (surface: *sdl.Surface) callconv(.c) void, .{ .name = "SDL_UnlockSurface" });

// SDL_CreateRGBSurfaceWithFormat is not exposed by zsdl, so we declare it here
const SDL_CreateRGBSurfaceWithFormat = @extern(*const fn (
    flags: c_int,
    width: c_int,
    height: c_int,
    depth: c_int,
    format: u32,
) callconv(.c) ?*sdl.Surface, .{ .name = "SDL_CreateRGBSurfaceWithFormat" });

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
    anchorPoint: ?vec.IVec2 = null,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    pos: vec.IVec2,
};

pub var sprites = thread_safe.ThreadSafeAutoArrayHashMap(u64, Sprite).init(allocator);
var spritesToCleanup = thread_safe.ThreadSafeArrayList(u64).init(allocator);

pub fn drawWithOptions(sprite: Sprite, centerPos: vec.IVec2, angle: f32, highlight: bool, flip: bool, fog: f32, maybeColor: ?Color, pivot: ?sdl.Point) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    // Calculate top-left corner from center position
    const halfW = @divTrunc(sprite.sizeP.x, 2);
    const halfH = @divTrunc(sprite.sizeP.y, 2);

    // Handle sprite offset (rotated for sub-sprites/tiles)
    const cosAngle = @cos(angle);
    const sinAngle = @sin(angle);
    const offsetX = @as(f32, @floatFromInt(sprite.offset.x));
    const offsetY = @as(f32, @floatFromInt(sprite.offset.y));
    const rotatedOffsetX = offsetX * cosAngle - offsetY * sinAngle;
    const rotatedOffsetY = offsetX * sinAngle + offsetY * cosAngle;

    const rect = sdl.Rect{
        .x = centerPos.x - halfW + @as(i32, @intFromFloat(rotatedOffsetX)),
        .y = centerPos.y - halfH + @as(i32, @intFromFloat(rotatedOffsetY)),
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

    const pivotSdl: sdl.Point = if (pivot) |p| p else .{ .x = 0, .y = 0 };
    try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, angle * 180.0 / PI, if (pivot != null) &pivotSdl else null, if (flip) sdl.RendererFlip.horizontal else sdl.RendererFlip.none);
}

pub fn createFromImg(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2) !u64 {
    const spriteUuid = uuid.generate();

    const imgPath = try shared.allocator.dupe(u8, imagePath);
    errdefer shared.allocator.free(imgPath);

    const imgPathZ = try shared.allocator.dupeZ(u8, imagePath);
    defer shared.allocator.free(imgPathZ);
    const surface = try image.load(imgPathZ);
    errdefer sdl.freeSurface(surface);

    const anchorPoint = findAndProcessAnchorPixel(surface, scale);

    const resources = try shared.getResources();
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);
    errdefer sdl.destroyTexture(texture);

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
        .anchorPoint = anchorPoint,
        .sizeM = .{
            .x = sizeM.x,
            .y = sizeM.y,
        },
        .sizeP = .{
            .x = size.x,
            .y = size.y,
        },
    };

    try sprites.putLocking(spriteUuid, sprite);

    return spriteUuid;
}

pub fn cleanup(sprite: Sprite) void {
    shared.allocator.free(sprite.imgPath);
}

pub fn getSprite(spriteUuid: u64) ?Sprite {
    return sprites.getLocking(spriteUuid);
}

pub fn createCopy(spriteUuid: u64) !u64 {
    const originalSprite = sprites.getLocking(spriteUuid) orelse return error.SpriteNotFound;

    const newUuid = uuid.generate();

    const resources = try shared.getResources();

    const format: u32 = if (originalSprite.surface.format) |fmt| @intFromEnum(fmt.*) else 373694468; // fallback to RGBA8888
    const copiedSurface = SDL_CreateRGBSurfaceWithFormat(
        0,
        originalSprite.surface.w,
        originalSprite.surface.h,
        32,
        format,
    ) orelse {
        return error.SurfaceCopyFailed;
    };
    errdefer sdl.freeSurface(copiedSurface);

    try sdl.blitSurface(originalSprite.surface, null, copiedSurface, null);

    const copiedTexture = try sdl.createTextureFromSurface(resources.renderer, copiedSurface);
    errdefer sdl.destroyTexture(copiedTexture);

    const imgPathCopy = try shared.allocator.dupe(u8, originalSprite.imgPath);
    errdefer shared.allocator.free(imgPathCopy);

    const newSprite = Sprite{
        .surface = copiedSurface,
        .texture = copiedTexture,
        .imgPath = imgPathCopy,
        .scale = originalSprite.scale,
        .sizeM = originalSprite.sizeM,
        .sizeP = originalSprite.sizeP,
        .offset = originalSprite.offset,
        .anchorPoint = originalSprite.anchorPoint,
    };

    try sprites.putLocking(newUuid, newSprite);

    return newUuid;
}

fn findAndProcessAnchorPixel(surface: *sdl.Surface, scale: vec.Vec2) ?vec.IVec2 {
    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const bytesPerPixel: usize = 4;

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixelIndex = y * pitch + x * bytesPerPixel;

            // BGRA: b0=B, b1=G, b2=R, b3=A
            if (pixels[pixelIndex + 2] == 255 and pixels[pixelIndex + 1] == 0 and pixels[pixelIndex + 0] == 255 and pixels[pixelIndex + 3] > 0) {
                const minY = if (y >= 5) y - 5 else 0;
                const maxY = @min(y + 5, height);
                const minX = if (x >= 5) x - 5 else 0;
                const maxX = @min(x + 5, width);

                var ny: usize = minY;
                while (ny < maxY) : (ny += 1) {
                    var nx: usize = minX;
                    while (nx < maxX) : (nx += 1) {
                        const ni = ny * pitch + nx * bytesPerPixel;
                        if (pixels[ni + 2] == 255 and pixels[ni + 1] == 0 and pixels[ni + 0] == 255 and pixels[ni + 3] > 0) {
                            pixels[ni + 0] = 255;
                            pixels[ni + 1] = 255;
                            pixels[ni + 2] = 255;
                        }
                    }
                }

                const anchorX: i32 = @intFromFloat(@as(f32, @floatFromInt(x)) * scale.x);
                const anchorY: i32 = @intFromFloat(@as(f32, @floatFromInt(y)) * scale.y);
                return vec.IVec2{ .x = anchorX, .y = anchorY };
            }
        }
    }
    return null;
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

pub fn colorCircleOnSurface(spriteUuid: u64, centerWorld: vec.Vec2, radiusWorld: f32, entityPos: vec.Vec2, rotation: f32, color: Color) !void {
    const sprite = sprites.getLocking(spriteUuid) orelse return error.SpriteNotFound;
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

pub fn updateTextureFromSurface(spriteUuid: u64) !void {
    const sprite = sprites.getPtrLocking(spriteUuid) orelse return error.SpriteNotFound;

    const resources = try shared.getResources();

    // Destroy old texture
    sdl.destroyTexture(sprite.texture);

    // Create new texture from modified surface
    sprite.texture = try sdl.createTextureFromSurface(resources.renderer, sprite.surface);
}

pub fn isWhite(r: u8, g: u8, b: u8) bool {
    return r > 150 and g > 150 and b > 150;
}

pub fn isCyan(r: u8, _: u8, b: u8) bool {
    return r < 150 and b > 100;
}

pub fn colorMatchingPixels(spriteUuid: u64, color: Color, comptime predicate: fn (u8, u8, u8) bool) !void {
    const s = sprites.getLocking(spriteUuid) orelse return error.SpriteNotFound;

    if (SDL_LockSurface(s.surface) != 0) {
        return error.SDLLockSurfaceFailed;
    }
    defer SDL_UnlockSurface(s.surface);

    const pixels: [*]u8 = @ptrCast(s.surface.pixels);
    const bytesPerPixel: usize = 4;
    const width: usize = @intCast(s.surface.w);
    const height: usize = @intCast(s.surface.h);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixelIndex = (y * width + x) * bytesPerPixel;

            const alpha = pixels[pixelIndex + 3];
            if (alpha == 0) continue;

            const b = pixels[pixelIndex + 0];
            const g = pixels[pixelIndex + 1];
            const r = pixels[pixelIndex + 2];

            if (predicate(r, g, b)) {
                pixels[pixelIndex + 0] = color.b;
                pixels[pixelIndex + 1] = color.g;
                pixels[pixelIndex + 2] = color.r;
            }
        }
    }

    try updateTextureFromSurface(spriteUuid);
}

pub const SpriteTile = struct {
    spriteUuid: u64,
    offsetPos: vec.Vec2, // Offset position in meters relative to original sprite center
};

pub fn splitIntoTiles(originalSpriteUuid: u64, maxTileSize: u32) ![]SpriteTile {
    const originalSprite = sprites.getLocking(originalSpriteUuid) orelse return error.SpriteNotFound;

    const width: u32 = @intCast(originalSprite.surface.w);
    const height: u32 = @intCast(originalSprite.surface.h);

    var tiles = std.array_list.Managed(SpriteTile).init(allocator);
    defer tiles.deinit();

    // If sprite is already small enough, return single tile
    if (width <= maxTileSize and height <= maxTileSize) {
        try tiles.append(SpriteTile{
            .spriteUuid = originalSpriteUuid,
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

            const tileUuid = uuid.generate();
            try sprites.putLocking(tileUuid, tileSprite);

            try tiles.append(SpriteTile{
                .spriteUuid = tileUuid,
                .offsetPos = offsetMeters,
            });
        }
    }

    return tiles.toOwnedSlice();
}

pub fn cleanupLater(spriteUuid: u64) void {
    if (sprites.getLocking(spriteUuid) == null) {
        return;
    }
    const uuid_as_ptr: ?*anyopaque = @ptrFromInt(spriteUuid);
    _ = timer.addTimer(10, markSpriteForCleanup, uuid_as_ptr);
}

fn markSpriteForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;

    const spriteUuid: u64 = @intFromPtr(param.?);

    spritesToCleanup.appendLocking(spriteUuid) catch {};

    return 0; // Don't repeat timer
}

pub fn cleanupSprites() void {
    spritesToCleanup.mutex.lock();
    defer spritesToCleanup.mutex.unlock();

    for (spritesToCleanup.list.items) |spriteUuid| {
        const maybeKV = sprites.fetchSwapRemoveLocking(spriteUuid);
        if (maybeKV) |kv| {
            cleanupOne(kv.value);
        }
    }

    spritesToCleanup.list.clearAndFree();
}

fn cleanupOne(s: Sprite) void {
    shared.allocator.free(s.imgPath);
    sdl.destroyTexture(s.texture);
    sdl.freeSurface(s.surface);
}

pub fn cleanupAll() void {
    spritesToCleanup.mutex.lock();
    spritesToCleanup.list.clearRetainingCapacity();
    spritesToCleanup.mutex.unlock();

    sprites.mutex.lock();
    defer sprites.mutex.unlock();

    for (sprites.map.values()) |s| {
        cleanupOne(s);
    }
    sprites.map.clearRetainingCapacity();
}

pub fn deinit() void {
    cleanupAll();

    sprites.mutex.lock();
    sprites.map.deinit();
    sprites.mutex.unlock();

    spritesToCleanup.mutex.lock();
    spritesToCleanup.list.deinit();
    spritesToCleanup.mutex.unlock();
}
