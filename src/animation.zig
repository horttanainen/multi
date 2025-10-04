const std = @import("std");

const vec = @import("vector.zig");
const shared = @import("shared.zig");
const sprite = @import("sprite.zig");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const time = @import("time.zig");
const thread_safe = @import("thread_safe_array_list.zig");

pub const Animation = struct {
    fps: i32,
    current: usize,
    lastTime: f64,
    frames: []sprite.Sprite,
};

pub const AnimationInstance = struct {
    animation: Animation,
    loop: bool,
};

var animationInstances = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, AnimationInstance).init(shared.allocator);

pub fn register(bodyId: box2d.c.b2BodyId, anim: Animation, loop: bool) !void {
    try animationInstances.putLocking(bodyId, .{
        .animation = anim,
        .loop = loop,
    });

    const maybeEntityPtr = entity.entities.getPtrLocking(bodyId);
    if (maybeEntityPtr) |entPtr| {
        entPtr.animated = true;
    }
}

pub fn animate() void {
    animationInstances.mutex.lock();
    defer animationInstances.mutex.unlock();

    var iter = animationInstances.map.iterator();
    while (iter.next()) |entry| {
        const bodyId = entry.key_ptr.*;
        const instance = entry.value_ptr;

        const timeNowS = time.now();
        const timePassedS = timeNowS - instance.animation.lastTime;
        const fpsSeconds = 1.0 / @as(f64, @floatFromInt(instance.animation.fps));

        if (timePassedS > fpsSeconds) {
            if (instance.loop) {
                // Loop animation
                const nextFrame = (instance.animation.current + 1) % instance.animation.frames.len;
                instance.animation.current = nextFrame;
            } else {
                // Play once, stop at last frame
                const nextFrame = instance.animation.current + 1;
                if (nextFrame < instance.animation.frames.len) {
                    instance.animation.current = nextFrame;
                } else {
                    const maybeE = entity.entities.fetchSwapRemoveLocking(bodyId);
                    if (maybeE) |e| {
                        entity.cleanupLater(e.value);
                    }
                }
            }

            // Update entity sprite
            const maybeEntity = entity.entities.getPtrLocking(bodyId);
            if (maybeEntity) |ent| {
                ent.sprite = instance.animation.frames[instance.animation.current];
            }

            instance.animation.lastTime = timeNowS;
        }
    }
}

pub fn cleanupAnimationFrames(bodyId: box2d.c.b2BodyId) void {
    animationInstances.mutex.lock();
    defer animationInstances.mutex.unlock();

    const maybeInstance = animationInstances.map.fetchSwapRemove(bodyId);
    if (maybeInstance) |instance| {
        for (instance.value.animation.frames) |frame| {
            sprite.cleanup(frame);
        }
        shared.allocator.free(instance.value.animation.frames);
    }
}

pub fn cleanup() void {
    animationInstances.mutex.lock();
    defer animationInstances.mutex.unlock();

    var iter = animationInstances.map.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.animation.frames) |frame| {
            sprite.cleanup(frame);
        }
        shared.allocator.free(entry.value_ptr.animation.frames);
    }

    animationInstances.map.clearAndFree();
}

pub fn load(pathToAnimationDir: []const u8, fps: i32, scale: vec.Vec2, offset: vec.IVec2) !Animation {
    var dir = try std.fs.cwd().openDir(pathToAnimationDir, .{});
    defer dir.close();

    var images = std.array_list.Managed([]const u8).init(shared.allocator);
    defer images.deinit();
    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            try images.append(dirContent.name);
        }
    }

    std.mem.sort([]const u8, images.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var frames = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
    for (images.items) |image| {
        var textBuf: [100]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&textBuf, "{s}/{s}", .{ pathToAnimationDir, image });
        const s = try sprite.createFromImg(imagePath, scale, offset);
        try frames.append(s);
    }

    return .{
        .fps = fps,
        .lastTime = 0,
        .current = 0,
        .frames = try frames.toOwnedSlice(),
    };
}
