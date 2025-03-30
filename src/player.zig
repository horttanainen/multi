const std = @import("std");
const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl2");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const box = @import("box.zig");

const config = @import("config.zig").config;

const p2m = @import("conversion.zig").p2m;

const IVec2 = @import("vector.zig").IVec2;

pub const Player = struct { entity: entity.Entity, bodyShapeId: box2d.b2ShapeId, footSensorShapeId: box2d.b2ShapeId };

pub var player: ?Player = null;
pub var isMoving: bool = false;
pub var isInAir: bool = false;
pub var allowJump: bool = true;
var airJumpCounter: i32 = 0;

const PlayerError = error{NotSpawned};

pub fn getPlayer() !Player {
    if (player) |p| {
        return p;
    }
    return PlayerError.NotSpawned;
}

pub fn spawn(position: IVec2) !void {
    const resources = try shared.getResources();
    const texture = try sdl.createTextureFromSurface(resources.renderer, resources.lieroSurface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = p2m(.{ .x = size.x, .y = size.y });

    const bodyId = try box.createNonRotatingDynamicBody(position);

    const dynamicBox = box2d.b2MakeBox(0.1, 0.33);
    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.density = 1.0;
    shapeDef.friction = config.player.movementFriction;
    const shapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
    box2d.b2Shape_SetMaterial(shapeId, config.player.materialId);

    const footBox = box2d.b2MakeOffsetBox(0.1, 0.1, .{ .x = 0, .y = 0.4 }, .{ .c = 0, .s = 1 });
    var footShapeDef = box2d.b2DefaultShapeDef();
    footShapeDef.isSensor = true;
    const sensorShapeId = box2d.b2CreatePolygonShape(bodyId, &footShapeDef, &footBox);

    const sprite = entity.Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    player = Player{ .entity = entity.Entity{ .bodyId = bodyId, .sprite = sprite }, .bodyShapeId = shapeId, .footSensorShapeId = sensorShapeId };
}

// var last: u64 = 0;
// var deltaTime: u64 = 0;

pub fn jump() void {
    // const now = sdl.getPerformanceCounter();

    // deltaTime = (now - last) * 1000 / sdl.getPerformanceFrequency();
    // if (deltaTime < 200) {
    //     return;
    // }
    // last = now;

    if (!allowJump) {
        return;
    }

    if (player) |p| {
        if (!isInAir) {
            airJumpCounter = 0;
        }

        if (isInAir and airJumpCounter < config.player.maxAirJumps) {
            airJumpCounter += 1;
        } else if (isInAir and airJumpCounter >= config.player.maxAirJumps) {
            return;
        }

        box2d.b2Body_ApplyLinearImpulseToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = 0, .y = -config.player.jumpImpulse }, true);
        allowJump = false;
    }
}

pub fn brake() void {
    isMoving = false;
}

pub fn moveLeft() void {
    isMoving = true;
    if (player) |p| {
        box2d.b2Body_ApplyForceToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = -config.player.sidewaysMovementForce, .y = 0 }, true);
    }
}

pub fn moveRight() void {
    isMoving = true;
    if (player) |p| {
        box2d.b2Body_ApplyForceToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = config.player.sidewaysMovementForce, .y = 0 }, true);
    }
}
pub fn clampSpeed() void {
    if (player) |p| {
        var velocity = box2d.b2Body_GetLinearVelocity(p.entity.bodyId);
        if (velocity.x > config.player.maxMovementSpeed) {
            velocity.x = config.player.maxMovementSpeed;
            box2d.b2Body_SetLinearVelocity(p.entity.bodyId, velocity);
        } else if (velocity.x < -config.player.maxMovementSpeed) {
            velocity.x = -config.player.maxMovementSpeed;
            box2d.b2Body_SetLinearVelocity(p.entity.bodyId, velocity);
        }
    }
}

pub fn checkFootSensor() !void {
    const resources = try shared.getResources();
    if (player) |p| {
        const sensorEvents = box2d.b2World_GetSensorEvents(resources.worldId);

        for (0..@intCast(sensorEvents.beginCount)) |i| {
            const e = sensorEvents.beginEvents[i];
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                isInAir = false;
            }
        }

        for (0..@intCast(sensorEvents.endCount)) |i| {
            const e = sensorEvents.endEvents[i];
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                isInAir = true;
            }
        }
    }
}
