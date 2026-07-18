const std = @import("std");
const sdl = @import("sdl.zig");

const vec = @import("vector.zig");
const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const runtime = @import("runtime.zig");
const data = @import("data.zig");

pub const Particle = struct {
    bodyId: box2d.c.b2BodyId,
    spriteUuid: u64,
    state: ?box2d.State,
    color: ?sprite.Color,
    timerId: sdl.TimerID,
    scale: f32,
    stainRadius: f32,
    seed: u64,
};

pub var particles = thread_safe.ThreadSafeAutoArrayHashMap(box2d.c.b2BodyId, Particle).init(allocator);
var particlesToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(allocator);
var bloodStainTextureUpdates = std.AutoArrayHashMapUnmanaged(u64, vec.IRect).empty;
const bloodStainTextureUpdatesPerFrame: usize = 4;
var loadedBloodParticleConfig: ?data.ParticleData = null;

pub fn setBloodParticleConfig(cfg: data.ParticleData) void {
    loadedBloodParticleConfig = cfg;
}

fn requireBloodParticleConfig(functionName: []const u8) !data.ParticleData {
    const cfg = loadedBloodParticleConfig orelse {
        std.log.err("{s}: blood particle config has not been loaded", .{functionName});
        return error.BloodParticleConfigMissing;
    };
    return cfg;
}

pub fn currentBloodColor() !sprite.Color {
    const cfg = try requireBloodParticleConfig("currentBloodColor");
    return .{ .r = cfg.colorR, .g = cfg.colorG, .b = cfg.colorB };
}

pub fn create(bodyId: box2d.c.b2BodyId, lifetime: u32, color: ?sprite.Color, scale: f32, stainRadius: f32, seed: u64) !void {
    const cfg = try requireBloodParticleConfig("create");
    const particleSpriteUuid = try sprite.createFromImg(
        cfg.spritePath,
        .{ .x = scale, .y = scale },
        .{ .x = 0, .y = 0 },
    );
    errdefer sprite.cleanupLater(particleSpriteUuid);

    const id_int: usize = @bitCast(bodyId);
    const ptr: ?*anyopaque = @ptrFromInt(id_int);
    const timerId = sdl.addTimer(lifetime, markParticleForCleanup, ptr);
    errdefer _ = sdl.removeTimer(timerId);

    const particle = Particle{
        .bodyId = bodyId,
        .spriteUuid = particleSpriteUuid,
        .state = null,
        .color = color,
        .timerId = timerId,
        .scale = scale,
        .stainRadius = stainRadius,
        .seed = seed,
    };

    try particles.putLocking(bodyId, particle);
}

pub fn updateStates() void {
    particles.mutex.lockUncancelable(runtime.io());
    defer particles.mutex.unlock(runtime.io());
    for (particles.map.values()) |*p| {
        p.state = box2d.getState(p.bodyId);
    }
}

pub fn drawAll() !void {
    particles.mutex.lockUncancelable(runtime.io());
    defer particles.mutex.unlock(runtime.io());
    for (particles.map.values()) |*p| {
        try draw(p);
    }
}

fn draw(particle: *Particle) !void {
    const particleSprite = sprite.getSprite(particle.spriteUuid) orelse return;

    const currentState = box2d.getState(particle.bodyId);
    const state = box2d.getInterpolatedState(particle.state, currentState);

    const pos = camera.relativePosition(conv.m2Pixel(state.pos));

    try sprite.drawWithOptions(particleSprite, pos, state.rotAngle, false, false, 0, particle.color, null);
}

fn randomRange(min: f32, max: f32) f32 {
    return min + runtime.random().float(f32) * (max - min);
}

fn randomBaseBloodDirection() box2d.c.b2Vec2 {
    const roll = runtime.random().float(f32);
    var angle: f32 = undefined;
    if (roll < 0.68) {
        angle = -std.math.pi * 0.5 + randomRange(-std.math.pi * 0.42, std.math.pi * 0.42);
    } else if (roll < 0.9) {
        const side: f32 = if (runtime.random().float(f32) < 0.5) -1.0 else 1.0;
        angle = if (side < 0.0)
            std.math.pi + randomRange(-std.math.pi * 0.25, std.math.pi * 0.25)
        else
            randomRange(-std.math.pi * 0.25, std.math.pi * 0.25);
    } else {
        angle = runtime.random().float(f32) * std.math.pi * 2.0;
    }

    return .{
        .x = @cos(angle),
        .y = @sin(angle),
    };
}

fn randomBloodDirection(directionBias: vec.Vec2, biasStrength: f32) box2d.c.b2Vec2 {
    const base = randomBaseBloodDirection();
    const biasLength = vec.magnitude(directionBias);
    if (biasLength < 0.001 or biasStrength <= 0.0) {
        return base;
    }

    const bias = box2d.c.b2Vec2{
        .x = directionBias.x / biasLength,
        .y = directionBias.y / biasLength,
    };
    const mix = std.math.clamp(biasStrength, 0.0, 0.9) * (0.35 + runtime.random().float(f32) * 0.65);
    const mixed = box2d.c.b2Vec2{
        .x = base.x * (1.0 - mix) + bias.x * mix,
        .y = base.y * (1.0 - mix) + bias.y * mix,
    };
    const length = @sqrt(mixed.x * mixed.x + mixed.y * mixed.y);
    if (length < 0.001) {
        return base;
    }

    return .{
        .x = mixed.x / length,
        .y = mixed.y / length,
    };
}

fn randomSpawnPosition(pos: vec.Vec2) vec.Vec2 {
    const angle = runtime.random().float(f32) * std.math.pi * 2.0;
    const distance = runtime.random().float(f32) * 0.18;
    return .{
        .x = pos.x + @cos(angle) * distance,
        .y = pos.y + @sin(angle) * distance,
    };
}

fn createBloodParticlesBiased(pos: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2, directionBiasStrength: f32, inheritedVelocityScale: f32) !void {
    const cfg = try requireBloodParticleConfig("createBloodParticlesBiased");
    if (damage <= 0.0) {
        return;
    }

    const scaledParticleCount = @ceil(damage * cfg.particlesPerDamage);
    const particleCount: u32 = @min(cfg.maxParticles, @max(1, @as(u32, @intFromFloat(scaledParticleCount))));
    if (particleCount == 0) return;

    const bloodColor = sprite.Color{ .r = cfg.colorR, .g = cfg.colorG, .b = cfg.colorB };

    for (0..particleCount) |_| {
        const dir = randomBloodDirection(inheritedVelocity, directionBiasStrength);
        const spawnPos = randomSpawnPosition(pos);
        var bodyDef = box2d.createNonRotatingDynamicBodyDef(spawnPos);
        bodyDef.isBullet = true;
        bodyDef.linearDamping = cfg.linearDamping;
        bodyDef.gravityScale = cfg.gravityScale;

        const speedRoll = runtime.random().float(f32);
        const speedVariation = cfg.minSpeedVariation + (cfg.maxSpeedVariation - cfg.minSpeedVariation) * speedRoll * speedRoll;
        const inherited = box2d.mul(vec.toBox2d(inheritedVelocity), inheritedVelocityScale);
        bodyDef.linearVelocity = box2d.add(box2d.mul(dir, speedVariation), inherited);

        const bodyId = try box2d.createBody(bodyDef);

        var circleShapeDef = box2d.c.b2DefaultShapeDef();
        circleShapeDef.density = cfg.density;
        circleShapeDef.material.friction = cfg.friction;
        circleShapeDef.material.restitution = cfg.restitution;
        circleShapeDef.filter.groupIndex = cfg.groupIndex;
        circleShapeDef.filter.categoryBits = collision.CATEGORY_BLOOD;
        circleShapeDef.filter.maskBits = collision.MASK_BLOOD;
        circleShapeDef.enableHitEvents = true;
        circleShapeDef.enableContactEvents = true;

        const circleShape = box2d.c.b2Circle{
            .center = box2d.c.b2Vec2_zero,
            .radius = cfg.boxSize,
        };
        _ = box2d.c.b2CreateCircleShape(bodyId, &circleShapeDef, &circleShape);

        const scale = cfg.minScale + runtime.random().float(f32) * (cfg.maxScale - cfg.minScale);
        const stainRadius = cfg.minStainRadius + runtime.random().float(f32) * (cfg.maxStainRadius - cfg.minStainRadius);
        try create(bodyId, cfg.lifetimeMs, bloodColor, scale, stainRadius, runtime.random().int(u64));
    }
}

pub fn createBloodParticles(pos: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2) !void {
    try createBloodParticlesBiased(pos, damage, inheritedVelocity, 0.25, 0.35);
}

pub fn createBloodParticlesFromImpact(pos: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2) !void {
    try createBloodParticlesBiased(pos, damage, inheritedVelocity, 0.85, 0.55);
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

fn queueBloodStainTextureUpdate(spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const maybePendingRect = bloodStainTextureUpdates.getPtr(spriteUuid);
    if (maybePendingRect == null) {
        try bloodStainTextureUpdates.put(allocator, spriteUuid, dirtyRect);
        return;
    }

    const pendingRect = maybePendingRect.?;
    pendingRect.* = vec.irectUnion(pendingRect.*, dirtyRect);
}

pub fn processBloodStainTextureUpdates() void {
    var processed: usize = 0;
    while (processed < bloodStainTextureUpdatesPerFrame and bloodStainTextureUpdates.count() > 0) : (processed += 1) {
        const spriteUuid = bloodStainTextureUpdates.keys()[0];
        const dirtyRect = bloodStainTextureUpdates.values()[0];
        _ = bloodStainTextureUpdates.swapRemove(spriteUuid);

        sprite.updateTextureVisualRegionFromSurface(spriteUuid, dirtyRect) catch |err| {
            std.log.warn("processBloodStainTextureUpdates: sprite {d} update failed with {}", .{ spriteUuid, err });
        };
    }
}

fn stainSurface(bloodBodyId: box2d.c.b2BodyId) !void {
    const cfg = try requireBloodParticleConfig("stainSurface");

    const maybeParticle = particles.getLocking(bloodBodyId);
    if (maybeParticle == null) {
        return;
    }
    const bloodParticle = maybeParticle.?;

    if (!box2d.c.b2Body_IsValid(bloodBodyId)) {
        std.log.warn("stainSurface: blood body became invalid before staining", .{});
        return;
    }

    const bloodPos = box2d.c.b2Body_GetPosition(bloodBodyId);
    const bloodVec = vec.fromBox2d(bloodPos);
    const impactVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bloodBodyId));

    const bloodStainRadius = bloodParticle.stainRadius;
    const bloodColor = bloodParticle.color orelse sprite.Color{ .r = cfg.colorR, .g = cfg.colorG, .b = cfg.colorB };

    // Setup overlap query to find all entities within blood stain radius
    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = bloodStainRadius * 2.4,
    };

    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(bloodVec),
        .q = box2d.c.b2Rot_identity,
    };

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_BLOOD_QUERY;
    filter.maskBits = collision.MASK_BLOOD_QUERY;

    // Query for overlapping bodies
    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);

    // Stain all overlapping entities
    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            continue;
        }

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("stainSurface: target body has no entity", .{});
            continue;
        };
        if (ent.spriteUuids.len == 0) {
            std.log.warn("stainSurface: target entity has no sprites", .{});
            continue;
        }

        const state = box2d.getState(bodyId);
        const entityPos = vec.fromBox2d(state.pos);
        const rotation = state.rotAngle;
        const spriteUuid = ent.spriteUuids[0];

        const dirtyRect = try sprite.bloodSplatOnSurface(
            spriteUuid,
            bloodVec,
            bloodStainRadius,
            entityPos,
            rotation,
            bloodColor,
            impactVelocity,
            bloodParticle.seed,
        );
        if (dirtyRect == null) {
            continue;
        }

        try queueBloodStainTextureUpdate(spriteUuid, dirtyRect.?);
    }

    // Mark blood particle for cleanup
    const particleToCleanup = particles.fetchSwapRemoveLocking(bloodBodyId) orelse {
        return;
    };
    _ = sdl.removeTimer(particleToCleanup.value.timerId);
    sprite.cleanupLater(particleToCleanup.value.spriteUuid);
    if (box2d.c.b2Body_IsValid(bloodBodyId)) {
        box2d.c.b2Body_Disable(bloodBodyId);
    }
    try particlesToCleanup.appendLocking(bloodBodyId);
}

pub fn checkContacts() !void {
    const contactEvents = box2d.getContactEvents();

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

fn markParticleForCleanup(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const id_int: usize = @intFromPtr(param.?);
    const bodyId: box2d.c.b2BodyId = @bitCast(id_int);

    particlesToCleanup.appendLocking(bodyId) catch {};

    return 0;
}

pub fn cleanupParticles() !void {
    particlesToCleanup.mutex.lockUncancelable(runtime.io());
    defer particlesToCleanup.mutex.unlock(runtime.io());

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
    bloodStainTextureUpdates.clearAndFree(allocator);

    // Cleanup all remaining particles
    particles.mutex.lockUncancelable(runtime.io());
    for (particles.map.keys()) |bodyId| {
        const maybeParticle = particles.map.get(bodyId);
        if (maybeParticle) |p| {
            _ = sdl.removeTimer(p.timerId);
            sprite.cleanupLater(p.spriteUuid);
        }
        if (box2d.c.b2Body_IsValid(bodyId)) {
            box2d.c.b2DestroyBody(bodyId);
        }
    }
    particles.map.clearAndFree(allocator);
    particles.mutex.unlock(runtime.io());

    particlesToCleanup.mutex.lockUncancelable(runtime.io());
    defer particlesToCleanup.mutex.unlock(runtime.io());
    for (particlesToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    particlesToCleanup.list.clearAndFree();
}
