const std = @import("std");
const sprite = @import("sprite.zig");
const animation = @import("animation.zig");
const shared = @import("shared.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");

pub const SpriteData = struct {
    path: []const u8,
    scale: f32,
};

pub const AnimationData = struct {
    path: []const u8,
    fps: i32,
    scale: f32,
    offsetX: i32,
    offsetY: i32,
    loop: bool,
    spriteIndex: usize,
    switchDelay: f64,
};

var spriteDataMap: std.StringHashMapUnmanaged(SpriteData) = .{};
var animationDataMap: std.StringHashMapUnmanaged(AnimationData) = .{};

pub fn init() !void {
    try initSprites();
    try initAnimations();
}

fn initSprites() !void {
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

fn initAnimations() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("animations.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read animations.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        path: []const u8,
        fps: i32 = 8,
        scale: f32 = 1.0,
        offsetX: i32 = 0,
        offsetY: i32 = 0,
        loop: bool = true,
        spriteIndex: usize = 0,
        switchDelay: f64 = 0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse animations.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const path = shared.allocator.dupe(u8, entry.path) catch {
            shared.allocator.free(key);
            continue;
        };

        animationDataMap.put(shared.allocator, key, .{
            .path = path,
            .fps = entry.fps,
            .scale = entry.scale,
            .offsetX = entry.offsetX,
            .offsetY = entry.offsetY,
            .loop = entry.loop,
            .spriteIndex = entry.spriteIndex,
            .switchDelay = entry.switchDelay,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(path);
            continue;
        };

        std.debug.print("Parsed animation data '{s}'\n", .{key});
    }
}

pub fn createSpriteFrom(key: []const u8) ?u64 {
    const d = spriteDataMap.get(key) orelse return null;
    return sprite.createFromImg(d.path, .{ .x = d.scale, .y = d.scale }, vec.izero) catch |err| {
        std.debug.print("Warning: Failed to create sprite for '{s}': {}\n", .{ key, err });
        return null;
    };
}

pub fn createAnimationFrom(key: []const u8) !animation.Animation {
    const d = animationDataMap.get(key) orelse return error.AnimationDataNotFound;
    const scale = vec.Vec2{ .x = d.scale, .y = d.scale };
    const offset = vec.IVec2{ .x = d.offsetX, .y = d.offsetY };
    var anim = try animation.load(d.path, d.fps, scale, offset, d.loop, d.spriteIndex);
    anim.switchDelay = d.switchDelay;
    return anim;
}

pub fn getAnimationData(key: []const u8) ?AnimationData {
    return animationDataMap.get(key);
}

pub fn getSpriteData(key: []const u8) ?SpriteData {
    return spriteDataMap.get(key);
}

pub fn cleanup() void {
    var spriteIter = spriteDataMap.iterator();
    while (spriteIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    spriteDataMap.deinit(shared.allocator);

    var animIter = animationDataMap.iterator();
    while (animIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    animationDataMap.deinit(shared.allocator);
}
