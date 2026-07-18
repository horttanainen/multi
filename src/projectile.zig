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
const blood = @import("blood.zig");
const perf = @import("perf.zig");

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

pub const PenetrationMode = enum {
    non_penetrating,
    penetrating,
};

pub const Spec = struct {
    owner_id: usize,
    direct_damage: f32 = 0,
    penetration: PenetrationMode = .non_penetrating,
    explosion: ?Explosion = null,
};

const ActiveProjectile = struct {
    owner_id: usize,
    direct_damage: f32,
    penetration: PenetrationMode,
    explosion: ?Explosion,
    hit_player_bits: u64 = 0,
};

pub var activeProjectiles = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, ActiveProjectile).empty;
const PropulsionData = struct {
    magnitude: f32,
    lateralDamping: f32,
};

pub var propulsions = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, PropulsionData).empty;

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

const DirectHitDamage = struct {
    player_id: usize,
    applied_damage: f32,
};

const terrainTextureUpdatesPerFrame: usize = 2;
const terrainColliderUpdatesPerFrame: usize = 1;
const perfLogFramesAfterExplosion: u32 = 120;
const hitscanBloodCarrySpeed: f32 = 24;

var terrainEdits = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, TerrainEdit).empty;
var terrainTextureUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, TerrainEdit).empty;
var terrainColliderUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, vec.IRect).empty;
var perfExplosionId: u64 = 0;
var perfLogFramesRemaining: u32 = 0;

inline fn beginExplosionPerfLog() u64 {
    if (comptime !perf.configured(.explosion)) return 0;
    if (!perf.enabled(.explosion)) return 0;

    perfExplosionId += 1;
    perfLogFramesRemaining = perfLogFramesAfterExplosion;
    perf.log(.explosion, "perf.explosion begin id={d}", .{perfExplosionId});
    return perfExplosionId;
}

inline fn logExplosionStage(perfId: u64, label: []const u8, start: u64) void {
    if (comptime !perf.configured(.explosion)) return;
    perf.log(.explosion, "perf.explosion id={d} stage={s} us={d}", .{ perfId, label, perf.elapsedUs(start) });
}

pub inline fn shouldCollectPerfFrameLog() bool {
    if (comptime !perf.configured(.explosion)) return false;
    return perf.enabled(.explosion) and perfLogFramesRemaining > 0;
}

pub inline fn consumePerfFrameLog() bool {
    if (comptime !perf.configured(.explosion)) return false;
    if (!perf.enabled(.explosion)) {
        return false;
    }

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
    var processed: usize = 0;
    while (processed < terrainTextureUpdatesPerFrame and terrainTextureUpdates.count() > 0) : (processed += 1) {
        const bodyId = terrainTextureUpdates.keys()[0];
        const edit = terrainTextureUpdates.values()[0];
        _ = terrainTextureUpdates.swapRemove(bodyId);

        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("processTerrainTextureUpdates: terrain body became invalid before texture update", .{});
            continue;
        }

        sprite.updateTextureGeometryRegionFromSurface(edit.spriteUuid, edit.dirtyRect) catch |err| {
            std.log.warn("processTerrainTextureUpdates: terrain texture update failed with {}", .{err});
        };

        queueTerrainColliderUpdate(bodyId, edit.dirtyRect) catch |err| {
            std.log.warn("processTerrainTextureUpdates: failed to queue terrain collider update with {}", .{err});
        };
    }
}

pub fn processTerrainColliderUpdates() void {
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

        const stillExists = entity.regenerateCollidersInPixelRect(ent, dirtyRect) catch |err| {
            std.log.warn("processTerrainColliderUpdates: terrain collider rebuild failed with {}", .{err});
            continue;
        };
        if (!stillExists) {
            entity.cleanupLater(ent.*);
        }
    }
}

fn damageTerrainInRadius(pos: vec.Vec2, radius: f32) !void {
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
    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);

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

        const dirtyRect = try sprite.removeCircleFromSurface(firstSprite, pos, radius, entityPos, rotation);
        if (dirtyRect == null) continue;

        const rect = dirtyRect.?;
        try queueTerrainEdit(bodyId, ent.spriteUuids[0], rect);
    }
}

fn normalizedOrZero(value: vec.Vec2) vec.Vec2 {
    const length = vec.magnitude(value);
    if (length < 0.001) return vec.zero;
    return .{
        .x = value.x / length,
        .y = value.y / length,
    };
}

pub fn damagePlayerWithBlood(playerId: usize, damage: f32, attackerId: ?usize, emission: blood.Emission) !player.DamageResult {
    const result = try player.damage(playerId, damage, attackerId);
    if (!result.applied) return result;

    const profileBlood = result.fatal and perf.isCapturingPlayerDeath(playerId);
    const bloodStart = if (profileBlood) perf.begin(.player_death) else 0;
    defer {
        if (profileBlood) {
            perf.recordPlayerDeathTriggerStage(.blood_spawn, bloodStart);
        }
    }
    try blood.emit(emission);
    return result;
}

fn damageAtExplosionDistance(explosion: Explosion, distance: f32) f32 {
    if (explosion.blastRadius <= 0) {
        std.log.err("damageAtExplosionDistance: explosion blast radius must be positive", .{});
        return 0;
    }
    if (distance > explosion.blastRadius) return 0;
    return 100.0 - (99.0 * distance / explosion.blastRadius);
}

fn damagePlayersInRadius(
    pos: vec.Vec2,
    explosion: Explosion,
    attackerId: ?usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    for (player.players.values()) |*p| {
        if (!box2d.c.b2Body_IsValid(p.bodyId)) {
            continue;
        }

        const playerBodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
        const playerPosM = vec.add(playerBodyPosition, player.centerOffset);

        const dx = playerPosM.x - pos.x;
        const dy = playerPosM.y - pos.y;
        const centerDistance = @sqrt(dx * dx + dy * dy);
        const isDirectHit = directHitDamage != null and directHitDamage.?.player_id == p.id;
        const distance = if (isDirectHit)
            0
        else
            @max(0, centerDistance - player.lowerBodyColliderRadius);
        const baseDamage = damageAtExplosionDistance(explosion, distance);
        if (baseDamage <= 0) continue;

        var damage = baseDamage;
        if (isDirectHit) {
            damage = @max(0, damage - directHitDamage.?.applied_damage);
        }
        if (damage <= 0) continue;

        const radialDirection = normalizedOrZero(.{ .x = dx, .y = dy });
        const playerVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(p.bodyId));
        const blastVelocity = vec.mul(radialDirection, explosion.blastPower * 0.08);
        _ = try damagePlayerWithBlood(p.id, damage, attackerId, .{
            .position = playerPosM,
            .amount = damage,
            .direction = if (vec.magnitude(radialDirection) < 0.001) null else radialDirection,
            .spread_radians = std.math.pi * 0.9,
            .inherited_velocity = vec.add(playerVelocity, blastVelocity),
            .inherited_velocity_scale = 0.35,
        });
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

fn explodeAtWithDirectHit(
    pos: vec.Vec2,
    explosion: Explosion,
    attackerId: ?usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    const perfId = beginExplosionPerfLog();
    const totalStart = perf.begin(.explosion);

    const createExplosionStart = perf.begin(.explosion);
    const explosionBodies = try createExplosion(pos, explosion);
    logExplosionStage(perfId, "create_shrapnel", createExplosionStart);
    if (comptime perf.configured(.explosion)) {
        perf.log(.explosion, "perf.explosion id={d} shrapnel_bodies={d}", .{ perfId, explosionBodies.len });
    }

    const registerShrapnelStart = perf.begin(.explosion);
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

    const animationStart = perf.begin(.explosion);
    if (explosion.animation) |anim| {
        try createExplosionAnimation(pos, anim);
    }
    logExplosionStage(perfId, "animation", animationStart);

    const terrainStart = perf.begin(.explosion);
    try damageTerrainInRadius(pos, explosion.blastRadius);
    logExplosionStage(perfId, "terrain_damage", terrainStart);

    const playerDamageStart = perf.begin(.explosion);
    if (explosion.damagePlayers) {
        try damagePlayersInRadius(pos, explosion, attackerId, directHitDamage);
    }
    logExplosionStage(perfId, "player_damage", playerDamageStart);
    logExplosionStage(perfId, "total", totalStart);
}

pub fn explodeAt(pos: vec.Vec2, explosion: Explosion, attackerId: ?usize) !void {
    try explodeAtWithDirectHit(pos, explosion, attackerId, null);
}

pub fn create(bodyId: box2d.c.b2BodyId, spec: Spec) !void {
    try activeProjectiles.put(allocator, bodyId, .{
        .owner_id = spec.owner_id,
        .direct_damage = spec.direct_damage,
        .penetration = spec.penetration,
        .explosion = spec.explosion,
    });
}

pub fn registerPropulsion(bodyId: box2d.c.b2BodyId, propulsionMagnitude: f32, lateralDamping: f32) !void {
    try propulsions.put(allocator, bodyId, .{ .magnitude = propulsionMagnitude, .lateralDamping = lateralDamping });
}

pub fn getOwner(bodyId: box2d.c.b2BodyId) ?usize {
    const active = activeProjectiles.get(bodyId) orelse return null;
    return active.owner_id;
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

pub fn playerIdForBody(bodyId: box2d.c.b2BodyId) ?usize {
    for (player.players.values()) |p| {
        if (!box2d.c.b2Body_IsValid(p.bodyId)) continue;
        if (box2d.c.B2_ID_EQUALS(p.bodyId, bodyId)) return p.id;
    }
    return null;
}

pub fn damagePlayerFromHitscan(
    playerId: usize,
    damage: f32,
    attackerId: usize,
    impactPoint: vec.Vec2,
    travelDirection: vec.Vec2,
    penetration: PenetrationMode,
) !void {
    if (damage <= 0) return;

    const victim = player.players.get(playerId) orelse {
        std.log.err("damagePlayerFromHitscan: player {d} is missing", .{playerId});
        return error.PlayerUnspawned;
    };
    const normalizedDirection = normalizedOrZero(travelDirection);
    const bloodDirection = if (penetration == .penetrating)
        normalizedDirection
    else
        vec.mul(normalizedDirection, -1.0);
    const spread: f32 = if (penetration == .penetrating)
        std.math.pi * 0.3
    else
        std.math.pi * 0.65;
    const carriedVelocity: ?vec.Vec2 = if (penetration == .penetrating)
        vec.mul(normalizedDirection, hitscanBloodCarrySpeed)
    else
        null;
    const victimVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(victim.bodyId));
    _ = try damagePlayerWithBlood(playerId, damage, attackerId, .{
        .position = impactPoint,
        .amount = damage,
        .direction = if (vec.magnitude(bloodDirection) < 0.001) null else bloodDirection,
        .spread_radians = spread,
        .inherited_velocity = victimVelocity,
        .inherited_velocity_scale = 0.35,
        .carried_velocity = carriedVelocity,
        .carried_fraction = 0.35,
        .carried_spread_radians = std.math.pi * 0.12,
    });
}

fn markPlayerHit(bodyId: box2d.c.b2BodyId, playerId: usize) !bool {
    const active = activeProjectiles.getPtr(bodyId) orelse return false;
    if (playerId >= @bitSizeOf(u64)) {
        std.log.err("markPlayerHit: player id {d} does not fit the projectile hit mask", .{playerId});
        return error.PlayerIdOutOfRange;
    }

    const playerBit = @as(u64, 1) << @intCast(playerId);
    if ((active.hit_player_bits & playerBit) != 0) return false;
    active.hit_player_bits |= playerBit;
    return true;
}

fn triggerProjectileExplosion(
    explosion: ?Explosion,
    pos: vec.Vec2,
    ownerId: usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    if (explosion == null) return;
    try explodeAtWithDirectHit(pos, explosion.?, ownerId, directHitDamage);
}

fn finishProjectile(
    bodyId: box2d.c.b2BodyId,
    impactPoint: vec.Vec2,
    directHitDamage: ?DirectHitDamage,
) !void {
    const removed = activeProjectiles.fetchSwapRemove(bodyId) orelse return;
    _ = propulsions.swapRemove(bodyId);

    const active = removed.value;
    const projectileEntity = entity.entities.getLocking(bodyId) orelse {
        std.log.warn("finishProjectile: projectile body has no entity", .{});
        try triggerProjectileExplosion(active.explosion, impactPoint, active.owner_id, directHitDamage);
        return;
    };
    entity.cleanupLater(projectileEntity);
    try triggerProjectileExplosion(active.explosion, impactPoint, active.owner_id, directHitDamage);
}

fn projectileImpactPoint(bodyId: box2d.c.b2BodyId, maybePoint: ?vec.Vec2) vec.Vec2 {
    if (maybePoint != null) return maybePoint.?;
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("projectileImpactPoint: projectile body became invalid before contact handling", .{});
        return vec.zero;
    }
    return vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId));
}

fn damagePlayerFromPhysicalImpact(bodyId: box2d.c.b2BodyId, playerId: usize, impactPoint: vec.Vec2, active: ActiveProjectile) !f32 {
    if (active.direct_damage <= 0) return 0;

    const victim = player.players.get(playerId) orelse {
        std.log.err("damagePlayerFromPhysicalImpact: player {d} is missing", .{playerId});
        return error.PlayerUnspawned;
    };
    const directDamage = if (active.explosion != null and active.explosion.?.damagePlayers)
        @min(active.direct_damage, damageAtExplosionDistance(active.explosion.?, 0))
    else
        active.direct_damage;
    if (directDamage <= 0) return 0;

    const projectileVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
    const outwardDirection = vec.mul(normalizedOrZero(projectileVelocity), -1.0);
    const victimVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(victim.bodyId));
    const damageResult = try damagePlayerWithBlood(playerId, directDamage, active.owner_id, .{
        .position = impactPoint,
        .amount = directDamage,
        .direction = if (vec.magnitude(outwardDirection) < 0.001) null else outwardDirection,
        .spread_radians = std.math.pi * 0.65,
        .inherited_velocity = victimVelocity,
        .inherited_velocity_scale = 0.35,
    });
    if (!damageResult.applied) return 0;
    return directDamage;
}

fn handleProjectileContactForBody(bodyId: box2d.c.b2BodyId, otherShapeId: box2d.c.b2ShapeId, maybePoint: ?vec.Vec2) !void {
    const active = activeProjectiles.get(bodyId) orelse return;
    const otherFilter = box2d.c.b2Shape_GetFilter(otherShapeId);
    if ((otherFilter.categoryBits & collision.CATEGORY_HOOK) != 0) return;

    const impactPoint = projectileImpactPoint(bodyId, maybePoint);
    if ((otherFilter.categoryBits & collision.CATEGORY_PLAYER) == 0) {
        try finishProjectile(bodyId, impactPoint, null);
        return;
    }

    if (active.penetration == .penetrating) return;

    const otherBodyId = box2d.c.b2Shape_GetBody(otherShapeId);
    const playerId = playerIdForBody(otherBodyId) orelse {
        std.log.warn("handleProjectileContactForBody: contacted player shape has no player", .{});
        try finishProjectile(bodyId, impactPoint, null);
        return;
    };
    const directDamage = try damagePlayerFromPhysicalImpact(bodyId, playerId, impactPoint, active);
    const directHitDamage: ?DirectHitDamage = if (active.explosion != null and active.explosion.?.damagePlayers)
        .{ .player_id = playerId, .applied_damage = directDamage }
    else
        null;
    try finishProjectile(bodyId, impactPoint, directHitDamage);
}

fn handleProjectileContact(shapeIdA: box2d.c.b2ShapeId, shapeIdB: box2d.c.b2ShapeId, maybePoint: ?vec.Vec2) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) return;

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);
    try handleProjectileContactForBody(bodyIdA, shapeIdB, maybePoint);
    try handleProjectileContactForBody(bodyIdB, shapeIdA, maybePoint);
}

fn handlePenetratingSensorContact(sensorShapeId: box2d.c.b2ShapeId, visitorShapeId: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Shape_IsValid(sensorShapeId) or !box2d.c.b2Shape_IsValid(visitorShapeId)) return;

    const bodyId = box2d.c.b2Shape_GetBody(sensorShapeId);
    const active = activeProjectiles.get(bodyId) orelse return;
    if (active.penetration != .penetrating) return;

    const visitorFilter = box2d.c.b2Shape_GetFilter(visitorShapeId);
    if ((visitorFilter.categoryBits & collision.CATEGORY_PLAYER) == 0) return;

    const playerBodyId = box2d.c.b2Shape_GetBody(visitorShapeId);
    const playerId = playerIdForBody(playerBodyId) orelse {
        std.log.warn("handlePenetratingSensorContact: visitor player shape has no player", .{});
        return;
    };
    if (!try markPlayerHit(bodyId, playerId)) return;
    if (active.direct_damage <= 0) return;

    const victim = player.players.get(playerId) orelse {
        std.log.err("handlePenetratingSensorContact: player {d} is missing", .{playerId});
        return error.PlayerUnspawned;
    };
    const projectilePosition = box2d.c.b2Body_GetPosition(bodyId);
    const hitPoint = vec.fromBox2d(box2d.c.b2Shape_GetClosestPoint(visitorShapeId, projectilePosition));
    const projectileVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
    const forwardDirection = normalizedOrZero(projectileVelocity);
    const victimVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(victim.bodyId));
    _ = try damagePlayerWithBlood(playerId, active.direct_damage, active.owner_id, .{
        .position = hitPoint,
        .amount = active.direct_damage,
        .direction = if (vec.magnitude(forwardDirection) < 0.001) null else forwardDirection,
        .spread_radians = std.math.pi * 0.3,
        .inherited_velocity = vec.add(victimVelocity, vec.mul(projectileVelocity, 0.2)),
        .inherited_velocity_scale = 0.4,
        .carried_velocity = projectileVelocity,
        .carried_fraction = 0.35,
        .carried_spread_radians = std.math.pi * 0.12,
    });
}

pub fn checkContacts() !void {
    errdefer flushTerrainEdits() catch |err| {
        std.log.err("checkContacts: failed to flush terrain edits: {}", .{err});
    };

    const sensorEvents = box2d.getSensorEvents();
    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const event = sensorEvents.beginEvents[i];
        try handlePenetratingSensorContact(event.sensorShapeId, event.visitorShapeId);
    }

    const contactEvents = box2d.getContactEvents();

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        try handleProjectileContact(event.shapeIdA, event.shapeIdB, vec.fromBox2d(event.point));
    }

    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try handleProjectileContact(event.shapeIdA, event.shapeIdB, null);
    }

    try flushTerrainEdits();
}

pub fn cleanup() void {
    activeProjectiles.clearAndFree(allocator);
    propulsions.clearAndFree(allocator);
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
