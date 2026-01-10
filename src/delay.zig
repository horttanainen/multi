const std = @import("std");

const shared = @import("shared.zig");
const timer = @import("sdl_timer.zig");

pub var delayedActions: std.StringHashMap(bool) = std.StringHashMap(bool).init(shared.allocator);

pub fn check(name: [:0]const u8) bool {
    return delayedActions.contains(name);
}

pub fn action(name: [:0]const u8, delayMs: u32) void {
    const nameCopy = shared.allocator.dupe(u8, name) catch {
        return;
    };

    delayedActions.put(nameCopy, true) catch {
        shared.allocator.free(nameCopy);
        return;
    };
    const keyPtr = delayedActions.getKeyPtr(nameCopy);

    _ = timer.addTimer(delayMs, shutTimer, @ptrCast(@constCast(keyPtr)));
}

fn shutTimer(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const name: *[]const u8 = @alignCast(@ptrCast(param));

    if (delayedActions.fetchRemove(name.*)) |entry| {
        shared.allocator.free(entry.key);
    }

    return 0;
}

pub fn cleanup() void {
    var iter = delayedActions.keyIterator();
    while (iter.next()) |key| {
        shared.allocator.free(key.*);
    }
    delayedActions.deinit();
}
