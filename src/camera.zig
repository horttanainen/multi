const vec = @import("vector.zig");

const config = @import("config.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

var camPos: vec.IVec2 = .{ .x = 0, .y = 0 };

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
}
