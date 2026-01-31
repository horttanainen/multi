const std = @import("std");
const sdl = @import("zsdl");
const box2d = @import("box2d.zig");
const vec = @import("vector.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const shared = @import("shared.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const player = @import("player.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");

pub const RopeState = enum {
    inactive,
    flying,
    attached,
};

pub const Rope = struct {
    state: RopeState,
    hookBodyId: box2d.c.b2BodyId,
};

pub var ropes: std.AutoArrayHashMapUnmanaged(usize, Rope) = .{};
var hookSpriteUuid: ?u64 = null;
var segmentSpriteUuid: ?u64 = null;

pub fn init() !void {
    hookSpriteUuid = try sprite.createFromImg(
        "items/ninja_rope/item.png",
        .{ .x = 0.3, .y = 0.3 },
        vec.izero,
    );
    segmentSpriteUuid = try sprite.createFromImg(
        "items/ninja_rope/segment.png",
        .{ .x = 1.0, .y = 1.0 },
        vec.izero,
    );
}

pub fn shootHook(playerId: usize, origin: vec.Vec2, direction: vec.Vec2) !void {
    releaseRope(playerId);

    const spriteUuid = hookSpriteUuid orelse return error.HookSpriteNotLoaded;

    const hookSprite = try sprite.createCopy(spriteUuid);

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 1.0;
    shapeDef.enableHitEvents = true;
    shapeDef.filter.categoryBits = collision.CATEGORY_HOOK;
    shapeDef.filter.maskBits = collision.MASK_HOOK;

    var bodyDef = box2d.createDynamicBodyDef(origin);
    bodyDef.isBullet = true;
    bodyDef.gravityScale = config.rope.hookGravityScale;

    const hookEntity = try entity.createFromImg(hookSprite, shapeDef, bodyDef, "hook");

    const normalizedDir = vec.normalize(.{
        .x = direction.x,
        .y = -direction.y,
    });
    const impulse = vec.mul(normalizedDir, config.rope.hookImpulse);
    box2d.c.b2Body_ApplyLinearImpulseToCenter(hookEntity.bodyId, vec.toBox2d(impulse), true);

    try ropes.put(shared.allocator, playerId, Rope{
        .state = .flying,
        .hookBodyId = hookEntity.bodyId,
    });
}

pub fn releaseRope(playerId: usize) void {
    const maybeRope = ropes.fetchSwapRemove(playerId);
    if (maybeRope) |kv| {
        const ropeState = kv.value;
        if (!box2d.c.b2Body_IsValid(ropeState.hookBodyId)) {
            return;
        }
        const maybeEntity = entity.entities.fetchSwapRemoveLocking(ropeState.hookBodyId);
        if (maybeEntity) |ent| {
            entity.cleanupOne(ent.value);
        }
    }
}

pub fn checkHookContacts() !void {
    const resources = try shared.getResources();
    const contactEvents = box2d.c.b2World_GetContactEvents(resources.worldId);

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];

        if (!box2d.c.b2Shape_IsValid(event.shapeIdA) or !box2d.c.b2Shape_IsValid(event.shapeIdB)) {
            continue;
        }

        const aFilter = box2d.c.b2Shape_GetFilter(event.shapeIdA);
        const bFilter = box2d.c.b2Shape_GetFilter(event.shapeIdB);

        const bodyIdA = box2d.c.b2Shape_GetBody(event.shapeIdA);
        const bodyIdB = box2d.c.b2Shape_GetBody(event.shapeIdB);

        if ((aFilter.categoryBits & collision.CATEGORY_HOOK) != 0) {
            const maybeRope = getRopePtrByBodyId(bodyIdA);
            if (maybeRope) |rope| {
                if (rope.state == .flying) {
                    attach(rope);
                }
            }
        }
        if ((bFilter.categoryBits & collision.CATEGORY_HOOK) != 0) {
            const maybeRope = getRopePtrByBodyId(bodyIdB);
            if (maybeRope) |rope| {
                if (rope.state == .flying) {
                    attach(rope);
                }
            }
        }
    }
}

fn getRopePtrByBodyId(bodyId: box2d.c.b2BodyId) ?*Rope {
    for (ropes.values()) |*rope| {
        if (!box2d.c.B2_ID_EQUALS(rope.hookBodyId, bodyId)) {
            continue;
        }
        return rope;
    }
    return null;
}

fn attach(rope: *Rope) void {
    rope.state = .attached;
    box2d.c.b2Body_SetType(rope.hookBodyId, box2d.c.b2_staticBody);
}

pub fn applyTension() void {
    for (ropes.keys(), ropes.values()) |playerId, ropeState| {
        if (ropeState.state != .attached) {
            continue;
        }

        const maybePlayer = player.players.get(playerId);
        if (maybePlayer == null) {
            continue;
        }
        const p = maybePlayer.?;

        const hookPosM: vec.Vec2 = vec.fromBox2d(box2d.c.b2Body_GetPosition(ropeState.hookBodyId));
        const playerPos = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
        const dx = hookPosM.x - playerPos.x;
        const dy = hookPosM.y - playerPos.y;
        const distance = @sqrt(dx * dx + dy * dy);

        if (distance <= config.rope.minLength) {
            return;
        }
        const direction = vec.Vec2{ .x = dx / distance, .y = dy / distance };
        const force = vec.mul(direction, config.rope.tensionMultiplier);
        box2d.c.b2Body_ApplyForceToCenter(p.bodyId, vec.toBox2d(force), true);
    }
}

pub fn drawRopes() !void {
    const resources = try shared.getResources();
    const segmentSprite = sprite.getSprite(segmentSpriteUuid orelse return) orelse return;

    for (ropes.keys(), ropes.values()) |playerId, ropeState| {
        if (ropeState.state == .inactive) continue;

        const maybePlayer = player.players.get(playerId);
        if (maybePlayer == null) continue;
        const p = maybePlayer.?;

        const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
        const playerPosPx = conv.m2Pixel(.{ .x = playerPosM.x, .y = playerPosM.y });

        const hookPosM: vec.Vec2 = vec.fromBox2d(box2d.c.b2Body_GetPosition(ropeState.hookBodyId));

        const hookPosPx = conv.m2Pixel(.{ .x = hookPosM.x, .y = hookPosM.y });

        const playerScreenPos = camera.relativePosition(playerPosPx);
        const hookScreenPos = camera.relativePosition(hookPosPx);

        try drawRopeSegments(resources.renderer, segmentSprite, playerScreenPos, hookScreenPos);
    }
}

fn drawRopeSegments(renderer: *sdl.Renderer, segmentSprite: sprite.Sprite, start: vec.IVec2, end: vec.IVec2) !void {
    const dx = @as(f32, @floatFromInt(end.x - start.x));
    const dy = @as(f32, @floatFromInt(end.y - start.y));
    const length = @sqrt(dx * dx + dy * dy);

    if (length < 1.0) return;

    const angle = std.math.atan2(dy, dx);
    const angleDegrees = angle * 180.0 / std.math.pi;

    const segmentWidth: f32 = config.rope.segmentWidth;
    const segmentHeight: f32 = @floatFromInt(segmentSprite.sizeP.y);

    const numSegments: usize = @max(1, @as(usize, @intFromFloat(length / segmentHeight)));
    const actualSegmentLength = length / @as(f32, @floatFromInt(numSegments));

    for (0..numSegments) |i| {
        const t = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(numSegments));

        const centerX = @as(f32, @floatFromInt(start.x)) + dx * t;
        const centerY = @as(f32, @floatFromInt(start.y)) + dy * t;

        const rect = sdl.Rect{
            .x = @as(i32, @intFromFloat(centerX - segmentWidth / 2.0)),
            .y = @as(i32, @intFromFloat(centerY - actualSegmentLength / 2.0)),
            .w = @as(i32, @intFromFloat(segmentWidth)),
            .h = @as(i32, @intFromFloat(actualSegmentLength)),
        };

        try sdl.renderCopyEx(
            renderer,
            segmentSprite.texture,
            null,
            &rect,
            angleDegrees + 90.0,
            null,
            sdl.RendererFlip.none,
        );
    }
}

pub fn cleanup() void {
    var iter = ropes.iterator();
    while (iter.next()) |entry| {
        const ropeState = entry.value_ptr.*;
        if (!box2d.c.b2Body_IsValid(ropeState.hookBodyId)) {
            continue;
        }
        const maybeEntity = entity.entities.fetchSwapRemoveLocking(ropeState.hookBodyId);
        if (maybeEntity) |ent| {
            entity.cleanupOne(ent.value);
        }
    }
    ropes.clearAndFree(shared.allocator);
}
