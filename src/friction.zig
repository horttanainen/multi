const std = @import("std");
const config = @import("config.zig");
const movement = @import("movement.zig");

pub fn callback(frictionA: f32, materialA: c_int, frictionB: f32, materialB: c_int) callconv(.c) f32 {
    var fA = frictionA;
    var fB = frictionB;

    if (materialA >= config.player.materialOffset) {
        const playerId: usize = @intCast(materialA - config.player.materialOffset);
        fA = movement.surfaceFriction(playerId) orelse frictionA;
    }

    if (materialB >= config.player.materialOffset) {
        const playerId: usize = @intCast(materialB - config.player.materialOffset);
        fB = movement.surfaceFriction(playerId) orelse frictionB;
    }

    return @sqrt(fA * fB);
}
