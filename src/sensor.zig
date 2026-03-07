const std = @import("std");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const Entity = entity.Entity;
const allocator = @import("allocator.zig").allocator;

pub const SensorEntity = struct {
    entity: Entity,
    onBegin: *const fn (visitorShapeId: box2d.c.b2ShapeId) anyerror!void,
};

pub var sensorEntities = std.AutoArrayHashMap(box2d.c.b2BodyId, SensorEntity).init(allocator);

pub fn createSensorEntityFromImg(
    spriteUuid: u64,
    shapeDef: box2d.c.b2ShapeDef,
    bodyDef: box2d.c.b2BodyDef,
    entityType: []const u8,
    onBegin: *const fn (box2d.c.b2ShapeId) anyerror!void,
) !void {
    const bodyId = try box2d.createBody(bodyDef);
    const e = entity.createEntityForBody(bodyId, spriteUuid, shapeDef, entityType) catch |err| {
        box2d.c.b2DestroyBody(bodyId);
        return err;
    };
    try sensorEntities.put(bodyId, .{ .entity = e, .onBegin = onBegin });
}

pub fn processSensorEvents() !void {
    const sensorEvents = box2d.getSensorEvents();
    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const ev = sensorEvents.beginEvents[i];
        if (!box2d.c.b2Shape_IsValid(ev.sensorShapeId)) continue;
        const bodyId = box2d.c.b2Shape_GetBody(ev.sensorShapeId);
        const se = sensorEntities.get(bodyId) orelse continue;
        try se.onBegin(ev.visitorShapeId);
    }
}

pub fn drawAllSensors() !void {
    for (sensorEntities.values()) |*se| {
        if (!se.entity.enabled) continue;
        try entity.draw(&se.entity);
    }
}

pub fn cleanup() void {
    for (sensorEntities.values()) |se| {
        entity.cleanupOne(se.entity);
    }
    sensorEntities.clearAndFree();
}
