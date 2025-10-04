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

pub const Entity = struct {
    type: []const u8,
    friction: f32,
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
    sprite: Sprite,
    highlighted: bool,
    shapeIds: []box2d.c.b2ShapeId,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: []const u8,
    scale: vec.Vec2,
    pos: vec.IVec2,
};

pub var entitiesToCleanup = thread_safe.ThreadSafeArrayList(Entity).init(shared.allocator);

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
        try draw(e);
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

    const pos = camera.relativePosition(
        conv.m2PixelPos(
            state.pos.x,
            state.pos.y,
            entity.sprite.sizeM.x,
            entity.sprite.sizeM.y,
        ),
    );

    try sprite.drawWithOptions(entity.sprite, pos, state.rotAngle, entity.highlighted, flip, 0);
}

pub fn createFromShape(s: Sprite, shape: box2d.c.b2Polygon, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, eType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entityType = try shared.allocator.dupe(u8, eType);

    const shapeId = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &shape);

    const shapeIds = try shared.allocator.alloc(box2d.c.b2ShapeId, 1);
    shapeIds[0] = shapeId;

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.friction,
        .state = null,
        .bodyId = bodyId,
        .sprite = s,
        .shapeIds = shapeIds,
        .highlighted = false,
    };

    try entities.putLocking(bodyId, entity);
    return entity;
}



pub fn createFromImg(s: Sprite, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, entityType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entity = try createEntityForBody(bodyId, s, shapeDef, entityType);
    try entities.putLocking(bodyId, entity);
    return entity;
}

pub fn createEntityForBody(bodyId: box2d.c.b2BodyId, s: Sprite, shapeDef: box2d.c.b2ShapeDef, eType: []const u8) !Entity {
    const entityType = try shared.allocator.dupe(u8, eType);

    const triangles = try polygon.triangulate(s);
    defer shared.allocator.free(triangles);

    const shapeIds = try box2d.createPolygonShape(bodyId, triangles, .{ .x = s.sizeP.x, .y = s.sizeP.y }, shapeDef);

    const entity = Entity{
        .type = entityType,
        .friction = shapeDef.friction,
        .state = null,
        .bodyId = bodyId,
        .sprite = s,
        .shapeIds = shapeIds,
        .highlighted = false,
    };
    return entity;
}

pub fn cleanupLater(entity: Entity) void {
    box2d.c.b2Body_Disable(entity.bodyId);

    const id_int: usize = @bitCast(entity.bodyId);
    const ptr: ?*anyopaque = @ptrFromInt(id_int);

    _ = timer.addTimer(10, markEntityForCleanup, ptr);
}

fn markEntityForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;

    const id_int: usize = @intFromPtr(param.?);
    const bodyId: box2d.c.b2BodyId = @bitCast(id_int);

    const maybeE = entities.fetchSwapRemoveLocking(bodyId);

    if (maybeE) |entity| {
        entitiesToCleanup.appendLocking(entity.value) catch {};
    }
    return 0;
}

pub fn cleanupEntities() void {
    entitiesToCleanup.mutex.lock();
    for (entitiesToCleanup.list.items) |entity| {
        cleanupOne(entity);
    }
    entitiesToCleanup.mutex.unlock();
    entitiesToCleanup.replaceLocking(std.array_list.Managed(Entity).init(shared.allocator));
}

pub fn cleanupOne(entity: Entity) void {
    box2d.c.b2DestroyBody(entity.bodyId);
    shared.allocator.free(entity.shapeIds);
    shared.allocator.free(entity.type);
    sprite.cleanup(entity.sprite);
}

pub fn cleanup() void {
    entities.mutex.lock();
    for (entities.map.values()) |entity| {
        cleanupOne(entity);
    }
    entities.mutex.unlock();
    entities.replaceLocking(AutoArrayHashMap(box2d.c.b2BodyId, Entity).init(allocator));
}

pub fn getPosition(entity: Entity) vec.IVec2 {
    const currentState = box2d.getState(entity.bodyId);
    const state = box2d.getInterpolatedState(entity.state, currentState);
    const pos = conv.m2PixelPos(
        state.pos.x,
        state.pos.y,
        entity.sprite.sizeM.x,
        entity.sprite.sizeM.y,
    );
    return pos;
}

pub fn getEntity(bodyId: box2d.c.b2BodyId) ?*Entity {
    return entities.getPtrLocking(bodyId);
}

pub fn serialize(entity: Entity, pos: vec.IVec2) SerializableEntity {
    return SerializableEntity{
        .type = entity.type,
        .scale = entity.sprite.scale,
        .pos = pos,
        .friction = entity.friction,
        .imgPath = entity.sprite.imgPath,
    };
}
