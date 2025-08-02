const std = @import("std");
const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const camera = @import("camera.zig");
const delay = @import("delay.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box = @import("box.zig");

const config = @import("config.zig");

const conv = @import("conversion.zig");

const vec = @import("vector.zig");

pub const Player = struct {
    entity: entity.Entity,
    bodyShapeId: box2d.b2ShapeId,
    lowerBodyShapeId: box2d.b2ShapeId,
    footSensorShapeId: box2d.b2ShapeId,
    leftWallSensorId: box2d.b2ShapeId,
    rightWallSensorId: box2d.b2ShapeId,
};

pub var maybeCrosshair: ?sprite.Sprite = null;

pub var maybePlayer: ?Player = null;

var groundContactCount: usize = 0;

pub var isMoving: bool = false;
pub var touchesGround: bool = false;
pub var touchesWallOnLeft: bool = false;
pub var touchesWallOnRight: bool = false;
pub var aimDirection = vec.west;

var airJumpCounter: i32 = 0;
var movingRight: bool = false;

const PlayerError = error{PlayerUnspawned};

pub fn getPlayer() !Player {
    if (maybePlayer) |p| {
        return p;
    }
    return PlayerError.PlayerUnspawned;
}

pub fn draw() !void {
    if (maybePlayer) |*player| {
        if (aimDirection.x > 0) {
            try entity.draw(&player.entity);
        } else {
            try entity.drawFlipped(&player.entity);
        }
        if (maybeCrosshair) |crosshair| {
            const pos = calcCrosshairPosition(player.*);
            try sprite.drawWithOptions(crosshair, pos, 0, false, false);
        }
    }
}

fn calcCrosshairPosition(player: Player) vec.IVec2 {
    const currentState = box.getState(player.entity.bodyId);
    const state = box.getInterpolatedState(player.entity.state, currentState);
    const playerPos = camera.relativePosition(conv.m2PixelPos(state.pos.x, state.pos.y, player.entity.sprite.sizeM.x, player.entity.sprite.sizeM.y));

    const crosshairDisplacement = vec.mul(vec.normalize(aimDirection), 100);
    const crosshairDisplacementI: vec.IVec2 = .{
        .x = @intFromFloat(crosshairDisplacement.x),
        .y = @intFromFloat(-crosshairDisplacement.y), //inverse y-axel
    };

    const crosshairPos = vec.iadd(playerPos, crosshairDisplacementI);
    return crosshairPos;
}

pub fn updateState() void {
    if (maybePlayer) |*player| {
        player.entity.state = box.getState(player.entity.bodyId);
    }
}

pub fn spawn(position: vec.IVec2) !void {
    const resources = try shared.getResources();
    const surface = try image.load(shared.lieroImgSrc);
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const sizeM = conv.p2m(.{ .x = size.x, .y = size.y });

    const pos = conv.pixel2MPos(position.x, position.y, sizeM.x, sizeM.y);

    const bodyDef = box.createNonRotatingDynamicBodyDef(pos);
    const bodyId = try box.createBody(bodyDef);

    const dynamicBox = box2d.b2MakeBox(0.1, 0.25);
    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.density = 1.0;
    shapeDef.friction = config.player.movementFriction;
    shapeDef.material = config.player.materialId;
    const bodyShapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const lowerBodyCircle: box2d.b2Circle = .{
        .center = .{
            .x = 0,
            .y = 0.25,
        },
        .radius = 0.1,
    };
    var lowerBodyShapeDef = box2d.b2DefaultShapeDef();
    lowerBodyShapeDef.density = 1.0;
    lowerBodyShapeDef.friction = config.player.movementFriction;
    lowerBodyShapeDef.material = config.player.materialId;
    const lowerBodyShapeId = box2d.b2CreateCircleShape(bodyId, &lowerBodyShapeDef, &lowerBodyCircle);

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

    const s = sprite.Sprite{
        .surface = surface,
        .texture = texture,
        .imgPath = shared.lieroImgSrc,
        .sizeM = .{
            .x = sizeM.x,
            .y = sizeM.y,
        },
        .sizeP = .{
            .x = size.x,
            .y = size.y,
        },
    };

    var shapeIds = std.ArrayList(box2d.b2ShapeId).init(shared.allocator);
    try shapeIds.append(bodyShapeId);
    try shapeIds.append(lowerBodyShapeId);
    try shapeIds.append(footSensorShapeId);
    try shapeIds.append(leftWallSensorId);
    try shapeIds.append(rightWallSensorId);

    maybePlayer = Player{
        .entity = entity.Entity{
            .type = "dynamic",
            .friction = config.player.movementFriction,
            .bodyId = bodyId,
            .sprite = s,
            .shapeIds = try shapeIds.toOwnedSlice(),
            .state = null,
            .highlighted = false,
        },
        .bodyShapeId = bodyShapeId,
        .lowerBodyShapeId = lowerBodyShapeId,
        .footSensorShapeId = footSensorShapeId,
        .leftWallSensorId = leftWallSensorId,
        .rightWallSensorId = rightWallSensorId,
    };

    maybeCrosshair = try sprite.createFromImg(shared.crosshairImgSrc);
}

pub fn jump() void {
    if (delay.check("jump")) {
        return;
    }

    if (maybePlayer) |p| {
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
            jumpImpulse = if (touchesWallOnLeft) box2d.b2Vec2{
                .x = config.player.jumpImpulse / 2,
                .y = -config.player.jumpImpulse,
            } else box2d.b2Vec2{
                .x = -config.player.jumpImpulse / 2,
                .y = -config.player.jumpImpulse,
            };
        }

        box2d.b2Body_ApplyLinearImpulseToCenter(p.entity.bodyId, jumpImpulse, true);
        delay.action("jump", config.jumpDelayMs);
    }
}

pub fn brake() void {
    isMoving = false;
}

pub fn moveLeft() void {
    movingRight = false;
    applyForce(box2d.b2Vec2{ .x = -config.player.sidewaysMovementForce, .y = 0 });
}

pub fn moveRight() void {
    movingRight = true;
    applyForce(box2d.b2Vec2{ .x = config.player.sidewaysMovementForce, .y = 0 });
}

fn applyForce(force: box2d.b2Vec2) void {
    isMoving = true;
    if (maybePlayer) |p| {
        box2d.b2Body_ApplyForceToCenter(p.entity.bodyId, force, true);
    }
}

pub fn clampSpeed() void {
    if (maybePlayer) |p| {
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
    if (maybePlayer) |p| {
        const sensorEvents = box2d.b2World_GetSensorEvents(resources.worldId);

        for (0..@intCast(sensorEvents.beginCount)) |i| {
            const e = sensorEvents.beginEvents[i];

            if (box2d.B2_ID_EQUALS(e.visitorShapeId, p.bodyShapeId)) {
                continue;
            }
            if (box2d.B2_ID_EQUALS(e.visitorShapeId, p.lowerBodyShapeId)) {
                continue;
            }

            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                groundContactCount += 1;
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
            if (box2d.B2_ID_EQUALS(e.visitorShapeId, p.lowerBodyShapeId)) {
                continue;
            }

            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.footSensorShapeId)) {
                if (groundContactCount > 0) {
                    groundContactCount -= 1;
                }
            }

            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.leftWallSensorId)) {
                touchesWallOnLeft = false;
            }
            if (box2d.B2_ID_EQUALS(e.sensorShapeId, p.rightWallSensorId)) {
                touchesWallOnRight = false;
            }
        }
        touchesGround = groundContactCount > 0;
    }
}

pub fn aim(direction: vec.Vec2) void {
    var dir = direction;
    if (vec.equals(dir, vec.zero)) {
        dir = vec.add(dir, if (movingRight) vec.east else vec.west);
    }
    aimDirection = dir;
}

pub fn shoot() !void {
    if (!delay.check("shoot")) {
        if (maybePlayer) |*player| {
            var shapeDef = box2d.b2DefaultShapeDef();
            shapeDef.friction = 0.5;

            const s = try sprite.createFromImg(shared.cannonBallmgSrc);
            const crosshairPos = calcCrosshairPosition(player.*);
            const position = camera.relativePositionForCreating(crosshairPos);
            const pos = conv.pixel2MPos(position.x, position.y, s.sizeM.x, s.sizeM.y);
            var bodyDef = box.createDynamicBodyDef(pos);
            bodyDef.isBullet = true;
            const cannonBall = try entity.createFromImg(s, shapeDef, bodyDef, "dynamic");

            const cannonImpulse = vec.mul(vec.normalize(.{
                .x = aimDirection.x,
                .y = -aimDirection.y,
            }), config.cannonImpulse);

            box2d.b2Body_ApplyLinearImpulseToCenter(cannonBall.bodyId, vec.toBox2d(cannonImpulse), true);
            box2d.b2Body_ApplyLinearImpulseToCenter(player.entity.bodyId, vec.toBox2d(vec.mul(cannonImpulse, -0.1)), true);
        }

        delay.action("shoot", config.shootDelayMs);
    }
}

pub fn cleanup() void {
    if (maybePlayer) |player| {
        box2d.b2DestroyBody(player.entity.bodyId);
        shared.allocator.free(player.entity.shapeIds);
    }
    if (maybeCrosshair) |crosshair| {
        sprite.cleanup(crosshair);
    }
    maybeCrosshair = null;
    maybePlayer = null;
}
