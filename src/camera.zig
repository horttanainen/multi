const std = @import("std");

const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const level = @import("level.zig");
const allocator = @import("allocator.zig").allocator;
const player = @import("player.zig");
const entity = @import("entity.zig");
const viewport = @import("viewport.zig");
const window = @import("window.zig");

const conv = @import("conversion.zig");

pub const Camera = struct {
    id: usize,
    playerId: usize,
    posPx: vec.IVec2,
};

pub var cameras: std.AutoArrayHashMapUnmanaged(usize, Camera) = .{};
var nextCameraId: usize = 0;
// Camera 0 is the persistent pre-level camera spawned at startup; player cameras start at 1.
const PLAYER_CAMERA_ID_START: usize = 1;

pub fn resetPlayerCameraIds() void {
    nextCameraId = PLAYER_CAMERA_ID_START;
}
pub var activeCameraId: usize = 0;

pub fn spawn(position: vec.IVec2) !void {
    _ = try spawnForPlayer(0, position);
}

pub fn spawnForPlayer(playerId: usize, position: vec.IVec2) !usize {
    const cameraId = nextCameraId;
    nextCameraId += 1;

    const camera = Camera{
        .id = cameraId,
        .playerId = playerId,
        .posPx = position,
    };

    try cameras.put(allocator, cameraId, camera);
    return cameraId;
}

pub fn destroyCamera(cameraId: usize) void {
    _ = cameras.fetchSwapRemove(cameraId);
}

pub fn setActiveCamera(cameraId: usize) !void {
    activeCameraId = cameraId;
    try viewport.setActiveViewport(cameraId);
}

pub fn getActiveCamera() ?*Camera {
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

pub fn followAllPlayers(zoom: f32) void {
    if (level.fixedCamera) {
        followSharedCamera(zoom);
        return;
    }
    for (player.players.values()) |*p| {
        if (cameras.getPtr(p.cameraId)) |cam| {
            const maybeEntity = entity.getEntity(p.bodyId);
            if (maybeEntity) |ent| {
                const currentState = box2d.getState(ent.bodyId);
                const state = box2d.getInterpolatedState(ent.state, currentState);
                var pos = conv.m2Pixel(state.pos);

                const lerpFactor: f32 = 0.10;
                const crosshairOffset = player.getCrosshairOffset(p.*);
                const target: vec.Vec2 = .{
                    .x = @as(f32, @floatFromInt(crosshairOffset.x)) * 0.5,
                    .y = @as(f32, @floatFromInt(crosshairOffset.y)) * 0.5,
                };

                p.zoomOffset.x += (target.x - p.zoomOffset.x) * lerpFactor;
                p.zoomOffset.y += (target.y - p.zoomOffset.y) * lerpFactor;

                pos.x += @intFromFloat(p.zoomOffset.x);
                pos.y += @intFromFloat(p.zoomOffset.y);

                moveCamera(cam, pos, zoom);
            }
        }
    }
}

fn followSharedCamera(zoom: f32) void {
    const values = player.players.values();
    if (values.len == 0) {
        std.log.warn("followSharedCamera: no players found, skipping", .{});
        return;
    }
    const p = values[0];
    if (cameras.getPtr(p.cameraId) == null) {
        std.log.warn("followSharedCamera: camera {d} not found for player {d}", .{ p.cameraId, p.id });
        return;
    }
    const cam = cameras.getPtr(p.cameraId).?;

    // Keep the camera centered on the level.
    moveCamera(cam, level.position, zoom);
}

pub fn centerOn(worldPos: vec.IVec2, zoom: f32) void {
    if (getActiveCamera()) |cam| moveCamera(cam, worldPos, zoom);
}

fn moveCamera(cam: *Camera, pos: vec.IVec2, zoom: f32) void {
    // Get viewport dimensions, or fall back to full window
    const vp = viewport.getViewportForCamera(cam.id) orelse viewport.Viewport{
        .x = 0,
        .y = 0,
        .width = window.width,
        .height = window.height,
    };

    // Effective viewport: how many world pixels are visible at this zoom level.
    const effW: i32 = @intFromFloat(@as(f32, @floatFromInt(vp.width)) / zoom);
    const effH: i32 = @intFromFloat(@as(f32, @floatFromInt(vp.height)) / zoom);

    cam.posPx.x = pos.x - @divFloor(effW, 2);
    cam.posPx.y = pos.y - @divFloor(effH, 2);

    const levelSize = level.size;
    const levelPos = level.position;

    const levelWidthHalf = @divFloor(levelSize.x, 2);
    const levelHeightHalf = @divFloor(levelSize.y, 2);

    if (effW < levelSize.x) {
        if (cam.posPx.x < levelPos.x - levelWidthHalf) {
            cam.posPx.x = levelPos.x - levelWidthHalf;
        } else if (cam.posPx.x >= levelPos.x + levelWidthHalf - effW) {
            cam.posPx.x = levelPos.x + levelWidthHalf - effW;
        }
    } else {
        cam.posPx.x = levelPos.x - @divFloor(effW, 2);
    }
    if (effH < levelSize.y) {
        if (cam.posPx.y < levelPos.y - levelHeightHalf) {
            cam.posPx.y = levelPos.y - levelHeightHalf;
        } else if (cam.posPx.y >= levelPos.y + levelHeightHalf - effH) {
            cam.posPx.y = levelPos.y + levelHeightHalf - effH;
        }
    } else {
        cam.posPx.y = levelPos.y - @divFloor(effH, 2);
    }
}

pub fn cleanup() void {
    cameras.deinit(allocator);
}
