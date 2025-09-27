const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

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

pub var entities: AutoArrayHashMap(
    box2d.c.b2BodyId,
    Entity,
) = AutoArrayHashMap(box2d.c.b2BodyId, Entity).init(allocator);

pub const MarkedEntity = struct {
    entity: Entity,
    counter: i32,
    linkedBodies: []box2d.c.b2BodyId
};

pub var markedEntities = std.array_list.Managed(MarkedEntity).init(allocator);

pub fn updateStates() void {
    for (entities.values()) |*e| {
        e.state = box2d.getState(e.bodyId);
    }
}

pub fn drawAll() !void {
    for (entities.values()) |*e| {
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

pub fn createFromImg(s: Sprite, shapeDef: box2d.c.b2ShapeDef, bodyDef: box2d.c.b2BodyDef, entityType: []const u8) !Entity {
    const bodyId = try box2d.createBody(bodyDef);
    const entity = try createEntityForBody(bodyId, s, shapeDef, entityType);
    try entities.put(bodyId, entity);
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

pub fn cleanupOne(entity: Entity) void {
    box2d.c.b2DestroyBody(entity.bodyId);
    shared.allocator.free(entity.shapeIds);
    shared.allocator.free(entity.type);
    sprite.cleanup(entity.sprite);
}

pub fn cleanupLater(entity: Entity, linkedBodies: []box2d.c.b2BodyId) !void {
    _ = entities.swapRemove(entity.bodyId);
    box2d.c.b2Body_SetAwake(entity.bodyId, false);
    try markedEntities.append(.{
        .entity = entity,
        .counter = 0,
        .linkedBodies = linkedBodies,
    });
}

pub fn cleanupMarkedEntities() !void {
    var toBeDestroyedEntities = std.array_list.Managed(MarkedEntity).init(allocator);
    defer toBeDestroyedEntities.deinit();
    var entitiesToKeep = std.array_list.Managed(MarkedEntity).init(allocator);
    for (markedEntities.items) |*markedEntity| {
        if (markedEntity.counter > 10) {
            try toBeDestroyedEntities.append(.{
                .entity = markedEntity.entity,
                .counter = markedEntity.counter,
                .linkedBodies = markedEntity.linkedBodies
            });
        } else {
            try entitiesToKeep.append(.{
                .entity = markedEntity.entity,
                .counter = markedEntity.counter + 1,
                .linkedBodies = markedEntity.linkedBodies
            });
        }
    }
    markedEntities.deinit();
    markedEntities = entitiesToKeep;

    for (toBeDestroyedEntities.items) |de| {
        cleanupOne(de.entity);
        for (de.linkedBodies) |bodyId| {
            box2d.c.b2DestroyBody(bodyId);
        }
    }
}

pub fn cleanup() void {
    for (entities.values()) |entity| {
        cleanupOne(entity);
    }
    entities.deinit();
    markedEntities.deinit();
    entities = AutoArrayHashMap(box2d.c.b2BodyId, Entity).init(allocator);
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
    return entities.getPtr(bodyId);
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
