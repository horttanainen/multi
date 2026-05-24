const std = @import("std");

const data = @import("data.zig");
const sprite = @import("sprite.zig");
const camera = @import("camera.zig");
const vec = @import("vector.zig");
const level = @import("level.zig");
const config = @import("config.zig");
const renderer = @import("renderer.zig");

var created: bool = false;
var posPx: vec.IVec2 = vec.izero;
var crosshairUuid: ?u64 = null;

var pendingKey: ?[]const u8 = null;
var pendingUuid: ?u64 = null;
var pendingImgPath: ?[]const u8 = null;
var pendingScale: vec.Vec2 = .{ .x = 1, .y = 1 };

pub fn create() !void {
    if (created) return;
    posPx = level.position;
    created = true;
}

pub fn deinit() void {
    created = false;
    if (crosshairUuid) |uuid| {
        sprite.cleanupLater(uuid);
        crosshairUuid = null;
    }
    detachSprite();
}

// Called on initial level editor entry: refresh sprite and reset cursor to level center.
pub fn initSprite() void {
    if (crosshairUuid) |old| sprite.cleanupLater(old);
    crosshairUuid = data.createSpriteFrom("crosshair");
    posPx = level.position;
}

// Called after editor reloads: refreshes sprites without moving the cursor.
pub fn refreshSprite() void {
    if (crosshairUuid) |old| sprite.cleanupLater(old);
    crosshairUuid = data.createSpriteFrom("crosshair");

    // Re-create pending sprite so its texture reference stays valid after atlas repack.
    if (pendingKey) |key| {
        if (pendingUuid) |old| sprite.cleanupLater(old);
        pendingUuid = data.createSpriteFrom(key);
        if (data.getSpriteData(key)) |d| {
            pendingImgPath = d.path;
            pendingScale = .{ .x = d.scale, .y = d.scale };
        }
    }
}

pub fn cameraFollow() void {
    if (!created) return;
    if (level.fixedCamera) {
        camera.centerOn(level.position, renderer.zoom);
        return;
    }
    camera.centerOn(posPx, renderer.zoom);
}

pub fn attachSprite(key: []const u8) void {
    detachSprite();
    const d = data.getSpriteData(key) orelse return;
    pendingUuid = data.createSpriteFrom(key);
    pendingKey = key;
    pendingImgPath = d.path;
    pendingScale = .{ .x = d.scale, .y = d.scale };
}

pub fn detachSprite() void {
    if (pendingUuid) |uuid| sprite.cleanupLater(uuid);
    pendingUuid = null;
    pendingKey = null;
    pendingImgPath = null;
}

pub fn hasPendingSprite() bool {
    return pendingKey != null;
}

pub fn getPendingImgPath() ?[]const u8 {
    return pendingImgPath;
}

pub fn getPendingScale() vec.Vec2 {
    return pendingScale;
}

pub fn getWorldPos() vec.IVec2 {
    if (!created) {
        std.log.warn("getWorldPos: cursor not created, returning origin", .{});
        return vec.izero;
    }
    return posPx;
}

pub fn moveLeft() void {
    moveByScreenPixels(.{ .x = -config.levelEditorCursorMovePixels, .y = 0 });
}
pub fn moveRight() void {
    moveByScreenPixels(.{ .x = config.levelEditorCursorMovePixels, .y = 0 });
}
pub fn moveUp() void {
    moveByScreenPixels(.{ .x = 0, .y = -config.levelEditorCursorMovePixels });
}
pub fn moveDown() void {
    moveByScreenPixels(.{ .x = 0, .y = config.levelEditorCursorMovePixels });
}

fn moveByScreenPixels(delta: vec.IVec2) void {
    if (!created) return;
    if (renderer.zoom <= 0) {
        std.log.warn("moveByScreenPixels: invalid renderer zoom {d}, skipping cursor movement", .{renderer.zoom});
        return;
    }

    var worldDelta = vec.IVec2{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(delta.x)) / renderer.zoom)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(delta.y)) / renderer.zoom)),
    };
    if (delta.x != 0 and worldDelta.x == 0) {
        worldDelta.x = if (delta.x > 0) 1 else -1;
    }
    if (delta.y != 0 and worldDelta.y == 0) {
        worldDelta.y = if (delta.y > 0) 1 else -1;
    }
    posPx = vec.iadd(posPx, worldDelta);
}

pub fn draw() !void {
    if (!created) return;
    const screenPos = camera.relativePosition(posPx);

    if (pendingUuid) |uuid| {
        const s = sprite.getSprite(uuid) orelse return;
        try sprite.drawWithOptions(s, screenPos, 0, false, false, 0, null, null);
    } else {
        const uuid = crosshairUuid orelse return;
        const s = sprite.getSprite(uuid) orelse return;
        try sprite.drawWithOptions(s, screenPos, 0, false, false, 0, null, null);
    }
}
