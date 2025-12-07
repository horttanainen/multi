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

pub const AnimationSet = struct {
    animations: std.StringHashMap(Animation),
    currentKey: []const u8,
    currentAnimation: *Animation,
    loop: bool,
    autoDestroy: bool, // Destroy entity when animation completes (for one-off effects)
};

var animationSets = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, AnimationSet).init(shared.allocator);

pub fn register(bodyId: box2d.c.b2BodyId, anim: Animation, loop: bool) !void {
    // Create a single-animation AnimationSet for one-off effects
    var animations = std.StringHashMap(Animation).init(shared.allocator);
    try animations.put("default", anim);

    const currentAnim = animations.getPtr("default").?;

    try animationSets.putLocking(bodyId, .{
        .animations = animations,
        .currentKey = "default",
        .currentAnimation = currentAnim,
        .loop = loop,
        .autoDestroy = true, // One-off animations auto-destroy when finished
    });

    const maybeEntityPtr = entity.entities.getPtrLocking(bodyId);
    if (maybeEntityPtr) |entPtr| {
        entPtr.animated = true;
    }
}

pub fn registerAnimationSet(
    bodyId: box2d.c.b2BodyId,
    animations: std.StringHashMap(Animation),
    startKey: []const u8,
    loop: bool,
) !void {
    const currentAnim = animations.getPtr(startKey) orelse return error.AnimationNotFound;

    try animationSets.putLocking(bodyId, .{
        .animations = animations,
        .currentKey = startKey,
        .currentAnimation = currentAnim,
        .loop = loop,
        .autoDestroy = false, // Multi-animation entities don't auto-destroy
    });

    const maybeEntityPtr = entity.entities.getPtrLocking(bodyId);
    if (maybeEntityPtr) |entPtr| {
        entPtr.animated = true;
    }
}

pub fn switchAnimation(bodyId: box2d.c.b2BodyId, animationKey: []const u8) !void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    const animSet = animationSets.map.getPtr(bodyId) orelse return error.EntityNotAnimated;

    // Don't switch if already playing this animation
    if (std.mem.eql(u8, animSet.currentKey, animationKey)) {
        return;
    }

    // Get new animation
    const newAnim = animSet.animations.getPtr(animationKey) orelse return error.AnimationNotFound;

    // Switch and reset
    animSet.currentKey = animationKey;
    animSet.currentAnimation = newAnim;
    animSet.currentAnimation.current = 0;
    animSet.currentAnimation.lastTime = time.now();
}

pub fn animate() void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    var iter = animationSets.map.iterator();
    while (iter.next()) |entry| {
        const bodyId = entry.key_ptr.*;
        const animSet = entry.value_ptr;

        // Advance current animation
        const finished = advanceAnimation(animSet.currentAnimation);
        updateEntitySprite(bodyId, animSet.currentAnimation);

        // Destroy entity if it's marked for auto-destroy and animation finished without looping
        if (animSet.autoDestroy and finished and !animSet.loop) {
            const maybeE = entity.entities.getLocking(bodyId);
            if (maybeE) |e| {
                entity.cleanupLater(e);
            }
        }
    }
}

// returns true if animation finished (looped)
fn advanceAnimation(anim: *Animation) bool {
    const timeNowS = time.now();
    const timePassedS = timeNowS - anim.lastTime;
    const fpsSeconds = 1.0 / @as(f64, @floatFromInt(anim.fps));

    if (timePassedS > fpsSeconds) {
        const nextFrame = anim.current + 1;
        if (nextFrame >= anim.frames.len) {
            anim.current = 0; // Loop
            anim.lastTime = timeNowS;
            return true; // Reached end
        } else {
            anim.current = nextFrame;
            anim.lastTime = timeNowS;
            return false; // Still playing
        }
    }
    return false;
}

fn updateEntitySprite(bodyId: box2d.c.b2BodyId, anim: *Animation) void {
    const maybeEntity = entity.entities.getPtrLocking(bodyId);
    if (maybeEntity) |ent| {
        ent.sprite = anim.frames[anim.current];
    }
}

pub fn cleanupAnimationFrames(bodyId: box2d.c.b2BodyId) void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    const maybeAnimSet = animationSets.map.fetchSwapRemove(bodyId);
    if (maybeAnimSet) |animSet| {
        var animations = animSet.value.animations;
        var animIter = animations.valueIterator();
        while (animIter.next()) |anim| {
            for (anim.frames) |frame| {
                sprite.cleanup(frame);
            }
            shared.allocator.free(anim.frames);
        }
        animations.deinit();
    }
}

pub fn cleanup() void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    var animSetIter = animationSets.map.iterator();
    while (animSetIter.next()) |entry| {
        var animIter = entry.value_ptr.animations.valueIterator();
        while (animIter.next()) |anim| {
            for (anim.frames) |frame| {
                sprite.cleanup(frame);
            }
            shared.allocator.free(anim.frames);
        }
        entry.value_ptr.animations.deinit();
    }
    animationSets.map.clearAndFree();
}

pub fn load(pathToAnimationDir: []const u8, fps: i32, scale: vec.Vec2, offset: vec.IVec2) !Animation {
    var dir = try std.fs.cwd().openDir(pathToAnimationDir, .{});
    defer dir.close();

    var images = std.array_list.Managed([]const u8).init(shared.allocator);
    defer images.deinit();
    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            // Skip .DS_Store files
            if (!std.mem.eql(u8, dirContent.name, ".DS_Store")) {
                try images.append(dirContent.name);
            }
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
