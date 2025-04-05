const std = @import("std");
const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl2");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const box = @import("box.zig");

const config = @import("config.zig");

const p2m = @import("conversion.zig").p2m;

const IVec2 = @import("vector.zig").IVec2;

pub const Player = struct { entity: entity.Entity, bodyShapeId: box2d.b2ShapeId, footSensorShapeId: box2d.b2ShapeId, leftWallSensorId: box2d.b2ShapeId, rightWallSensorId: box2d.b2ShapeId };

pub var player: ?Player = null;
pub var isMoving: bool = false;
pub var touchesGround: bool = false;
pub var allowJump: bool = true;
pub var touchesWallOnLeft: bool = false;
pub var touchesWallOnRight: bool = false;
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
    shapeDef.material = config.player.materialId;
    const shapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const footBox = box2d.b2MakeOffsetBox(0.1, 0.1, .{ .x = 0, .y = 0.4 }, .{ .c = 1, .s = 0 });
    var footShapeDef = box2d.b2DefaultShapeDef();
    footShapeDef.isSensor = true;
    const footSensorShapeId = box2d.b2CreatePolygonShape(bodyId, &footShapeDef, &footBox);

    const leftWallBox = box2d.b2MakeOffsetBox(0.1, 0.1, .{ .x = -0.1, .y = 0 }, .{ .c = 1, .s = 0 });
    var leftWallShapeDef = box2d.b2DefaultShapeDef();
    leftWallShapeDef.isSensor = true;
    const leftWallSensorId = box2d.b2CreatePolygonShape(bodyId, &leftWallShapeDef, &leftWallBox);

    const rightWallBox = box2d.b2MakeOffsetBox(0.1, 0.1, .{ .x = 0.1, .y = 0 }, .{ .c = 1, .s = 0 });
    var rightWallShapeDef = box2d.b2DefaultShapeDef();
    rightWallShapeDef.isSensor = true;
    const rightWallSensorId = box2d.b2CreatePolygonShape(bodyId, &rightWallShapeDef, &rightWallBox);

    const sprite = entity.Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    var shapeIds = std.ArrayList(box2d.b2ShapeId).init(shared.allocator);
    try shapeIds.append(shapeId);

    player = Player{ .entity = entity.Entity{ .bodyId = bodyId, .sprite = sprite, .shapeIds = try shapeIds.toOwnedSlice() }, .bodyShapeId = shapeId, .footSensorShapeId = footSensorShapeId, .leftWallSensorId = leftWallSensorId, .rightWallSensorId = rightWallSensorId };
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
        if (touchesGround) {
            airJumpCounter = 0;
        }

        if (!touchesGround and airJumpCounter < config.player.maxAirJumps) {
            airJumpCounter += 1;
        } else if (!touchesGround and airJumpCounter >= config.player.maxAirJumps) {
            return;
        }

        var jumpImpulse = box2d.b2Vec2{ .x = 0, .y = -config.player.jumpImpulse };
        if (touchesWallOnRight or touchesWallOnLeft) {
            jumpImpulse = if (touchesWallOnLeft) box2d.b2Vec2{ .x = config.player.jumpImpulse / 2, .y = -config.player.jumpImpulse } else box2d.b2Vec2{ .x = -config.player.jumpImpulse / 2, .y = -config.player.jumpImpulse };
        }

        box2d.b2Body_ApplyLinearImpulseToCenter(p.entity.bodyId, jumpImpulse, true);
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

pub fn checkSensors() !void {
    const resources = try shared.getResources();
    if (player) |p| {
        const sensorEvents = box2d.b2World_GetSensorEvents(resources.worldId);

        for (0..@intCast(sensorEvents.beginCount)) |i| {
            const e = sensorEvents.beginEvents[i];

            if (box2d.B2_ID_EQUALS(e.visitorShapeId, p.bodyShapeId)) {
                continue;
            }

            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                touchesGround = true;
            }
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.leftWallSensorId)) {
                touchesWallOnLeft = true;
            }
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.rightWallSensorId)) {
                touchesWallOnRight = true;
            }
        }

        for (0..@intCast(sensorEvents.endCount)) |i| {
            const e = sensorEvents.endEvents[i];

            if (box2d.B2_ID_EQUALS(e.visitorShapeId, p.bodyShapeId)) {
                continue;
            }

            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                touchesGround = false;
            }
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.leftWallSensorId)) {
                touchesWallOnLeft = false;
            }
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.rightWallSensorId)) {
                touchesWallOnRight = false;
            }
        }
    }
}
