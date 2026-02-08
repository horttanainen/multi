const std = @import("std");

const vec = @import("vector.zig");
const shared = @import("shared.zig");
const sprite = @import("sprite.zig");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const time = @import("time.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const fs = @import("fs.zig");

pub const Animation = struct {
    fps: i32,
    current: usize,
    lastTime: f64,
    frames: []u64,
    spriteIndex: usize,  // Which sprite slot this animates (0, 1, 2, etc.)
    loop: bool,
};

pub const AnimationSet = struct {
    animations: std.StringHashMap(Animation),
    currentAnimations: []?*Animation,
    autoDestroy: bool, // Destroy entity when animation completes (for one-off effects)
};

var animationSets = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, AnimationSet).init(shared.allocator);

pub fn register(bodyId: box2d.c.b2BodyId, anim: Animation) !void {
    // Create a single-animation AnimationSet for one-off effects
    var animations = std.StringHashMap(Animation).init(shared.allocator);
    try animations.put("default", anim);

    try registerAnimationSet(bodyId, animations, "default", true);
}

pub fn registerAnimationSet(
    bodyId: box2d.c.b2BodyId,
    animations: std.StringHashMap(Animation),
    startKey: []const u8,
    autoDestroy: bool,
) !void {
    const maybeEntityPtr = entity.entities.getPtrLocking(bodyId);
    if (maybeEntityPtr) |entPtr| {
        entPtr.animated = true;

        const currentAnimations = try shared.allocator.alloc(?*Animation, entPtr.spriteUuids.len);
        for (currentAnimations) |*slot| {
            slot.* = null;
        }

        try animationSets.putLocking(bodyId, .{
            .animations = animations,
            .currentAnimations = currentAnimations,
            .autoDestroy = autoDestroy,
        });

        var animIter = animations.iterator();
        while (animIter.next()) |entry| {
            const key = entry.key_ptr.*;
            try switchAnimation(bodyId, key);
        }

        try switchAnimation(bodyId, startKey);
    }
}

pub fn switchAnimation(bodyId: box2d.c.b2BodyId, animationKey: []const u8) !void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    const animSet = animationSets.map.getPtr(bodyId) orelse return error.EntityNotAnimated;

    const anim = animSet.animations.getPtr(animationKey) orelse return error.AnimationNotFound;

    if (anim.spriteIndex < animSet.currentAnimations.len) {
        animSet.currentAnimations[anim.spriteIndex] = anim;
    }
}

pub fn animate() void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    var iter = animationSets.map.iterator();
    while (iter.next()) |entry| {
        const bodyId = entry.key_ptr.*;
        const animSet = entry.value_ptr;

        var anyFinished = false;

        for (animSet.currentAnimations) |maybeAnim| {
            if (maybeAnim) |anim| {
                const finished = advanceAnimation(anim);
                updateEntitySprite(bodyId, anim);

                // Track if any animation finished without looping
                if (finished and !anim.loop) {
                    anyFinished = true;
                }
            }
        }

        // Destroy entity if it's marked for auto-destroy and any animation finished without looping
        if (animSet.autoDestroy and anyFinished) {
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
        if (anim.spriteIndex < ent.spriteUuids.len) {
            ent.spriteUuids[anim.spriteIndex] = anim.frames[anim.current];
        }
    }
}

pub fn colorAllFrames(bodyId: box2d.c.b2BodyId, color: sprite.Color) !void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    const animSet = animationSets.map.getPtr(bodyId) orelse return error.EntityNotAnimated;

    var animIter = animSet.animations.valueIterator();
    while (animIter.next()) |anim| {
        for (anim.frames) |frameUuid| {
            try sprite.colorWhitePixels(frameUuid, color);
        }
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
            cleanupOne(anim.*);
        }
        animations.deinit();
        shared.allocator.free(animSet.value.currentAnimations);
    }
}

pub fn cleanup() void {
    animationSets.mutex.lock();
    defer animationSets.mutex.unlock();

    var animSetIter = animationSets.map.iterator();
    while (animSetIter.next()) |entry| {
        var animIter = entry.value_ptr.animations.valueIterator();
        while (animIter.next()) |anim| {
            cleanupOne(anim.*);
        }
        entry.value_ptr.animations.deinit();
        shared.allocator.free(entry.value_ptr.currentAnimations);
    }
    animationSets.map.clearAndFree();
}

pub fn cleanupOne(anim: Animation) void {
    for (anim.frames) |frameUuid| {
        sprite.cleanupLater(frameUuid);
    }
    shared.allocator.free(anim.frames);
}

pub fn load(pathToAnimationDir: []const u8, fps: i32, scale: vec.Vec2, offset: vec.IVec2, loop: bool, spriteIndex: usize) !Animation {
    const frameUuids = try fs.loadSpritesFromFolder(pathToAnimationDir, scale, offset);

    return .{
        .fps = fps,
        .lastTime = 0,
        .current = 0,
        .frames = frameUuids,
        .spriteIndex = spriteIndex,
        .loop = loop,
    };
}

pub fn copyAnimation(anim: Animation) !Animation {
    // Allocate new frames array
    const framesCopy = try shared.allocator.alloc(u64, anim.frames.len);

    // Deep copy each sprite frame
    for (anim.frames, 0..) |frameUuid, i| {
        framesCopy[i] = try sprite.createCopy(frameUuid);
    }

    return Animation{
        .fps = anim.fps,
        .current = 0,
        .lastTime = 0.0,
        .frames = framesCopy,
        .spriteIndex = anim.spriteIndex,
        .loop = anim.loop,
    };
}
