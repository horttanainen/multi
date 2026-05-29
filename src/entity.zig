const std = @import("std");
const sdl = @import("sdl.zig");

const thread_safe = @import("thread_safe_array_list.zig");

const AutoArrayHashMap = std.AutoArrayHashMap;

const camera = @import("camera.zig");
const time = @import("time.zig");
const polygon = @import("polygon.zig");
const box2d = @import("box2d.zig");

const PI = std.math.pi;

const allocator = @import("allocator.zig").allocator;

const vec = @import("vector.zig");

const sprite = @import("sprite.zig");
const Sprite = sprite.Sprite;

const conv = @import("conversion.zig");
const animation = @import("animation.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");

pub const terrainColliderChunkSizeP: i32 = 64;

pub const ColliderChunk = struct {
    rect: vec.IRect,
    shapeIds: []box2d.c.b2ShapeId,
};

pub const Entity = struct {
    type: []const u8,
    friction: f32,
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
    spriteUuids: []u64,
    highlighted: bool,
    shapeIds: []box2d.c.b2ShapeId,
    colliderChunks: []ColliderChunk,
    animated: bool,
    flipEntityHorizontally: bool,
    categoryBits: u64,
    maskBits: u64,
    enabled: bool,
    ownsSpriteUuids: bool = true,
    color: ?sprite.Color = null,
    glow: bool = false,
};

pub const SerializableEntity = struct {
    id: u64,
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    scale: vec.Vec2,
    pos: vec.IVec2,
    breakable: bool = true,
};

var entitiesToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(allocator);

pub var entities = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, Entity).init(allocator);

pub fn updateStates() void {
    entities.mutex.lock();
    defer entities.mutex.unlock();
    for (entities.map.values()) |*e| {
        e.state = box2d.getState(e.bodyId);
    }
}

pub fn drawAll() !void {
    entities.mutex.lock();
    defer entities.mutex.unlock();
    for (entities.map.values()) |*e| {
        // Skip drawing disabled entities
        if (!e.enabled) continue;

        try drawWithOptions(e, e.flipEntityHorizontally);
    }
}

pub fn drawFlipped(entity: *Entity) !void {
    try drawWithOptions(entity, true);
}

pub fn draw(entity: *Entity) !void {
    try drawWithOptions(entity, false);
}

fn drawWithOptions(entity: *Entity, flip: bool) !void {
    const currentState = box2d.getState(entity.bodyId);
    const state = box2d.getInterpolatedState(entity.state, currentState);

    for (entity.spriteUuids) |spriteUuid| {
        const entitySprite = sprite.getSprite(spriteUuid) orelse continue;

        const pos = camera.relativePosition(conv.m2Pixel(state.pos));

        if (entity.glow) {
            try sprite.drawGlow(entitySprite, pos, state.rotAngle, flip, entity.color);
        } else {
            try sprite.drawWithOptions(entitySprite, pos, state.rotAngle, entity.highlighted, flip, 0, entity.color, null);
        }
    }
}

pub fn createFromShape(spriteUuid: u64, shape: box2d.c.b2Polygon, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, eType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entityType = try allocator.dupe(u8, eType);

    const shapeId = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &shape);

    const shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 1);
    shapeIds[0] = shapeId;

    const colliderChunks = try allocator.alloc(ColliderChunk, 0);

    var spriteUuids = try allocator.alloc(u64, 1);
    spriteUuids[0] = spriteUuid;

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.material.friction,
        .state = null,
        .bodyId = bodyId,
        .spriteUuids = spriteUuids,
        .shapeIds = shapeIds,
        .colliderChunks = colliderChunks,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = shapeDef.filter.categoryBits,
        .maskBits = shapeDef.filter.maskBits,
        .enabled = true,
    };

    try entities.putLocking(bodyId, entity);
    return entity;
}

pub fn createFromImg(spriteUuid: u64, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, entityType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entity = createEntityForBody(bodyId, spriteUuid, shapeDef, entityType) catch |err| {
        // Clean up bodyId if entity creation fails
        box2d.c.b2DestroyBody(bodyId);
        return err;
    };
    try entities.putLocking(bodyId, entity);
    return entity;
}

fn isStaticTerrainType(eType: []const u8) bool {
    return std.mem.eql(u8, eType, "static");
}

fn createShapeDefForEntity(entity: Entity) box2d.c.b2ShapeDef {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = entity.friction;
    shapeDef.enableSensorEvents = true;
    shapeDef.filter.categoryBits = entity.categoryBits;
    shapeDef.filter.maskBits = entity.maskBits;
    return shapeDef;
}

fn destroyShapeIds(shapeIds: []const box2d.c.b2ShapeId) void {
    for (shapeIds) |shapeId| {
        box2d.c.b2DestroyShape(shapeId, true);
    }
}

fn freeColliderChunks(colliderChunks: []ColliderChunk) void {
    for (colliderChunks) |colliderChunk| {
        allocator.free(colliderChunk.shapeIds);
    }
    allocator.free(colliderChunks);
}

fn destroyAndFreeColliderChunks(colliderChunks: []ColliderChunk) void {
    for (colliderChunks) |colliderChunk| {
        destroyShapeIds(colliderChunk.shapeIds);
        allocator.free(colliderChunk.shapeIds);
    }
    allocator.free(colliderChunks);
}

fn flattenColliderChunkShapeIds(colliderChunks: []const ColliderChunk) ![]box2d.c.b2ShapeId {
    var shapeIds = std.array_list.Managed(box2d.c.b2ShapeId).init(allocator);
    defer shapeIds.deinit();

    for (colliderChunks) |colliderChunk| {
        try shapeIds.appendSlice(colliderChunk.shapeIds);
    }

    return shapeIds.toOwnedSlice();
}

fn createColliderChunksForSprite(
    bodyId: box2d.c.b2BodyId,
    s: sprite.Sprite,
    shapeDef: box2d.c.b2ShapeDef,
) ![]ColliderChunk {
    const triangleChunks = try polygon.triangulateChunksCached(s, terrainColliderChunkSizeP);
    var colliderChunks = std.array_list.Managed(ColliderChunk).init(allocator);
    errdefer {
        for (colliderChunks.items) |colliderChunk| {
            destroyShapeIds(colliderChunk.shapeIds);
            allocator.free(colliderChunk.shapeIds);
        }
        colliderChunks.deinit();
    }

    for (triangleChunks) |triangleChunk| {
        const shapeIds = try box2d.createPolygonShape(bodyId, triangleChunk.triangles, .{ .x = s.sizeP.x, .y = s.sizeP.y }, shapeDef);

        if (shapeIds.len == 0) {
            allocator.free(shapeIds);
            continue;
        }

        colliderChunks.append(.{
            .rect = triangleChunk.rect,
            .shapeIds = shapeIds,
        }) catch |err| {
            destroyShapeIds(shapeIds);
            allocator.free(shapeIds);
            return err;
        };
    }

    if (colliderChunks.items.len == 0) {
        return polygon.PolygonError.CouldNotCreateTriangle;
    }

    return colliderChunks.toOwnedSlice();
}

pub fn createEntityForBody(bodyId: box2d.c.b2BodyId, spriteUuid: u64, shapeDef: box2d.c.b2ShapeDef, eType: []const u8) !Entity {
    const entityType = try allocator.dupe(u8, eType);
    errdefer allocator.free(entityType);

    const s = sprite.getSprite(spriteUuid) orelse return error.SpriteNotFound;

    const colliderChunks = if (isStaticTerrainType(eType))
        try createColliderChunksForSprite(bodyId, s, shapeDef)
    else
        try allocator.alloc(ColliderChunk, 0);
    errdefer freeColliderChunks(colliderChunks);

    const shapeIds = if (colliderChunks.len > 0) blk: {
        break :blk try flattenColliderChunkShapeIds(colliderChunks);
    } else blk: {
        const triangles = try polygon.triangulateCached(s);
        break :blk try box2d.createPolygonShape(bodyId, triangles, .{ .x = s.sizeP.x, .y = s.sizeP.y }, shapeDef);
    };
    errdefer allocator.free(shapeIds);

    var spriteUuids = try allocator.alloc(u64, 1);
    spriteUuids[0] = spriteUuid;

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.material.friction,
        .state = null,
        .bodyId = bodyId,
        .spriteUuids = spriteUuids,
        .shapeIds = shapeIds,
        .colliderChunks = colliderChunks,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = shapeDef.filter.categoryBits,
        .maskBits = shapeDef.filter.maskBits,
        .enabled = true,
    };
    return entity;
}

pub fn cleanupLater(entity: Entity) void {
    box2d.c.b2Body_Disable(entity.bodyId);

    const id_int: usize = @bitCast(entity.bodyId);
    const ptr: ?*anyopaque = @ptrFromInt(id_int);

    _ = sdl.addTimer(10, markEntityForCleanup, ptr);
}

pub fn addSprite(bodyId: box2d.c.b2BodyId, spriteUuid: u64) !void {
    const maybeEnt = entities.getPtrLocking(bodyId);
    if (maybeEnt) |ent| {
        var uuids: std.ArrayListUnmanaged(u64) = .{};
        for (ent.spriteUuids) |uuid| {
            try uuids.append(allocator, uuid);
        }
        try uuids.append(allocator, spriteUuid);
        allocator.free(ent.spriteUuids);
        ent.spriteUuids = try uuids.toOwnedSlice(allocator);
    }
}

pub fn markSpriteUuidsShared(bodyId: box2d.c.b2BodyId) void {
    const ent = entities.getPtrLocking(bodyId) orelse {
        std.log.warn("markSpriteUuidsShared: entity missing for body", .{});
        return;
    };

    ent.ownsSpriteUuids = false;
}

fn markEntityForCleanup(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const id_int: usize = @intFromPtr(param.?);
    const bodyId: box2d.c.b2BodyId = @bitCast(id_int);

    entitiesToCleanup.appendLocking(bodyId) catch {};

    return 0;
}

pub fn cleanupEntities() void {
    entitiesToCleanup.mutex.lock();
    defer entitiesToCleanup.mutex.unlock();

    for (entitiesToCleanup.list.items) |bodyId| {
        const maybeKV = entities.fetchSwapRemoveLocking(bodyId);
        if (maybeKV) |kv| {
            cleanupOne(kv.value);
        }
    }

    entitiesToCleanup.list.clearAndFree();
}

pub fn cleanupOne(entity: Entity) void {
    box2d.c.b2DestroyBody(entity.bodyId);
    allocator.free(entity.shapeIds);
    freeColliderChunks(entity.colliderChunks);
    allocator.free(entity.type);

    if (entity.animated) {
        animation.cleanupAnimationFrames(entity.bodyId);
    }
    if (entity.ownsSpriteUuids) {
        for (entity.spriteUuids) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
    }
    allocator.free(entity.spriteUuids);
}

pub fn remove(bodyId: box2d.c.b2BodyId) bool {
    const maybeKV = entities.fetchSwapRemoveLocking(bodyId);
    if (maybeKV == null) return false;

    cleanupOne(maybeKV.?.value);
    return true;
}

pub fn cleanup() void {
    entities.mutex.lock();
    for (entities.map.values()) |entity| {
        cleanupOne(entity);
    }
    entities.mutex.unlock();
    entities.replaceLocking(AutoArrayHashMap(box2d.c.b2BodyId, Entity).init(allocator));
}

pub fn getEntity(bodyId: box2d.c.b2BodyId) ?*Entity {
    return entities.getPtrLocking(bodyId);
}

pub fn serialize(entity: Entity, pos: vec.IVec2, id: u64) ?SerializableEntity {
    const firstSprite = sprite.getSprite(entity.spriteUuids[0]) orelse return null;

    const breakable = entity.categoryBits == collision.CATEGORY_TERRAIN;
    return SerializableEntity{
        .id = id,
        .type = entity.type,
        .scale = firstSprite.scale,
        .pos = pos,
        .friction = entity.friction,
        .imgPath = firstSprite.imgPath,
        .breakable = breakable,
    };
}

pub fn regenerateColliders(entity: *Entity) !bool {
    const firstSprite = sprite.getSprite(entity.spriteUuids[0]) orelse {
        std.log.warn("regenerateColliders: sprite {d} not found", .{entity.spriteUuids[0]});
        return false;
    };

    // Destroy old shapes
    destroyShapeIds(entity.shapeIds);
    allocator.free(entity.shapeIds);
    freeColliderChunks(entity.colliderChunks);

    // Create new shapes with same collision filter as original
    const shapeDef = createShapeDefForEntity(entity.*);

    if (isStaticTerrainType(entity.type)) {
        const newColliderChunks = createColliderChunksForSprite(entity.bodyId, firstSprite, shapeDef) catch |err| {
            std.log.warn("regenerateColliders: could not rebuild static collider chunks with {}", .{err});
            entity.colliderChunks = try allocator.alloc(ColliderChunk, 0);
            entity.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);
            return false;
        };
        errdefer destroyAndFreeColliderChunks(newColliderChunks);

        const newShapeIds = try flattenColliderChunkShapeIds(newColliderChunks);
        entity.colliderChunks = newColliderChunks;
        entity.shapeIds = newShapeIds;
        return entity.shapeIds.len > 0;
    }

    entity.colliderChunks = try allocator.alloc(ColliderChunk, 0);

    const triangles = polygon.triangulateCached(firstSprite) catch |err| {
        std.log.warn("regenerateColliders: could not triangulate sprite with {}", .{err});
        entity.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);
        return false;
    };

    if (triangles.len == 0) {
        std.log.warn("regenerateColliders: triangulation produced no triangles", .{});
        entity.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);
        return false;
    }

    const newShapeIds = box2d.createPolygonShape(
        entity.bodyId,
        triangles,
        .{ .x = firstSprite.sizeP.x, .y = firstSprite.sizeP.y },
        shapeDef,
    ) catch |err| {
        std.log.warn("regenerateColliders: could not create regenerated Box2D shapes with {}", .{err});
        entity.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);
        return false;
    };

    entity.shapeIds = newShapeIds;
    return true;
}

pub fn regenerateCollidersInPixelRect(entity: *Entity, dirtyRect: vec.IRect) !bool {
    if (entity.colliderChunks.len == 0) {
        return regenerateColliders(entity);
    }

    const firstSprite = sprite.getSprite(entity.spriteUuids[0]) orelse {
        std.log.warn("regenerateCollidersInPixelRect: sprite {d} not found", .{entity.spriteUuids[0]});
        return false;
    };

    const surface = firstSprite.surface.*;
    const width: i32 = @intCast(surface.w);
    const height: i32 = @intCast(surface.h);
    const affectedRect = vec.irectExpandedClamped(dirtyRect, 1, width, height);
    const shapeDef = createShapeDefForEntity(entity.*);

    var regeneratedAny = false;
    for (entity.colliderChunks) |*colliderChunk| {
        if (!vec.irectIntersects(colliderChunk.rect, affectedRect)) continue;

        try regenerateColliderChunk(entity.bodyId, firstSprite, shapeDef, colliderChunk);
        regeneratedAny = true;
    }

    if (!regeneratedAny) {
        return true;
    }

    const newShapeIds = flattenColliderChunkShapeIds(entity.colliderChunks) catch |err| {
        allocator.free(entity.shapeIds);
        entity.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);
        return err;
    };
    allocator.free(entity.shapeIds);
    entity.shapeIds = newShapeIds;

    return entity.shapeIds.len > 0;
}

fn regenerateColliderChunk(
    bodyId: box2d.c.b2BodyId,
    s: sprite.Sprite,
    shapeDef: box2d.c.b2ShapeDef,
    colliderChunk: *ColliderChunk,
) !void {
    destroyShapeIds(colliderChunk.shapeIds);
    allocator.free(colliderChunk.shapeIds);
    colliderChunk.shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);

    const triangles = polygon.triangulateRegion(s, colliderChunk.rect) catch |err| {
        if (err != polygon.PolygonError.CouldNotCreateTriangle) {
            std.log.warn("regenerateColliderChunk: region ({d},{d})-({d},{d}) failed with {}", .{ colliderChunk.rect.minX, colliderChunk.rect.minY, colliderChunk.rect.maxX, colliderChunk.rect.maxY, err });
        }
        return;
    };
    defer allocator.free(triangles);

    const shapeIds = try box2d.createPolygonShape(
        bodyId,
        triangles,
        .{ .x = s.sizeP.x, .y = s.sizeP.y },
        shapeDef,
    );

    allocator.free(colliderChunk.shapeIds);
    colliderChunk.shapeIds = shapeIds;
}
