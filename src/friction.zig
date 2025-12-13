const std = @import("std");
const config = @import("config.zig");
const player = @import("player.zig");

pub fn frictionCallback(frictionA: f32, materialA: c_int, frictionB: f32, materialB: c_int) callconv(.c) f32 {
    var fA = frictionA;
    var fB = frictionB;

    // Check if material A is a player (material IDs 0, 1, 2, ... correspond to player IDs)
    if (materialA >= 0 and materialA < player.players.items.len) {
        fA = player.getFrictionForMaterial(materialA);
    }

    // Check if material B is a player
    if (materialB >= 0 and materialB < player.players.items.len) {
        fB = player.getFrictionForMaterial(materialB);
    }

    return @sqrt(fA * fB);
}
