const std = @import("std");

const box2d = @import("box2d.zig");
const collision = @import("collision.zig");
const config = @import("config.zig");
const data = @import("data.zig");
const damage = @import("damage.zig");
const entity = @import("entity.zig");
const polygon = @import("polygon.zig");
const runtime = @import("runtime.zig");
const rubble = @import("rubble.zig");
const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const vec = @import("vector.zig");

const allocator = @import("allocator.zig").allocator;

const ScheduledSpawn = struct {
    position: vec.Vec2,
    timerId: sdl.TimerID,
};

var templateSpriteUuid: ?u64 = null;
var scheduledSpawns = std.AutoHashMapUnmanaged(usize, ScheduledSpawn).empty;
var gravestonesToSpawn = thread_safe.ThreadSafeArrayList(usize).init(allocator);
const gravestoneHealth: f32 = 100;
const gravestoneRubbleSeed: u64 = 0x6A617665;

fn markForSpawn(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    if (param == null) {
        std.log.err("gravestone.markForSpawn: player ID is missing", .{});
        return 0;
    }

    const playerId: usize = @intFromPtr(param.?) - 1;
    gravestonesToSpawn.appendLocking(playerId) catch |err| {
        std.log.err("gravestone.markForSpawn: could not queue player {d}: {}", .{ playerId, err });
    };
    return 0;
}

pub fn init() !void {
    const spriteUuid = data.createSpriteFrom("gravestone") orelse {
        std.log.err("gravestone.init: sprite data is missing", .{});
        return error.GravestoneSpriteMissing;
    };
    templateSpriteUuid = spriteUuid;
}

pub fn warmColliderCache() !void {
    const spriteUuid = templateSpriteUuid orelse {
        std.log.err("gravestone.warmColliderCache: component is not initialized", .{});
        return error.GravestoneNotInitialized;
    };
    const templateSprite = sprite.getSprite(spriteUuid) orelse {
        std.log.err("gravestone.warmColliderCache: template sprite {d} is missing", .{spriteUuid});
        return error.GravestoneSpriteMissing;
    };

    _ = try polygon.triangulateCached(templateSprite);
}

pub fn schedule(playerId: usize, position: vec.Vec2) !void {
    const oldSpawn = scheduledSpawns.fetchRemove(playerId);
    if (oldSpawn != null) {
        std.log.warn("gravestone.schedule: replacing pending gravestone for player {d}", .{playerId});
        sdl.removeTimer(oldSpawn.?.value.timerId);
    }

    const timerId = sdl.addTimer(config.gravestoneSpawnDelayMs, markForSpawn, @ptrFromInt(playerId + 1));
    errdefer sdl.removeTimer(timerId);

    try scheduledSpawns.put(allocator, playerId, .{
        .position = position,
        .timerId = timerId,
    });
}

pub fn processScheduledSpawns() void {
    gravestonesToSpawn.mutex.lockUncancelable(runtime.io());
    defer gravestonesToSpawn.mutex.unlock(runtime.io());

    for (gravestonesToSpawn.list.items) |playerId| {
        const scheduled = scheduledSpawns.fetchRemove(playerId) orelse {
            std.log.warn("gravestone.processScheduledSpawns: no pending gravestone for player {d}", .{playerId});
            continue;
        };

        spawn(scheduled.value.position) catch |err| {
            std.log.err("gravestone.processScheduledSpawns: could not spawn gravestone for player {d}: {}", .{ playerId, err });
        };
    }
    gravestonesToSpawn.list.clearRetainingCapacity();
}

pub fn clearScheduledSpawns() void {
    var scheduledIterator = scheduledSpawns.valueIterator();
    while (scheduledIterator.next()) |scheduled| {
        sdl.removeTimer(scheduled.timerId);
    }
    scheduledSpawns.clearRetainingCapacity();

    gravestonesToSpawn.mutex.lockUncancelable(runtime.io());
    defer gravestonesToSpawn.mutex.unlock(runtime.io());
    gravestonesToSpawn.list.clearRetainingCapacity();
}

fn spawn(position: vec.Vec2) !void {
    const templateUuid = templateSpriteUuid orelse {
        std.log.err("gravestone.spawn: component is not initialized", .{});
        return error.GravestoneNotInitialized;
    };
    const spriteUuid = try sprite.createMutableCopy(templateUuid);
    errdefer sprite.cleanupLater(spriteUuid);

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = 0.5;
    shapeDef.density = 10;
    shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
    shapeDef.filter.maskBits = collision.MASK_DYNAMIC;

    const bodyDef = box2d.createDynamicBodyDef(position);
    const gravestone = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");
    const rubbleTemplateId = rubble.prepare(spriteUuid, gravestoneRubbleSeed) catch |err| {
        _ = entity.remove(gravestone.bodyId);
        return err;
    };
    damage.register(gravestone.bodyId, .{
        .model = .{ .health = .{
            .current = gravestoneHealth,
            .maximum = gravestoneHealth,
        } },
        .onDestroyed = .{ .spawn_rubble = rubbleTemplateId },
    }) catch |err| {
        _ = entity.remove(gravestone.bodyId);
        return err;
    };
}

pub fn cleanup() void {
    clearScheduledSpawns();
    scheduledSpawns.deinit(allocator);

    gravestonesToSpawn.mutex.lockUncancelable(runtime.io());
    gravestonesToSpawn.list.deinit();
    gravestonesToSpawn.mutex.unlock(runtime.io());

    const spriteUuid = templateSpriteUuid orelse {
        std.log.warn("gravestone.cleanup: component is not initialized", .{});
        return;
    };

    sprite.cleanupLater(spriteUuid);
    templateSpriteUuid = null;
}
