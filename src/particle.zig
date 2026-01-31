const std = @import("std");
const timer = @import("sdl_timer.zig");

const vec = @import("vector.zig");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");

pub const Particle = struct {
    bodyId: box2d.c.b2BodyId,
    spriteUuid: u64,
    state: ?box2d.State,
    color: ?sprite.Color,
    timerId: i32,
    scale: f32,
};

pub var particles = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, Particle).init(shared.allocator);
var particlesToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(shared.allocator);

pub fn create(bodyId: box2d.c.b2BodyId, lifetime: u32, color: ?sprite.Color, scale: f32) !void {
    const particleSpriteUuid = try sprite.createFromImg(
        "particles/circle.png",
        .{ .x = scale, .y = scale },
        .{ .x = 0, .y = 0 },
    );
    errdefer sprite.cleanupLater(particleSpriteUuid);

    const id_int: usize = @bitCast(bodyId);
    const ptr: ?*anyopaque = @ptrFromInt(id_int);
    const timerId = timer.addTimer(lifetime, markParticleForCleanup, ptr);
    errdefer _ = timer.removeTimer(timerId);

    const particle = Particle{
        .bodyId = bodyId,
        .spriteUuid = particleSpriteUuid,
        .state = null,
        .color = color,
        .timerId = timerId,
        .scale = scale,
    };

    try particles.putLocking(bodyId, particle);
}

pub fn updateStates() void {
    particles.mutex.lock();
    defer particles.mutex.unlock();
    for (particles.map.values()) |*p| {
        p.state = box2d.getState(p.bodyId);
    }
}

pub fn drawAll() !void {
    particles.mutex.lock();
    defer particles.mutex.unlock();
    for (particles.map.values()) |*p| {
        try draw(p);
    }
}

fn draw(particle: *Particle) !void {
    const particleSprite = sprite.getSprite(particle.spriteUuid) orelse return;

    const currentState = box2d.getState(particle.bodyId);
    const state = box2d.getInterpolatedState(particle.state, currentState);

    const pos = camera.relativePosition(
        conv.m2PixelPos(
            state.pos.x,
            state.pos.y,
            particleSprite.sizeM.x,
            particleSprite.sizeM.y,
        ),
    );

    try sprite.drawWithOptions(particleSprite, pos, state.rotAngle, false, false, 0, particle.color);
}

pub fn createBloodParticles(pos: vec.Vec2, damage: f32) !void {
    const cfg = config.bloodParticle;

    // More damage = more blood particles
    const particleCount: u32 = @min(cfg.maxParticles, @as(u32, @intFromFloat(damage * cfg.particlesPerDamage)));
    if (particleCount == 0) return;

    const bloodColor = sprite.Color{ .r = cfg.colorR, .g = cfg.colorG, .b = cfg.colorB };

    for (0..particleCount) |i| {
        const angle = std.math.degreesToRadians(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(particleCount)) * 360);
        const dir = box2d.c.b2Vec2{ .x = std.math.sin(angle), .y = std.math.cos(angle) };

        var bodyDef = box2d.createNonRotatingDynamicBodyDef(pos);
        bodyDef.isBullet = true;
        bodyDef.linearDamping = cfg.linearDamping;
        bodyDef.gravityScale = cfg.gravityScale;

        // Random velocity variation
        const speedVariation = cfg.minSpeedVariation + std.crypto.random.float(f32) * (cfg.maxSpeedVariation - cfg.minSpeedVariation);
        bodyDef.linearVelocity = box2d.mul(dir, speedVariation);

        const bodyId = try box2d.createBody(bodyDef);

        var boxShapeDef = box2d.c.b2DefaultShapeDef();
        boxShapeDef.density = cfg.density;
        boxShapeDef.friction = cfg.friction;
        boxShapeDef.restitution = cfg.restitution;
        boxShapeDef.filter.groupIndex = cfg.groupIndex;
        boxShapeDef.filter.categoryBits = collision.CATEGORY_BLOOD;
        boxShapeDef.filter.maskBits = collision.MASK_BLOOD;
        boxShapeDef.enableHitEvents = true;
        boxShapeDef.enableContactEvents = true;

        const boxShape = box2d.c.b2MakeBox(cfg.boxSize, cfg.boxSize);
        _ = box2d.c.b2CreatePolygonShape(bodyId, &boxShapeDef, &boxShape);

        // Random scale
        const scale = cfg.minScale + std.crypto.random.float(f32) * (cfg.maxScale - cfg.minScale);
        try create(bodyId, cfg.lifetimeMs, bloodColor, scale);
    }
}

const OverlapContext = struct {
    bodies: [100]box2d.c.b2BodyId,
    count: usize,
};

fn overlapCallback(shapeId: box2d.c.b2ShapeId, context: ?*anyopaque) callconv(.c) bool {
    const ctx: *OverlapContext = @ptrCast(@alignCast(context.?));

    // Get the body from the shape
    const bodyId = box2d.c.b2Shape_GetBody(shapeId);

    // Check if we already have this body (multiple shapes can belong to same body)
    for (ctx.bodies[0..ctx.count]) |existingBody| {
        if (box2d.c.b2Body_IsValid(existingBody) and
            box2d.c.B2_ID_EQUALS(existingBody, bodyId))
        {
            return true; // Already added, skip
        }
    }

    // Add body if we have space
    if (ctx.count < 100) {
        ctx.bodies[ctx.count] = bodyId;
        ctx.count += 1;
    }

    return true; // Continue the query
}

fn stainSurface(bloodBodyId: box2d.c.b2BodyId) !void {
    const resources = try shared.getResources();
    const cfg = config.bloodParticle;

    // Get blood particle to access its scale
    const maybeParticle = particles.getLocking(bloodBodyId);
    if (maybeParticle == null) return;
    const particleScale = maybeParticle.?.scale;

    // Get blood particle position
    const bloodPos = box2d.c.b2Body_GetPosition(bloodBodyId);
    const bloodVec = vec.fromBox2d(bloodPos);

    // Blood stain radius proportional to particle scale
    const baseStainRadius = cfg.minStainRadius + std.crypto.random.float(f32) * (cfg.maxStainRadius - cfg.minStainRadius);
    const bloodStainRadius = baseStainRadius * particleScale;
    const bloodColor = sprite.Color{ .r = cfg.colorR, .g = cfg.colorG, .b = cfg.colorB };

    // Setup overlap query to find all entities within blood stain radius
    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = bloodStainRadius,
    };

    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(bloodVec),
        .q = box2d.c.b2Rot_identity,
    };

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_BLOOD_QUERY;
    filter.maskBits = collision.MASK_BLOOD_QUERY;

    // Query for overlapping bodies
    _ = box2d.c.b2World_OverlapCircle(
        resources.worldId,
        &circle,
        transform,
        filter,
        overlapCallback,
        &context,
    );

    // Stain all overlapping entities
    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            continue;
        }

        const maybeEntity = entity.entities.getPtrLocking(bodyId);
        if (maybeEntity) |ent| {
            if (ent.spriteUuids.len == 0) {
                continue;
            }

            const state = box2d.getState(bodyId);
            const entityPos = vec.fromBox2d(state.pos);
            const rotation = state.rotAngle;

            try sprite.colorCircleOnSurface(ent.spriteUuids[0], bloodVec, bloodStainRadius, entityPos, rotation, bloodColor);

            try sprite.updateTextureFromSurface(ent.spriteUuids[0]);
        }
    }

    // Mark blood particle for cleanup
    const maybeParticleToCleanup = particles.fetchSwapRemoveLocking(bloodBodyId);
    if (maybeParticleToCleanup) |p| {
        _ = timer.removeTimer(p.value.timerId);
        sprite.cleanupLater(p.value.spriteUuid);
        try particlesToCleanup.appendLocking(bloodBodyId);
    }
}

pub fn checkContacts() !void {
    const resources = try shared.getResources();
    const contactEvents = box2d.c.b2World_GetContactEvents(resources.worldId);

    // Check begin contact events for blood particles
    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];

        if (!box2d.c.b2Shape_IsValid(event.shapeIdA) or !box2d.c.b2Shape_IsValid(event.shapeIdB)) {
            continue;
        }

        const bodyIdA = box2d.c.b2Shape_GetBody(event.shapeIdA);
        const bodyIdB = box2d.c.b2Shape_GetBody(event.shapeIdB);

        // Check for blood particle collisions
        if (particles.getLocking(bodyIdA) != null) {
            try stainSurface(bodyIdA);
            continue;
        }
        if (particles.getLocking(bodyIdB) != null) {
            try stainSurface(bodyIdB);
            continue;
        }
    }

    // Check hit events for blood particles
    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];

        if (!box2d.c.b2Shape_IsValid(event.shapeIdA) or !box2d.c.b2Shape_IsValid(event.shapeIdB)) {
            continue;
        }

        const bodyIdA = box2d.c.b2Shape_GetBody(event.shapeIdA);
        const bodyIdB = box2d.c.b2Shape_GetBody(event.shapeIdB);

        // Check for blood particle collisions
        if (particles.getLocking(bodyIdA) != null) {
            try stainSurface(bodyIdA);
            continue;
        }
        if (particles.getLocking(bodyIdB) != null) {
            try stainSurface(bodyIdB);
            continue;
        }
    }
}

fn markParticleForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const id_int: usize = @intFromPtr(param.?);
    const bodyId: box2d.c.b2BodyId = @bitCast(id_int);

    particlesToCleanup.appendLocking(bodyId) catch {};

    return 0;
}

pub fn cleanupParticles() !void {
    particlesToCleanup.mutex.lock();
    defer particlesToCleanup.mutex.unlock();

    for (particlesToCleanup.list.items) |bodyId| {
        const maybeParticle = particles.fetchSwapRemoveLocking(bodyId);
        if (maybeParticle) |p| {
            sprite.cleanupLater(p.value.spriteUuid);
        }
        if (box2d.c.b2Body_IsValid(bodyId)) {
            box2d.c.b2DestroyBody(bodyId);
        }
    }

    particlesToCleanup.list.clearAndFree();
}

pub fn cleanup() void {
    // Cleanup all remaining particles
    particles.mutex.lock();
    for (particles.map.keys()) |bodyId| {
        const maybeParticle = particles.map.get(bodyId);
        if (maybeParticle) |p| {
            _ = timer.removeTimer(p.timerId);
            sprite.cleanupLater(p.spriteUuid);
        }
        if (box2d.c.b2Body_IsValid(bodyId)) {
            box2d.c.b2DestroyBody(bodyId);
        }
    }
    particles.map.clearAndFree();
    particles.mutex.unlock();

    particlesToCleanup.mutex.lock();
    defer particlesToCleanup.mutex.unlock();
    for (particlesToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    particlesToCleanup.list.clearAndFree();
}
