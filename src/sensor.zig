const box2d = @import("box2d.zig");
const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const polygon = @import("polygon.zig");
const player = @import("player.zig");

const config = @import("config.zig");

const conv = @import("conversion.zig");

const vec = @import("vector.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const Entity = entity.Entity;

pub var maybeGoalSensor: ?Entity = null;

const SensorError = error{GoalUninitialized};

pub fn getGoalSensor() !Entity {
    if (maybeGoalSensor) |goalSensor| {
        return goalSensor;
    }
    return SensorError.GoalUninitialized;
}

pub fn drawGoal() !void {
    var goalSensor = try getGoalSensor();
    try entity.draw(&goalSensor);
}

pub fn createGoalSensorFromImg(position: vec.Vec2, spriteUuid: u64) !void {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.isSensor = true;
    shapeDef.filter.categoryBits = config.CATEGORY_SENSOR;
    shapeDef.filter.maskBits = config.CATEGORY_PLAYER;
    const bodyDef = box2d.createStaticBodyDef(position);
    const bodyId = try box2d.createBody(bodyDef);
    const e = try entity.createEntityForBody(bodyId, spriteUuid, shapeDef, "goal");
    maybeGoalSensor = e;
}

pub fn checkGoal() !void {
    const resources = try shared.getResources();
    if (maybeGoalSensor) |goalSensor| {
        const sensorEvents = box2d.c.b2World_GetSensorEvents(resources.worldId);

        // Check if any player touches the goal
        for (player.players.values()) |p| {
            for (0..@intCast(sensorEvents.beginCount)) |i| {
                const e = sensorEvents.beginEvents[i];

                if (!box2d.c.B2_ID_EQUALS(e.visitorShapeId, p.bodyShapeId)) {
                    continue;
                }
                for (goalSensor.shapeIds) |sensorId| {
                    if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, sensorId)) {
                        shared.goalReached = true;
                        return;
                    }
                }
            }
        }
    }
}

pub fn cleanup() void {
    if (maybeGoalSensor) |goalSensor| {
        entity.cleanupOne(goalSensor);
    }
    maybeGoalSensor = null;
}
