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
    bodyId: box2d.c.b2BodyId,
    animation: Animation,
    loop: bool,
};

var animationInstances = thread_safe.ThreadSafeArrayList(AnimationInstance).init(shared.allocator);

pub fn register(bodyId: box2d.c.b2BodyId, anim: Animation, loop: bool) !void {
    try animationInstances.appendLocking(.{
        .bodyId = bodyId,
        .animation = anim,
        .loop = loop,
    });
}

pub fn animate() void {
    animationInstances.mutex.lock();
    defer animationInstances.mutex.unlock();

    for (animationInstances.list.items) |*instance| {
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
                }
            }

            // Update entity sprite
            const maybeEntity = entity.entities.getPtrLocking(instance.bodyId);
            if (maybeEntity) |ent| {
                ent.sprite = instance.animation.frames[instance.animation.current];
            }

            instance.animation.lastTime = timeNowS;
        }
    }
}

pub fn cleanup() void {
    animationInstances.mutex.lock();
    for (animationInstances.list.items) |instance| {
        for (instance.animation.frames) |frame| {
            sprite.cleanup(frame);
        }
        shared.allocator.free(instance.animation.frames);
    }
    animationInstances.mutex.unlock();

    animationInstances.replaceLocking(std.array_list.Managed(AnimationInstance).init(shared.allocator));
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
