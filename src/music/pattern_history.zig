const std = @import("std");

pub const MAX_HISTORY_ENTRIES: usize = 16;

pub const PatternHistory = struct {
    entries: [MAX_HISTORY_ENTRIES]u32 = .{0} ** MAX_HISTORY_ENTRIES,
    capacity: usize,
    count: usize = 0,
    write_pos: usize = 0,
};

pub fn clear(history: *PatternHistory) void {
    history.entries = .{0} ** MAX_HISTORY_ENTRIES;
    history.count = 0;
    history.write_pos = 0;
}

pub fn seenRecently(history: *const PatternHistory, hash: u32) bool {
    const cap = resolveCapacity(history.capacity);
    if (cap == 0) return false;

    const count = @min(history.count, cap);
    for (0..count) |i| {
        if (history.entries[i] == hash) return true;
    }
    return false;
}

pub fn remember(history: *PatternHistory, hash: u32) void {
    const cap = resolveCapacity(history.capacity);
    if (cap == 0) return;

    if (history.write_pos >= cap) {
        std.log.warn("music.pattern_history.remember: invalid write_pos={d}, clamping to 0", .{history.write_pos});
        history.write_pos = 0;
    }

    history.entries[history.write_pos] = hash;
    history.write_pos = (history.write_pos + 1) % cap;
    if (history.count < cap) {
        history.count += 1;
    }
}

pub fn hashEnumPattern(comptime T: type, values: []const T) u32 {
    var hash: u32 = 2166136261;
    for (values) |value| {
        hash = (hash ^ @as(u32, @intCast(@intFromEnum(value)))) *% 16777619;
    }
    return hash;
}

fn resolveCapacity(capacity: usize) usize {
    if (capacity == 0) {
        std.log.warn("music.pattern_history: capacity is zero", .{});
        return 0;
    }

    if (capacity > MAX_HISTORY_ENTRIES) {
        std.log.warn("music.pattern_history: capacity={d} exceeds max={d}, clamping", .{ capacity, MAX_HISTORY_ENTRIES });
        return MAX_HISTORY_ENTRIES;
    }

    return capacity;
}
