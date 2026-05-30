const std = @import("std");
const sdl = @import("sdl.zig");

const audio = @import("audio.zig");
const vec = @import("vector.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");

const collision = @import("collision.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const animation = @import("animation.zig");
const conv = @import("conversion.zig");
const runtime = @import("runtime.zig");
const player = @import("player.zig");
const particle = @import("particle.zig");

pub const Explosion = struct {
    sound: ?audio.Audio = null,
    animation: ?animation.Animation = null,
    blastPower: f32,
    blastRadius: f32,
    particleCount: u32,
    particleDensity: f32,
    particleFriction: f32,
    particleRestitution: f32,
    particleRadius: f32,
    particleLinearDamping: f32,
    particleGravityScale: f32,
    damagePlayers: bool = true,
};

pub var explosions = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, Explosion).empty;
const PropulsionData = struct {
    magnitude: f32,
    lateralDamping: f32,
};

pub var propulsions = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, PropulsionData).empty;
pub var owners = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, usize).empty;
pub var directDamages = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, f32).empty;

pub var id: usize = 1;
pub const Shrapnel = struct {
    id: usize,
    cleaned: bool,
    bodies: []box2d.c.b2BodyId,
    timerId: sdl.TimerID,
};

pub var shrapnel = thread_safe.ThreadSafeArrayList(Shrapnel).init(allocator);

var shrapnelToCleanup = thread_safe.ThreadSafeArrayList(box2d.c.b2BodyId).init(allocator);

fn createExplosionAnimation(pos: vec.Vec2, anim: animation.Animation) !void {
    const animCopy = try animation.copyAnimationSharedFrames(anim);

    var bodyDef = box2d.createStaticBodyDef(pos);

    const randomAngle = runtime.random().float(f32) * 2.0 * std.math.pi;
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
    entity.markSpriteUuidsShared(explosionEntity.bodyId);

    try animation.register(explosionEntity.bodyId, animCopy);
}

const OverlapContext = struct {
    bodies: [100]box2d.c.b2BodyId,
    count: usize,
};

const TerrainEdit = struct {
    spriteUuid: u64,
    dirtyRect: vec.IRect,
};

const terrainTextureUpdatesPerFrame: usize = 2;
const terrainColliderUpdatesPerFrame: usize = 1;
const perfLogFramesAfterExplosion: u32 = 120;

var terrainEdits = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, TerrainEdit).empty;
var terrainTextureUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, TerrainEdit).empty;
var terrainColliderUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, vec.IRect).empty;
var perfExplosionId: u64 = 0;
var perfLogFramesRemaining: u32 = 0;

fn perfNow() u64 {
    return sdl.getPerformanceCounter();
}

fn perfElapsedUs(start: u64) u64 {
    const elapsed = sdl.getPerformanceCounter() - start;
    return elapsed * 1_000_000 / sdl.getPerformanceFrequency();
}

fn beginExplosionPerfLog() u64 {
    perfExplosionId += 1;
    perfLogFramesRemaining = perfLogFramesAfterExplosion;
    std.log.info("perf.explosion begin id={d}", .{perfExplosionId});
    return perfExplosionId;
}

fn logExplosionStage(perfId: u64, label: []const u8, start: u64) void {
    std.log.info("perf.explosion id={d} stage={s} us={d}", .{ perfId, label, perfElapsedUs(start) });
}

pub fn consumePerfFrameLog() bool {
    if (perfLogFramesRemaining == 0) {
        return false;
    }

    perfLogFramesRemaining -= 1;
    return true;
}

pub fn pendingTerrainTextureUpdateCount() usize {
    return terrainTextureUpdates.count();
}

pub fn pendingTerrainColliderUpdateCount() usize {
    return terrainColliderUpdates.count();
}

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

fn queueTerrainEdit(bodyId: box2d.c.b2BodyId, spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const maybeEdit = terrainEdits.getPtr(bodyId);
    if (maybeEdit == null) {
        try terrainEdits.put(allocator, bodyId, .{
            .spriteUuid = spriteUuid,
            .dirtyRect = dirtyRect,
        });
        return;
    }

    const edit = maybeEdit.?;
    edit.dirtyRect = vec.irectUnion(edit.dirtyRect, dirtyRect);
}

fn queueTerrainColliderUpdate(bodyId: box2d.c.b2BodyId, dirtyRect: vec.IRect) !void {
    const maybeDirtyRect = terrainColliderUpdates.getPtr(bodyId);
    if (maybeDirtyRect == null) {
        try terrainColliderUpdates.put(allocator, bodyId, dirtyRect);
        return;
    }

    const dirtyRectPtr = maybeDirtyRect.?;
    dirtyRectPtr.* = vec.irectUnion(dirtyRectPtr.*, dirtyRect);
}

fn queueTerrainTextureUpdate(bodyId: box2d.c.b2BodyId, edit: TerrainEdit) !void {
    const maybeEdit = terrainTextureUpdates.getPtr(bodyId);
    if (maybeEdit == null) {
        try terrainTextureUpdates.put(allocator, bodyId, edit);
        return;
    }

    const pendingEdit = maybeEdit.?;
    pendingEdit.dirtyRect = vec.irectUnion(pendingEdit.dirtyRect, edit.dirtyRect);
}

fn flushTerrainEdits() !void {
    if (terrainEdits.count() == 0) {
        return;
    }
    defer terrainEdits.clearRetainingCapacity();

    for (terrainEdits.keys(), terrainEdits.values()) |bodyId, edit| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("flushTerrainEdits: terrain body became invalid before flush", .{});
            continue;
        }

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("flushTerrainEdits: terrain entity missing before flush", .{});
            continue;
        };

        if (ent.spriteUuids.len == 0) {
            std.log.warn("flushTerrainEdits: terrain entity has no sprites", .{});
            continue;
        }

        try queueTerrainTextureUpdate(bodyId, edit);
    }
}

pub fn processTerrainTextureUpdates() void {
    const totalStart = perfNow();
    var updateUs: u64 = 0;
    var queueUs: u64 = 0;
    var updatedPixels: usize = 0;
    var processed: usize = 0;
    while (processed < terrainTextureUpdatesPerFrame and terrainTextureUpdates.count() > 0) : (processed += 1) {
        const bodyId = terrainTextureUpdates.keys()[0];
        const edit = terrainTextureUpdates.values()[0];
        _ = terrainTextureUpdates.swapRemove(bodyId);

        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("processTerrainTextureUpdates: terrain body became invalid before texture update", .{});
            continue;
        }

        const rectWidth = edit.dirtyRect.maxX - edit.dirtyRect.minX;
        const rectHeight = edit.dirtyRect.maxY - edit.dirtyRect.minY;
        if (rectWidth > 0 and rectHeight > 0) {
            updatedPixels += @as(usize, @intCast(rectWidth)) * @as(usize, @intCast(rectHeight));
        }

        const updateStart = perfNow();
        sprite.updateTextureRegionFromSurface(edit.spriteUuid, edit.dirtyRect) catch |err| {
            std.log.warn("processTerrainTextureUpdates: terrain texture update failed with {}", .{err});
        };
        updateUs += perfElapsedUs(updateStart);

        const queueStart = perfNow();
        queueTerrainColliderUpdate(bodyId, edit.dirtyRect) catch |err| {
            std.log.warn("processTerrainTextureUpdates: failed to queue terrain collider update with {}", .{err});
        };
        queueUs += perfElapsedUs(queueStart);
    }

    if (processed == 0) {
        return;
    }

    std.log.info(
        "perf.terrain_texture_queue processed={d} remaining={d} pixels={d} update_us={d} queue_us={d} total_us={d}",
        .{ processed, terrainTextureUpdates.count(), updatedPixels, updateUs, queueUs, perfElapsedUs(totalStart) },
    );
}

pub fn processTerrainColliderUpdates() void {
    const totalStart = perfNow();
    var rebuildUs: u64 = 0;
    var rebuiltPixels: usize = 0;
    var processed: usize = 0;
    while (processed < terrainColliderUpdatesPerFrame and terrainColliderUpdates.count() > 0) : (processed += 1) {
        const bodyId = terrainColliderUpdates.keys()[0];
        const dirtyRect = terrainColliderUpdates.values()[0];
        _ = terrainColliderUpdates.swapRemove(bodyId);

        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("processTerrainColliderUpdates: terrain body became invalid before collider rebuild", .{});
            continue;
        }

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("processTerrainColliderUpdates: terrain entity missing before collider rebuild", .{});
            continue;
        };

        const rectWidth = dirtyRect.maxX - dirtyRect.minX;
        const rectHeight = dirtyRect.maxY - dirtyRect.minY;
        if (rectWidth > 0 and rectHeight > 0) {
            rebuiltPixels += @as(usize, @intCast(rectWidth)) * @as(usize, @intCast(rectHeight));
        }

        const rebuildStart = perfNow();
        const stillExists = entity.regenerateCollidersInPixelRect(ent, dirtyRect) catch |err| {
            std.log.warn("processTerrainColliderUpdates: terrain collider rebuild failed with {}", .{err});
            continue;
        };
        rebuildUs += perfElapsedUs(rebuildStart);
        if (!stillExists) {
            entity.cleanupLater(ent.*);
        }
    }

    if (processed == 0) {
        return;
    }

    std.log.info(
        "perf.terrain_collider_queue processed={d} remaining={d} pixels={d} rebuild_us={d} total_us={d}",
        .{ processed, terrainColliderUpdates.count(), rebuiltPixels, rebuildUs, perfElapsedUs(totalStart) },
    );
}

fn damageTerrainInRadius(pos: vec.Vec2, radius: f32, perfId: u64) !void {
    const totalStart = perfNow();
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
    const overlapStart = perfNow();
    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);
    const overlapUs = perfElapsedUs(overlapStart);

    var changed: usize = 0;
    var carvedPixels: usize = 0;
    var carveUs: u64 = 0;
    var queueUs: u64 = 0;
    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("damageTerrainInRadius: terrain body has no entity", .{});
            continue;
        };

        // Get entity position and rotation
        const state = box2d.getState(bodyId);
        const entityPos = vec.fromBox2d(state.pos);
        const rotation = state.rotAngle;

        if (ent.spriteUuids.len == 0) {
            std.log.warn("damageTerrainInRadius: terrain entity has no sprites", .{});
            continue;
        }
        const firstSprite = sprite.getSprite(ent.spriteUuids[0]) orelse {
            std.log.warn("damageTerrainInRadius: terrain sprite {d} not found", .{ent.spriteUuids[0]});
            continue;
        };

        const carveStart = perfNow();
        const dirtyRect = try sprite.removeCircleFromSurface(firstSprite, pos, radius, entityPos, rotation);
        carveUs += perfElapsedUs(carveStart);
        if (dirtyRect == null) continue;

        const rect = dirtyRect.?;
        const rectWidth = rect.maxX - rect.minX;
        const rectHeight = rect.maxY - rect.minY;
        if (rectWidth > 0 and rectHeight > 0) {
            carvedPixels += @as(usize, @intCast(rectWidth)) * @as(usize, @intCast(rectHeight));
        }
        changed += 1;

        const queueStart = perfNow();
        try queueTerrainEdit(bodyId, ent.spriteUuids[0], rect);
        queueUs += perfElapsedUs(queueStart);
    }

    std.log.info(
        "perf.terrain_damage id={d} bodies={d} changed={d} pixels={d} overlap_us={d} carve_us={d} queue_us={d} total_us={d}",
        .{ perfId, context.count, changed, carvedPixels, overlapUs, carveUs, queueUs, perfElapsedUs(totalStart) },
    );
}

fn damagePlayersInRadius(pos: vec.Vec2, radius: f32, attackerId: ?usize) !void {
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

            try player.damage(p, damage, attackerId);
        }
    }
}

fn createExplosion(pos: vec.Vec2, explosion: Explosion) ![]box2d.c.b2BodyId {
    if (explosion.sound) |snd| {
        try audio.playFor(snd);
    }

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);

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
        circleShapeDef.material.friction = explosion.particleFriction;
        circleShapeDef.material.restitution = explosion.particleRestitution;
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

    _ = propulsions.swapRemove(bodyId);

    const attackerId = owners.get(bodyId);
    _ = owners.swapRemove(bodyId);
    _ = directDamages.swapRemove(bodyId);

    const explosion = maybeExplosion.?.value;
    const maybeE = entity.entities.getLocking(bodyId);

    var pos = vec.zero;
    if (maybeE) |e| {
        if (e.state) |state| {
            pos = vec.fromBox2d(state.pos);
        }
        entity.cleanupLater(e);
    }

    try explodeAt(pos, explosion, attackerId);
}

fn markShrapnelForCleanup(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const shrapnelId: usize = @intFromPtr(param.?);

    shrapnel.mutex.lockUncancelable(runtime.io());
    defer shrapnel.mutex.unlock(runtime.io());

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
    var shrapnelToKeep = std.array_list.Managed(Shrapnel).init(allocator);
    var shrapnelToDiscard = std.array_list.Managed(Shrapnel).init(allocator);
    defer shrapnelToDiscard.deinit();

    shrapnel.mutex.lockUncancelable(runtime.io());
    for (shrapnel.list.items) |item| {
        if (item.cleaned) {
            try shrapnelToDiscard.append(item);
            continue;
        }
        try shrapnelToKeep.append(item);
    }
    shrapnel.mutex.unlock(runtime.io());

    shrapnel.replaceLocking(shrapnelToKeep);

    shrapnelToCleanup.mutex.lockUncancelable(runtime.io());
    for (shrapnelToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    shrapnelToCleanup.mutex.unlock(runtime.io());

    shrapnelToCleanup.replaceLocking(std.array_list.Managed(box2d.c.b2BodyId).init(allocator));

    for (shrapnelToDiscard.items) |item| {
        if (item.cleaned) {
            allocator.free(item.bodies);
        }
    }
}

pub fn explodeAt(pos: vec.Vec2, explosion: Explosion, attackerId: ?usize) !void {
    const perfId = beginExplosionPerfLog();
    const totalStart = perfNow();

    const createExplosionStart = perfNow();
    const explosionBodies = try createExplosion(pos, explosion);
    logExplosionStage(perfId, "create_shrapnel", createExplosionStart);
    std.log.info("perf.explosion id={d} shrapnel_bodies={d}", .{ perfId, explosionBodies.len });

    const registerShrapnelStart = perfNow();
    if (explosionBodies.len > 0) {
        const timerId = sdl.addTimer(500, markShrapnelForCleanup, @ptrFromInt(id));
        try shrapnel.appendLocking(.{
            .id = id,
            .cleaned = false,
            .bodies = explosionBodies,
            .timerId = timerId,
        });
        id = id + 1;
    } else {
        allocator.free(explosionBodies);
    }
    logExplosionStage(perfId, "register_shrapnel", registerShrapnelStart);

    const animationStart = perfNow();
    if (explosion.animation) |anim| {
        try createExplosionAnimation(pos, anim);
    }
    logExplosionStage(perfId, "animation", animationStart);

    const terrainStart = perfNow();
    try damageTerrainInRadius(pos, explosion.blastRadius, perfId);
    logExplosionStage(perfId, "terrain_damage", terrainStart);

    const playerDamageStart = perfNow();
    if (explosion.damagePlayers) {
        try damagePlayersInRadius(pos, explosion.blastRadius, attackerId);
    }
    logExplosionStage(perfId, "player_damage", playerDamageStart);
    logExplosionStage(perfId, "total", totalStart);
}

pub fn create(bodyId: box2d.c.b2BodyId, explosion: Explosion) !void {
    try explosions.put(allocator, bodyId, explosion);
}

pub fn registerDirectDamage(bodyId: box2d.c.b2BodyId, damage: f32) !void {
    try directDamages.put(allocator, bodyId, damage);
}

pub fn registerPropulsion(bodyId: box2d.c.b2BodyId, propulsionMagnitude: f32, lateralDamping: f32) !void {
    try propulsions.put(allocator, bodyId, .{ .magnitude = propulsionMagnitude, .lateralDamping = lateralDamping });
}

pub fn registerOwner(bodyId: box2d.c.b2BodyId, playerId: usize) !void {
    try owners.put(allocator, bodyId, playerId);
}

pub fn getOwner(bodyId: box2d.c.b2BodyId) ?usize {
    return owners.get(bodyId);
}

pub fn applyPropulsion() void {
    for (propulsions.keys(), propulsions.values()) |bodyId, propData| {
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
        const force = vec.mul(forward, propData.magnitude);

        box2d.c.b2Body_ApplyForceToCenter(bodyId, vec.toBox2d(force), true);

        // Simulate aerodynamic fin stabilization by damping lateral velocity.
        // Decompose velocity into forward and lateral components, then apply
        // a force opposing the lateral component (like drag from fins).
        const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
        const forwardSpeed = vec.dot(velocity, forward);
        const forwardVelocity = vec.mul(forward, forwardSpeed);
        const lateralVelocity = vec.subtract(velocity, forwardVelocity);
        const lateralDampingForce = vec.mul(lateralVelocity, -propData.lateralDamping);
        box2d.c.b2Body_ApplyForceToCenter(bodyId, vec.toBox2d(lateralDampingForce), true);
    }
}

pub fn damagePlayerDirect(hitBodyId: box2d.c.b2BodyId, damage: f32, attackerId: ?usize) !void {
    if (!box2d.c.b2Body_IsValid(hitBodyId)) return;

    for (player.players.values()) |*p| {
        if (!box2d.c.b2Body_IsValid(p.bodyId)) continue;
        if (box2d.c.B2_ID_EQUALS(p.bodyId, hitBodyId)) {
            try player.damage(p, damage, attackerId);
            return;
        }
    }
}

fn handleProjectileContact(shapeIdA: box2d.c.b2ShapeId, shapeIdB: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) {
        return;
    }

    const aFilter = box2d.c.b2Shape_GetFilter(shapeIdA);
    const bFilter = box2d.c.b2Shape_GetFilter(shapeIdB);

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);

    // Check if shape A is a projectile
    if ((aFilter.categoryBits & collision.CATEGORY_PROJECTILE) != 0 and (bFilter.categoryBits & collision.CATEGORY_HOOK) == 0) {
        if (explosions.contains(bodyIdA)) {
            if (directDamages.get(bodyIdA)) |dmg| {
                const attackerId = owners.get(bodyIdA);
                try damagePlayerDirect(bodyIdB, dmg, attackerId);
            }
            try explode(bodyIdA);
        }
    }
    // Check if shape B is a projectile
    if ((bFilter.categoryBits & collision.CATEGORY_PROJECTILE) != 0 and (aFilter.categoryBits & collision.CATEGORY_HOOK) == 0) {
        if (explosions.contains(bodyIdB)) {
            if (directDamages.get(bodyIdB)) |dmg| {
                const attackerId = owners.get(bodyIdB);
                try damagePlayerDirect(bodyIdA, dmg, attackerId);
            }
            try explode(bodyIdB);
        }
    }
}

pub fn checkContacts() !void {
    errdefer flushTerrainEdits() catch |err| {
        std.log.err("checkContacts: failed to flush terrain edits: {}", .{err});
    };

    const contactEvents = box2d.getContactEvents();

    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try handleProjectileContact(event.shapeIdA, event.shapeIdB);
    }

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        try handleProjectileContact(event.shapeIdA, event.shapeIdB);
    }

    try flushTerrainEdits();
}

pub fn cleanup() void {
    explosions.clearAndFree(allocator);
    propulsions.clearAndFree(allocator);
    owners.clearAndFree(allocator);
    directDamages.clearAndFree(allocator);
    terrainEdits.clearAndFree(allocator);
    terrainTextureUpdates.clearAndFree(allocator);
    terrainColliderUpdates.clearAndFree(allocator);

    shrapnel.mutex.lockUncancelable(runtime.io());
    for (shrapnel.list.items) |item| {
        _ = sdl.removeTimer(item.timerId);
        for (item.bodies) |toClean| {
            box2d.c.b2DestroyBody(toClean);
        }
        allocator.free(item.bodies);
    }
    shrapnel.mutex.unlock(runtime.io());

    shrapnel.replaceLocking(std.array_list.Managed(Shrapnel).init(allocator));

    shrapnelToCleanup.mutex.lockUncancelable(runtime.io());
    defer shrapnelToCleanup.mutex.unlock(runtime.io());
    for (shrapnelToCleanup.list.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    shrapnelToCleanup.list.deinit();
}
