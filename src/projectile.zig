const std = @import("std");
const timer = @import("sdl_timer.zig");

const audio = @import("audio.zig");
const vec = @import("vector.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const animation = @import("animation.zig");
const conv = @import("conversion.zig");
const player = @import("player.zig");
const particle = @import("particle.zig");

pub const Explosion = struct {
    sound: audio.Audio,
    animation: animation.Animation,
    blastPower: f32,
    blastRadius: f32,
    particleCount: u32,
    particleDensity: f32,
    particleFriction: f32,
    particleRestitution: f32,
    particleRadius: f32,
    particleLinearDamping: f32,
    particleGravityScale: f32,
};

pub var explosions = std.AutoArrayHashMap(box2d.c.b2BodyId, Explosion).init(shared.allocator);
pub var propulsions = std.AutoArrayHashMap(box2d.c.b2BodyId, f32).init(shared.allocator);

pub var id: usize = 1;
pub const Shrapnel = struct {
    id: usize,
    cleaned: bool,
    bodies: []box2d.c.b2BodyId,
    timerId: i32,
};

pub var shrapnel = thread_safe.ThreadSafeArrayList(Shrapnel).init(shared.allocator);

var shrapnelToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(shared.allocator);

fn createExplosionAnimation(pos: vec.Vec2, anim: animation.Animation) !void {
    const animCopy = try animation.copyAnimation(anim);

    var bodyDef = box2d.createStaticBodyDef(pos);

    const randomAngle = std.crypto.random.float(f32) * 2.0 * std.math.pi;
    bodyDef.rotation = box2d.c.b2MakeRot(randomAngle);

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.isSensor = true;
    shapeDef.filter.categoryBits = 0; // Don't collide with anything
    shapeDef.filter.maskBits = 0;

    // Use first frame as the sprite
    const firstFrame = animCopy.frames[0];

    // Create a simple box shape for the explosion entity
    const boxShape = box2d.c.b2MakeBox(0.5, 0.5);
    const explosionEntity = try entity.createFromShape(firstFrame, boxShape, shapeDef, bodyDef, "explosion");

    try animation.register(explosionEntity.bodyId, animCopy);
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

fn damageTerrainInRadius(pos: vec.Vec2, radius: f32) !void {
    const resources = try shared.getResources();

    // Setup overlap query
    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = radius,
    };

    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(pos),
        .q = box2d.c.b2Rot_identity,
    };

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_EXPLOSION_QUERY;
    filter.maskBits = collision.MASK_EXPLOSION_QUERY;

    // Query for overlapping bodies
    _ = box2d.c.b2World_OverlapCircle(
        resources.worldId,
        &circle,
        transform,
        filter,
        overlapCallback,
        &context,
    );

    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;

        // Get the entity
        const maybeEntity = entity.entities.getPtrLocking(bodyId);
        if (maybeEntity) |ent| {
            // Get entity position and rotation
            const state = box2d.getState(bodyId);
            const entityPos = vec.fromBox2d(state.pos);
            const rotation = state.rotAngle;

            if (ent.spriteUuids.len == 0) continue;
            const firstSprite = sprite.getSprite(ent.spriteUuids[0]) orelse continue;

            try sprite.removeCircleFromSurface(firstSprite, pos, radius, entityPos, rotation);

            try sprite.updateTextureFromSurface(ent.spriteUuids[0]);

            const stillExists = try entity.regenerateColliders(ent);

            if (!stillExists) {
                entity.cleanupLater(ent.*);
            }
        }
    }
}

fn damagePlayersInRadius(pos: vec.Vec2, radius: f32) !void {
    for (player.players.values()) |*p| {
        if (!box2d.c.b2Body_IsValid(p.bodyId)) {
            continue;
        }

        const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));

        const dx = playerPosM.x - pos.x;
        const dy = playerPosM.y - pos.y;
        const distance = @sqrt(dx * dx + dy * dy);

        if (distance <= radius) {
            const damage = 100.0 - (99.0 * distance / radius);

            try player.damage(p, damage);
        }
    }
}


fn createExplosion(pos: vec.Vec2, explosion: Explosion) ![]box2d.c.b2BodyId {
    try audio.playFor(explosion.sound);

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(shared.allocator);

    for (0..explosion.particleCount) |i| {
        const angle = std.math.degreesToRadians(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(explosion.particleCount)) * 360);
        const dir = box2d.c.b2Vec2{ .x = std.math.sin(angle), .y = std.math.cos(angle) };

        var bodyDef = box2d.createNonRotatingDynamicBodyDef(pos);
        bodyDef.isBullet = true;
        bodyDef.linearDamping = explosion.particleLinearDamping;
        bodyDef.gravityScale = explosion.particleGravityScale;
        bodyDef.linearVelocity = box2d.mul(dir, explosion.blastPower);

        const bodyId = try box2d.createBody(bodyDef);

        var circleShapeDef = box2d.c.b2DefaultShapeDef();
        circleShapeDef.density = explosion.particleDensity;
        circleShapeDef.friction = explosion.particleFriction;
        circleShapeDef.restitution = explosion.particleRestitution;
        circleShapeDef.filter.groupIndex = -1; // Don't collide with each other
        circleShapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
        circleShapeDef.filter.maskBits = collision.MASK_EXPLOSION_SHRAPNEL;

        const circleShape: box2d.c.b2Circle = .{
            .center = .{
                .x = 0,
                .y = 0,
            },
            .radius = explosion.particleRadius,
        };

        _ = box2d.c.b2CreateCircleShape(bodyId, &circleShapeDef, &circleShape);

        try bodyIds.append(bodyId);
    }

    return try bodyIds.toOwnedSlice();
}

pub fn explode(bodyId: box2d.c.b2BodyId) !void {
    const maybeExplosion = explosions.fetchSwapRemove(bodyId);
    if (maybeExplosion == null) return;

    // Remove propulsion config if it exists
    _ = propulsions.swapRemove(bodyId);

    const explosion = maybeExplosion.?.value;
    const maybeE = entity.entities.getLocking(bodyId);

    var pos = vec.zero;
    if (maybeE) |e| {
        if (e.state) |state| {
            pos = vec.fromBox2d(state.pos);
        }
        entity.cleanupLater(e);
    }

    const explosionBodies = try createExplosion(pos, explosion);

    const timerId = timer.addTimer(500, markShrapnelForCleanup, @ptrFromInt(id));
    try shrapnel.appendLocking(.{
        .id = id,
        .cleaned = false,
        .bodies = explosionBodies,
        .timerId = timerId,
    });
    id = id + 1;

    try createExplosionAnimation(pos, explosion.animation);

    try damageTerrainInRadius(pos, explosion.blastRadius);

    try damagePlayersInRadius(pos, explosion.blastRadius);
}

fn markShrapnelForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const shrapnelId: usize = @intFromPtr(param.?);

    shrapnel.mutex.lock();
    defer shrapnel.mutex.unlock();

    for (shrapnel.list.items) |*item| {
        if (item.id == shrapnelId) {
            shrapnelToCleanup.appendSliceLocking(item.bodies) catch {};
            item.cleaned = true;
            break;
        }
    }

    return 0;
}

pub fn cleanupShrapnel() !void {
    var shrapnelToKeep = std.array_list.Managed(Shrapnel).init(shared.allocator);
    var shrapnelToDiscard = std.array_list.Managed(Shrapnel).init(shared.allocator);
    defer shrapnelToDiscard.deinit();

    shrapnel.mutex.lock();
    for (shrapnel.list.items) |item| {
        if (item.cleaned) {
            try shrapnelToDiscard.append(item);
            continue;
        }
        try shrapnelToKeep.append(item);
    }
    shrapnel.mutex.unlock();

    shrapnel.replaceLocking(shrapnelToKeep);

    shrapnelToCleanup.mutex.lock();
    for (shrapnelToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    shrapnelToCleanup.mutex.unlock();

    shrapnelToCleanup.replaceLocking(std.array_list.Managed(box2d.c.b2BodyId).init(shared.allocator));

    for (shrapnelToDiscard.items) |item| {
        if (item.cleaned) {
            shared.allocator.free(item.bodies);
        }
    }
}


pub fn create(bodyId: box2d.c.b2BodyId, explosion: Explosion) !void {
    try explosions.put(bodyId, explosion);
}

pub fn registerPropulsion(bodyId: box2d.c.b2BodyId, propulsionMagnitude: f32) !void {
    try propulsions.put(bodyId, propulsionMagnitude);
}

pub fn applyPropulsion() void {
    for (propulsions.keys(), propulsions.values()) |bodyId, propulsionMagnitude| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            continue;
        }

        const rot = box2d.c.b2Body_GetRotation(bodyId);

        // The missile sprite points "up" (+Y in sprite space) and is rotated by angle + π/2
        // To get the forward direction from the rotation:
        // rotation = angle + π/2, so angle = rotation - π/2
        // forward = (cos(angle), sin(angle)) = (cos(rot - π/2), sin(rot - π/2))
        //         = (sin(rot), -cos(rot)) = (rot.s, -rot.c)
        const forward = vec.Vec2{ .x = rot.s, .y = -rot.c };
        const force = vec.mul(forward, propulsionMagnitude);

        box2d.c.b2Body_ApplyForceToCenter(bodyId, vec.toBox2d(force), true);

        // Simulate aerodynamic fin stabilization by damping lateral velocity.
        // Decompose velocity into forward and lateral components, then apply
        // a force opposing the lateral component (like drag from fins).
        const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
        const forwardSpeed = vec.dot(velocity, forward);
        const forwardVelocity = vec.mul(forward, forwardSpeed);
        const lateralVelocity = vec.subtract(velocity, forwardVelocity);
        const lateralDampingForce = vec.mul(lateralVelocity, -config.rocketLateralDamping);
        box2d.c.b2Body_ApplyForceToCenter(bodyId, vec.toBox2d(lateralDampingForce), true);
    }
}

pub fn checkContacts() !void {

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

        // Check if shape A is a projectile
        if ((aFilter.categoryBits & collision.CATEGORY_PROJECTILE) != 0 and (bFilter.categoryBits & collision.CATEGORY_HOOK) == 0) {
            if (explosions.contains(bodyIdA)) {
                try explode(bodyIdA);
            }
        }
        // Check if shape B is a projectile
        if ((bFilter.categoryBits & collision.CATEGORY_PROJECTILE) != 0 and (aFilter.categoryBits & collision.CATEGORY_HOOK) == 0) {
            if (explosions.contains(bodyIdB)) {
                try explode(bodyIdB);
            }
        }
    }
}

pub fn cleanup() void {
    explosions.clearAndFree();
    propulsions.clearAndFree();

    shrapnel.mutex.lock();
    for (shrapnel.list.items) |item| {
        _ = timer.removeTimer(item.timerId);
        for (item.bodies) |toClean| {
            box2d.c.b2DestroyBody(toClean);
        }
        shared.allocator.free(item.bodies);
    }
    shrapnel.mutex.unlock();

    shrapnel.replaceLocking(std.array_list.Managed(Shrapnel).init(shared.allocator));

    shrapnelToCleanup.mutex.lock();
    defer shrapnelToCleanup.mutex.unlock();
    for (shrapnelToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    shrapnelToCleanup.list.deinit();
}
