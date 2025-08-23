const std = @import("std");

const shared = @import("shared.zig");
const timer = @import("sdl_timer.zig");

pub var delayedActions: std.StringHashMap(bool) = std.StringHashMap(bool).init(shared.allocator);

pub fn check(name: [:0]const u8) bool {
    return delayedActions.contains(name);
}

pub fn action(name: [:0]const u8, delayMs: u32) void {
    delayedActions.put(name, true) catch {
        return;
    };
    const keyPtr = delayedActions.getKeyPtr(name);

    _ = timer.addTimer(delayMs, shutTimer, @ptrCast(@constCast(keyPtr)));
}

fn shutTimer(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const name: *[:0]const u8 = @alignCast(@ptrCast(param));

    _ = delayedActions.remove(name.*);

    return 0;
}

pub fn cleanup() void {
    delayedActions.deinit();
}
