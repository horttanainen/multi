const box2d = @import("box2dnative.zig");

const vec = @import("vector.zig");
const box = @import("box.zig");
const level = @import("level.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

const conv = @import("conversion.zig");

pub const Camera = struct { posPx: vec.IVec2, bodyId: box2d.b2BodyId, state: ?box.State };

var maybeCamera: ?Camera = null;

pub fn spawn(position: vec.IVec2) !void {
    const bodyId = try box.createDynamicBody(position);
    box2d.b2Body_SetGravityScale(bodyId, 0);

    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    shapeDef.isSensor = true;

    const polygon = box2d.b2MakeSquare(0.5);

    _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);

    maybeCamera = .{ .posPx = position, .bodyId = bodyId, .state = null };
}

pub fn relativePositionForCreating(pos: vec.IVec2) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (maybeCamera) |camera| {
        camPos = camera.posPx;
    }

    return vec.iadd(pos, camPos);
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
        const currentState = box.getState(camera.bodyId);
        const state = box.getInterpolatedState(camera.state, currentState);
        move(conv.m2Pixel(state.pos));
    }
}

pub fn moveLeft() void {
    applyForce(box2d.b2Vec2{ .x = -config.player.sidewaysMovementForce, .y = 0 });
}

pub fn moveRight() void {
    applyForce(box2d.b2Vec2{ .x = config.player.sidewaysMovementForce, .y = 0 });
}

fn applyForce(force: box2d.b2Vec2) void {
    if (maybeCamera) |camera| {
        box2d.b2Body_ApplyForceToCenter(camera.bodyId, force, true);
    }
}

pub fn updateState() void {
    if (maybeCamera) |*camera| {
        camera.state = box.getState(camera.bodyId);
    }
}

fn move(pos: vec.IVec2) void {
    if (maybeCamera) |*camera| {
        camera.posPx.x = pos.x - config.window.width / 2;
        camera.posPx.y = pos.y - config.window.height / 2;

        if (level.maybeLevel) |l| {
            const levelWidthHalf = @divFloor(conv.m2P(l.sprite.dimM.x), 2);
            const levelHeightHalf = @divFloor(conv.m2P(l.sprite.dimM.y), 2);

            //TODO: store levelPosition in level as pixels
            const levelPos = conv.m2Pixel(box.getState(l.bodyId).pos);

            if (camera.posPx.x < levelPos.x - levelWidthHalf) {
                camera.posPx.x = levelPos.x - levelWidthHalf;
            } else if (camera.posPx.x > levelPos.x + levelWidthHalf - config.window.width) {
                camera.posPx.x = levelPos.x + levelWidthHalf - config.window.width;
            }
            if (camera.posPx.y < levelPos.y - levelHeightHalf) {
                camera.posPx.y = levelPos.y - levelHeightHalf;
            } else if (camera.posPx.y > levelPos.y + levelHeightHalf - config.window.height) {
                camera.posPx.y = levelPos.y + levelHeightHalf - config.window.height;
            }
        }
    }
}
