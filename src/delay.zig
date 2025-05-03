const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");

pub const TimerCallback = *const fn (
    interval: u32,
    param: ?*anyopaque,
) callconv(.C) u32;

pub const addTimer = SDL_AddTimer;
extern fn SDL_AddTimer(interval: u32, callback: TimerCallback, param: ?*anyopaque) i32;

pub const removeTimer = SDL_RemoveTimer;
extern fn SDL_RemoveTimer(id: i32) c_int;

pub var delayedActions: std.StringHashMap(bool) = std.StringHashMap(bool).init(shared.allocator);

pub fn check(name: [:0]const u8) bool {
    return delayedActions.contains(name);
}

pub fn action(name: [:0]const u8, delayMs: u32) void {
    delayedActions.put(name, true) catch {
        return;
    };
    const keyPtr = delayedActions.getKeyPtr(name);

    _ = addTimer(delayMs, shutTimer, @ptrCast(@constCast(keyPtr)));
}

fn shutTimer(interval: u32, param: ?*anyopaque) callconv(.C) u32 {
    _ = interval;
    const name: *[:0]const u8 = @alignCast(@ptrCast(param));

    _ = delayedActions.remove(name.*);

    return 0;
}

pub fn cleanup() void {
    delayedActions.deinit();
}
