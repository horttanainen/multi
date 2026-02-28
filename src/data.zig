const std = @import("std");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");

pub const SpriteData = struct {
    path: []const u8,
    scale: f32,
};

var spriteDataMap: std.StringHashMapUnmanaged(SpriteData) = .{};

pub fn init() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("sprites.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read sprites.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        path: []const u8,
        scale: f32 = 1.0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse sprites.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const path = shared.allocator.dupe(u8, entry.path) catch {
            shared.allocator.free(key);
            continue;
        };

        spriteDataMap.put(shared.allocator, key, .{
            .path = path,
            .scale = entry.scale,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(path);
            continue;
        };

        std.debug.print("Parsed sprite data '{s}'\n", .{key});
    }
}

pub fn createSpriteFrom(key: []const u8) ?u64 {
    const d = spriteDataMap.get(key) orelse return null;
    return sprite.createFromImg(d.path, .{ .x = d.scale, .y = d.scale }, vec.izero) catch |err| {
        std.debug.print("Warning: Failed to create sprite for '{s}': {}\n", .{ key, err });
        return null;
    };
}

pub fn getSpriteData(key: []const u8) ?SpriteData {
    return spriteDataMap.get(key);
}

pub fn cleanup() void {
    var iter = spriteDataMap.iterator();
    while (iter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    spriteDataMap.deinit(shared.allocator);
}
