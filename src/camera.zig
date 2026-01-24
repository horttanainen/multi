const std = @import("std");

const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const level = @import("level.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const viewport = @import("viewport.zig");
const window = @import("window.zig");

const conv = @import("conversion.zig");

pub const Camera = struct {
    id: usize,
    playerId: usize,
    posPx: vec.IVec2,
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
};

pub var cameras: std.AutoArrayHashMapUnmanaged(usize, Camera) = .{};
var nextCameraId: usize = 0;
pub var activeCameraId: usize = 0;

pub fn spawn(position: vec.IVec2) !void {
    _ = try spawnForPlayer(0, position);
}

pub fn spawnForPlayer(playerId: usize, position: vec.IVec2) !usize {
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

    const cameraId = nextCameraId;
    nextCameraId += 1;

    const camera = Camera{
        .id = cameraId,
        .playerId = playerId,
        .posPx = position,
        .bodyId = bodyId,
        .state = null,
    };

    try cameras.put(shared.allocator, cameraId, camera);
    return cameraId;
}

pub fn destroyCamera(cameraId: usize) void {
    if (cameras.fetchSwapRemove(cameraId)) |entry| {
        box2d.c.b2DestroyBody(entry.value.bodyId);
    }
}

pub fn setActiveCamera(cameraId: usize) !void {
    const resources = try shared.getResources();

    activeCameraId = cameraId;

    try viewport.setActiveViewport(resources.renderer, cameraId);
}

fn getActiveCamera() ?*Camera {
    return cameras.getPtr(activeCameraId);
}

pub fn relativePositionForCreating(pos: vec.IVec2) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (getActiveCamera()) |camera| {
        camPos = camera.posPx;
    }

    return vec.iadd(pos, camPos);
}

pub fn parallaxAdjustedRelativePosition(pos: vec.IVec2, parallaxDistance: f32) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (getActiveCamera()) |camera| {
        camPos = camera.posPx;
    }
    camPos.x = @intFromFloat(@as(f32, @floatFromInt(camPos.x)) / parallaxDistance);
    camPos.y = @intFromFloat(@as(f32, @floatFromInt(camPos.y)) / parallaxDistance);
    return vec.isubtract(pos, camPos);
}

pub fn relativePosition(pos: vec.IVec2) vec.IVec2 {
    var camPos = vec.IVec2{ .x = 0, .y = 0 };
    if (getActiveCamera()) |camera| {
        camPos = camera.posPx;
    }
    return vec.isubtract(pos, camPos);
}

pub fn followAllPlayers() void {
    for (player.players.values()) |*p| {
        if (cameras.getPtr(p.cameraId)) |cam| {
            const maybeEntity = entity.getEntity(p.bodyId);
            if (maybeEntity) |ent| {
                const currentState = box2d.getState(ent.bodyId);
                const state = box2d.getInterpolatedState(ent.state, currentState);
                const pos = conv.m2Pixel(state.pos);
                moveCamera(cam, pos);
            }
        }
    }
}

pub fn followKeyboard() void {
    if (getActiveCamera()) |camera| {
        const currentState = box2d.getState(camera.bodyId);
        const state = box2d.getInterpolatedState(camera.state, currentState);
        moveCamera(camera, conv.m2Pixel(state.pos));
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
    if (getActiveCamera()) |camera| {
        box2d.c.b2Body_ApplyForceToCenter(camera.bodyId, force, true);
    }
}

pub fn updateState() void {
    for (cameras.values()) |*cam| {
        cam.state = box2d.getState(cam.bodyId);
    }
}

fn moveCamera(cam: *Camera, pos: vec.IVec2) void {
    // Get viewport dimensions, or fall back to full window
    const vp = viewport.getViewportForCamera(cam.id) orelse viewport.Viewport{
        .x = 0,
        .y = 0,
        .width = window.width,
        .height = window.height,
    };

    cam.posPx.x = pos.x - @divFloor(vp.width, 2);
    cam.posPx.y = pos.y - @divFloor(vp.height, 2);

    const levelSize = level.size;
    const levelPos = level.position;

    const levelWidthHalf = @divFloor(levelSize.x, 2);
    const levelHeightHalf = @divFloor(levelSize.y, 2);

    if (vp.width < levelSize.x) {
        if (cam.posPx.x < levelPos.x - levelWidthHalf) {
            cam.posPx.x = levelPos.x - levelWidthHalf;
        } else if (cam.posPx.x >= levelPos.x + levelWidthHalf - vp.width) {
            cam.posPx.x = levelPos.x + levelWidthHalf - vp.width;
        }
    } else {
        cam.posPx.x = -@divFloor(vp.width, 2);
    }
    if (vp.height < levelSize.y) {
        if (cam.posPx.y < levelPos.y - levelHeightHalf) {
            cam.posPx.y = levelPos.y - levelHeightHalf;
        } else if (cam.posPx.y >= levelPos.y + levelHeightHalf - vp.height) {
            cam.posPx.y = levelPos.y + levelHeightHalf - vp.height;
        }
    } else {
        cam.posPx.y = -@divFloor(vp.height, 2);
    }
}

pub fn cleanup() void {
    cameras.deinit(shared.allocator);
}
