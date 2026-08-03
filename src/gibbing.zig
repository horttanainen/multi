const std = @import("std");

const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const damage = @import("damage.zig");
const entity = @import("entity.zig");
const collision = @import("collision.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");
const pool = @import("pool.zig");
const particle_effect = @import("particle_effect.zig");
const runtime = @import("runtime.zig");
const blood = @import("blood.zig");
const time = @import("time.zig");

const GibletSet = struct {
    heads: []u64,
    legs: []u64,
    meat: []u64,
    headPoolId: pool.Id,
    legPoolId: pool.Id,
    meatPoolId: pool.Id,
};

const gibletBloodCooldownSeconds: f64 = 0.16;
const gibletBloodMinImpactSpeed: f32 = 1.4;
const gibletBloodMinDamage: f32 = 4.0;
const gibletBloodMaxDamage: f32 = 18.0;
const gibletBloodDamagePerSpeed: f32 = 3.0;
const maxHeadGibletsPerDeath: u32 = 1;
const maxLegGibletsPerDeath: u32 = 2;
const maxMeatGibletsPerDeath: u32 = 3;
const gibletColliderHalfExtentScale: f32 = 0.35;
const gibletColliderMinimumHalfExtent: f32 = 0.08;
const gibletHealth: f32 = 1.0;
const gibletDestructionParticleAmount: f32 = 18.0;
const gibletDestructionParticleSpreadRadians: f32 = std.math.pi * 0.55;

// uncolored template giblets
var templateHeadGiblets: []u64 = &[_]u64{};
var templateLegGiblets: []u64 = &[_]u64{};
var templateMeatGiblets: []u64 = &[_]u64{};

var playerGiblets: std.AutoHashMap(usize, GibletSet) = undefined;
var gibletBloodCooldowns = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, f64).empty;
var bloodParticleEffectId: ?particle_effect.Id = null;

pub fn init() !void {
    templateHeadGiblets = try fs.loadSpritesFromFolder(
        "giblets/head",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );
    templateLegGiblets = try fs.loadSpritesFromFolder(
        "giblets/leg",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );
    templateMeatGiblets = try fs.loadSpritesFromFolder(
        "giblets/meat",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );

    playerGiblets = std.AutoHashMap(usize, GibletSet).init(allocator);
    bloodParticleEffectId = try blood.particleEffectId();

    std.debug.print("Loaded giblet templates - heads: {}, legs: {}, meat: {}\n", .{ templateHeadGiblets.len, templateLegGiblets.len, templateMeatGiblets.len });
}

fn cleanupSpriteUuids(spriteUuids: []const u64) void {
    for (spriteUuids) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
}

fn createColoredSprites(templateGiblets: []const u64, playerColor: sprite.Color) ![]u64 {
    var coloredSprites = std.array_list.Managed(u64).init(allocator);
    errdefer {
        cleanupSpriteUuids(coloredSprites.items);
        coloredSprites.deinit();
    }

    for (templateGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredSprites.append(colored);
    }

    return coloredSprites.toOwnedSlice();
}

fn gibletCollider(spriteUuid: u64) !box2d.c.b2Polygon {
    const gibletSprite = sprite.getSprite(spriteUuid) orelse {
        std.log.err("gibletCollider: sprite {d} is missing", .{spriteUuid});
        return error.SpriteNotFound;
    };
    const halfWidth = @max(gibletColliderMinimumHalfExtent, gibletSprite.sizeM.x * gibletColliderHalfExtentScale);
    const halfHeight = @max(gibletColliderMinimumHalfExtent, gibletSprite.sizeM.y * gibletColliderHalfExtentScale);
    return box2d.c.b2MakeBox(halfWidth, halfHeight);
}

fn gibletShapeDef() box2d.c.b2ShapeDef {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = 0.5;
    shapeDef.density = 1.0;
    shapeDef.filter.categoryBits = collision.CATEGORY_GIBLET;
    shapeDef.filter.maskBits = collision.MASK_GIBLET;
    shapeDef.enableHitEvents = true;
    shapeDef.enableContactEvents = true;
    return shapeDef;
}

fn gibletBatchSize(spriteTemplates: []const u64, maximumPerDeath: u32) usize {
    return @max(spriteTemplates.len, @as(usize, @intCast(maximumPerDeath)));
}

fn destroyGibletBodies(bodyIds: []const box2d.c.b2BodyId) void {
    for (bodyIds) |bodyId| {
        _ = gibletBloodCooldowns.swapRemove(bodyId);
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;
        if (entity.remove(bodyId)) continue;
        std.log.warn("destroyGibletBodies: pooled body has no entity", .{});
    }
}

fn destroyGibletPool(poolId: pool.Id) void {
    const bodyIds = pool.takeBodyIds(poolId) catch |err| {
        std.log.err("destroyGibletPool: could not take bodies from pool {d}: {}", .{ poolId, err });
        return;
    };
    defer allocator.free(bodyIds);
    destroyGibletBodies(bodyIds);
}

fn createPooledGibletBody(templateSpriteUuid: u64) !box2d.c.b2BodyId {
    const destructionParticleEffectId = bloodParticleEffectId orelse {
        std.log.err("createPooledGibletBody: blood particle effect is not initialized", .{});
        return error.BloodParticleEffectNotInitialized;
    };
    const collider = try gibletCollider(templateSpriteUuid);
    const bodyDef = box2d.createDynamicBodyDef(vec.zero);
    const gibletEntity = try entity.createFromShape(templateSpriteUuid, collider, gibletShapeDef(), bodyDef, "dynamic");
    errdefer _ = entity.remove(gibletEntity.bodyId);
    entity.markSpriteUuidsShared(gibletEntity.bodyId);

    try damage.register(gibletEntity.bodyId, .{
        .model = .{ .health = .{
            .current = gibletHealth,
            .maximum = gibletHealth,
        } },
        .onDestroyed = .{ .particle_burst = .{
            .effectId = destructionParticleEffectId,
            .amount = gibletDestructionParticleAmount,
            .spreadRadians = gibletDestructionParticleSpreadRadians,
        } },
        .destructionLifecycle = .return_to_pool,
    });

    const pooledEntity = entity.entities.getPtrLocking(gibletEntity.bodyId) orelse {
        std.log.err("createPooledGibletBody: new pooled entity is missing", .{});
        return error.EntityNotFound;
    };
    pooledEntity.enabled = false;
    box2d.c.b2Body_Disable(gibletEntity.bodyId);

    try gibletBloodCooldowns.put(allocator, gibletEntity.bodyId, 0.0);
    errdefer _ = gibletBloodCooldowns.swapRemove(gibletEntity.bodyId);

    return gibletEntity.bodyId;
}

fn createGibletBodies(spriteTemplates: []const u64, batchSize: usize) ![]box2d.c.b2BodyId {
    if (spriteTemplates.len == 0) {
        std.log.err("createGibletBodies: cannot create bodies without sprite templates", .{});
        return error.NoGibletSprites;
    }
    if (batchSize == 0) {
        std.log.err("createGibletBodies: cannot create an empty batch", .{});
        return error.EmptyGibletBatch;
    }

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    defer bodyIds.deinit();
    errdefer destroyGibletBodies(bodyIds.items);

    for (0..batchSize) |index| {
        const bodyId = try createPooledGibletBody(spriteTemplates[index % spriteTemplates.len]);
        bodyIds.append(bodyId) catch |err| {
            destroyGibletBodies(&.{bodyId});
            return err;
        };
    }

    return bodyIds.toOwnedSlice();
}

fn createGibletPool(spriteTemplates: []const u64, batchSize: usize) !pool.Id {
    const bodyIds = try createGibletBodies(spriteTemplates, batchSize);
    defer allocator.free(bodyIds);
    errdefer destroyGibletBodies(bodyIds);
    return pool.create(bodyIds);
}

fn replenishGibletPool(poolId: pool.Id, spriteTemplates: []const u64, batchSize: usize) !void {
    const bodyIds = try createGibletBodies(spriteTemplates, batchSize);
    defer allocator.free(bodyIds);
    errdefer destroyGibletBodies(bodyIds);
    try pool.addBodies(poolId, bodyIds);
}

fn cleanupGibletSet(gibletSet: GibletSet) void {
    destroyGibletPool(gibletSet.headPoolId);
    destroyGibletPool(gibletSet.legPoolId);
    destroyGibletPool(gibletSet.meatPoolId);

    cleanupSpriteUuids(gibletSet.heads);
    allocator.free(gibletSet.heads);
    cleanupSpriteUuids(gibletSet.legs);
    allocator.free(gibletSet.legs);
    cleanupSpriteUuids(gibletSet.meat);
    allocator.free(gibletSet.meat);
}

pub fn prepareGibletsForPlayer(playerId: usize, playerColor: sprite.Color) !void {
    const coloredHeads = try createColoredSprites(templateHeadGiblets, playerColor);
    errdefer {
        cleanupSpriteUuids(coloredHeads);
        allocator.free(coloredHeads);
    }

    const coloredLegs = try createColoredSprites(templateLegGiblets, playerColor);
    errdefer {
        cleanupSpriteUuids(coloredLegs);
        allocator.free(coloredLegs);
    }

    const coloredMeat = try createColoredSprites(templateMeatGiblets, playerColor);
    errdefer {
        cleanupSpriteUuids(coloredMeat);
        allocator.free(coloredMeat);
    }

    if (coloredHeads.len == 0 or coloredLegs.len == 0 or coloredMeat.len == 0) {
        std.log.err("prepareGibletsForPlayer: one or more giblet categories are empty for player {d}", .{playerId});
        return error.NoGibletSprites;
    }

    const headBatchSize = gibletBatchSize(coloredHeads, maxHeadGibletsPerDeath);
    const legBatchSize = gibletBatchSize(coloredLegs, maxLegGibletsPerDeath);
    const meatBatchSize = gibletBatchSize(coloredMeat, maxMeatGibletsPerDeath);
    const headPoolId = try createGibletPool(coloredHeads, headBatchSize);
    errdefer destroyGibletPool(headPoolId);
    const legPoolId = try createGibletPool(coloredLegs, legBatchSize);
    errdefer destroyGibletPool(legPoolId);
    const meatPoolId = try createGibletPool(coloredMeat, meatBatchSize);
    errdefer destroyGibletPool(meatPoolId);

    const gibletSet = GibletSet{
        .heads = coloredHeads,
        .legs = coloredLegs,
        .meat = coloredMeat,
        .headPoolId = headPoolId,
        .legPoolId = legPoolId,
        .meatPoolId = meatPoolId,
    };

    const oldGibletSet = playerGiblets.get(playerId);
    try playerGiblets.put(playerId, gibletSet);
    if (oldGibletSet != null) {
        cleanupGibletSet(oldGibletSet.?);
    }

    std.debug.print("Prepared giblet pools for player {}: {} heads, {} legs, {} meat, {} bodies\n", .{ playerId, gibletSet.heads.len, gibletSet.legs.len, gibletSet.meat.len, headBatchSize + legBatchSize + meatBatchSize });
}

fn acquireGiblet(poolId: pool.Id, spriteTemplates: []const u64, batchSize: usize) !pool.Acquisition {
    const available = try pool.acquire(poolId, .return_null);
    if (available != null) return available.?;

    try replenishGibletPool(poolId, spriteTemplates, batchSize);
    const replenished = try pool.acquire(poolId, .return_null);
    if (replenished == null) {
        std.log.err("acquireGiblet: replenished pool {d} has no available body", .{poolId});
        return error.EmptyGibletPool;
    }
    return replenished.?;
}

fn activateGiblet(poolId: pool.Id, spriteTemplates: []const u64, batchSize: usize, posM: vec.Vec2) !void {
    const acquisition = try acquireGiblet(poolId, spriteTemplates, batchSize);
    const bodyId = acquisition.bodyId;
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.err("activateGiblet: pooled body is invalid", .{});
        _ = pool.discardBody(bodyId);
        return error.InvalidGibletBody;
    }
    box2d.c.b2Body_Disable(bodyId);
    errdefer {
        const failedEntity = entity.entities.getPtrLocking(bodyId);
        if (failedEntity != null) {
            failedEntity.?.enabled = false;
        }
        pool.release(poolId, bodyId) catch |err| {
            std.log.err("activateGiblet: could not return failed acquisition to pool {d}: {}", .{ poolId, err });
        };
    }

    const pooledEntity = entity.entities.getPtrLocking(bodyId) orelse {
        std.log.err("activateGiblet: pooled body has no entity", .{});
        return error.EntityNotFound;
    };
    const nextBloodSpatterAt = gibletBloodCooldowns.getPtr(bodyId) orelse {
        std.log.err("activateGiblet: pooled body has no blood cooldown", .{});
        return error.MissingGibletCooldown;
    };

    try damage.reset(bodyId);
    pooledEntity.state = null;
    pooledEntity.enabled = true;
    nextBloodSpatterAt.* = 0.0;

    const variedPosM: vec.Vec2 = .{
        .x = posM.x + runtime.random().float(f32) * 2 - 1,
        .y = posM.y - runtime.random().float(f32) * 2,
    };
    const rotationAngle = runtime.random().float(f32) * std.math.pi * 2.0;
    box2d.c.b2Body_SetTransform(bodyId, vec.toBox2d(variedPosM), box2d.c.b2MakeRot(rotationAngle));
    box2d.c.b2Body_SetLinearVelocity(bodyId, box2d.c.b2Vec2_zero);
    box2d.c.b2Body_SetAngularVelocity(bodyId, 0);
    box2d.c.b2Body_Enable(bodyId);

    // Apply random impulse to scatter giblets
    const angle = runtime.random().float(f32) * std.math.pi * 2.0;
    const force = 5.0 + runtime.random().float(f32) * 10.0;
    const impulse = box2d.c.b2Vec2{
        .x = std.math.cos(angle) * force,
        .y = std.math.sin(angle) * force,
    };
    box2d.c.b2Body_ApplyLinearImpulseToCenter(bodyId, impulse, true);
}

fn activateRandomGiblets(poolId: pool.Id, spriteUuids: []const u64, maximumPerDeath: u32, count: u32, posM: vec.Vec2) void {
    if (count == 0) return;
    if (spriteUuids.len == 0) {
        std.log.err("activateRandomGiblets: requested {d} giblets without sprites", .{count});
        return;
    }

    const batchSize = gibletBatchSize(spriteUuids, maximumPerDeath);
    for (0..count) |_| {
        activateGiblet(poolId, spriteUuids, batchSize, posM) catch |err| {
            std.log.err("activateRandomGiblets: failed to activate pooled giblet with {}", .{err});
        };
    }
}

pub fn gib(posM: vec.Vec2, playerId: usize) void {
    if (playerGiblets.getPtr(playerId) == null) {
        std.log.err("gib: no prepared giblets found for player {d}", .{playerId});
        return;
    }
    const gibletSet = playerGiblets.getPtr(playerId).?;

    const headCount = runtime.random().intRangeAtMost(u32, 0, maxHeadGibletsPerDeath);
    activateRandomGiblets(gibletSet.headPoolId, gibletSet.heads, maxHeadGibletsPerDeath, headCount, posM);

    const legCount = runtime.random().intRangeAtMost(u32, 0, maxLegGibletsPerDeath);
    activateRandomGiblets(gibletSet.legPoolId, gibletSet.legs, maxLegGibletsPerDeath, legCount, posM);

    const meatCount = runtime.random().intRangeAtMost(u32, 1, maxMeatGibletsPerDeath);
    activateRandomGiblets(gibletSet.meatPoolId, gibletSet.meat, maxMeatGibletsPerDeath, meatCount, posM);
}

fn createColoredSprite(gibletSpriteUuid: u64, playerColor: sprite.Color) !u64 {
    const coloredSpriteUuid = try sprite.createMutableCopy(gibletSpriteUuid);
    errdefer sprite.cleanupLater(coloredSpriteUuid);

    const bloodColor = try blood.currentColor();

    try sprite.colorMatchingPixels(coloredSpriteUuid, bloodColor, sprite.isCyan);
    try sprite.colorMatchingPixels(coloredSpriteUuid, playerColor, sprite.isWhite);

    return coloredSpriteUuid;
}

fn cleanupInvalidTrackedGiblets() void {
    var index: usize = 0;
    while (index < gibletBloodCooldowns.count()) {
        const bodyId = gibletBloodCooldowns.keys()[index];
        if (box2d.c.b2Body_IsValid(bodyId)) {
            index += 1;
            continue;
        }

        _ = gibletBloodCooldowns.swapRemove(bodyId);
        _ = damage.unregister(bodyId);
        _ = pool.discardBody(bodyId);
    }
}

fn shapeCanReceiveGibletBlood(shapeId: box2d.c.b2ShapeId) bool {
    if (!box2d.c.b2Shape_IsValid(shapeId)) {
        return false;
    }

    const filter = box2d.c.b2Shape_GetFilter(shapeId);
    const mask = collision.CATEGORY_TERRAIN | collision.CATEGORY_DYNAMIC | collision.CATEGORY_UNBREAKABLE;
    return (filter.categoryBits & mask) != 0;
}

fn spatterFromGiblet(gibletBodyId: box2d.c.b2BodyId, targetShapeId: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Body_IsValid(gibletBodyId)) {
        return;
    }
    if (!shapeCanReceiveGibletBlood(targetShapeId)) {
        return;
    }

    const nextAllowed = gibletBloodCooldowns.getPtr(gibletBodyId) orelse {
        return;
    };

    const now = time.now();
    if (now < nextAllowed.*) {
        return;
    }

    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(gibletBodyId));
    const speed = vec.magnitude(velocity);
    if (speed < gibletBloodMinImpactSpeed) {
        return;
    }

    nextAllowed.* = now + gibletBloodCooldownSeconds;
    const pos = vec.fromBox2d(box2d.c.b2Body_GetPosition(gibletBodyId));
    const impactAmount = std.math.clamp((speed - gibletBloodMinImpactSpeed) * gibletBloodDamagePerSpeed, gibletBloodMinDamage, gibletBloodMaxDamage);
    try blood.createParticlesFromImpact(pos, impactAmount, velocity);
}

fn handleGibletContact(shapeIdA: box2d.c.b2ShapeId, shapeIdB: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) {
        return;
    }

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);
    const aIsGiblet = gibletBloodCooldowns.contains(bodyIdA);
    const bIsGiblet = gibletBloodCooldowns.contains(bodyIdB);

    if (aIsGiblet and !bIsGiblet) {
        try spatterFromGiblet(bodyIdA, shapeIdB);
    }
    if (bIsGiblet and !aIsGiblet) {
        try spatterFromGiblet(bodyIdB, shapeIdA);
    }
}

pub fn checkContacts() !void {
    cleanupInvalidTrackedGiblets();

    const contactEvents = box2d.getContactEvents();
    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try handleGibletContact(event.shapeIdA, event.shapeIdB);
    }

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        try handleGibletContact(event.shapeIdA, event.shapeIdB);
    }
}

pub fn cleanup() void {
    // Clean up template giblets
    for (templateHeadGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateHeadGiblets);

    for (templateLegGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateLegGiblets);

    for (templateMeatGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateMeatGiblets);

    // Clean up all player-specific colored giblets
    var iter = playerGiblets.valueIterator();
    while (iter.next()) |gibletSet| {
        cleanupGibletSet(gibletSet.*);
    }

    playerGiblets.deinit();
    gibletBloodCooldowns.clearAndFree(allocator);
    bloodParticleEffectId = null;
}
