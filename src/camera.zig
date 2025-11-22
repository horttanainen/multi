const std = @import("std");

const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const level = @import("level.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

const conv = @import("conversion.zig");

pub const Camera = struct { posPx: vec.IVec2, bodyId: box2d.c.b2BodyId, state: ?box2d.State };

var maybeCamera: ?Camera = null;

pub fn spawn(position: vec.IVec2) !void {
    const bodyDef = box2d.createDynamicBodyDef(.{
        .x = @floatFromInt(position.x),
        .y = @floatFromInt(position.y),
    });
    const bodyId = try box2d.createBody(bodyDef);
    box2d.c.b2Body_SetGravityScale(bodyId, 0);
    box2d.c.b2Body_SetLinearDamping(bodyId, 2);

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 1;
    shapeDef.isSensor = true;

    const polygon = box2d.c.b2MakeSquare(0.5);

    _ = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);

    maybeCamera = .{
        .posPx = position,
        .bodyId = bodyId,
        .state = null,
    };
}

pub fn relativePositionForCreating(pos: vec.IVec2) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (maybeCamera) |camera| {
        camPos = camera.posPx;
    }

    return vec.iadd(pos, camPos);
}

pub fn parallaxAdjustedRelativePosition(pos: vec.IVec2, parallaxDistance: f32) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (maybeCamera) |camera| {
        camPos = camera.posPx;
    }
    camPos.x = @intFromFloat(@as(f32, @floatFromInt(camPos.x)) / parallaxDistance);
    camPos.y = @intFromFloat(@as(f32, @floatFromInt(camPos.y)) / parallaxDistance);
    return vec.isubtract(pos, camPos);
}

pub fn relativePosition(pos: vec.IVec2) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (maybeCamera) |camera| {
        camPos = camera.posPx;
    }
    return vec.isubtract(pos, camPos);
}

pub fn followPlayer() void {
    if (player.maybePlayer) |p| {
        move(entity.getPosition(p.entity));
    }
}

pub fn followKeyboard() void {
    if (maybeCamera) |camera| {
        const currentState = box2d.getState(camera.bodyId);
        const state = box2d.getInterpolatedState(camera.state, currentState);
        move(conv.m2Pixel(state.pos));
    }
}

pub fn moveLeft() void {
    applyForce(box2d.c.b2Vec2{ .x = -config.levelEditorCameraMovementForce, .y = 0 });
}

pub fn moveRight() void {
    applyForce(box2d.c.b2Vec2{ .x = config.levelEditorCameraMovementForce, .y = 0 });
}

pub fn moveUp() void {
    applyForce(box2d.c.b2Vec2{ .x = 0, .y = -config.levelEditorCameraMovementForce });
}

pub fn moveDown() void {
    applyForce(box2d.c.b2Vec2{ .x = 0, .y = config.levelEditorCameraMovementForce });
}

fn applyForce(force: box2d.c.b2Vec2) void {
    if (maybeCamera) |camera| {
        box2d.c.b2Body_ApplyForceToCenter(camera.bodyId, force, true);
    }
}

pub fn updateState() void {
    if (maybeCamera) |*camera| {
        camera.state = box2d.getState(camera.bodyId);
    }
}

fn move(pos: vec.IVec2) void {
    if (maybeCamera) |*camera| {
        camera.posPx.x = pos.x - config.window.width / 2;
        camera.posPx.y = pos.y - config.window.height / 2;

        const levelSize = level.size;
        const levelPos = level.position;

        const levelWidthHalf = @divFloor(levelSize.x, 2);
        const levelHeightHalf = @divFloor(levelSize.y, 2);

        if (config.window.width < levelSize.x) {
            if (camera.posPx.x < levelPos.x - levelWidthHalf) {
                camera.posPx.x = levelPos.x - levelWidthHalf;
            } else if (camera.posPx.x >= levelPos.x + levelWidthHalf - config.window.width) {
                camera.posPx.x = levelPos.x + levelWidthHalf - config.window.width;
            }
        } else {
            camera.posPx.x = -config.window.width / 2;
        }
        if (config.window.height < levelSize.y) {
            if (camera.posPx.y < levelPos.y - levelHeightHalf) {
                camera.posPx.y = levelPos.y - levelHeightHalf;
            } else if (camera.posPx.y >= levelPos.y + levelHeightHalf - config.window.height) {
                camera.posPx.y = levelPos.y + levelHeightHalf - config.window.height;
            }
        } else {
            camera.posPx.y = -config.window.height / 2;
        }
    }
}
