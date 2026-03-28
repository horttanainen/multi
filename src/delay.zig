const std = @import("std");
const time = @import("time.zig");

const allocator = @import("allocator.zig").allocator;
pub var delayedActions: std.StringHashMap(u64) = std.StringHashMap(u64).init(allocator);

fn nowMs() u64 {
    return @intFromFloat(time.now() * 1000.0);
}

pub fn check(name: [:0]const u8) bool {
    const expires_at = delayedActions.get(name) orelse return false;
    if (expires_at > nowMs()) return true;

    const removed = delayedActions.fetchRemove(name);
    if (removed == null) {
        std.log.warn("delay.check: key '{s}' vanished during expiry cleanup", .{name});
        return false;
    }
    allocator.free(removed.?.key);
    return false;
}

pub fn action(name: [:0]const u8, delayMs: u32) void {
    const now = nowMs();
    const expires_at = now + delayMs;
    if (delayedActions.get(name)) |existing_expires_at| {
        if (existing_expires_at > now) return;
        const removed = delayedActions.fetchRemove(name);
        if (removed == null) {
            std.log.warn("delay.action: key '{s}' vanished while refreshing expired entry", .{name});
            return;
        }
        allocator.free(removed.?.key);
    }

    const nameCopy = allocator.dupe(u8, name) catch {
        std.log.err("delay.action: failed to duplicate key '{s}'", .{name});
        return;
    };

    delayedActions.put(nameCopy, expires_at) catch {
        allocator.free(nameCopy);
        std.log.err("delay.action: failed to store key '{s}'", .{name});
        return;
    };
}

pub fn cleanup() void {
    var iter = delayedActions.keyIterator();
    while (iter.next()) |key| {
        allocator.free(key.*);
    }
    delayedActions.deinit();
}
