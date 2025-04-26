const vec = @import("vector.zig");

const box = @import("box.zig");
const level = @import("level.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

const conv = @import("conversion.zig");

pub var camPos: vec.IVec2 = .{ .x = 0, .y = 0 };

pub fn relativePositionForCreating(pos: vec.IVec2) vec.IVec2 {
    return vec.iadd(pos, camPos);
}

pub fn relativePosition(pos: vec.IVec2) vec.IVec2 {
    return vec.isubtract(pos, camPos);
}

pub fn followPlayer() void {
    if (player.maybePlayer) |p| {
        move(entity.getPosition(p.entity));
    }
}

fn move(pos: vec.IVec2) void {
    camPos.x = pos.x - config.window.width / 2;
    camPos.y = pos.y - config.window.height / 2;

    if (level.maybeLevel) |l| {
        const levelWidthHalf = @divFloor(conv.m2P(l.sprite.dimM.x), 2);
        const levelHeightHalf = @divFloor(conv.m2P(l.sprite.dimM.y), 2);

        //TODO: store levelPosition in level as pixels
        const levelPos = conv.m2Pixel(box.getState(l.bodyId).pos);

        if (camPos.x < levelPos.x - levelWidthHalf) {
            camPos.x = levelPos.x - levelWidthHalf;
        } else if (camPos.x > levelPos.x + levelWidthHalf - config.window.width) {
            camPos.x = levelPos.x + levelWidthHalf - config.window.width;
        }
        if (camPos.y < levelPos.y - levelHeightHalf) {
            camPos.y = levelPos.y - levelHeightHalf;
        } else if (camPos.y > levelPos.y + levelHeightHalf - config.window.height) {
            camPos.y = levelPos.y + levelHeightHalf - config.window.height;
        }
    }
}
