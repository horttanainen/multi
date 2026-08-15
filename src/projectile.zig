const std = @import("std");

const audio = @import("audio.zig");
const vec = @import("vector.zig");
const entity = @import("entity.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");

const collision = @import("collision.zig");
const conv = @import("conversion.zig");
const player = @import("player.zig");
const blood = @import("blood.zig");
const blast_pressure = @import("blast_pressure.zig");
const blast_pressure_visual = @import("blast_pressure_visual.zig");
const explosion_visual = @import("explosion_visual.zig");
const perf = @import("perf.zig");
const destruction = @import("destruction.zig");

pub const Explosion = struct {
    sound: ?audio.Audio = null,
    visual: ?explosion_visual.Id = null,
    maximumDamage: f32,
    maximumPlayerVelocityChange: f32,
    maximumObjectImpulse: f32,
    blastRadius: f32,
    pressureRadius: f32,
    cutoutIrregularity: f32,
    cutoutCharWidth: f32,
    cutoutCharStrength: f32,
    cutoutSeedSalt: u64,
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

const OverlapContext = struct {
    bodies: [100]box2d.c.b2BodyId,
    count: usize,
    truncated: bool = false,
};

const DirectHitDamage = struct {
    player_id: usize,
    applied_damage: f32,
};

const PressureResponse = struct {
    direction: vec.Vec2 = vec.zero,
    strength: f32 = 0,
};

const perfLogFramesAfterExplosion: u32 = 120;
const hitscanBloodCarrySpeed: f32 = 45;
const hitscanBloodCarryFraction: f32 = 0.75;
const hitscanBloodCarrySpreadRadians: f32 = std.math.degreesToRadians(16);

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
    if (ctx.count < ctx.bodies.len) {
        ctx.bodies[ctx.count] = bodyId;
        ctx.count += 1;
    } else {
        ctx.truncated = true;
    }

    return true; // Continue the query
}

fn sortOverlapBodies(context: *OverlapContext) void {
    var index: usize = 1;
    while (index < context.count) : (index += 1) {
        const bodyId = context.bodies[index];
        const bodyKey: usize = @bitCast(bodyId);
        var insertionIndex = index;
        while (insertionIndex > 0) {
            const previousKey: usize = @bitCast(context.bodies[insertionIndex - 1]);
            if (previousKey <= bodyKey) break;
            context.bodies[insertionIndex] = context.bodies[insertionIndex - 1];
            insertionIndex -= 1;
        }
        context.bodies[insertionIndex] = bodyId;
    }
}

fn damageEntitiesInExplosion(
    field: blast_pressure.Field,
    impactPosition: vec.Vec2,
    explosion: Explosion,
    attackerId: ?usize,
    cutoutSeed: u64,
) !void {
    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = explosion.blastRadius,
    };

    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(impactPosition),
        .q = box2d.c.b2Rot_identity,
    };

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_EXPLOSION_QUERY;
    filter.maskBits = collision.MASK_EXPLOSION_QUERY;

    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);
    if (context.truncated) {
        std.log.warn("damageEntitiesInExplosion: explosion damage query exceeded {d} bodies", .{context.bodies.len});
    }
    sortOverlapBodies(&context);

    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("damageEntitiesInExplosion: body became invalid during damage query", .{});
            continue;
        }

        const bodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId));
        const sample = blast_pressure.sample(field, bodyPosition);
        const direction = if (sample != null)
            sample.?.direction
        else
            normalizedOrUp(vec.subtract(bodyPosition, field.origin));
        const amount = if (sample != null) damageFromPressureStrength(explosion, sample.?.strength) else 0;
        const debrisVelocity = if (sample != null)
            vec.mul(sample.?.direction, explosion.maximumObjectImpulse * sample.?.strength)
        else
            vec.zero;

        try destruction.apply(bodyId, .{
            .source = .explosion,
            .amount = amount,
            .position = impactPosition,
            .direction = direction,
            .debrisVelocity = debrisVelocity,
            .radius = explosion.blastRadius,
            .cutoutIrregularity = explosion.cutoutIrregularity,
            .cutoutCharWidth = explosion.cutoutCharWidth,
            .cutoutCharStrength = explosion.cutoutCharStrength,
            .cutoutSeed = cutoutSeed,
            .attackerId = attackerId,
        });
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

fn normalizedOrUp(value: vec.Vec2) vec.Vec2 {
    const normalized = normalizedOrZero(value);
    if (vec.magnitude(normalized) >= 0.001) return normalized;
    return .{ .x = 0, .y = -1 };
}

fn pressureResponseForPlayer(
    field: blast_pressure.Field,
    playerPosition: vec.Vec2,
    playerRadius: f32,
    isDirectHit: bool,
) PressureResponse {
    if (isDirectHit) {
        return .{
            .direction = normalizedOrUp(vec.subtract(playerPosition, field.origin)),
            .strength = 1,
        };
    }

    const sampleRadius = @max(playerRadius, field.cell_size);
    const sampleOffsets = [_]vec.Vec2{
        vec.zero,
        .{ .x = -sampleRadius, .y = 0 },
        .{ .x = sampleRadius, .y = 0 },
        .{ .x = 0, .y = -sampleRadius },
        .{ .x = 0, .y = sampleRadius },
    };
    var totalStrength: f32 = 0;
    var weightedDirection = vec.zero;
    for (sampleOffsets) |offset| {
        const pressureSample = blast_pressure.sample(field, vec.add(playerPosition, offset)) orelse continue;
        totalStrength += pressureSample.strength;
        weightedDirection = vec.add(weightedDirection, vec.mul(pressureSample.direction, pressureSample.strength));
    }
    if (totalStrength <= 0) return .{};

    return .{
        .direction = normalizedOrUp(weightedDirection),
        .strength = totalStrength / @as(f32, @floatFromInt(sampleOffsets.len)),
    };
}

fn applyVelocityChange(bodyId: box2d.c.b2BodyId, velocity: vec.Vec2) void {
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("applyVelocityChange: body is invalid", .{});
        return;
    }
    if (box2d.c.b2Body_GetType(bodyId) != box2d.c.b2_dynamicBody) return;

    const mass = box2d.c.b2Body_GetMass(bodyId);
    if (mass <= 0) {
        std.log.warn("applyVelocityChange: dynamic body has no mass", .{});
        return;
    }
    box2d.c.b2Body_ApplyLinearImpulseToCenter(bodyId, vec.toBox2d(vec.mul(velocity, mass)), true);
}

fn applyPhysicalImpulse(bodyId: box2d.c.b2BodyId, impulse: vec.Vec2) void {
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("applyPhysicalImpulse: body is invalid", .{});
        return;
    }
    if (box2d.c.b2Body_GetType(bodyId) != box2d.c.b2_dynamicBody) return;

    const mass = box2d.c.b2Body_GetMass(bodyId);
    if (mass <= 0) {
        std.log.warn("applyPhysicalImpulse: dynamic body has no mass", .{});
        return;
    }
    box2d.c.b2Body_ApplyLinearImpulseToCenter(bodyId, vec.toBox2d(impulse), true);
}

fn applyExplosionPressureToBodies(field: blast_pressure.Field, explosion: Explosion) void {
    if (explosion.maximumObjectImpulse <= 0) return;

    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };
    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = explosion.pressureRadius,
    };
    const transform = box2d.c.b2Transform{
        .p = vec.toBox2d(field.origin),
        .q = box2d.c.b2Rot_identity,
    };
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_EXPLOSION_IMPULSE;
    filter.maskBits = collision.MASK_EXPLOSION_IMPULSE;
    box2d.overlapCircle(&circle, transform, filter, overlapCallback, &context);

    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("applyExplosionPressureToBodies: body became invalid during pressure query", .{});
            continue;
        }

        const bodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId));
        const sample = blast_pressure.sample(field, bodyPosition) orelse continue;
        applyPhysicalImpulse(bodyId, vec.mul(sample.direction, explosion.maximumObjectImpulse * sample.strength));
    }
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

fn damageFromPressureStrength(explosion: Explosion, strength: f32) f32 {
    if (explosion.maximumDamage <= 0) return 0;
    if (strength <= 0) return 0;
    const clampedStrength = std.math.clamp(strength, 0, 1);
    return explosion.maximumDamage * clampedStrength * clampedStrength;
}

fn hashCutoutSeed(value: u64) u64 {
    var result = value;
    result ^= result >> 30;
    result *%= 0xbf58476d1ce4e5b9;
    result ^= result >> 27;
    result *%= 0x94d049bb133111eb;
    result ^= result >> 31;
    return result;
}

fn cutoutSeedForExplosion(impactPosition: vec.Vec2, pressureSourcePosition: vec.Vec2, explosion: Explosion) u64 {
    const impactPixel = conv.m2Pixel(vec.toBox2d(impactPosition));
    const pressureSourcePixel = conv.m2Pixel(vec.toBox2d(pressureSourcePosition));
    const impactX: u64 = @bitCast(@as(i64, impactPixel.x));
    const impactY: u64 = @bitCast(@as(i64, impactPixel.y));
    const sourceX: u64 = @bitCast(@as(i64, pressureSourcePixel.x));
    const sourceY: u64 = @bitCast(@as(i64, pressureSourcePixel.y));

    var seed = hashCutoutSeed(explosion.cutoutSeedSalt ^ impactX);
    seed = hashCutoutSeed(seed ^ std.math.rotl(u64, impactY, 17));
    seed = hashCutoutSeed(seed ^ std.math.rotl(u64, sourceX, 31));
    seed = hashCutoutSeed(seed ^ std.math.rotl(u64, sourceY, 47));
    return seed;
}

fn applyExplosionPressureToPlayers(
    field: blast_pressure.Field,
    explosion: Explosion,
    attackerId: ?usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    for (player.players.values()) |*p| {
        if (p.isDead) continue;
        if (!box2d.c.b2Body_IsValid(p.bodyId)) {
            std.log.warn("applyExplosionPressureToPlayers: player {d} body is invalid", .{p.id});
            continue;
        }

        const playerBodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
        const playerPosM = vec.add(playerBodyPosition, player.centerOffset);
        const isDirectHit = directHitDamage != null and directHitDamage.?.player_id == p.id;
        const response = pressureResponseForPlayer(
            field,
            playerPosM,
            player.lowerBodyColliderRadius,
            isDirectHit,
        );
        if (response.strength <= 0) continue;

        const playerVelocityChange = vec.mul(
            response.direction,
            explosion.maximumPlayerVelocityChange * response.strength,
        );
        if (explosion.maximumPlayerVelocityChange > 0) {
            applyVelocityChange(p.bodyId, playerVelocityChange);
        }

        if (!explosion.damagePlayers) continue;

        var damage = damageFromPressureStrength(explosion, response.strength);
        if (isDirectHit) {
            damage = @max(0, damage - directHitDamage.?.applied_damage);
        }
        if (damage <= 0) continue;

        const playerVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(p.bodyId));
        _ = try damagePlayerWithBlood(p.id, damage, attackerId, .{
            .position = playerPosM,
            .amount = damage,
            .direction = response.direction,
            .spread_radians = std.math.pi * 0.9,
            .inherited_velocity = vec.add(playerVelocity, playerVelocityChange),
            .inherited_velocity_scale = 0.35,
        });
    }
}

fn playExplosionSound(explosion: Explosion) !void {
    if (explosion.sound == null) return;
    try audio.playFor(explosion.sound.?);
}

fn captureExplosionVisual(
    impactPosition: vec.Vec2,
    pressureSourcePosition: vec.Vec2,
    explosion: Explosion,
) void {
    if (explosion.visual == null) return;
    explosion_visual.capture(explosion.visual.?, .{
        .impact_position = impactPosition,
        .pressure_source_position = pressureSourcePosition,
        .blast_radius = explosion.blastRadius,
        .pressure_radius = explosion.pressureRadius,
    }) catch |err| {
        std.log.warn("captureExplosionVisual: failed to capture explosion visual: {}", .{err});
    };
}

fn explodeAtWithDirectHit(
    impactPosition: vec.Vec2,
    pressureSourcePosition: vec.Vec2,
    explosion: Explosion,
    attackerId: ?usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    const perfId = beginExplosionPerfLog();
    const totalStart = perf.begin(.explosion);
    const cutoutSeed = cutoutSeedForExplosion(impactPosition, pressureSourcePosition, explosion);

    const pressureStart = perf.begin(.explosion);
    var pressureField = try blast_pressure.build(pressureSourcePosition, explosion.pressureRadius);
    defer blast_pressure.deinit(&pressureField);
    blast_pressure_visual.capture(pressureField) catch |err| {
        std.log.warn("explodeAtWithDirectHit: failed to capture blast pressure visualization: {}", .{err});
    };
    captureExplosionVisual(impactPosition, pressureSourcePosition, explosion);
    logExplosionStage(perfId, "pressure_field", pressureStart);

    const soundStart = perf.begin(.explosion);
    try playExplosionSound(explosion);
    logExplosionStage(perfId, "sound", soundStart);

    const impulseStart = perf.begin(.explosion);
    applyExplosionPressureToBodies(pressureField, explosion);
    logExplosionStage(perfId, "body_pressure", impulseStart);

    const entityDamageStart = perf.begin(.explosion);
    try damageEntitiesInExplosion(pressureField, impactPosition, explosion, attackerId, cutoutSeed);
    logExplosionStage(perfId, "entity_damage", entityDamageStart);

    const playerPressureStart = perf.begin(.explosion);
    try applyExplosionPressureToPlayers(pressureField, explosion, attackerId, directHitDamage);
    logExplosionStage(perfId, "player_pressure", playerPressureStart);
    logExplosionStage(perfId, "total", totalStart);
}

pub fn explodeAt(pos: vec.Vec2, explosion: Explosion, attackerId: ?usize) !void {
    try explodeAtWithDirectHit(pos, pos, explosion, attackerId, null);
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
        .carried_fraction = hitscanBloodCarryFraction,
        .carried_spread_radians = hitscanBloodCarrySpreadRadians,
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
    impactPosition: vec.Vec2,
    pressureSourcePosition: vec.Vec2,
    ownerId: usize,
    directHitDamage: ?DirectHitDamage,
) !void {
    if (explosion == null) return;
    try explodeAtWithDirectHit(impactPosition, pressureSourcePosition, explosion.?, ownerId, directHitDamage);
}

fn finishProjectile(
    bodyId: box2d.c.b2BodyId,
    impactPoint: vec.Vec2,
    pressureSourcePosition: vec.Vec2,
    directHitDamage: ?DirectHitDamage,
) !void {
    const removed = activeProjectiles.fetchSwapRemove(bodyId) orelse return;
    _ = propulsions.swapRemove(bodyId);

    const active = removed.value;
    const projectileEntity = entity.entities.getLocking(bodyId) orelse {
        std.log.warn("finishProjectile: projectile body has no entity", .{});
        try triggerProjectileExplosion(active.explosion, impactPoint, pressureSourcePosition, active.owner_id, directHitDamage);
        return;
    };
    entity.cleanupLater(projectileEntity);
    try triggerProjectileExplosion(active.explosion, impactPoint, pressureSourcePosition, active.owner_id, directHitDamage);
}

fn projectileImpactPoint(bodyId: box2d.c.b2BodyId, maybePoint: ?vec.Vec2) vec.Vec2 {
    if (maybePoint != null) return maybePoint.?;
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("projectileImpactPoint: projectile body became invalid before contact handling", .{});
        return vec.zero;
    }
    return vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId));
}

fn directHitDamageAmount(active: ActiveProjectile) f32 {
    if (active.explosion == null) return active.direct_damage;
    const explosion = active.explosion.?;
    if (!explosion.damagePlayers) return active.direct_damage;
    if (explosion.maximumDamage <= 0) return active.direct_damage;
    return @min(active.direct_damage, explosion.maximumDamage);
}

fn damagePlayerFromPhysicalImpact(bodyId: box2d.c.b2BodyId, playerId: usize, impactPoint: vec.Vec2, active: ActiveProjectile) !f32 {
    if (active.direct_damage <= 0) return 0;

    const victim = player.players.get(playerId) orelse {
        std.log.err("damagePlayerFromPhysicalImpact: player {d} is missing", .{playerId});
        return error.PlayerUnspawned;
    };
    const directDamage = directHitDamageAmount(active);
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

fn pressureSourceForImpact(
    bodyId: box2d.c.b2BodyId,
    impactPoint: vec.Vec2,
    otherCategoryBits: u64,
    maybeOutwardNormal: ?vec.Vec2,
) vec.Vec2 {
    if ((otherCategoryBits & collision.MASK_EXPLOSION_PRESSURE_BLOCKER) == 0) return impactPoint;

    var outwardNormal = if (maybeOutwardNormal != null)
        normalizedOrZero(maybeOutwardNormal.?)
    else
        vec.zero;
    if (vec.magnitude(outwardNormal) < 0.001) {
        const projectileVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
        outwardNormal = vec.mul(normalizedOrZero(projectileVelocity), -1);
    }
    if (vec.magnitude(outwardNormal) < 0.001) {
        std.log.warn("pressureSourceForImpact: pressure-blocking impact has no usable normal", .{});
        return impactPoint;
    }
    return blast_pressure.sourceOutsideSurface(impactPoint, outwardNormal);
}

fn handleProjectileContactForBody(
    bodyId: box2d.c.b2BodyId,
    otherShapeId: box2d.c.b2ShapeId,
    maybePoint: ?vec.Vec2,
    maybeOutwardNormal: ?vec.Vec2,
) !void {
    const active = activeProjectiles.get(bodyId) orelse return;
    const otherFilter = box2d.c.b2Shape_GetFilter(otherShapeId);
    if ((otherFilter.categoryBits & collision.CATEGORY_HOOK) != 0) return;

    const impactPoint = projectileImpactPoint(bodyId, maybePoint);
    if ((otherFilter.categoryBits & collision.CATEGORY_PLAYER) == 0) {
        const otherBodyId = box2d.c.b2Shape_GetBody(otherShapeId);
        const projectileVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId));
        const pressureSourcePosition = pressureSourceForImpact(
            bodyId,
            impactPoint,
            otherFilter.categoryBits,
            maybeOutwardNormal,
        );
        try destruction.apply(otherBodyId, .{
            .source = .projectile,
            .amount = active.direct_damage,
            .position = impactPoint,
            .direction = normalizedOrZero(projectileVelocity),
            .attackerId = active.owner_id,
        });
        try finishProjectile(bodyId, impactPoint, pressureSourcePosition, null);
        return;
    }

    if (active.penetration == .penetrating) return;

    const otherBodyId = box2d.c.b2Shape_GetBody(otherShapeId);
    const playerId = playerIdForBody(otherBodyId) orelse {
        std.log.warn("handleProjectileContactForBody: contacted player shape has no player", .{});
        try finishProjectile(bodyId, impactPoint, impactPoint, null);
        return;
    };
    const directDamage = try damagePlayerFromPhysicalImpact(bodyId, playerId, impactPoint, active);
    const directHitDamage: ?DirectHitDamage = if (active.explosion != null and active.explosion.?.damagePlayers)
        .{ .player_id = playerId, .applied_damage = directDamage }
    else
        null;
    try finishProjectile(bodyId, impactPoint, impactPoint, directHitDamage);
}

fn handleProjectileContact(
    shapeIdA: box2d.c.b2ShapeId,
    shapeIdB: box2d.c.b2ShapeId,
    maybePoint: ?vec.Vec2,
    outwardNormalForA: ?vec.Vec2,
    outwardNormalForB: ?vec.Vec2,
) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) return;

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);
    try handleProjectileContactForBody(bodyIdA, shapeIdB, maybePoint, outwardNormalForA);
    try handleProjectileContactForBody(bodyIdB, shapeIdA, maybePoint, outwardNormalForB);
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
    errdefer destruction.flushSurfaceEdits() catch |err| {
        std.log.err("checkContacts: failed to flush surface edits: {}", .{err});
    };

    const sensorEvents = box2d.getSensorEvents();
    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const event = sensorEvents.beginEvents[i];
        try handlePenetratingSensorContact(event.sensorShapeId, event.visitorShapeId);
    }

    const contactEvents = box2d.getContactEvents();

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        const normalFromAToB = vec.fromBox2d(event.normal);
        try handleProjectileContact(
            event.shapeIdA,
            event.shapeIdB,
            vec.fromBox2d(event.point),
            vec.mul(normalFromAToB, -1),
            normalFromAToB,
        );
    }

    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try handleProjectileContact(event.shapeIdA, event.shapeIdB, null, null, null);
    }

    try destruction.flushSurfaceEdits();
}

pub fn cleanup() void {
    activeProjectiles.clearAndFree(allocator);
    propulsions.clearAndFree(allocator);
}
