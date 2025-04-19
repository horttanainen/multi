const box2d = @import("box2dnative.zig");
const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const polygon = @import("polygon.zig");
const box = @import("box.zig");
const player = @import("player.zig");

const config = @import("config.zig");

const p2m = @import("conversion.zig").p2m;

const IVec2 = @import("vector.zig").IVec2;
const entity = @import("entity.zig");
const Sprite = entity.Sprite;
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
    const goalSensor = try getGoalSensor();
    try entity.draw(goalSensor);
}

pub fn createGoalSensorFromImg(position: IVec2, img: *sdl.Surface) !void {
    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.isSensor = true;
    shapeDef.material = config.goalMaterialId;
    const bodyId = try box.createStaticBody(position);
    const e = try entity.createEntityForBody(bodyId, img, shapeDef);
    maybeGoalSensor = e;
}

pub fn checkGoal() !void {
    const resources = try shared.getResources();
    if (maybeGoalSensor) |goalSensor| {
        if (player.player) |p| {
            const sensorEvents = box2d.b2World_GetSensorEvents(resources.worldId);

            for (0..@intCast(sensorEvents.beginCount)) |i| {
                const e = sensorEvents.beginEvents[i];

                if (!box2d.B2_ID_EQUALS(e.visitorShapeId, p.bodyShapeId)) {
                    continue;
                }
                for (goalSensor.shapeIds) |sensorId| {
                    if (box2d.B2_ID_EQUALS(e.sensorShapeId, sensorId)) {
                        shared.goalReached = true;
                        return;
                    }
                }
            }
        }
    }
}
