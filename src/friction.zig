const std = @import("std");
const config = @import("config.zig");
const player = @import("player.zig");

pub fn callback(frictionA: f32, materialA: c_int, frictionB: f32, materialB: c_int) callconv(.c) f32 {
    var fA = frictionA;
    var fB = frictionB;


    if (materialA >= config.player.materialOffset) {
        const maybePlayerA = player.players.getPtr(@intCast(materialA - config.player.materialOffset));
        if (maybePlayerA) |p| {
            fA = player.getFrictionForPlayer(p);
        }
    }

    if (materialB >= config.player.materialOffset) {
        const maybePlayerB = player.players.getPtr(@intCast(materialB - config.player.materialOffset));

        if (maybePlayerB) |p| {
            fB = player.getFrictionForPlayer(p);
        }
    }

    return @sqrt(fA * fB);
}
