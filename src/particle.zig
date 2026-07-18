const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const runtime = @import("runtime.zig");
const sprite = @import("sprite.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

pub const StainBehavior = struct {
    color: sprite.Color,
    radius: f32,
    target_mask: u64,
    query_radius_scale: f32 = 2.4,
    destroy_on_contact: bool = true,
};

pub const Behaviors = struct {
    stain: ?StainBehavior = null,
};

pub const CircleSpawn = struct {
    position: vec.Vec2,
    velocity: vec.Vec2,
    visual_scale: f32,
    radius: ?f32 = null,
    lifetime_ms: u32,
    color: ?sprite.Color = null,
    linear_damping: f32 = 0,
    gravity_scale: f32 = 1,
    density: f32 = 1,
    friction: f32 = 0,
    restitution: f32 = 0,
    group_index: i32 = 0,
    category_bits: u64,
    mask_bits: u64,
    is_bullet: bool = false,
    behaviors: Behaviors = .{},
    seed: u64,
};

pub const Particle = struct {
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
    color: ?sprite.Color,
    visual_scale: f32,
    expires_at: f64,
    behaviors: Behaviors,
    seed: u64,
};

pub var particles = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, Particle).init(allocator);
var particlesToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(allocator);
var stainTextureUpdates = std.AutoArrayHashMapUnmanaged(u64, vec.IRect).empty;
const stainTextureUpdatesPerFrame: usize = 4;
var circleSpriteUuid: ?u64 = null;

pub fn init(circleSpritePath: []const u8) !void {
    if (circleSpriteUuid != null) {
        return;
    }

    circleSpriteUuid = try sprite.createFromImg(
        circleSpritePath,
        .{ .x = 1, .y = 1 },
        vec.izero,
    );
}

fn validateBehaviors(behaviors: Behaviors) !void {
    const stain = behaviors.stain orelse return;
    if (stain.radius <= 0 or stain.query_radius_scale <= 0) {
        std.log.err("validateBehaviors: stain radius and query scale must be positive", .{});
        return error.InvalidStainBehavior;
    }
}

pub fn spawnCircle(spawn: CircleSpawn) !box2d.c.b2BodyId {
    const spriteUuid = circleSpriteUuid orelse {
        std.log.err("spawnCircle: particle component is not initialized", .{});
        return error.ParticleComponentNotInitialized;
    };
    if (spawn.visual_scale <= 0) {
        std.log.err("spawnCircle: visual scale must be positive", .{});
        return error.InvalidCircleParticleSize;
    }

    const circleSprite = sprite.getSprite(spriteUuid) orelse {
        std.log.err("spawnCircle: shared circle sprite {d} is missing", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const defaultRadius = @max(circleSprite.sizeM.x, circleSprite.sizeM.y) * spawn.visual_scale * 0.5;
    const radius = spawn.radius orelse defaultRadius;
    if (radius <= 0) {
        std.log.err("spawnCircle: collider radius must be positive", .{});
        return error.InvalidCircleParticleSize;
    }
    try validateBehaviors(spawn.behaviors);

    var bodyDef = box2d.createNonRotatingDynamicBodyDef(spawn.position);
    bodyDef.isBullet = spawn.is_bullet;
    bodyDef.linearDamping = spawn.linear_damping;
    bodyDef.gravityScale = spawn.gravity_scale;
    bodyDef.linearVelocity = vec.toBox2d(spawn.velocity);

    const bodyId = try box2d.createBody(bodyDef);
    errdefer box2d.c.b2DestroyBody(bodyId);

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.density = spawn.density;
    shapeDef.material.friction = spawn.friction;
    shapeDef.material.restitution = spawn.restitution;
    shapeDef.filter.groupIndex = spawn.group_index;
    shapeDef.filter.categoryBits = spawn.category_bits;
    shapeDef.filter.maskBits = spawn.mask_bits;
    shapeDef.enableHitEvents = spawn.behaviors.stain != null;
    shapeDef.enableContactEvents = spawn.behaviors.stain != null;

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = radius,
    };
    _ = box2d.c.b2CreateCircleShape(bodyId, &shapeDef, &circle);

    try particles.putLocking(bodyId, .{
        .bodyId = bodyId,
        .state = null,
        .color = spawn.color,
        .visual_scale = spawn.visual_scale,
        .expires_at = time.now() + @as(f64, @floatFromInt(spawn.lifetime_ms)) / 1000.0,
        .behaviors = spawn.behaviors,
        .seed = spawn.seed,
    });

    return bodyId;
}

pub fn updateStates() void {
    particles.mutex.lockUncancelable(runtime.io());
    defer particles.mutex.unlock(runtime.io());

    for (particles.map.values()) |*particle| {
        particle.state = box2d.getState(particle.bodyId);
    }
}

pub fn drawAll() !void {
    const spriteUuid = circleSpriteUuid orelse {
        std.log.err("drawAll: particle component is not initialized", .{});
        return error.ParticleComponentNotInitialized;
    };
    const circleSprite = sprite.getSprite(spriteUuid) orelse {
        std.log.err("drawAll: shared circle sprite {d} is missing", .{spriteUuid});
        return error.SpriteNotFound;
    };

    particles.mutex.lockUncancelable(runtime.io());
    defer particles.mutex.unlock(runtime.io());

    for (particles.map.values()) |*particle| {
        const currentState = box2d.getState(particle.bodyId);
        const state = box2d.getInterpolatedState(particle.state, currentState);
        const pos = camera.relativePosition(conv.m2Pixel(state.pos));
        const scale = vec.Vec2{ .x = particle.visual_scale, .y = particle.visual_scale };
        try sprite.drawWithScale(circleSprite, pos, state.rotAngle, scale, particle.color);
    }
}

const OverlapContext = struct {
    bodies: [100]box2d.c.b2BodyId,
    count: usize,
};

fn overlapCallback(shapeId: box2d.c.b2ShapeId, context: ?*anyopaque) callconv(.c) bool {
    const ctx: *OverlapContext = @ptrCast(@alignCast(context.?));
    const bodyId = box2d.c.b2Shape_GetBody(shapeId);

    for (ctx.bodies[0..ctx.count]) |existingBody| {
        if (box2d.c.b2Body_IsValid(existingBody) and box2d.c.B2_ID_EQUALS(existingBody, bodyId)) {
            return true;
        }
    }

    if (ctx.count < ctx.bodies.len) {
        ctx.bodies[ctx.count] = bodyId;
        ctx.count += 1;
    }
    return true;
}

fn queueStainTextureUpdate(spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const pendingRect = stainTextureUpdates.getPtr(spriteUuid);
    if (pendingRect == null) {
        try stainTextureUpdates.put(allocator, spriteUuid, dirtyRect);
        return;
    }

    pendingRect.?.* = vec.irectUnion(pendingRect.?.*, dirtyRect);
}

pub fn processStainTextureUpdates() void {
    if (stainTextureUpdates.count() == 0) {
        return;
    }

    var processed: usize = 0;
    while (processed < stainTextureUpdatesPerFrame and stainTextureUpdates.count() > 0) : (processed += 1) {
        const spriteUuid = stainTextureUpdates.keys()[0];
        const dirtyRect = stainTextureUpdates.values()[0];
        _ = stainTextureUpdates.swapRemove(spriteUuid);

        sprite.updateTextureVisualRegionFromSurface(spriteUuid, dirtyRect) catch |err| {
            std.log.warn("processStainTextureUpdates: sprite {d} update failed with {}", .{ spriteUuid, err });
        };
    }
}

fn stainSurfaces(particle: Particle, stain: StainBehavior) !void {
    if (!box2d.c.b2Body_IsValid(particle.bodyId)) {
        std.log.warn("stainSurfaces: particle body became invalid before staining", .{});
        return;
    }

    const particlePosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(particle.bodyId));
    const impactVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(particle.bodyId));
    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = stain.radius * stain.query_radius_scale,
    };
    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(particlePosition),
        .q = box2d.c.b2Rot_identity,
    };
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = stain.target_mask;
    filter.maskBits = stain.target_mask;

    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);

    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            continue;
        }

        const target = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("stainSurfaces: target body has no entity", .{});
            continue;
        };
        if (target.spriteUuids.len == 0) {
            std.log.warn("stainSurfaces: target entity has no sprites", .{});
            continue;
        }

        const state = box2d.getState(bodyId);
        const spriteUuid = target.spriteUuids[0];
        const dirtyRect = try sprite.stainSplatOnSurface(
            spriteUuid,
            particlePosition,
            stain.radius,
            vec.fromBox2d(state.pos),
            state.rotAngle,
            stain.color,
            impactVelocity,
            particle.seed,
        );
        if (dirtyRect == null) {
            continue;
        }

        try queueStainTextureUpdate(spriteUuid, dirtyRect.?);
    }
}

fn processContact(bodyId: box2d.c.b2BodyId) !bool {
    const particle = particles.getLocking(bodyId) orelse {
        return false;
    };
    const stain = particle.behaviors.stain orelse {
        return false;
    };

    try stainSurfaces(particle, stain);
    if (!stain.destroy_on_contact) {
        return true;
    }

    _ = particles.fetchSwapRemoveLocking(bodyId);
    if (box2d.c.b2Body_IsValid(bodyId)) {
        box2d.c.b2Body_Disable(bodyId);
    }
    try particlesToCleanup.appendLocking(bodyId);
    return true;
}

fn processShapeContact(shapeIdA: box2d.c.b2ShapeId, shapeIdB: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) {
        return;
    }

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);
    if (try processContact(bodyIdA)) {
        return;
    }
    _ = try processContact(bodyIdB);
}

pub fn checkContacts() !void {
    const contactEvents = box2d.getContactEvents();

    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try processShapeContact(event.shapeIdA, event.shapeIdB);
    }

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        try processShapeContact(event.shapeIdA, event.shapeIdB);
    }
}

fn destroyParticleBody(bodyId: box2d.c.b2BodyId) void {
    if (box2d.c.b2Body_IsValid(bodyId)) {
        box2d.c.b2DestroyBody(bodyId);
    }
}

pub fn cleanupParticles() !void {
    {
        particlesToCleanup.mutex.lockUncancelable(runtime.io());
        defer particlesToCleanup.mutex.unlock(runtime.io());

        for (particlesToCleanup.list.items) |bodyId| {
            _ = particles.fetchSwapRemoveLocking(bodyId);
            destroyParticleBody(bodyId);
        }
        particlesToCleanup.list.clearRetainingCapacity();
    }

    var expiredBodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    defer expiredBodyIds.deinit();

    const now = time.now();
    {
        particles.mutex.lockUncancelable(runtime.io());
        defer particles.mutex.unlock(runtime.io());

        for (particles.map.values()) |particle| {
            if (particle.expires_at <= now) {
                try expiredBodyIds.append(particle.bodyId);
            }
        }
    }

    for (expiredBodyIds.items) |bodyId| {
        _ = particles.fetchSwapRemoveLocking(bodyId);
        destroyParticleBody(bodyId);
    }
}

pub fn cleanup() void {
    stainTextureUpdates.clearAndFree(allocator);

    particles.mutex.lockUncancelable(runtime.io());
    for (particles.map.keys()) |bodyId| {
        destroyParticleBody(bodyId);
    }
    particles.map.clearAndFree(allocator);
    particles.mutex.unlock(runtime.io());

    particlesToCleanup.mutex.lockUncancelable(runtime.io());
    defer particlesToCleanup.mutex.unlock(runtime.io());
    for (particlesToCleanup.list.items) |bodyId| {
        destroyParticleBody(bodyId);
    }
    particlesToCleanup.list.clearAndFree();
}
