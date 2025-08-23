const std = @import("std");
const config = @import("config.zig");
const player = @import("player.zig");

pub fn frictionCallback(frictionA: f32, materialA: c_int, frictionB: f32, materialB: c_int) callconv(.c) f32 {
    const playerFriction = if (player.isMoving) config.player.movementFriction else config.player.restingFriction;

    var fA = frictionA;
    var fB = frictionB;
    if (materialA == config.player.materialId) {
        fA = playerFriction;
    }

    if (materialB == config.player.materialId) {
        fB = playerFriction;
    }

    return @sqrt(fA * fB);
}
