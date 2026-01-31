const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const timer = @import("sdl_timer.zig");
const thread_safe = @import("thread_safe_array_list.zig");

const AutoArrayHashMap = std.AutoArrayHashMap;

const camera = @import("camera.zig");
const time = @import("time.zig");
const polygon = @import("polygon.zig");
const box2d = @import("box2d.zig");

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const vec = @import("vector.zig");

const sprite = @import("sprite.zig");
const Sprite = sprite.Sprite;

const conv = @import("conversion.zig");
const animation = @import("animation.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");

pub const Entity = struct {
    type: []const u8,
    friction: f32,
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
    spriteUuids: []u64,
    color: ?sprite.Color,
    highlighted: bool,
    shapeIds: []box2d.c.b2ShapeId,
    animated: bool,
    flipEntityHorizontally: bool,
    categoryBits: u64,
    maskBits: u64,
    enabled: bool,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    scale: vec.Vec2,
    pos: vec.IVec2,
    breakable: bool = true,
};

var entitiesToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(shared.allocator);

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

        try sprite.drawWithOptions(entitySprite, pos, state.rotAngle, entity.highlighted, flip, 0, entity.color);
    }
}

pub fn createFromShape(spriteUuid: u64, shape: box2d.c.b2Polygon, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, eType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entityType = try shared.allocator.dupe(u8, eType);

    const shapeId = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &shape);

    const shapeIds = try shared.allocator.alloc(box2d.c.b2ShapeId, 1);
    shapeIds[0] = shapeId;

    var spriteUuids = try shared.allocator.alloc(u64, 1);
    spriteUuids[0] = spriteUuid;

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.friction,
        .state = null,
        .bodyId = bodyId,
        .spriteUuids = spriteUuids,
        .shapeIds = shapeIds,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = shapeDef.filter.categoryBits,
        .maskBits = shapeDef.filter.maskBits,
        .color = null,
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

pub fn createEntityForBody(bodyId: box2d.c.b2BodyId, spriteUuid: u64, shapeDef: box2d.c.b2ShapeDef, eType: []const u8) !Entity {
    const entityType = try shared.allocator.dupe(u8, eType);
    errdefer shared.allocator.free(entityType);

    const s = sprite.getSprite(spriteUuid) orelse return error.SpriteNotFound;

    const triangles = try polygon.triangulate(s);
    defer shared.allocator.free(triangles);

    const shapeIds = try box2d.createPolygonShape(bodyId, triangles, .{ .x = s.sizeP.x, .y = s.sizeP.y }, shapeDef);

    var spriteUuids = try shared.allocator.alloc(u64, 1);
    spriteUuids[0] = spriteUuid;

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.friction,
        .state = null,
        .bodyId = bodyId,
        .spriteUuids = spriteUuids,
        .shapeIds = shapeIds,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = shapeDef.filter.categoryBits,
        .maskBits = shapeDef.filter.maskBits,
        .color = null,
        .enabled = true,
    };
    return entity;
}

pub fn cleanupLater(entity: Entity) void {
    box2d.c.b2Body_Disable(entity.bodyId);

    const id_int: usize = @bitCast(entity.bodyId);
    const ptr: ?*anyopaque = @ptrFromInt(id_int);

    _ = timer.addTimer(10, markEntityForCleanup, ptr);
}

pub fn addSprite(bodyId: box2d.c.b2BodyId, spriteUuid: u64) !void {
    const maybeEnt = entities.getPtrLocking(bodyId);
    if (maybeEnt) |ent| {
        var uuids: std.ArrayListUnmanaged(u64) = .{};
        for (ent.spriteUuids) |uuid| {
            try uuids.append(shared.allocator, uuid);
        }
        try uuids.append(shared.allocator, spriteUuid);
        shared.allocator.free(ent.spriteUuids);
        ent.spriteUuids = try uuids.toOwnedSlice(shared.allocator);
    }
}

fn markEntityForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;

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
    shared.allocator.free(entity.shapeIds);
    shared.allocator.free(entity.type);

    if (entity.animated) {
        animation.cleanupAnimationFrames(entity.bodyId);
    } 
    for (entity.spriteUuids) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    shared.allocator.free(entity.spriteUuids);
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

pub fn serialize(entity: Entity, pos: vec.IVec2) ?SerializableEntity {
    const firstSprite = sprite.getSprite(entity.spriteUuids[0]) orelse return null;

    const breakable = entity.categoryBits == collision.CATEGORY_TERRAIN;
    return SerializableEntity{
        .type = entity.type,
        .scale = firstSprite.scale,
        .pos = pos,
        .friction = entity.friction,
        .imgPath = firstSprite.imgPath,
        .breakable = breakable,
    };
}

pub fn regenerateColliders(entity: *Entity) !bool {
    const firstSprite = sprite.getSprite(entity.spriteUuids[0]) orelse return false;

    const triangles = polygon.triangulate(firstSprite) catch {
        return false; // destroy entity
    };
    defer shared.allocator.free(triangles);

    if (triangles.len == 0) {
        return false; // destroy entity
    }

    // Destroy old shapes
    for (entity.shapeIds) |shapeId| {
        box2d.c.b2DestroyShape(shapeId, true);
    }
    shared.allocator.free(entity.shapeIds);

    // Create new shapes with same collision filter as original
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = entity.friction;
    shapeDef.filter.categoryBits = entity.categoryBits;
    shapeDef.filter.maskBits = entity.maskBits;

    const newShapeIds = box2d.createPolygonShape(
        entity.bodyId,
        triangles,
        .{ .x = firstSprite.sizeP.x, .y = firstSprite.sizeP.y },
        shapeDef,
    ) catch {
        std.debug.print("Could not create box2d object from regenerated triangles\n", .{});
        return false;
    };

    entity.shapeIds = newShapeIds;
    return true;
}
