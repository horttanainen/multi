const std = @import("std");
const sdl = @import("sdl.zig");
const tex = @import("texture.zig");
const gpu = @import("gpu.zig");
const config = @import("config.zig");

const camera = @import("camera.zig");
const time = @import("time.zig");

const PI = std.math.pi;

const allocator = @import("allocator.zig").allocator;

const vec = @import("vector.zig");

const conv = @import("conversion.zig");
const runtime = @import("runtime.zig");
const uuid = @import("uuid.zig");
const thread_safe = @import("thread_safe_array_list.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const SurfaceCutoutEdit = struct {
    textureDirtyRect: vec.IRect,
    colliderDirtyRect: ?vec.IRect,
};

pub const SurfaceHotRimQuad = struct {
    corners: [4]vec.Vec2,
};

pub const SurfaceCutoutResult = struct {
    edit: SurfaceCutoutEdit,
    hotRimQuads: ?[]SurfaceHotRimQuad,
};

pub const Sprite = struct {
    texture: *tex.Texture,
    surface: *sdl.Surface,
    scale: vec.Vec2,
    sizeM: vec.Vec2,
    sizeP: vec.IVec2,
    offset: vec.IVec2,
    imgPath: []const u8,
    atlasProfile: config.RuntimeAtlasProfile,
    geometryId: u64,
    geometryVersion: u64 = 0,
    anchorPointLeft: ?vec.IVec2 = null, // Magenta pixel - left shoulder
    anchorPointRight: ?vec.IVec2 = null, // Green pixel - right shoulder
};

pub const ScalePreviewState = struct {
    scale: vec.Vec2,
    sizeM: vec.Vec2,
    sizeP: vec.IVec2,
    anchorPointLeft: ?vec.IVec2,
    anchorPointRight: ?vec.IVec2,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    pos: vec.IVec2,
};

pub const Backing = enum {
    immutable,
    mutable,
};

pub var sprites = thread_safe.ThreadSafeAutoArrayHashMap(u64, Sprite).init(allocator);
var spritesToCleanup = thread_safe.ThreadSafeArrayList(u64).init(allocator);
var acceptSpriteCleanupTimers = true;

const RuntimeTextureSize = struct {
    width: i32,
    height: i32,
};

const RuntimeAtlasSurface = struct {
    surface: *sdl.Surface,
    owned: bool,
};

const StainSpot = struct {
    offsetX: f32,
    offsetY: f32,
    radius: f32,
    strength: f32,
};

const CutoutVertex = struct {
    x: i32,
    y: i32,
};

const FracturedCutout = struct {
    vertices: [maximumFractureVertexCount]CutoutVertex,
    vertexCount: usize,
};

const CutoutEdit = struct {
    changed: bool = false,
    minimumX: i32,
    minimumY: i32,
    maximumX: i32 = 0,
    maximumY: i32 = 0,
};

const cutoutFixedPointScale: i32 = 256;
const cutoutRadiusFactorScale: i32 = 32768;
const minimumFractureVertexCount: usize = 9;
const maximumFractureVertexCount: usize = 16;
const fractureFacetLengthPixels: f32 = 42;
const maximumFractureAngleJitter: f32 = 0.28;
const maximumCharWidthScale: f32 = 4.4;
const hotRimMinimumSurfaceAlpha: u8 = 150;
pub const maximumCutoutIrregularity: f32 = 0.35;

// Texture cache: maps image path → atlas region + dimensions.
// Sprites with the same image share the same atlas region for draw call batching.
const CachedTexInfo = struct {
    atlas_x: u32,
    atlas_y: u32,
    width: i32,
    height: i32,
    atlas_generation: u64,
    geometry_id: u64,
};
var textureCache = std.StringHashMap(CachedTexInfo).init(allocator);

fn sourceTextureSize(surface: *sdl.Surface) RuntimeTextureSize {
    return .{
        .width = surface.w,
        .height = surface.h,
    };
}

fn validRuntimeScale(scale: vec.Vec2) bool {
    return std.math.isFinite(scale.x) and std.math.isFinite(scale.y) and scale.x > 0.0 and scale.y > 0.0;
}

fn runtimeScaleTargetRatio(sourceSize: RuntimeTextureSize, scale: vec.Vec2, atlasConfig: config.RuntimeAtlasConfig) f32 {
    const qualityMultiplier = atlasConfig.maxQualityZoom * atlasConfig.oversample;
    const sourceW: f32 = @floatFromInt(sourceSize.width);
    const sourceH: f32 = @floatFromInt(sourceSize.height);
    const logicalW = sourceW * scale.x;
    const logicalH = sourceH * scale.y;
    const targetW = logicalW * qualityMultiplier;
    const targetH = logicalH * qualityMultiplier;

    const targetRatio = @max(targetW / sourceW, targetH / sourceH);
    const maxEdgeRatio = @min(
        @as(f32, @floatFromInt(atlasConfig.maxTextureEdge)) / sourceW,
        @as(f32, @floatFromInt(atlasConfig.maxTextureEdge)) / sourceH,
    );
    const minAllowedW = @min(sourceSize.width, atlasConfig.minTextureEdge);
    const minAllowedH = @min(sourceSize.height, atlasConfig.minTextureEdge);
    const minEdgeRatio = @max(
        @as(f32, @floatFromInt(minAllowedW)) / sourceW,
        @as(f32, @floatFromInt(minAllowedH)) / sourceH,
    );

    return @min(1.0, @max(minEdgeRatio, @min(targetRatio, maxEdgeRatio)));
}

fn scaledRuntimeDimension(sourceDimension: i32, ratio: f32) i32 {
    const scaled = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(sourceDimension)) * ratio)));
    return @max(1, @min(sourceDimension, scaled));
}

fn roundUpToMultiple(value: i32, multiple: i32) i32 {
    if (value <= 0) return multiple;
    return @divTrunc(value + multiple - 1, multiple) * multiple;
}

fn bucketRuntimeTextureSize(sourceSize: RuntimeTextureSize, desiredRatio: f32, atlasConfig: config.RuntimeAtlasConfig) RuntimeTextureSize {
    const desired = RuntimeTextureSize{
        .width = scaledRuntimeDimension(sourceSize.width, desiredRatio),
        .height = scaledRuntimeDimension(sourceSize.height, desiredRatio),
    };
    const sourceLongEdge = @max(sourceSize.width, sourceSize.height);
    var targetLongEdge = @max(desired.width, desired.height);
    targetLongEdge = roundUpToMultiple(targetLongEdge, atlasConfig.textureBucket);
    targetLongEdge = @min(targetLongEdge, atlasConfig.maxTextureEdge);
    targetLongEdge = @min(targetLongEdge, sourceLongEdge);

    const bucketRatio = @as(f32, @floatFromInt(targetLongEdge)) / @as(f32, @floatFromInt(sourceLongEdge));
    return .{
        .width = scaledRuntimeDimension(sourceSize.width, bucketRatio),
        .height = scaledRuntimeDimension(sourceSize.height, bucketRatio),
    };
}

fn shouldUseDownscaledRuntimeTexture(sourceSize: RuntimeTextureSize, targetSize: RuntimeTextureSize, atlasConfig: config.RuntimeAtlasConfig) bool {
    if (targetSize.width >= sourceSize.width and targetSize.height >= sourceSize.height) return false;

    const thresholdW = @as(f32, @floatFromInt(targetSize.width)) * atlasConfig.downscaleThreshold;
    const thresholdH = @as(f32, @floatFromInt(targetSize.height)) * atlasConfig.downscaleThreshold;
    return @as(f32, @floatFromInt(sourceSize.width)) > thresholdW or
        @as(f32, @floatFromInt(sourceSize.height)) > thresholdH;
}

fn runtimeTextureSizeForSurface(surface: *sdl.Surface, scale: vec.Vec2, atlasConfig: config.RuntimeAtlasConfig) RuntimeTextureSize {
    const sourceSize = sourceTextureSize(surface);
    if (sourceSize.width <= 0 or sourceSize.height <= 0) {
        std.log.warn("runtimeTextureSizeForSurface: invalid source surface size {d}x{d}", .{ sourceSize.width, sourceSize.height });
        return sourceSize;
    }
    if (!validRuntimeScale(scale)) {
        std.log.warn("runtimeTextureSizeForSurface: invalid scale ({d},{d}), keeping source texture size", .{ scale.x, scale.y });
        return sourceSize;
    }

    const desiredRatio = runtimeScaleTargetRatio(sourceSize, scale, atlasConfig);
    const targetSize = bucketRuntimeTextureSize(sourceSize, desiredRatio, atlasConfig);
    if (!shouldUseDownscaledRuntimeTexture(sourceSize, targetSize, atlasConfig)) return sourceSize;

    return targetSize;
}

fn runtimeTextureCacheKey(imagePath: []const u8, runtimeSize: RuntimeTextureSize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}@{d}x{d}", .{ imagePath, runtimeSize.width, runtimeSize.height });
}

fn createScaledSurface(surface: *sdl.Surface, runtimeSize: RuntimeTextureSize) !*sdl.Surface {
    const scaledSurface = sdl.c.SDL_CreateSurface(runtimeSize.width, runtimeSize.height, surface.format) orelse return error.CreateSurfaceFailed;
    errdefer sdl.destroySurface(scaledSurface);

    const sourceRect = sdl.Rect{ .x = 0, .y = 0, .w = surface.w, .h = surface.h };
    const targetRect = sdl.Rect{ .x = 0, .y = 0, .w = runtimeSize.width, .h = runtimeSize.height };
    try sdl.blitSurfaceScaled(surface, &sourceRect, scaledSurface, &targetRect, .linear);
    return scaledSurface;
}

fn createRuntimeAtlasSurfaceWithSize(surface: *sdl.Surface, runtimeSize: RuntimeTextureSize) !RuntimeAtlasSurface {
    if (runtimeSize.width == surface.w and runtimeSize.height == surface.h) {
        return .{ .surface = surface, .owned = false };
    }

    const scaledSurface = try createScaledSurface(surface, runtimeSize);
    return .{ .surface = scaledSurface, .owned = true };
}

fn createRuntimeAtlasSurface(surface: *sdl.Surface, scale: vec.Vec2, atlasConfig: config.RuntimeAtlasConfig) !RuntimeAtlasSurface {
    const runtimeSize = runtimeTextureSizeForSurface(surface, scale, atlasConfig);
    return createRuntimeAtlasSurfaceWithSize(surface, runtimeSize);
}

fn createRuntimeAtlasSurfaceForTexture(surface: *sdl.Surface, texture: *tex.Texture) !RuntimeAtlasSurface {
    const runtimeSize = RuntimeTextureSize{
        .width = texture.width,
        .height = texture.height,
    };
    return createRuntimeAtlasSurfaceWithSize(surface, runtimeSize);
}

fn destroyRuntimeAtlasSurface(runtimeSurface: RuntimeAtlasSurface) void {
    if (!runtimeSurface.owned) return;
    sdl.destroySurface(runtimeSurface.surface);
}

fn surfaceMatchesTexture(surface: *sdl.Surface, texture: *tex.Texture) bool {
    return surface.w == texture.width and surface.h == texture.height;
}

fn createSpriteFromOwnedSurface(imagePath: []const u8, surface: *sdl.Surface, texture: *tex.Texture, scale: vec.Vec2, offset: vec.IVec2, atlasProfile: config.RuntimeAtlasProfile, geometryId: u64) !u64 {
    const spriteUuid = uuid.generate();

    const imgPath = try allocator.dupe(u8, imagePath);
    errdefer allocator.free(imgPath);

    const anchorPointLeft = findAndProcessAnchorPixel(surface, scale, isMagenta);
    const anchorPointRight = findAndProcessAnchorPixel(surface, scale, isGreen);

    var size = sdl.Point{
        .x = surface.w,
        .y = surface.h,
    };
    size.x = @intFromFloat(@as(f32, @floatFromInt(size.x)) * scale.x);
    size.y = @intFromFloat(@as(f32, @floatFromInt(size.y)) * scale.y);
    const sizeM = conv.p2m(.{ .x = size.x, .y = size.y });

    const sprite = Sprite{
        .surface = surface,
        .imgPath = imgPath,
        .atlasProfile = atlasProfile,
        .texture = texture,
        .scale = scale,
        .offset = offset,
        .geometryId = geometryId,
        .anchorPointLeft = anchorPointLeft,
        .anchorPointRight = anchorPointRight,
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

pub fn drawWithOptions(sprite: Sprite, centerPos: vec.IVec2, angle: f32, highlight: bool, flip: bool, fog: f32, maybeColor: ?Color, pivot: ?sdl.Point) !void {
    const rect = drawRectForSprite(sprite, centerPos, angle);

    try tex.setTextureColorMod(sprite.texture, 255, 255, 255);
    if (fog > 0) {
        try tex.setTextureColorMod(
            sprite.texture,
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
            @intFromFloat(@as(f32, @floatFromInt(255)) * (1 - fog)),
        );
    }

    if (highlight) {
        try tex.setTextureColorMod(sprite.texture, 100, 100, 100);
    }

    if (maybeColor) |color| {
        try tex.setTextureColorMod(
            sprite.texture,
            color.r,
            color.g,
            color.b,
        );
    }

    const pivotSdl: sdl.Point = if (pivot) |p| p else .{ .x = 0, .y = 0 };
    try gpu.renderCopyEx(sprite.texture, null, &rect, angle * 180.0 / PI, if (pivot != null) &pivotSdl else null, if (flip) .horizontal else .none);
}

pub fn drawWithScale(spriteValue: Sprite, centerPos: vec.IVec2, angle: f32, scale: vec.Vec2, maybeColor: ?Color) !void {
    if (scale.x <= 0.0 or scale.y <= 0.0) {
        return;
    }

    var scaledSprite = spriteValue;
    scaledSprite.scale = scale;
    scaledSprite.sizeP = .{
        .x = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(spriteValue.surface.w)) * scale.x)))),
        .y = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(spriteValue.surface.h)) * scale.y)))),
    };
    scaledSprite.sizeM = conv.pixel2M(scaledSprite.sizeP);
    try drawWithOptions(scaledSprite, centerPos, angle, false, false, 0, maybeColor, null);
}

pub fn drawSelectionMask(s: Sprite, centerPos: vec.IVec2, angle: f32, flip: bool, alpha: u8) !void {
    if (alpha == 0) return;

    const rect = drawRectForSprite(s, centerPos, angle);
    try gpu.renderSelectionMaskCopyEx(s.texture, null, &rect, angle * 180.0 / PI, null, if (flip) .horizontal else .none, alpha);
}

fn drawRectForSprite(s: Sprite, centerPos: vec.IVec2, angle: f32) sdl.Rect {
    const halfW = @divTrunc(s.sizeP.x, 2);
    const halfH = @divTrunc(s.sizeP.y, 2);

    const cosAngle = @cos(angle);
    const sinAngle = @sin(angle);
    const offsetX = @as(f32, @floatFromInt(s.offset.x));
    const offsetY = @as(f32, @floatFromInt(s.offset.y));
    const rotatedOffsetX = offsetX * cosAngle - offsetY * sinAngle;
    const rotatedOffsetY = offsetX * sinAngle + offsetY * cosAngle;

    return .{
        .x = centerPos.x - halfW + @as(i32, @intFromFloat(rotatedOffsetX)),
        .y = centerPos.y - halfH + @as(i32, @intFromFloat(rotatedOffsetY)),
        .w = s.sizeP.x,
        .h = s.sizeP.y,
    };
}

pub fn drawGlow(s: Sprite, centerPos: vec.IVec2, angle: f32, flip: bool, maybeColor: ?Color) !void {
    const color = maybeColor orelse Color{ .r = 255, .g = 255, .b = 255 };

    try tex.setTextureBlendMode(s.texture, .add);

    // t=0 is innermost (white), t=1 is outermost (pellet color)
    const glowPasses = [_]struct { scale: f32, alpha: u8, t: f32 }{
        .{ .scale = 3.0, .alpha = 30, .t = 1.0 },
        .{ .scale = 2.0, .alpha = 60, .t = 0.5 },
        .{ .scale = 1.5, .alpha = 90, .t = 0.2 },
    };

    for (glowPasses) |pass| {
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(s.sizeP.x)) * pass.scale);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(s.sizeP.y)) * pass.scale);

        const rect = sdl.Rect{
            .x = centerPos.x - @divTrunc(w, 2),
            .y = centerPos.y - @divTrunc(h, 2),
            .w = w,
            .h = h,
        };

        // Lerp from white to pellet color
        const r: u8 = @intFromFloat(255.0 - (255.0 - @as(f32, @floatFromInt(color.r))) * pass.t);
        const g: u8 = @intFromFloat(255.0 - (255.0 - @as(f32, @floatFromInt(color.g))) * pass.t);
        const b: u8 = @intFromFloat(255.0 - (255.0 - @as(f32, @floatFromInt(color.b))) * pass.t);

        try tex.setTextureColorMod(s.texture, r, g, b);
        try tex.setTextureAlphaMod(s.texture, pass.alpha);
        try gpu.renderCopyEx(s.texture, null, &rect, angle * 180.0 / PI, null, if (flip) .horizontal else .none);
    }

    // Restore to normal blend mode
    try tex.setTextureBlendMode(s.texture, .blend);
    try tex.setTextureAlphaMod(s.texture, 255);
}

pub fn createFromImg(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2) !u64 {
    return createFromImgWithBacking(imagePath, scale, offset, .immutable);
}

pub fn createMutableFromImg(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2) !u64 {
    return createFromImgWithBacking(imagePath, scale, offset, .mutable);
}

pub fn createFromImgWithBacking(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2, backing: Backing) !u64 {
    return createFromImgWithAtlasProfile(imagePath, scale, offset, backing, config.defaultRuntimeAtlasProfile);
}

pub fn createFromImgWithAtlasProfile(imagePath: []const u8, scale: vec.Vec2, offset: vec.IVec2, backing: Backing, atlasProfile: config.RuntimeAtlasProfile) !u64 {
    const imgPathZ = try allocator.dupeZ(u8, imagePath);
    defer allocator.free(imgPathZ);
    const surface = try sdl.image.load(imgPathZ);
    errdefer sdl.destroySurface(surface);

    const atlasConfig = config.runtimeAtlasConfigForProfile(atlasProfile);
    return createFromLoadedSurfaceWithBacking(imagePath, surface, scale, offset, backing, atlasProfile, atlasConfig);
}

pub fn createFromOwnedSurface(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, offset: vec.IVec2) !u64 {
    return createFromOwnedSurfaceWithBacking(imagePath, surface, scale, offset, .immutable);
}

pub fn createMutableFromOwnedSurface(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, offset: vec.IVec2) !u64 {
    return createFromOwnedSurfaceWithBacking(imagePath, surface, scale, offset, .mutable);
}

pub fn createFromOwnedSurfaceWithBacking(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, offset: vec.IVec2, backing: Backing) !u64 {
    errdefer sdl.destroySurface(surface);

    const texture = switch (backing) {
        .immutable => blk: {
            const runtimeSurface = try createRuntimeAtlasSurface(surface, scale, config.runtimeAtlas);
            defer destroyRuntimeAtlasSurface(runtimeSurface);
            break :blk try tex.addToAtlas(runtimeSurface.surface);
        },
        .mutable => blk: {
            const runtimeSurface = try createRuntimeAtlasSurface(surface, scale, config.runtimeAtlas);
            defer destroyRuntimeAtlasSurface(runtimeSurface);
            break :blk try tex.createMutableTexture(runtimeSurface.surface);
        },
    };
    errdefer tex.destroyTexture(texture);

    return createSpriteFromOwnedSurface(imagePath, surface, texture, scale, offset, config.defaultRuntimeAtlasProfile, uuid.generate());
}

const TextureForImage = struct {
    texture: *tex.Texture,
    geometryId: u64,
};

fn createFromLoadedSurfaceWithBacking(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, offset: vec.IVec2, backing: Backing, atlasProfile: config.RuntimeAtlasProfile, atlasConfig: config.RuntimeAtlasConfig) !u64 {
    const textureForImage = try createTextureForImage(imagePath, surface, scale, backing, atlasConfig);
    errdefer tex.destroyTexture(textureForImage.texture);

    return createSpriteFromOwnedSurface(imagePath, surface, textureForImage.texture, scale, offset, atlasProfile, textureForImage.geometryId);
}

fn createTextureForImage(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, backing: Backing, atlasConfig: config.RuntimeAtlasConfig) !TextureForImage {
    return switch (backing) {
        .immutable => createImmutableTextureForImage(imagePath, surface, scale, atlasConfig),
        .mutable => blk: {
            const runtimeSurface = try createRuntimeAtlasSurface(surface, scale, atlasConfig);
            defer destroyRuntimeAtlasSurface(runtimeSurface);
            break :blk .{
                .texture = try tex.createMutableTexture(runtimeSurface.surface),
                .geometryId = uuid.generate(),
            };
        },
    };
}

fn createImmutableTextureForImage(imagePath: []const u8, surface: *sdl.Surface, scale: vec.Vec2, atlasConfig: config.RuntimeAtlasConfig) !TextureForImage {
    const runtimeSize = runtimeTextureSizeForSurface(surface, scale, atlasConfig);
    const cacheKey = try runtimeTextureCacheKey(imagePath, runtimeSize);
    errdefer allocator.free(cacheKey);

    if (textureCache.get(cacheKey)) |cached| {
        allocator.free(cacheKey);
        const new_tex = try std.heap.c_allocator.create(tex.Texture);
        new_tex.* = .{
            .atlas_x = cached.atlas_x,
            .atlas_y = cached.atlas_y,
            .width = cached.width,
            .height = cached.height,
            .backing = .immutable_atlas,
            .atlas_generation = cached.atlas_generation,
            .owns_atlas_region = false,
        };
        return .{
            .texture = new_tex,
            .geometryId = cached.geometry_id,
        };
    }

    const runtimeSurface = try createRuntimeAtlasSurfaceWithSize(surface, runtimeSize);
    defer destroyRuntimeAtlasSurface(runtimeSurface);

    const texture = try tex.addToAtlas(runtimeSurface.surface);
    errdefer tex.destroyTexture(texture);

    const geometryId = uuid.generate();

    textureCache.put(cacheKey, .{
        .atlas_x = texture.atlas_x,
        .atlas_y = texture.atlas_y,
        .width = texture.width,
        .height = texture.height,
        .atlas_generation = texture.atlas_generation,
        .geometry_id = geometryId,
    }) catch |err| {
        std.log.warn("createImmutableTextureForImage: failed to store texture cache entry for '{s}' with {}", .{ imagePath, err });
        allocator.free(cacheKey);
    };
    return .{
        .texture = texture,
        .geometryId = geometryId,
    };
}

pub fn cleanup(sprite: Sprite) void {
    allocator.free(sprite.imgPath);
}

pub fn getSprite(spriteUuid: u64) ?Sprite {
    return sprites.getLocking(spriteUuid);
}

pub fn getScalePreviewState(spriteUuid: u64) ?ScalePreviewState {
    const s = sprites.getLocking(spriteUuid) orelse {
        std.log.warn("getScalePreviewState: sprite {d} not found", .{spriteUuid});
        return null;
    };

    return .{
        .scale = s.scale,
        .sizeM = s.sizeM,
        .sizeP = s.sizeP,
        .anchorPointLeft = s.anchorPointLeft,
        .anchorPointRight = s.anchorPointRight,
    };
}

pub fn applyScalePreview(spriteUuid: u64, base: ScalePreviewState, ratio: vec.Vec2) void {
    if (!std.math.isFinite(ratio.x) or !std.math.isFinite(ratio.y) or ratio.x <= 0.0 or ratio.y <= 0.0) {
        std.log.warn("applyScalePreview: invalid ratio ({d},{d}) for sprite {d}", .{ ratio.x, ratio.y, spriteUuid });
        return;
    }

    sprites.mutex.lockUncancelable(runtime.io());
    defer sprites.mutex.unlock(runtime.io());

    const s = sprites.map.getPtr(spriteUuid) orelse {
        std.log.warn("applyScalePreview: sprite {d} not found", .{spriteUuid});
        return;
    };

    s.scale = .{
        .x = base.scale.x * ratio.x,
        .y = base.scale.y * ratio.y,
    };
    s.sizeM = .{
        .x = base.sizeM.x * ratio.x,
        .y = base.sizeM.y * ratio.y,
    };
    s.sizeP = .{
        .x = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(base.sizeP.x)) * ratio.x)))),
        .y = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(base.sizeP.y)) * ratio.y)))),
    };
    s.anchorPointLeft = scaledAnchor(base.anchorPointLeft, ratio);
    s.anchorPointRight = scaledAnchor(base.anchorPointRight, ratio);
}

pub fn restoreScalePreview(spriteUuid: u64, base: ScalePreviewState) void {
    sprites.mutex.lockUncancelable(runtime.io());
    defer sprites.mutex.unlock(runtime.io());

    const s = sprites.map.getPtr(spriteUuid) orelse {
        std.log.warn("restoreScalePreview: sprite {d} not found", .{spriteUuid});
        return;
    };

    s.scale = base.scale;
    s.sizeM = base.sizeM;
    s.sizeP = base.sizeP;
    s.anchorPointLeft = base.anchorPointLeft;
    s.anchorPointRight = base.anchorPointRight;
}

fn scaledAnchor(anchor: ?vec.IVec2, ratio: vec.Vec2) ?vec.IVec2 {
    const value = anchor orelse return null;
    return .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(value.x)) * ratio.x)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(value.y)) * ratio.y)),
    };
}

pub fn createCopy(spriteUuid: u64) !u64 {
    const originalSprite = sprites.getLocking(spriteUuid) orelse {
        std.log.warn("createCopy: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const backing: Backing = if (tex.isImmutableAtlasTexture(originalSprite.texture)) .immutable else .mutable;
    return createCopyWithBacking(spriteUuid, backing);
}

pub fn createMutableCopy(spriteUuid: u64) !u64 {
    return createCopyWithBacking(spriteUuid, .mutable);
}

pub fn restoreMutableCopy(targetUuid: u64, sourceUuid: u64) !void {
    const sourceSprite = sprites.getLocking(sourceUuid) orelse {
        std.log.err("restoreMutableCopy: source sprite {d} is missing", .{sourceUuid});
        return error.SpriteNotFound;
    };
    const targetSprite = sprites.getPtrLocking(targetUuid) orelse {
        std.log.err("restoreMutableCopy: target sprite {d} is missing", .{targetUuid});
        return error.SpriteNotFound;
    };
    if (sourceSprite.surface.w != targetSprite.surface.w or
        sourceSprite.surface.h != targetSprite.surface.h or
        sourceSprite.surface.format != targetSprite.surface.format or
        sourceSprite.surface.pitch != targetSprite.surface.pitch)
    {
        std.log.err("restoreMutableCopy: source {d} and target {d} surfaces are incompatible", .{ sourceUuid, targetUuid });
        return error.IncompatibleSpriteSurfaces;
    }

    {
        try sdl.lockSurface(sourceSprite.surface);
        defer sdl.unlockSurface(sourceSprite.surface);
        try sdl.lockSurface(targetSprite.surface);
        defer sdl.unlockSurface(targetSprite.surface);

        const pitch: usize = @intCast(sourceSprite.surface.pitch);
        const height: usize = @intCast(sourceSprite.surface.h);
        const byteCount = try std.math.mul(usize, pitch, height);
        const sourcePixels: [*]const u8 = @ptrCast(sourceSprite.surface.pixels);
        const targetPixels: [*]u8 = @ptrCast(targetSprite.surface.pixels);
        @memcpy(targetPixels[0..byteCount], sourcePixels[0..byteCount]);
    }

    try updateTextureGeometryFromSurface(targetUuid);
}

pub fn createCopyWithBacking(spriteUuid: u64, backing: Backing) !u64 {
    const originalSprite = sprites.getLocking(spriteUuid) orelse {
        std.log.warn("createCopyWithBacking: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const atlasConfig = config.runtimeAtlasConfigForProfile(originalSprite.atlasProfile);

    const newUuid = uuid.generate();

    const format: sdl.PixelFormat = @enumFromInt(originalSprite.surface.format);
    const copiedSurface = try sdl.createSurface(
        originalSprite.surface.w,
        originalSprite.surface.h,
        format,
    );
    errdefer sdl.destroySurface(copiedSurface);

    try sdl.blitSurface(originalSprite.surface, null, copiedSurface, null);

    const copiedTexture = switch (backing) {
        .immutable => if (tex.isImmutableAtlasTexture(originalSprite.texture))
            try tex.cloneTexture(originalSprite.texture)
        else blk: {
            const runtimeSurface = try createRuntimeAtlasSurface(copiedSurface, originalSprite.scale, atlasConfig);
            defer destroyRuntimeAtlasSurface(runtimeSurface);
            break :blk try tex.addToAtlas(runtimeSurface.surface);
        },
        .mutable => blk: {
            const runtimeSurface = try createRuntimeAtlasSurface(copiedSurface, originalSprite.scale, atlasConfig);
            defer destroyRuntimeAtlasSurface(runtimeSurface);
            break :blk try tex.createMutableTexture(runtimeSurface.surface);
        },
    };
    errdefer tex.destroyTexture(copiedTexture);

    const imgPathCopy = try allocator.dupe(u8, originalSprite.imgPath);
    errdefer allocator.free(imgPathCopy);

    const newSprite = Sprite{
        .surface = copiedSurface,
        .texture = copiedTexture,
        .imgPath = imgPathCopy,
        .atlasProfile = originalSprite.atlasProfile,
        .scale = originalSprite.scale,
        .sizeM = originalSprite.sizeM,
        .sizeP = originalSprite.sizeP,
        .offset = originalSprite.offset,
        .geometryId = originalSprite.geometryId,
        .geometryVersion = originalSprite.geometryVersion,
        .anchorPointLeft = originalSprite.anchorPointLeft,
        .anchorPointRight = originalSprite.anchorPointRight,
    };

    try sprites.putLocking(newUuid, newSprite);

    return newUuid;
}

pub fn isMagenta(r: u8, g: u8, b: u8) bool {
    return r == 255 and g == 0 and b == 255;
}

pub fn isGreen(r: u8, g: u8, b: u8) bool {
    return r <= 5 and g >= 250 and b <= 5;
}

fn findAndProcessAnchorPixel(surface: *sdl.Surface, scale: vec.Vec2, comptime predicate: fn (u8, u8, u8) bool) ?vec.IVec2 {
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
            if (pixels[pixelIndex + 3] > 0 and predicate(pixels[pixelIndex + 2], pixels[pixelIndex + 1], pixels[pixelIndex + 0])) {
                const minY = if (y >= 5) y - 5 else 0;
                const maxY = @min(y + 5, height);
                const minX = if (x >= 5) x - 5 else 0;
                const maxX = @min(x + 5, width);

                var ny: usize = minY;
                while (ny < maxY) : (ny += 1) {
                    var nx: usize = minX;
                    while (nx < maxX) : (nx += 1) {
                        const ni = ny * pitch + nx * bytesPerPixel;
                        if (pixels[ni + 3] > 0 and predicate(pixels[ni + 2], pixels[ni + 1], pixels[ni + 0])) {
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
) ?vec.IRect {
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

    const radiusPixels = (radiusWorld * conv.met2pix) / sprite.scale.x;

    // 4. Calculate bounding box for iteration efficiency
    const rawMinX: i32 = @intFromFloat(@floor(centerPixelF.x - radiusPixels));
    const rawMaxX: i32 = @intFromFloat(@ceil(centerPixelF.x + radiusPixels));
    const rawMinY: i32 = @intFromFloat(@floor(centerPixelF.y - radiusPixels));
    const rawMaxY: i32 = @intFromFloat(@ceil(centerPixelF.y + radiusPixels));

    const widthI: i32 = @intCast(width);
    const heightI: i32 = @intCast(height);

    if (rawMaxX < 0 or rawMinX >= widthI or rawMaxY < 0 or rawMinY >= heightI) return null;

    const minX: usize = @intCast(@max(0, rawMinX));
    const maxX: usize = @intCast(@min(widthI - 1, rawMaxX));
    const minY: usize = @intCast(@max(0, rawMinY));
    const maxY: usize = @intCast(@min(heightI - 1, rawMaxY));

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

    return .{
        .minX = @intCast(minX),
        .minY = @intCast(minY),
        .maxX = @intCast(maxX + 1),
        .maxY = @intCast(maxY + 1),
    };
}

fn hash64(value: u64) u64 {
    var x = value;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

fn randomUnitFromSeed(seed: u64, salt: u64) f32 {
    const hashed = hash64(seed ^ (salt *% 0x9e3779b97f4a7c15));
    const value: u32 = @truncate(hashed >> 40);
    return @as(f32, @floatFromInt(value)) / 16777215.0;
}

fn pixelNoise(seed: u64, x: i32, y: i32, salt: u64) f32 {
    const ux: u64 = @bitCast(@as(i64, x));
    const uy: u64 = @bitCast(@as(i64, y));
    const hashed = hash64(seed ^ salt ^ (ux *% 0x517cc1b727220a95) ^ (uy *% 0x9e3779b185ebca87));
    const value: u32 = @truncate(hashed >> 40);
    return @as(f32, @floatFromInt(value)) / 16777215.0;
}

fn clampByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 255.0));
}

fn worldToSpritePixel(s: Sprite, centerWorld: vec.Vec2, entityPos: vec.Vec2, rotation: f32, width: usize, height: usize) vec.Vec2 {
    const relativeWorld = vec.Vec2{
        .x = centerWorld.x - entityPos.x,
        .y = centerWorld.y - entityPos.y,
    };

    const cosA = @cos(-rotation);
    const sinA = @sin(-rotation);
    const rotatedLocal = vec.Vec2{
        .x = relativeWorld.x * cosA - relativeWorld.y * sinA,
        .y = relativeWorld.x * sinA + relativeWorld.y * cosA,
    };

    const rotatedLocalPixels = conv.m2Pixel(.{ .x = rotatedLocal.x, .y = rotatedLocal.y });
    return .{
        .x = @as(f32, @floatFromInt(rotatedLocalPixels.x)) / s.scale.x + @as(f32, @floatFromInt(width)) / 2.0,
        .y = @as(f32, @floatFromInt(rotatedLocalPixels.y)) / s.scale.y + @as(f32, @floatFromInt(height)) / 2.0,
    };
}

fn spritePixelToWorld(s: Sprite, pixel: vec.Vec2, entityPos: vec.Vec2, rotation: f32, width: i32, height: i32) vec.Vec2 {
    const widthFloat: f32 = @floatFromInt(width);
    const heightFloat: f32 = @floatFromInt(height);
    const localMeters = vec.Vec2{
        .x = (pixel.x - widthFloat / 2.0) * s.scale.x / conv.met2pix,
        .y = (pixel.y - heightFloat / 2.0) * s.scale.y / conv.met2pix,
    };
    const cosA = @cos(rotation);
    const sinA = @sin(rotation);
    return .{
        .x = entityPos.x + localMeters.x * cosA - localMeters.y * sinA,
        .y = entityPos.y + localMeters.x * sinA + localMeters.y * cosA,
    };
}

fn worldDirectionToSpritePixelDirection(directionWorld: vec.Vec2, rotation: f32, scale: vec.Vec2) vec.Vec2 {
    const cosA = @cos(-rotation);
    const sinA = @sin(-rotation);
    const rotatedLocal = vec.Vec2{
        .x = directionWorld.x * cosA - directionWorld.y * sinA,
        .y = directionWorld.x * sinA + directionWorld.y * cosA,
    };
    const pixelDirection = vec.Vec2{
        .x = rotatedLocal.x / scale.x,
        .y = rotatedLocal.y / scale.y,
    };
    const length = vec.magnitude(pixelDirection);
    if (length < 0.001) {
        return .{ .x = 0.0, .y = -1.0 };
    }
    return .{
        .x = pixelDirection.x / length,
        .y = pixelDirection.y / length,
    };
}

fn blendStainPixel(pixels: [*]u8, pixelIndex: usize, color: Color, strength: f32, noise: f32) void {
    const tint = std.math.clamp(strength, 0.0, 0.95);
    const keep = 1.0 - tint;
    const darken = 1.0 - tint * 0.32;
    const colorJitter = 0.82 + noise * 0.24;

    const oldB = @as(f32, @floatFromInt(pixels[pixelIndex + 0]));
    const oldG = @as(f32, @floatFromInt(pixels[pixelIndex + 1]));
    const oldR = @as(f32, @floatFromInt(pixels[pixelIndex + 2]));

    const stainB = @as(f32, @floatFromInt(color.b)) * colorJitter;
    const stainG = @as(f32, @floatFromInt(color.g)) * colorJitter;
    const stainR = @as(f32, @floatFromInt(color.r)) * colorJitter;

    pixels[pixelIndex + 0] = clampByte(oldB * keep * darken + stainB * tint);
    pixels[pixelIndex + 1] = clampByte(oldG * keep * darken + stainG * tint);
    pixels[pixelIndex + 2] = clampByte(oldR * keep * darken + stainR * tint);
}

pub fn stainSplatOnSurface(
    spriteUuid: u64,
    centerWorld: vec.Vec2,
    radiusWorld: f32,
    entityPos: vec.Vec2,
    rotation: f32,
    color: Color,
    impactVelocityWorld: vec.Vec2,
    seed: u64,
) !?vec.IRect {
    if (radiusWorld <= 0.0) {
        return null;
    }

    const s = sprites.getLocking(spriteUuid) orelse {
        std.log.warn("stainSplatOnSurface: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };

    if (s.scale.x <= 0.0 or s.scale.y <= 0.0) {
        std.log.warn("stainSplatOnSurface: sprite {d} has invalid scale ({d},{d})", .{ spriteUuid, s.scale.x, s.scale.y });
        return null;
    }

    const surface = s.surface.*;
    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const bytesPerPixel: usize = 4;

    const centerPixelF = worldToSpritePixel(s, centerWorld, entityPos, rotation, width, height);
    const radiusPixels = @max(1.0, (radiusWorld * conv.met2pix) / @max(s.scale.x, s.scale.y));
    const impactSpeed = vec.magnitude(impactVelocityWorld);
    const impactDir = worldDirectionToSpritePixelDirection(impactVelocityWorld, rotation, s.scale);
    const sideDir = vec.Vec2{ .x = -impactDir.y, .y = impactDir.x };
    const mainStretch = 1.0 + @min(impactSpeed * 0.08, 1.25);

    var spots: [11]StainSpot = undefined;
    var spotCount: usize = 0;
    spots[spotCount] = .{
        .offsetX = 0.0,
        .offsetY = 0.0,
        .radius = radiusPixels,
        .strength = 0.9,
    };
    spotCount += 1;

    const satelliteCount: usize = 5 + @as(usize, @intFromFloat(randomUnitFromSeed(seed, 11) * 5.99));
    for (0..satelliteCount) |i| {
        const saltBase = @as(u64, @intCast(i)) * 17;
        const alongBias = randomUnitFromSeed(seed, 40 + saltBase);
        const distance = radiusPixels * (0.45 + randomUnitFromSeed(seed, 41 + saltBase) * (1.15 + @min(impactSpeed * 0.035, 0.85)));
        const radius = radiusPixels * (0.08 + randomUnitFromSeed(seed, 42 + saltBase) * 0.2);
        const strength = 0.35 + randomUnitFromSeed(seed, 43 + saltBase) * 0.45;

        if (alongBias < 0.62) {
            const sideOffset = (randomUnitFromSeed(seed, 44 + saltBase) - 0.5) * radiusPixels * 1.15;
            spots[spotCount] = .{
                .offsetX = impactDir.x * distance + sideDir.x * sideOffset,
                .offsetY = impactDir.y * distance + sideDir.y * sideOffset,
                .radius = radius,
                .strength = strength,
            };
        } else {
            const angle = randomUnitFromSeed(seed, 45 + saltBase) * std.math.pi * 2.0;
            spots[spotCount] = .{
                .offsetX = @cos(angle) * distance,
                .offsetY = @sin(angle) * distance,
                .radius = radius,
                .strength = strength,
            };
        }
        spotCount += 1;
    }

    var extent = radiusPixels * mainStretch;
    for (spots[0..spotCount]) |spot| {
        extent = @max(extent, @abs(spot.offsetX) + spot.radius);
        extent = @max(extent, @abs(spot.offsetY) + spot.radius);
    }
    extent += 2.0;

    const rawMinX: i32 = @intFromFloat(@floor(centerPixelF.x - extent));
    const rawMaxX: i32 = @intFromFloat(@ceil(centerPixelF.x + extent));
    const rawMinY: i32 = @intFromFloat(@floor(centerPixelF.y - extent));
    const rawMaxY: i32 = @intFromFloat(@ceil(centerPixelF.y + extent));

    const widthI: i32 = @intCast(width);
    const heightI: i32 = @intCast(height);

    if (rawMaxX < 0 or rawMinX >= widthI or rawMaxY < 0 or rawMinY >= heightI) {
        return null;
    }

    const minX: usize = @intCast(@max(0, rawMinX));
    const maxX: usize = @intCast(@min(widthI - 1, rawMaxX));
    const minY: usize = @intCast(@max(0, rawMinY));
    const maxY: usize = @intCast(@min(heightI - 1, rawMaxY));

    var changed = false;
    var dirtyMinX: i32 = widthI;
    var dirtyMinY: i32 = heightI;
    var dirtyMaxX: i32 = 0;
    var dirtyMaxY: i32 = 0;

    var y = minY;
    while (y <= maxY) : (y += 1) {
        var x = minX;
        while (x <= maxX) : (x += 1) {
            const pixelIndex = y * pitch + x * bytesPerPixel;
            if (pixels[pixelIndex + 3] == 0) {
                continue;
            }

            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const px = @as(f32, @floatFromInt(xi)) - centerPixelF.x;
            const py = @as(f32, @floatFromInt(yi)) - centerPixelF.y;
            const textureNoise = pixelNoise(seed, xi, yi, 700);
            const holeNoise = pixelNoise(seed, xi, yi, 911);
            var strongest: f32 = 0.0;

            for (spots[0..spotCount], 0..) |spot, spotIndex| {
                const localX = px - spot.offsetX;
                const localY = py - spot.offsetY;
                const along = localX * impactDir.x + localY * impactDir.y;
                const across = localX * sideDir.x + localY * sideDir.y;
                const stretch = if (spotIndex == 0) mainStretch else 1.0;
                const normalized = @sqrt((along / stretch) * (along / stretch) + across * across) / spot.radius;
                const edgeNoise = pixelNoise(seed, xi, yi, 1000 + @as(u64, @intCast(spotIndex)) * 97);
                const edge = 0.72 + edgeNoise * 0.34;
                if (normalized > edge) {
                    continue;
                }

                const fade = 1.0 - normalized / @max(edge, 0.001);
                const strength = spot.strength * (0.25 + fade * 0.75) * (0.8 + textureNoise * 0.25);
                strongest = @max(strongest, strength);
            }

            if (strongest <= 0.04) {
                continue;
            }
            if (holeNoise > 0.985 and strongest < 0.55) {
                continue;
            }

            blendStainPixel(pixels, pixelIndex, color, strongest, textureNoise);
            changed = true;
            dirtyMinX = @min(dirtyMinX, xi);
            dirtyMinY = @min(dirtyMinY, yi);
            dirtyMaxX = @max(dirtyMaxX, xi + 1);
            dirtyMaxY = @max(dirtyMaxY, yi + 1);
        }
    }

    if (!changed) {
        return null;
    }

    return .{
        .minX = dirtyMinX,
        .minY = dirtyMinY,
        .maxX = dirtyMaxX,
        .maxY = dirtyMaxY,
    };
}

fn cutoutSignedRandom(seed: u64, index: usize, salt: u64) i32 {
    const vertexIndex: u64 = @intCast(index);
    const hashed = hash64(seed ^ salt ^ (vertexIndex *% 0x9e3779b97f4a7c15));
    const randomValue: u16 = @truncate(hashed >> 48);
    return @as(i32, @intCast(randomValue)) - 32768;
}

fn fractureVertexCount(radiusPixels: f32, seed: u64) usize {
    const circumference = radiusPixels * std.math.tau;
    const estimated: i32 = @intFromFloat(@round(circumference / fractureFacetLengthPixels));
    const countVariation = @as(i32, @intCast(hash64(seed ^ 0xa0761d6478bd642f) % 3)) - 1;
    return @intCast(std.math.clamp(
        estimated + countVariation,
        @as(i32, @intCast(minimumFractureVertexCount)),
        @as(i32, @intCast(maximumFractureVertexCount)),
    ));
}

fn buildFracturedCutout(
    s: Sprite,
    radiusPixels: f32,
    rotation: f32,
    seed: u64,
    irregularity: f32,
) FracturedCutout {
    var cutout: FracturedCutout = undefined;
    cutout.vertexCount = fractureVertexCount(radiusPixels, seed);
    const vertexCountFloat: f32 = @floatFromInt(cutout.vertexCount);
    const angleStep = std.math.tau / vertexCountFloat;
    const phase = randomUnitFromSeed(seed, 0xe7037ed1a0b428db) * angleStep;
    const cosA = @cos(-rotation);
    const sinA = @sin(-rotation);

    for (cutout.vertices[0..cutout.vertexCount], 0..) |*vertex, index| {
        const angleRandom = @as(f32, @floatFromInt(cutoutSignedRandom(seed, index, 0x8ebc6af09c88c6e3))) /
            cutoutRadiusFactorScale;
        const radiusRandom = @as(f32, @floatFromInt(cutoutSignedRandom(seed, index, 0x589965cc75374cc3))) /
            cutoutRadiusFactorScale;
        const baseAngle = @as(f32, @floatFromInt(index)) * angleStep;
        const angle = phase + baseAngle + angleRandom * angleStep * maximumFractureAngleJitter;
        const vertexRadius = radiusPixels * (1.0 + radiusRandom * irregularity);
        const worldX = @cos(angle) * vertexRadius;
        const worldY = @sin(angle) * vertexRadius;
        const localX = worldX * cosA - worldY * sinA;
        const localY = worldX * sinA + worldY * cosA;
        vertex.* = .{
            .x = @intFromFloat(@round(localX / s.scale.x * cutoutFixedPointScale)),
            .y = @intFromFloat(@round(localY / s.scale.y * cutoutFixedPointScale)),
        };
    }
    return cutout;
}

fn crossCutoutVectors(a: CutoutVertex, b: CutoutVertex) i64 {
    return @as(i64, a.x) * b.y - @as(i64, a.y) * b.x;
}

fn pointInsideCutoutTriangle(point: CutoutVertex, a: CutoutVertex, b: CutoutVertex) bool {
    const orientation = crossCutoutVectors(a, b);
    const crossStart = crossCutoutVectors(a, point);
    const crossEnd = crossCutoutVectors(point, b);
    const edge = CutoutVertex{ .x = b.x - a.x, .y = b.y - a.y };
    const relativePoint = CutoutVertex{ .x = point.x - a.x, .y = point.y - a.y };
    const crossOuter = crossCutoutVectors(edge, relativePoint);

    if (orientation >= 0) return crossStart >= 0 and crossEnd >= 0 and crossOuter >= 0;
    return crossStart <= 0 and crossEnd <= 0 and crossOuter <= 0;
}

fn pointInsideFracturedCutout(point: CutoutVertex, cutout: *const FracturedCutout) bool {
    const vertices = cutout.vertices[0..cutout.vertexCount];
    for (vertices, 0..) |vertex, index| {
        const nextVertex = vertices[(index + 1) % vertices.len];
        if (pointInsideCutoutTriangle(point, vertex, nextVertex)) return true;
    }
    return false;
}

fn floorCutoutFixed(value: i32) i32 {
    return @divFloor(value, cutoutFixedPointScale);
}

fn ceilCutoutFixed(value: i32) i32 {
    return -@divFloor(-value, cutoutFixedPointScale);
}

fn includeCutoutEditPixel(edit: *CutoutEdit, x: i32, y: i32) void {
    edit.changed = true;
    edit.minimumX = @min(edit.minimumX, x);
    edit.minimumY = @min(edit.minimumY, y);
    edit.maximumX = @max(edit.maximumX, x + 1);
    edit.maximumY = @max(edit.maximumY, y + 1);
}

fn cutoutEditRect(edit: CutoutEdit) vec.IRect {
    return .{
        .minX = edit.minimumX,
        .minY = edit.minimumY,
        .maxX = edit.maximumX,
        .maxY = edit.maximumY,
    };
}

fn cutoutPointInWorldPixels(point: CutoutVertex, scale: vec.Vec2) vec.Vec2 {
    const fixedPointScale: f32 = @floatFromInt(cutoutFixedPointScale);
    return .{
        .x = @as(f32, @floatFromInt(point.x)) / fixedPointScale * scale.x,
        .y = @as(f32, @floatFromInt(point.y)) / fixedPointScale * scale.y,
    };
}

fn distanceSquaredToCutoutSegment(point: vec.Vec2, start: vec.Vec2, end: vec.Vec2) f32 {
    const segment = vec.subtract(end, start);
    const pointOffset = vec.subtract(point, start);
    const lengthSquared = vec.dot(segment, segment);
    if (lengthSquared <= 0.001) return vec.dot(pointOffset, pointOffset);

    const projection = std.math.clamp(vec.dot(pointOffset, segment) / lengthSquared, 0, 1);
    const closest = vec.add(start, vec.mul(segment, projection));
    const distance = vec.subtract(point, closest);
    return vec.dot(distance, distance);
}

fn distanceToFracturedCutout(point: CutoutVertex, cutout: *const FracturedCutout, scale: vec.Vec2) f32 {
    const pointPixels = cutoutPointInWorldPixels(point, scale);
    const vertices = cutout.vertices[0..cutout.vertexCount];
    var minimumDistanceSquared = std.math.inf(f32);
    var previousVertex = cutoutPointInWorldPixels(vertices[vertices.len - 1], scale);
    for (vertices) |vertex| {
        const currentVertex = cutoutPointInWorldPixels(vertex, scale);
        minimumDistanceSquared = @min(minimumDistanceSquared, distanceSquaredToCutoutSegment(pointPixels, previousVertex, currentVertex));
        previousVertex = currentVertex;
    }
    return @sqrt(minimumDistanceSquared);
}

fn charWidthAtPoint(
    point: CutoutVertex,
    cutout: *const FracturedCutout,
    scale: vec.Vec2,
    baseWidth: f32,
    seed: u64,
    x: i32,
    y: i32,
) f32 {
    const pointPixels = cutoutPointInWorldPixels(point, scale);
    var angle = std.math.atan2(pointPixels.y, pointPixels.x);
    if (angle < 0) angle += std.math.tau;

    const sectorCount = cutout.vertexCount * 2;
    const sectorCountFloat: f32 = @floatFromInt(sectorCount);
    const phase = randomUnitFromSeed(seed, 0xa4093822299f31d0) * std.math.tau;
    const sectorCoordinate = @mod(angle + phase, std.math.tau) / std.math.tau * sectorCountFloat;
    const sectorIndex: usize = @intFromFloat(@floor(sectorCoordinate));
    const sectorPosition = sectorCoordinate - @floor(sectorCoordinate);
    const triangle = 1.0 - @abs(sectorPosition * 2.0 - 1.0);
    const triangleSquared = triangle * triangle;
    const spikeShape = triangleSquared * triangleSquared;
    const spikeRoll = randomUnitFromSeed(seed, 0x082efa98ec4e6c89 ^ @as(u64, @intCast(sectorIndex)));
    const spikeAmplitude = spikeRoll * spikeRoll * spikeRoll;
    const spikeScale = 0.32 + spikeShape * (0.55 + spikeAmplitude * 3.0);
    const edgeBreakup = 0.88 + pixelNoise(seed, x, y, 0x452821e638d01377) * 0.24;
    return baseWidth * spikeScale * edgeBreakup;
}

fn darkenCharredPixel(pixels: [*]u8, pixelIndex: usize, intensity: f32) bool {
    const clampedIntensity = std.math.clamp(intensity, 0, 0.95);
    const remaining = 1.0 - clampedIntensity;
    const oldB = pixels[pixelIndex + 0];
    const oldG = pixels[pixelIndex + 1];
    const oldR = pixels[pixelIndex + 2];
    const newB = clampByte(@as(f32, @floatFromInt(oldB)) * remaining * (1.0 - clampedIntensity * 0.18));
    const newG = clampByte(@as(f32, @floatFromInt(oldG)) * remaining * (1.0 - clampedIntensity * 0.1));
    const newR = clampByte(@as(f32, @floatFromInt(oldR)) * remaining);
    if (newB == oldB and newG == oldG and newR == oldR) return false;

    pixels[pixelIndex + 0] = newB;
    pixels[pixelIndex + 1] = newG;
    pixels[pixelIndex + 2] = newR;
    return true;
}

fn applyFracturedSurfacePixels(
    pixels: [*]u8,
    pitch: usize,
    width: i32,
    height: i32,
    centerXFixed: i32,
    centerYFixed: i32,
    cutout: *const FracturedCutout,
    scale: vec.Vec2,
    charWidthWorld: f32,
    charStrength: f32,
    charSeed: u64,
) ?SurfaceCutoutEdit {
    const vertices = cutout.vertices[0..cutout.vertexCount];
    var minimumOffsetX = vertices[0].x;
    var maximumOffsetX = vertices[0].x;
    var minimumOffsetY = vertices[0].y;
    var maximumOffsetY = vertices[0].y;
    for (vertices[1..]) |vertex| {
        minimumOffsetX = @min(minimumOffsetX, vertex.x);
        maximumOffsetX = @max(maximumOffsetX, vertex.x);
        minimumOffsetY = @min(minimumOffsetY, vertex.y);
        maximumOffsetY = @max(maximumOffsetY, vertex.y);
    }

    const charWidthPixels = charWidthWorld * conv.met2pix;
    const shouldChar = charWidthPixels > 0 and charStrength > 0;
    const widthFloat: f32 = @floatFromInt(width);
    const heightFloat: f32 = @floatFromInt(height);
    const charExpansionX: i32 = if (shouldChar)
        @intFromFloat(@ceil(@min(charWidthPixels * maximumCharWidthScale / scale.x, widthFloat)))
    else
        0;
    const charExpansionY: i32 = if (shouldChar)
        @intFromFloat(@ceil(@min(charWidthPixels * maximumCharWidthScale / scale.y, heightFloat)))
    else
        0;

    const rawMinimumX = floorCutoutFixed(centerXFixed + minimumOffsetX) - charExpansionX;
    const rawMaximumX = ceilCutoutFixed(centerXFixed + maximumOffsetX) + charExpansionX;
    const rawMinimumY = floorCutoutFixed(centerYFixed + minimumOffsetY) - charExpansionY;
    const rawMaximumY = ceilCutoutFixed(centerYFixed + maximumOffsetY) + charExpansionY;
    if (rawMaximumX < 0 or rawMinimumX >= width or rawMaximumY < 0 or rawMinimumY >= height) return null;

    const minimumX = @max(0, rawMinimumX);
    const maximumX = @min(width - 1, rawMaximumX);
    const minimumY = @max(0, rawMinimumY);
    const maximumY = @min(height - 1, rawMaximumY);
    const bytesPerPixel: usize = 4;
    var textureEdit = CutoutEdit{ .minimumX = width, .minimumY = height };
    var colliderEdit = CutoutEdit{ .minimumX = width, .minimumY = height };
    var y = minimumY;
    while (y <= maximumY) : (y += 1) {
        var x = minimumX;
        while (x <= maximumX) : (x += 1) {
            const point = CutoutVertex{
                .x = x * cutoutFixedPointScale - centerXFixed,
                .y = y * cutoutFixedPointScale - centerYFixed,
            };
            const pixelIndex = @as(usize, @intCast(y)) * pitch + @as(usize, @intCast(x)) * bytesPerPixel;
            if (pointInsideFracturedCutout(point, cutout)) {
                if (pixels[pixelIndex + 3] == 0) continue;

                pixels[pixelIndex + 3] = 0;
                includeCutoutEditPixel(&textureEdit, x, y);
                includeCutoutEditPixel(&colliderEdit, x, y);
                continue;
            }

            if (!shouldChar or pixels[pixelIndex + 3] == 0) continue;

            const distance = distanceToFracturedCutout(point, cutout, scale);
            const noisyWidth = charWidthAtPoint(point, cutout, scale, charWidthPixels, charSeed, x, y);
            if (distance >= noisyWidth) continue;

            const distanceFalloff = 1.0 - distance / noisyWidth;
            const strengthNoise = pixelNoise(charSeed, x, y, 0x13198a2e03707344);
            const intensity = charStrength * @sqrt(distanceFalloff) * (0.82 + strengthNoise * 0.28);
            if (!darkenCharredPixel(pixels, pixelIndex, intensity)) continue;
            includeCutoutEditPixel(&textureEdit, x, y);
        }
    }

    if (!textureEdit.changed) return null;
    return .{
        .textureDirtyRect = cutoutEditRect(textureEdit),
        .colliderDirtyRect = if (colliderEdit.changed) cutoutEditRect(colliderEdit) else null,
    };
}

fn hotRimPixel(
    pixels: [*]u8,
    pitch: usize,
    x: i32,
    y: i32,
    centerXFixed: i32,
    centerYFixed: i32,
    cutout: *const FracturedCutout,
    scale: vec.Vec2,
    widthPixels: f32,
) bool {
    const bytesPerPixel: usize = 4;
    const pixelIndex = @as(usize, @intCast(y)) * pitch + @as(usize, @intCast(x)) * bytesPerPixel;
    if (pixels[pixelIndex + 3] < hotRimMinimumSurfaceAlpha) return false;

    const point = CutoutVertex{
        .x = x * cutoutFixedPointScale - centerXFixed,
        .y = y * cutoutFixedPointScale - centerYFixed,
    };
    if (pointInsideFracturedCutout(point, cutout)) return false;
    return distanceToFracturedCutout(point, cutout, scale) < widthPixels;
}

fn hotRimQuadForRun(
    s: Sprite,
    startX: i32,
    endX: i32,
    y: i32,
    entityPos: vec.Vec2,
    rotation: f32,
    width: i32,
    height: i32,
) SurfaceHotRimQuad {
    const startFloat: f32 = @floatFromInt(startX);
    const endFloat: f32 = @floatFromInt(endX);
    const yFloat: f32 = @floatFromInt(y);
    return .{ .corners = .{
        spritePixelToWorld(s, .{ .x = startFloat, .y = yFloat }, entityPos, rotation, width, height),
        spritePixelToWorld(s, .{ .x = endFloat, .y = yFloat }, entityPos, rotation, width, height),
        spritePixelToWorld(s, .{ .x = endFloat, .y = yFloat + 1 }, entityPos, rotation, width, height),
        spritePixelToWorld(s, .{ .x = startFloat, .y = yFloat + 1 }, entityPos, rotation, width, height),
    } };
}

fn buildHotRimQuads(
    s: Sprite,
    pixels: [*]u8,
    pitch: usize,
    width: i32,
    height: i32,
    centerXFixed: i32,
    centerYFixed: i32,
    cutout: *const FracturedCutout,
    entityPos: vec.Vec2,
    rotation: f32,
    hotRimWidthWorld: f32,
) !?[]SurfaceHotRimQuad {
    if (hotRimWidthWorld <= 0) return null;

    const vertices = cutout.vertices[0..cutout.vertexCount];
    var minimumOffsetX = vertices[0].x;
    var maximumOffsetX = vertices[0].x;
    var minimumOffsetY = vertices[0].y;
    var maximumOffsetY = vertices[0].y;
    for (vertices[1..]) |vertex| {
        minimumOffsetX = @min(minimumOffsetX, vertex.x);
        maximumOffsetX = @max(maximumOffsetX, vertex.x);
        minimumOffsetY = @min(minimumOffsetY, vertex.y);
        maximumOffsetY = @max(maximumOffsetY, vertex.y);
    }

    const widthPixels = hotRimWidthWorld * conv.met2pix;
    const expansionX: i32 = @intFromFloat(@ceil(widthPixels / s.scale.x));
    const expansionY: i32 = @intFromFloat(@ceil(widthPixels / s.scale.y));
    const rawMinimumX = floorCutoutFixed(centerXFixed + minimumOffsetX) - expansionX;
    const rawMaximumX = ceilCutoutFixed(centerXFixed + maximumOffsetX) + expansionX;
    const rawMinimumY = floorCutoutFixed(centerYFixed + minimumOffsetY) - expansionY;
    const rawMaximumY = ceilCutoutFixed(centerYFixed + maximumOffsetY) + expansionY;
    if (rawMaximumX < 0 or rawMinimumX >= width or rawMaximumY < 0 or rawMinimumY >= height) return null;

    const minimumX = @max(0, rawMinimumX);
    const maximumX = @min(width - 1, rawMaximumX);
    const minimumY = @max(0, rawMinimumY);
    const maximumY = @min(height - 1, rawMaximumY);
    var quads = std.array_list.Managed(SurfaceHotRimQuad).init(allocator);
    errdefer quads.deinit();

    var y = minimumY;
    while (y <= maximumY) : (y += 1) {
        var runStart: i32 = -1;
        var x = minimumX;
        while (x <= maximumX + 1) : (x += 1) {
            const belongsToRim = x <= maximumX and hotRimPixel(
                pixels,
                pitch,
                x,
                y,
                centerXFixed,
                centerYFixed,
                cutout,
                s.scale,
                widthPixels,
            );
            if (belongsToRim) {
                if (runStart < 0) runStart = x;
                continue;
            }
            if (runStart < 0) continue;

            try quads.append(hotRimQuadForRun(s, runStart, x, y, entityPos, rotation, width, height));
            runStart = -1;
        }
    }

    if (quads.items.len == 0) {
        quads.deinit();
        return null;
    }
    return try quads.toOwnedSlice();
}

pub fn removeFracturedCutoutFromSurface(
    s: Sprite,
    centerWorld: vec.Vec2,
    radiusWorld: f32,
    entityPos: vec.Vec2,
    rotation: f32,
    seed: u64,
    irregularity: f32,
    charWidthWorld: f32,
    charStrength: f32,
    hotRimWidthWorld: f32,
) ?SurfaceCutoutResult {
    const radiusPixels = radiusWorld * conv.met2pix;
    const centerPixel = worldToSpritePixel(s, centerWorld, entityPos, rotation, @intCast(s.surface.w), @intCast(s.surface.h));
    const centerXFixed: i32 = @intFromFloat(@round(centerPixel.x * cutoutFixedPointScale));
    const centerYFixed: i32 = @intFromFloat(@round(centerPixel.y * cutoutFixedPointScale));
    const cutout = buildFracturedCutout(s, radiusPixels, rotation, seed, irregularity);

    const width: i32 = s.surface.w;
    const height: i32 = s.surface.h;
    const pixels: [*]u8 = @ptrCast(s.surface.pixels);
    const pitch: usize = @intCast(s.surface.pitch);
    const charSeed = hash64(seed ^ @as(u64, @bitCast(time.realNow())));
    const edit = applyFracturedSurfacePixels(
        pixels,
        pitch,
        width,
        height,
        centerXFixed,
        centerYFixed,
        &cutout,
        s.scale,
        charWidthWorld,
        charStrength,
        charSeed,
    ) orelse return null;
    const hotRimQuads = buildHotRimQuads(
        s,
        pixels,
        pitch,
        width,
        height,
        centerXFixed,
        centerYFixed,
        &cutout,
        entityPos,
        rotation,
        hotRimWidthWorld,
    ) catch |err| {
        std.log.warn("removeFracturedCutoutFromSurface: could not capture hot-rim geometry: {}", .{err});
        return .{ .edit = edit, .hotRimQuads = null };
    };
    return .{ .edit = edit, .hotRimQuads = hotRimQuads };
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

    _ = iterateCircleOnSurface(sprite, centerWorld, radiusWorld, entityPos, rotation, Color, color, colorPixel);
}

pub fn paintSpriteOnSurface(
    targetUuid: u64,
    sourceUuid: u64,
    centerWorld: vec.Vec2,
    sizeWorldX: f32,
    sizeWorldY: f32,
    entityPos: vec.Vec2,
    rotation: f32,
) !void {
    const target = sprites.getLocking(targetUuid) orelse return error.SpriteNotFound;
    const source = sprites.getLocking(sourceUuid) orelse return error.SpriteNotFound;

    const targetSurface = target.surface.*;
    const targetPixels: [*]u8 = @ptrCast(targetSurface.pixels);
    const targetPitch: usize = @intCast(targetSurface.pitch);
    const targetWidth: usize = @intCast(targetSurface.w);
    const targetHeight: usize = @intCast(targetSurface.h);

    const sourceSurface = source.surface.*;
    const sourcePixels: [*]u8 = @ptrCast(sourceSurface.pixels);
    const sourcePitch: usize = @intCast(sourceSurface.pitch);
    const sourceWidth: usize = @intCast(sourceSurface.w);
    const sourceHeight: usize = @intCast(sourceSurface.h);

    const bytesPerPixel: usize = 4;

    // Transform centerWorld to target sprite local pixel coords (same as iterateCircleOnSurface)
    const relativeWorld = vec.Vec2{
        .x = centerWorld.x - entityPos.x,
        .y = centerWorld.y - entityPos.y,
    };

    const cosA = @cos(-rotation);
    const sinA = @sin(-rotation);
    const rotatedLocal = vec.Vec2{
        .x = relativeWorld.x * cosA - relativeWorld.y * sinA,
        .y = relativeWorld.x * sinA + relativeWorld.y * cosA,
    };

    const rotatedLocalPixels = conv.m2Pixel(.{ .x = rotatedLocal.x, .y = rotatedLocal.y });
    const centerPixelF = vec.Vec2{
        .x = @as(f32, @floatFromInt(rotatedLocalPixels.x)) / target.scale.x + @as(f32, @floatFromInt(targetWidth)) / 2.0,
        .y = @as(f32, @floatFromInt(rotatedLocalPixels.y)) / target.scale.y + @as(f32, @floatFromInt(targetHeight)) / 2.0,
    };

    const halfWidthPixels = (sizeWorldX / 2.0 * conv.met2pix) / target.scale.x;
    const halfHeightPixels = (sizeWorldY / 2.0 * conv.met2pix) / target.scale.y;

    // Bounding box in target pixels
    const minXi = @as(i32, @intFromFloat(@floor(centerPixelF.x - halfWidthPixels)));
    const maxXi = @as(i32, @intFromFloat(@ceil(centerPixelF.x + halfWidthPixels)));
    const minYi = @as(i32, @intFromFloat(@floor(centerPixelF.y - halfHeightPixels)));
    const maxYi = @as(i32, @intFromFloat(@ceil(centerPixelF.y + halfHeightPixels)));

    const twi: i32 = @intCast(targetWidth - 1);
    const thi: i32 = @intCast(targetHeight - 1);

    // Early return if entirely outside the target surface
    if (maxXi < 0 or minXi > twi or maxYi < 0 or minYi > thi) return;

    const minX: usize = @intCast(@max(0, minXi));
    const maxX: usize = @intCast(@min(twi, maxXi));
    const minY: usize = @intCast(@max(0, minYi));
    const maxY: usize = @intCast(@min(thi, maxYi));

    const sprayLeft = centerPixelF.x - halfWidthPixels;
    const sprayTop = centerPixelF.y - halfHeightPixels;
    const spraySizeX = halfWidthPixels * 2.0;
    const spraySizeY = halfHeightPixels * 2.0;

    var y = minY;
    while (y <= maxY) : (y += 1) {
        var x = minX;
        while (x <= maxX) : (x += 1) {
            const targetIndex = y * targetPitch + x * bytesPerPixel;

            // Skip transparent target pixels
            if (targetPixels[targetIndex + 3] < 50) continue;

            // Map target pixel to source pixel
            const srcXf = (@as(f32, @floatFromInt(x)) - sprayLeft) / spraySizeX * @as(f32, @floatFromInt(sourceWidth));
            const srcYf = (@as(f32, @floatFromInt(y)) - sprayTop) / spraySizeY * @as(f32, @floatFromInt(sourceHeight));

            const srcX = @as(i32, @intFromFloat(srcXf));
            const srcY = @as(i32, @intFromFloat(srcYf));

            if (srcX < 0 or srcX >= @as(i32, @intCast(sourceWidth)) or
                srcY < 0 or srcY >= @as(i32, @intCast(sourceHeight))) continue;

            const sourceIndex = @as(usize, @intCast(srcY)) * sourcePitch + @as(usize, @intCast(srcX)) * bytesPerPixel;

            // Only paint if source pixel is not transparent
            if (sourcePixels[sourceIndex + 3] > 50) {
                targetPixels[targetIndex + 0] = sourcePixels[sourceIndex + 0]; // B
                targetPixels[targetIndex + 1] = sourcePixels[sourceIndex + 1]; // G
                targetPixels[targetIndex + 2] = sourcePixels[sourceIndex + 2]; // R
                // Keep target alpha
            }
        }
    }
}

fn markGeometryChanged(s: *Sprite) void {
    s.geometryId = uuid.generate();
    s.geometryVersion += 1;
}

fn uploadTextureFromSurface(s: *Sprite) !void {
    const movedToMutable = tex.isImmutableAtlasTexture(s.texture);
    const runtimeSurface = try createRuntimeAtlasSurfaceForTexture(s.surface, s.texture);
    defer destroyRuntimeAtlasSurface(runtimeSurface);

    try tex.ensureMutableTexture(s.texture, runtimeSurface.surface);
    if (movedToMutable) {
        return;
    }

    try tex.reuploadTexture(s.texture, runtimeSurface.surface);
}

pub fn updateTextureVisualFromSurface(spriteUuid: u64) !void {
    const s = sprites.getPtrLocking(spriteUuid) orelse {
        std.log.warn("updateTextureVisualFromSurface: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };

    try uploadTextureFromSurface(s);
}

pub fn updateTextureVisualRegionFromSurface(spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const s = sprites.getPtrLocking(spriteUuid) orelse {
        std.log.warn("updateTextureVisualRegionFromSurface: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const width = s.surface.w;
    const height = s.surface.h;
    const rect = vec.irectExpandedClamped(dirtyRect, 1, width, height);
    if (rect.minX >= rect.maxX or rect.minY >= rect.maxY) {
        return;
    }

    const movedToMutable = tex.isImmutableAtlasTexture(s.texture);
    if (!surfaceMatchesTexture(s.surface, s.texture)) {
        try uploadTextureFromSurface(s);
        return;
    }

    try tex.ensureMutableTexture(s.texture, s.surface);
    if (movedToMutable) {
        return;
    }

    try tex.reuploadTextureRegion(s.texture, s.surface, .{
        .x = rect.minX,
        .y = rect.minY,
        .w = rect.maxX - rect.minX,
        .h = rect.maxY - rect.minY,
    });
}

pub fn updateTextureGeometryFromSurface(spriteUuid: u64) !void {
    const s = sprites.getPtrLocking(spriteUuid) orelse {
        std.log.warn("updateTextureGeometryFromSurface: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };

    try uploadTextureFromSurface(s);
    markGeometryChanged(s);
}

pub fn updateTextureGeometryRegionFromSurface(spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const s = sprites.getPtrLocking(spriteUuid) orelse {
        std.log.warn("updateTextureGeometryRegionFromSurface: sprite {d} not found", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const width = s.surface.w;
    const height = s.surface.h;
    const rect = vec.irectExpandedClamped(dirtyRect, 1, width, height);
    if (rect.minX >= rect.maxX or rect.minY >= rect.maxY) {
        return;
    }

    const movedToMutable = tex.isImmutableAtlasTexture(s.texture);
    if (!surfaceMatchesTexture(s.surface, s.texture)) {
        try uploadTextureFromSurface(s);
        markGeometryChanged(s);
        return;
    }

    try tex.ensureMutableTexture(s.texture, s.surface);
    if (movedToMutable) {
        markGeometryChanged(s);
        return;
    }

    try tex.reuploadTextureRegion(s.texture, s.surface, .{
        .x = rect.minX,
        .y = rect.minY,
        .w = rect.maxX - rect.minX,
        .h = rect.maxY - rect.minY,
    });
    markGeometryChanged(s);
}

pub fn isAny(_: u8, _: u8, _: u8) bool {
    return true;
}

pub fn isWhite(r: u8, g: u8, b: u8) bool {
    return r > 200 and g > 200 and b > 200;
}

pub fn isCyan(r: u8, _: u8, b: u8) bool {
    return r < 150 and b > 100;
}

pub fn colorMatchingPixels(spriteUuid: u64, color: Color, comptime predicate: fn (u8, u8, u8) bool) !void {
    {
        const s = sprites.getLocking(spriteUuid) orelse {
            std.log.warn("colorMatchingPixels: sprite {d} not found", .{spriteUuid});
            return error.SpriteNotFound;
        };

        try sdl.lockSurface(s.surface);
        defer sdl.unlockSurface(s.surface);

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
    }

    try updateTextureVisualFromSurface(spriteUuid);
}

pub fn cleanupLater(spriteUuid: u64) void {
    if (sprites.getLocking(spriteUuid) == null) {
        return;
    }

    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    const acceptTimers = acceptSpriteCleanupTimers;
    spritesToCleanup.mutex.unlock(runtime.io());
    if (!acceptTimers) return;

    const uuid_as_ptr: ?*anyopaque = @ptrFromInt(spriteUuid);
    _ = sdl.addTimer(10, markSpriteForCleanup, uuid_as_ptr);
}

fn markSpriteForCleanup(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const spriteUuid: u64 = @intFromPtr(param.?);

    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    defer spritesToCleanup.mutex.unlock(runtime.io());

    if (!acceptSpriteCleanupTimers) return 0;
    spritesToCleanup.list.append(spriteUuid) catch {};

    return 0; // Don't repeat timer
}

pub fn cleanupSprites() void {
    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    defer spritesToCleanup.mutex.unlock(runtime.io());

    for (spritesToCleanup.list.items) |spriteUuid| {
        const maybeKV = sprites.fetchSwapRemoveLocking(spriteUuid);
        if (maybeKV) |kv| {
            cleanupOne(kv.value);
        }
    }

    spritesToCleanup.list.clearAndFree();
}

fn cleanupOne(s: Sprite) void {
    allocator.free(s.imgPath);
    tex.destroyTexture(s.texture);
    sdl.destroySurface(s.surface);
}

pub fn clearTextureCache() void {
    var cacheIter = textureCache.keyIterator();
    while (cacheIter.next()) |key_ptr| {
        allocator.free(key_ptr.*);
    }
    textureCache.clearRetainingCapacity();
}

pub fn cleanupAll() void {
    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    spritesToCleanup.list.clearRetainingCapacity();
    spritesToCleanup.mutex.unlock(runtime.io());

    sprites.mutex.lockUncancelable(runtime.io());
    defer sprites.mutex.unlock(runtime.io());

    for (sprites.map.values()) |s| {
        cleanupOne(s);
    }
    sprites.map.clearRetainingCapacity();

    // Free cache-owned key strings, then clear cache and reset atlas packer for level reload
    var cacheIter = textureCache.keyIterator();
    while (cacheIter.next()) |key_ptr| {
        allocator.free(key_ptr.*);
    }
    textureCache.clearRetainingCapacity();
    tex.resetAtlas();
}

pub fn deinit() void {
    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    acceptSpriteCleanupTimers = false;
    spritesToCleanup.mutex.unlock(runtime.io());

    cleanupAll();

    sprites.mutex.lockUncancelable(runtime.io());
    sprites.map.deinit(allocator);
    sprites.mutex.unlock(runtime.io());

    spritesToCleanup.mutex.lockUncancelable(runtime.io());
    spritesToCleanup.list.deinit();
    spritesToCleanup.mutex.unlock(runtime.io());

    textureCache.deinit();
}
