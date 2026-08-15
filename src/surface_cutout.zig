const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const conv = @import("conversion.zig");
const sprite = @import("sprite.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

pub const Edit = struct {
    textureDirtyRect: vec.IRect,
    colliderDirtyRect: ?vec.IRect,
};

pub const HotRimQuad = struct {
    corners: [4]vec.Vec2,
};

pub const Result = struct {
    edit: Edit,
    hotRimQuads: ?[]HotRimQuad,
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
pub const maximumIrregularity: f32 = 0.35;

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

fn worldToSpritePixel(s: sprite.Sprite, centerWorld: vec.Vec2, entityPos: vec.Vec2, rotation: f32, width: usize, height: usize) vec.Vec2 {
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

fn spritePixelToWorld(s: sprite.Sprite, pixel: vec.Vec2, entityPos: vec.Vec2, rotation: f32, width: i32, height: i32) vec.Vec2 {
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
    s: sprite.Sprite,
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
) ?Edit {
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
    s: sprite.Sprite,
    startX: i32,
    endX: i32,
    y: i32,
    entityPos: vec.Vec2,
    rotation: f32,
    width: i32,
    height: i32,
) HotRimQuad {
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
    s: sprite.Sprite,
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
) !?[]HotRimQuad {
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
    var quads = std.array_list.Managed(HotRimQuad).init(allocator);
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

pub fn apply(
    s: sprite.Sprite,
    centerWorld: vec.Vec2,
    radiusWorld: f32,
    entityPos: vec.Vec2,
    rotation: f32,
    seed: u64,
    irregularity: f32,
    charWidthWorld: f32,
    charStrength: f32,
    hotRimWidthWorld: f32,
) ?Result {
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
        std.log.warn("surface_cutout.apply: could not capture hot-rim geometry: {}", .{err});
        return .{ .edit = edit, .hotRimQuads = null };
    };
    return .{ .edit = edit, .hotRimQuads = hotRimQuads };
}
