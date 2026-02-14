const std = @import("std");
const shared = @import("shared.zig");

pub const PlayerScore = struct {
    kills: i32,
    deaths: i32,
    suicides: i32,
};

pub var scores: std.AutoArrayHashMapUnmanaged(usize, PlayerScore) = .{};

pub fn registerPlayer(playerId: usize) !void {
    try scores.put(shared.allocator, playerId, .{ .kills = 0, .deaths = 0, .suicides = 0 });
}

pub fn recordKill(killerId: ?usize, victimId: usize) void {
    if (killerId) |kid| {
        if (kid == victimId) {
            // Suicide: +1 suicide, +1 death
            if (scores.getPtr(kid)) |s| {
                s.suicides += 1;
                s.deaths += 1;
            }
        } else {
            // Kill: +1 for killer, +1 death for victim
            if (scores.getPtr(kid)) |s| {
                s.kills += 1;
            }
            if (scores.getPtr(victimId)) |s| {
                s.deaths += 1;
            }
        }
    } else {
        // No killer: just +1 death
        if (scores.getPtr(victimId)) |s| {
            s.deaths += 1;
        }
    }
}

pub fn getScore(playerId: usize) ?PlayerScore {
    return scores.get(playerId);
}

pub fn cleanup() void {
    scores.clearAndFree(shared.allocator);
}
