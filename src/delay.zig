const std = @import("std");
const sdl = @import("sdl.zig");

const allocator = @import("allocator.zig").allocator;

pub var delayedActions: std.StringHashMap(bool) = std.StringHashMap(bool).init(allocator);

pub fn check(name: [:0]const u8) bool {
    return delayedActions.contains(name);
}

pub fn action(name: [:0]const u8, delayMs: u32) void {
    const nameCopy = allocator.dupe(u8, name) catch {
        return;
    };

    delayedActions.put(nameCopy, true) catch {
        allocator.free(nameCopy);
        return;
    };
    const keyPtr = delayedActions.getKeyPtr(nameCopy);

    _ = sdl.addTimer(delayMs, shutTimer, @ptrCast(@constCast(keyPtr)));
}

fn shutTimer(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const name: *[]const u8 = @alignCast(@ptrCast(param));

    if (delayedActions.fetchRemove(name.*)) |entry| {
        allocator.free(entry.key);
    }

    return 0;
}

pub fn cleanup() void {
    var iter = delayedActions.keyIterator();
    while (iter.next()) |key| {
        allocator.free(key.*);
    }
    delayedActions.deinit();
}
