const std = @import("std");
const config = @import("config.zig");
const player = @import("player.zig");

pub fn frictionCallback(frictionA: f32, materialA: c_int, frictionB: f32, materialB: c_int) callconv(.c) f32 {
    var fA = frictionA;
    var fB = frictionB;

    const maybePlayerA = player.players.getPtr(@intCast(materialA));
    const maybePlayerB = player.players.getPtr(@intCast(materialB));

    if (maybePlayerA) |p| {
        fA = player.getFrictionForPlayer(p);
    }

    if (maybePlayerB) |p| {
        fB = player.getFrictionForPlayer(p);
    }

    return @sqrt(fA * fB);
}
