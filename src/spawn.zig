const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const vec = @import("vector.zig");

pub var locations: std.AutoArrayHashMapUnmanaged(usize, vec.IVec2) = .empty;

pub fn addLocation(position: vec.IVec2) !void {
    const playerId = locations.count();
    try locations.put(allocator, playerId, position);
}

pub fn positionForPlayer(playerId: usize) !vec.IVec2 {
    const playerLocation = locations.get(playerId);
    if (playerLocation != null) return playerLocation.?;

    const firstLocation = locations.get(0) orelse {
        std.log.err("spawn.positionForPlayer: spawn location for player 0 is missing", .{});
        return error.NoSpawnLocations;
    };

    return .{
        .x = firstLocation.x + @as(i32, @intCast(playerId)) * 10,
        .y = firstLocation.y,
    };
}

pub fn cleanup() void {
    locations.deinit(allocator);
    locations = .empty;
}
