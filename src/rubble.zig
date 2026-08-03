const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const collision = @import("collision.zig");
const conv = @import("conversion.zig");
const damage = @import("damage.zig");
const entity = @import("entity.zig");
const particle_effect = @import("particle_effect.zig");
const pool = @import("pool.zig");
const runtime = @import("runtime.zig");
const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

pub const TemplateId = u64;

const desiredPieceCount: usize = 6;
const maximumVertices: usize = 8;
const minimumSolidPixels: usize = 24;
const alphaThreshold: u8 = 100;
const charcoalWidthPixels: f32 = 3.0;
const pieceRadiusRatio: f32 = 0.36;
const pieceCenterSpacingRatio: f32 = 0.26;
const rubbleParticleAmount: f32 = 10.0;
const rubbleParticleSpreadRadians: f32 = std.math.pi * 0.8;
const radialScatterSpeed: f32 = 4.8;
const impactScatterSpeed: f32 = 2.0;
const randomScatterSpeed: f32 = 1.6;
const upwardScatterSpeed: f32 = 1.8;

const Piece = struct {
    spriteUuid: u64,
    poolId: pool.Id,
    localCenterM: vec.Vec2,
    particleColor: sprite.Color,
};

const Template = struct {
    pieces: []Piece,
};

const PolygonMask = struct {
    vertices: [maximumVertices]vec.Vec2,
    vertexCount: usize,
    minX: i32,
    minY: i32,
    maxX: i32,
    maxY: i32,
};

const GeneratedPiece = struct {
    spriteUuid: u64,
    localCenterM: vec.Vec2,
    particleColor: sprite.Color,
};

const Rng = struct {
    state: u64,
};

var templates = std.AutoArrayHashMapUnmanaged(TemplateId, Template).empty;
var rubbleParticleEffectId: ?particle_effect.Id = null;

fn randomNext(rng: *Rng) u64 {
    var value = rng.state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    rng.state = value;
    return value *% 0x2545F4914F6CDD1D;
}

fn randomFloat(rng: *Rng) f32 {
    const bits: u24 = @truncate(randomNext(rng) >> 40);
    return @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(std.math.maxInt(u24)));
}

fn randomRange(rng: *Rng, minimum: f32, maximum: f32) f32 {
    return minimum + randomFloat(rng) * (maximum - minimum);
}

fn templateIdFor(source: sprite.Sprite, seed: u64) TemplateId {
    var id = std.hash.Wyhash.hash(seed, source.imgPath);
    id ^= @as(u64, @bitCast(@as(f64, source.scale.x))) *% 0x9E3779B185EBCA87;
    id ^= @as(u64, @bitCast(@as(f64, source.scale.y))) *% 0xC2B2AE3D27D4EB4F;
    if (id != 0) return id;
    return 1;
}

fn opaquePixel(source: sprite.Sprite, x: i32, y: i32) bool {
    if (x < 0 or y < 0 or x >= source.surface.w or y >= source.surface.h) return false;
    const pixels: [*]const u8 = @ptrCast(source.surface.pixels);
    const pitch: usize = @intCast(source.surface.pitch);
    const pixelIndex = @as(usize, @intCast(y)) * pitch + @as(usize, @intCast(x)) * 4;
    return pixels[pixelIndex + 3] >= alphaThreshold;
}

fn findOpaqueBounds(source: sprite.Sprite) ?vec.IRect {
    var bounds = vec.IRect{
        .minX = source.surface.w,
        .minY = source.surface.h,
        .maxX = 0,
        .maxY = 0,
    };
    var found = false;

    var y: i32 = 0;
    while (y < source.surface.h) : (y += 1) {
        var x: i32 = 0;
        while (x < source.surface.w) : (x += 1) {
            if (!opaquePixel(source, x, y)) continue;
            found = true;
            bounds.minX = @min(bounds.minX, x);
            bounds.minY = @min(bounds.minY, y);
            bounds.maxX = @max(bounds.maxX, x + 1);
            bounds.maxY = @max(bounds.maxY, y + 1);
        }
    }

    if (!found) return null;
    return bounds;
}

fn centerFarEnough(candidate: vec.Vec2, centers: []const vec.Vec2, minimumDistance: f32) bool {
    for (centers) |center| {
        if (vec.magnitude(vec.subtract(candidate, center)) < minimumDistance) return false;
    }
    return true;
}

fn chooseCenter(source: sprite.Sprite, bounds: vec.IRect, centers: []const vec.Vec2, minimumDistance: f32, rng: *Rng) ?vec.Vec2 {
    const width: f32 = @floatFromInt(bounds.maxX - bounds.minX);
    const height: f32 = @floatFromInt(bounds.maxY - bounds.minY);

    for (0..80) |_| {
        const candidate = vec.Vec2{
            .x = @as(f32, @floatFromInt(bounds.minX)) + randomFloat(rng) * width,
            .y = @as(f32, @floatFromInt(bounds.minY)) + randomFloat(rng) * height,
        };
        if (!opaquePixel(source, @intFromFloat(candidate.x), @intFromFloat(candidate.y))) continue;
        if (!centerFarEnough(candidate, centers, minimumDistance)) continue;
        return candidate;
    }

    return null;
}

fn createPolygonMask(center: vec.Vec2, radius: f32, source: sprite.Sprite, rng: *Rng) PolygonMask {
    const vertexCount = 5 + @as(usize, @intCast(randomNext(rng) % 3));
    const baseAngle = randomRange(rng, 0, std.math.pi * 2.0);
    const radiusX = radius * randomRange(rng, 0.82, 1.18);
    const radiusY = radius * randomRange(rng, 0.72, 1.10);
    var vertices: [maximumVertices]vec.Vec2 = undefined;
    var minX: f32 = @floatFromInt(source.surface.w);
    var minY: f32 = @floatFromInt(source.surface.h);
    var maxX: f32 = 0;
    var maxY: f32 = 0;

    for (0..vertexCount) |index| {
        const regularAngle = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(vertexCount)) * std.math.pi * 2.0;
        const angle = baseAngle + regularAngle + randomRange(rng, -0.17, 0.17);
        const radialVariation = randomRange(rng, 0.68, 1.24);
        const point = vec.Vec2{
            .x = center.x + @cos(angle) * radiusX * radialVariation,
            .y = center.y + @sin(angle) * radiusY * radialVariation,
        };
        vertices[index] = point;
        minX = @min(minX, point.x);
        minY = @min(minY, point.y);
        maxX = @max(maxX, point.x);
        maxY = @max(maxY, point.y);
    }

    return .{
        .vertices = vertices,
        .vertexCount = vertexCount,
        .minX = @max(0, @as(i32, @intFromFloat(@floor(minX)))),
        .minY = @max(0, @as(i32, @intFromFloat(@floor(minY)))),
        .maxX = @min(source.surface.w, @as(i32, @intFromFloat(@ceil(maxX))) + 1),
        .maxY = @min(source.surface.h, @as(i32, @intFromFloat(@ceil(maxY))) + 1),
    };
}

fn pointInsidePolygon(point: vec.Vec2, mask: PolygonMask) bool {
    var inside = false;
    var previousIndex = mask.vertexCount - 1;
    for (0..mask.vertexCount) |index| {
        const current = mask.vertices[index];
        const previous = mask.vertices[previousIndex];
        const crosses = (current.y > point.y) != (previous.y > point.y);
        if (crosses) {
            const intersectionX = (previous.x - current.x) * (point.y - current.y) /
                (previous.y - current.y) + current.x;
            if (point.x < intersectionX) inside = !inside;
        }
        previousIndex = index;
    }
    return inside;
}

fn distanceToSegment(point: vec.Vec2, start: vec.Vec2, end: vec.Vec2) f32 {
    const segment = vec.subtract(end, start);
    const lengthSquared = vec.dot(segment, segment);
    if (lengthSquared < 0.001) return vec.magnitude(vec.subtract(point, start));
    const projection = std.math.clamp(vec.dot(vec.subtract(point, start), segment) / lengthSquared, 0.0, 1.0);
    const closest = vec.add(start, vec.mul(segment, projection));
    return vec.magnitude(vec.subtract(point, closest));
}

fn distanceToPolygonEdge(point: vec.Vec2, mask: PolygonMask) f32 {
    var minimum = std.math.inf(f32);
    var previousIndex = mask.vertexCount - 1;
    for (0..mask.vertexCount) |index| {
        minimum = @min(minimum, distanceToSegment(point, mask.vertices[previousIndex], mask.vertices[index]));
        previousIndex = index;
    }
    return minimum;
}

fn pixelNoise(seed: u64, x: i32, y: i32) f32 {
    var value = seed ^ @as(u64, @bitCast(@as(i64, x))) *% 0x9E3779B185EBCA87;
    value ^= @as(u64, @bitCast(@as(i64, y))) *% 0xC2B2AE3D27D4EB4F;
    value ^= value >> 30;
    value *%= 0xBF58476D1CE4E5B9;
    value ^= value >> 27;
    const sample: u16 = @truncate(value >> 48);
    return @as(f32, @floatFromInt(sample)) / @as(f32, @floatFromInt(std.math.maxInt(u16)));
}

fn darkenCharredPixel(outputPixels: [*]u8, pixelIndex: usize, distance: f32, seed: u64, x: i32, y: i32) void {
    if (distance >= charcoalWidthPixels) return;
    const edgeRatio = distance / charcoalWidthPixels;
    const noise = pixelNoise(seed, x, y);
    const factor = std.math.clamp(0.16 + edgeRatio * 0.48 + (noise - 0.5) * 0.12, 0.10, 0.72);
    outputPixels[pixelIndex + 0] = @intFromFloat(@as(f32, @floatFromInt(outputPixels[pixelIndex + 0])) * factor);
    outputPixels[pixelIndex + 1] = @intFromFloat(@as(f32, @floatFromInt(outputPixels[pixelIndex + 1])) * factor);
    outputPixels[pixelIndex + 2] = @intFromFloat(@as(f32, @floatFromInt(outputPixels[pixelIndex + 2])) * factor);
}

fn generatePiece(source: sprite.Sprite, mask: PolygonMask, templateId: TemplateId, pieceIndex: usize) !?GeneratedPiece {
    const width = mask.maxX - mask.minX;
    const height = mask.maxY - mask.minY;
    if (width <= 0 or height <= 0) return null;

    const format: sdl.PixelFormat = @enumFromInt(source.surface.format);
    const outputSurface = try sdl.createSurface(width, height, format);
    var outputSurfaceOwned = true;
    defer {
        if (outputSurfaceOwned) sdl.destroySurface(outputSurface);
    }

    var redTotal: u64 = 0;
    var greenTotal: u64 = 0;
    var blueTotal: u64 = 0;
    var solidPixelCount: usize = 0;

    {
        try sdl.lockSurface(source.surface);
        defer sdl.unlockSurface(source.surface);
        try sdl.lockSurface(outputSurface);
        defer sdl.unlockSurface(outputSurface);

        const sourcePixels: [*]const u8 = @ptrCast(source.surface.pixels);
        const outputPixels: [*]u8 = @ptrCast(outputSurface.pixels);
        const sourcePitch: usize = @intCast(source.surface.pitch);
        const outputPitch: usize = @intCast(outputSurface.pitch);
        const outputByteCount = try std.math.mul(usize, outputPitch, @intCast(height));
        @memset(outputPixels[0..outputByteCount], 0);

        var y = mask.minY;
        while (y < mask.maxY) : (y += 1) {
            var x = mask.minX;
            while (x < mask.maxX) : (x += 1) {
                const point = vec.Vec2{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                };
                if (!pointInsidePolygon(point, mask)) continue;

                const sourceIndex = @as(usize, @intCast(y)) * sourcePitch + @as(usize, @intCast(x)) * 4;
                if (sourcePixels[sourceIndex + 3] < alphaThreshold) continue;

                const outputX: usize = @intCast(x - mask.minX);
                const outputY: usize = @intCast(y - mask.minY);
                const outputIndex = outputY * outputPitch + outputX * 4;
                @memcpy(outputPixels[outputIndex .. outputIndex + 4], sourcePixels[sourceIndex .. sourceIndex + 4]);

                blueTotal += sourcePixels[sourceIndex + 0];
                greenTotal += sourcePixels[sourceIndex + 1];
                redTotal += sourcePixels[sourceIndex + 2];
                solidPixelCount += 1;

                darkenCharredPixel(outputPixels, outputIndex, distanceToPolygonEdge(point, mask), templateId, x, y);
            }
        }
    }

    if (solidPixelCount < minimumSolidPixels) return null;

    const imagePath = try std.fmt.allocPrint(allocator, "generated/rubble/{d}/{d}", .{ templateId, pieceIndex });
    defer allocator.free(imagePath);
    outputSurfaceOwned = false;
    const spriteUuid = try sprite.createFromOwnedSurface(imagePath, outputSurface, source.scale, vec.izero);

    const cropCenterX = (@as(f32, @floatFromInt(mask.minX)) + @as(f32, @floatFromInt(width)) * 0.5) * source.scale.x;
    const cropCenterY = (@as(f32, @floatFromInt(mask.minY)) + @as(f32, @floatFromInt(height)) * 0.5) * source.scale.y;
    const pixelCount: u64 = @intCast(solidPixelCount);
    return .{
        .spriteUuid = spriteUuid,
        .localCenterM = .{
            .x = (cropCenterX - @as(f32, @floatFromInt(source.sizeP.x)) * 0.5) / conv.met2pix,
            .y = (cropCenterY - @as(f32, @floatFromInt(source.sizeP.y)) * 0.5) / conv.met2pix,
        },
        .particleColor = .{
            .r = @intCast(redTotal / pixelCount),
            .g = @intCast(greenTotal / pixelCount),
            .b = @intCast(blueTotal / pixelCount),
        },
    };
}

fn rubbleShapeDef() box2d.c.b2ShapeDef {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = 0.7;
    shapeDef.material.restitution = 0.08;
    shapeDef.density = 1.2;
    shapeDef.filter.categoryBits = collision.CATEGORY_RUBBLE;
    shapeDef.filter.maskBits = collision.MASK_RUBBLE;
    shapeDef.enableHitEvents = true;
    shapeDef.enableContactEvents = true;
    return shapeDef;
}

fn particleEffectId() !particle_effect.Id {
    if (rubbleParticleEffectId != null) return rubbleParticleEffectId.?;
    const effectId = particle_effect.idForName("rubble") orelse {
        std.log.err("rubble.particleEffectId: rubble particle preset is missing", .{});
        return error.RubbleParticlePresetMissing;
    };
    rubbleParticleEffectId = effectId;
    return effectId;
}

fn createPooledBody(piece: Piece) !box2d.c.b2BodyId {
    const bodyDef = box2d.createDynamicBodyDef(vec.zero);
    const rubbleEntity = try entity.createFromImg(piece.spriteUuid, rubbleShapeDef(), bodyDef, "rubble");
    errdefer _ = entity.remove(rubbleEntity.bodyId);
    entity.markSpriteUuidsShared(rubbleEntity.bodyId);

    try damage.register(rubbleEntity.bodyId, .{
        .model = .{ .health = .{
            .current = 0,
            .maximum = 0,
        } },
        .onDestroyed = .{ .particle_burst = .{
            .effectId = try particleEffectId(),
            .amount = rubbleParticleAmount,
            .spreadRadians = rubbleParticleSpreadRadians,
            .color = piece.particleColor,
        } },
        .destructionLifecycle = .return_to_pool,
    });

    const rubbleEntityPtr = entity.entities.getPtrLocking(rubbleEntity.bodyId) orelse {
        std.log.err("rubble.createPooledBody: new rubble entity is missing", .{});
        return error.EntityNotFound;
    };
    rubbleEntityPtr.enabled = false;
    box2d.c.b2Body_Disable(rubbleEntity.bodyId);
    return rubbleEntity.bodyId;
}

fn destroyPiece(piece: Piece) void {
    const bodyIds = pool.takeBodyIds(piece.poolId) catch |err| {
        std.log.err("rubble.destroyPiece: could not take bodies from pool {d}: {}", .{ piece.poolId, err });
        sprite.cleanupLater(piece.spriteUuid);
        return;
    };
    defer allocator.free(bodyIds);

    for (bodyIds) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;
        if (entity.remove(bodyId)) continue;
        std.log.warn("rubble.destroyPiece: pooled rubble body has no entity", .{});
    }
    sprite.cleanupLater(piece.spriteUuid);
}

fn createPiece(generated: GeneratedPiece) !Piece {
    var piece = Piece{
        .spriteUuid = generated.spriteUuid,
        .poolId = 0,
        .localCenterM = generated.localCenterM,
        .particleColor = generated.particleColor,
    };
    errdefer sprite.cleanupLater(generated.spriteUuid);

    const bodyId = try createPooledBody(piece);
    errdefer _ = entity.remove(bodyId);
    piece.poolId = try pool.create(&.{bodyId});
    return piece;
}

pub fn prepare(spriteUuid: u64, seed: u64) !TemplateId {
    const source = sprite.getSprite(spriteUuid) orelse {
        std.log.err("rubble.prepare: source sprite {d} is missing", .{spriteUuid});
        return error.SpriteNotFound;
    };
    if (source.surface.pitch < source.surface.w * 4) {
        std.log.err("rubble.prepare: source sprite {d} does not have four-byte pixels", .{spriteUuid});
        return error.UnsupportedPixelFormat;
    }

    const templateId = templateIdFor(source, seed);
    if (templates.contains(templateId)) return templateId;

    const bounds = findOpaqueBounds(source) orelse {
        std.log.err("rubble.prepare: source sprite {d} has no opaque pixels", .{spriteUuid});
        return error.EmptySprite;
    };
    const minimumDimension: f32 = @floatFromInt(@min(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY));
    const radius = @max(10.0, minimumDimension * pieceRadiusRatio);
    const minimumCenterDistance = minimumDimension * pieceCenterSpacingRatio;
    var rng = Rng{ .state = templateId ^ 0xA0761D6478BD642F };
    if (rng.state == 0) rng.state = 1;

    var centers: [desiredPieceCount]vec.Vec2 = undefined;
    var centerCount: usize = 0;
    var pieces = std.array_list.Managed(Piece).init(allocator);
    defer pieces.deinit();
    errdefer {
        for (pieces.items) |piece| destroyPiece(piece);
    }

    for (0..desiredPieceCount) |pieceIndex| {
        const center = chooseCenter(source, bounds, centers[0..centerCount], minimumCenterDistance, &rng) orelse continue;
        centers[centerCount] = center;
        centerCount += 1;

        const mask = createPolygonMask(center, radius, source, &rng);
        const generated = try generatePiece(source, mask, templateId, pieceIndex);
        if (generated == null) continue;
        const piece = try createPiece(generated.?);
        pieces.append(piece) catch |err| {
            destroyPiece(piece);
            return err;
        };
    }

    if (pieces.items.len == 0) {
        std.log.err("rubble.prepare: source sprite {d} produced no valid rubble pieces", .{spriteUuid});
        return error.NoRubblePieces;
    }

    const ownedPieces = try pieces.toOwnedSlice();
    errdefer {
        for (ownedPieces) |piece| destroyPiece(piece);
        allocator.free(ownedPieces);
    }
    try templates.put(allocator, templateId, .{ .pieces = ownedPieces });
    return templateId;
}

fn acquirePieceBody(piece: Piece) !box2d.c.b2BodyId {
    const available = try pool.acquire(piece.poolId, .return_null);
    if (available != null) return available.?.bodyId;

    const bodyId = try createPooledBody(piece);
    errdefer _ = entity.remove(bodyId);
    try pool.addBodies(piece.poolId, &.{bodyId});

    const replenished = try pool.acquire(piece.poolId, .return_null);
    if (replenished == null) {
        std.log.err("rubble.acquirePieceBody: replenished pool {d} has no available body", .{piece.poolId});
        return error.EmptyRubblePool;
    }
    return replenished.?.bodyId;
}

fn normalizedOrZero(value: vec.Vec2) vec.Vec2 {
    const length = vec.magnitude(value);
    if (length < 0.001) return vec.zero;
    return .{ .x = value.x / length, .y = value.y / length };
}

fn activatePiece(piece: Piece, sourcePosition: vec.Vec2, sourceAngle: f32, sourceVelocity: vec.Vec2, sourceAngularVelocity: f32, damageDirection: vec.Vec2, debrisVelocity: vec.Vec2) !void {
    const bodyId = try acquirePieceBody(piece);
    box2d.c.b2Body_Disable(bodyId);
    errdefer {
        pool.release(piece.poolId, bodyId) catch |err| {
            std.log.err("rubble.activatePiece: could not return failed acquisition to pool {d}: {}", .{ piece.poolId, err });
        };
    }

    const rubbleEntity = entity.entities.getPtrLocking(bodyId) orelse {
        std.log.err("rubble.activatePiece: pooled body has no entity", .{});
        return error.EntityNotFound;
    };
    try damage.reset(bodyId);

    const cosine = @cos(sourceAngle);
    const sine = @sin(sourceAngle);
    const rotatedOffset = vec.Vec2{
        .x = piece.localCenterM.x * cosine - piece.localCenterM.y * sine,
        .y = piece.localCenterM.x * sine + piece.localCenterM.y * cosine,
    };
    const piecePosition = vec.add(sourcePosition, rotatedOffset);
    const radialDirection = normalizedOrZero(rotatedOffset);
    const hitDirection = normalizedOrZero(damageDirection);
    const randomAngle = runtime.random().float(f32) * std.math.pi * 2.0;
    const randomDirection = vec.Vec2{ .x = @cos(randomAngle), .y = @sin(randomAngle) };
    const scatterVelocity = vec.add(
        vec.add(
            vec.add(vec.mul(radialDirection, radialScatterSpeed), vec.mul(hitDirection, impactScatterSpeed)),
            vec.mul(randomDirection, randomScatterSpeed),
        ),
        .{ .x = 0, .y = -upwardScatterSpeed },
    );

    rubbleEntity.state = null;
    rubbleEntity.enabled = true;
    box2d.c.b2Body_SetTransform(bodyId, vec.toBox2d(piecePosition), box2d.c.b2MakeRot(sourceAngle));
    box2d.c.b2Body_Enable(bodyId);
    const launchVelocity = vec.add(vec.add(sourceVelocity, scatterVelocity), debrisVelocity);
    box2d.c.b2Body_SetLinearVelocity(bodyId, vec.toBox2d(launchVelocity));
    const angularVariation = runtime.random().float(f32) * 8.0 - 4.0;
    box2d.c.b2Body_SetAngularVelocity(bodyId, sourceAngularVelocity + angularVariation);
}

pub fn activate(templateId: TemplateId, sourceBodyId: box2d.c.b2BodyId, damageDirection: vec.Vec2, debrisVelocity: vec.Vec2) !void {
    const template = templates.get(templateId) orelse {
        std.log.err("rubble.activate: template {d} is missing", .{templateId});
        return error.RubbleTemplateNotFound;
    };
    if (!box2d.c.b2Body_IsValid(sourceBodyId)) {
        std.log.err("rubble.activate: source body is invalid", .{});
        return error.InvalidBody;
    }

    const sourcePosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(sourceBodyId));
    const sourceAngle = box2d.c.b2Rot_GetAngle(box2d.c.b2Body_GetRotation(sourceBodyId));
    const sourceVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(sourceBodyId));
    const sourceAngularVelocity = box2d.c.b2Body_GetAngularVelocity(sourceBodyId);

    for (template.pieces) |piece| {
        activatePiece(piece, sourcePosition, sourceAngle, sourceVelocity, sourceAngularVelocity, damageDirection, debrisVelocity) catch |err| {
            std.log.err("rubble.activate: could not activate pooled rubble piece: {}", .{err});
        };
    }
}

pub fn cleanup() void {
    for (templates.values()) |template| {
        for (template.pieces) |piece| destroyPiece(piece);
        allocator.free(template.pieces);
    }
    templates.clearAndFree(allocator);
    rubbleParticleEffectId = null;
}
