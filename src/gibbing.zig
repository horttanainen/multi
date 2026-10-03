const character_hair = @import("character_hair.zig");
const std = @import("std");

const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const damage = @import("damage.zig");
const ragdoll = @import("ragdoll.zig");
const entity = @import("entity.zig");
const collision = @import("collision.zig");
const config = @import("config.zig");
const data = @import("data.zig");
const character_art = @import("character_art.zig");
const character_animation = @import("character_animation.zig");
const player = @import("player.zig");
const vec = @import("vector.zig");
const pool = @import("pool.zig");
const particle_effect = @import("particle_effect.zig");
const particle = @import("particle.zig");
const runtime = @import("runtime.zig");
const blood = @import("blood.zig");
const time = @import("time.zig");

// A slot keeps both layers on one physical object. Pools are shared across
// players; tint and pose belong to each activation, never to the shared textures.
pub const PartPools = struct { facing: [2]pool.Id };
pub var partPools: []PartPools = &.{};
var gibletBloodCooldowns = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, f64).empty;
var bloodParticleEffectId: ?particle_effect.Id = null;
pub var pooledBodyCreationCount: u64 = 0;
pub var poolRecycleCount: u64 = 0;

const gibletBloodCooldownSeconds: f64 = 0.16;
const gibletBloodMinImpactSpeed: f32 = 1.4;
const gibletBloodMinDamage: f32 = 4.0;
const gibletBloodMaxDamage: f32 = 18.0;
const gibletBloodDamagePerSpeed: f32 = 3.0;
pub const consumedPartBloodAmount: f32 = 4;
const destroyedPartBloodAmount: f32 = 18;

pub const PartSnapshot = struct {
    binding: usize,
    placed: character_art.PlacedPart,
    skin_color: sprite.Color,
    velocity: vec.Vec2,
    angular_velocity: f32,
    survival_weight: f32,
    hair: ?data.CharacterHairAppearance = null,
    hair_source: ?box2d.c.b2BodyId = null,
};
pub const Snapshot = struct { parts: [64]PartSnapshot = undefined, count: usize = 0 };

// Physics and artwork use the same mirrored pivot-relative coordinates.
pub fn collider(definition: data.CharacterArtPart, facing_right: bool) box2d.c.b2Polygon {
    const physics = definition.physics;
    const scale = definition.meters_per_pixel;
    const sign: f32 = if (facing_right) 1 else -1;
    return box2d.c.b2MakeOffsetBox(physics.half_extents[0] * scale, physics.half_extents[1] * scale, .{
        .x = (physics.center[0] - definition.pivot[0]) * scale * sign,
        .y = (physics.center[1] - definition.pivot[1]) * scale,
    }, box2d.c.b2Rot_identity);
}

pub fn snapshotPose(
    pack: *const character_art.Pack,
    rig: character_animation.Rig,
    frame: character_animation.FramePose,
    carrying: bool,
    color: sprite.Color,
    velocity: vec.Vec2,
    hair: ?data.CharacterHairAppearance,
) Snapshot {
    var result: Snapshot = .{};
    const points = character_art.worldJoints(rig, frame);
    // Preserve the manifest's back-to-front order on first activation.
    for (pack.order[@intFromBool(frame.facing_right)]) |item| {
        if (item != .part) continue;
        const index = item.part;
        const placed = character_art.placePart(pack, index, points, frame, carrying);
        result.parts[result.count] = .{
            .binding = index,
            .placed = placed,
            .skin_color = character_art.skinColor(color, if (placed.far) pack.far_skin_multiplier else 1),
            .velocity = velocity,
            .angular_velocity = 0,
            .survival_weight = pack.bindings[index].survival_weight,
            .hair = if (pack.hair != null and index == pack.hair.?.head_binding) hair else null,
        };
        result.count += 1;
    }
    return result;
}

// Shared by live-character and corpse snapshots. Exactly one draw per
// anatomical part, including zero/one weights, makes seeded checks reproducible.
pub fn selectSurvivors(snapshot: Snapshot, random: std.Random) [64]bool {
    var selected = [_]bool{false} ** 64;
    for (snapshot.parts[0..snapshot.count], selected[0..snapshot.count]) |part, *survives| {
        survives.* = random.float(f32) < part.survival_weight;
    }
    return selected;
}

// Add motion relative to the player's root, leaving the current physics velocity
// (including the fatal blast's impulse) intact. Facing/art changes are discrete.
pub fn inheritPoseMotion(
    snapshot: *Snapshot,
    previous: Snapshot,
    body: vec.Vec2,
    previous_body: vec.Vec2,
    seconds: f32,
) void {
    if (seconds <= 0 or snapshot.count != previous.count) {
        return;
    }
    for (snapshot.parts[0..snapshot.count], previous.parts[0..previous.count]) |*part, before| {
        if (part.binding != before.binding or
            part.placed.part != before.placed.part or
            part.placed.facing_right != before.placed.facing_right)
        {
            continue;
        }
        const local = vec.subtract(part.placed.position, body);
        const previous_local = vec.subtract(before.placed.position, previous_body);
        part.velocity = vec.add(part.velocity, vec.mul(vec.subtract(local, previous_local), 1 / seconds));
        const delta = part.placed.angle - before.placed.angle;
        part.angular_velocity = std.math.atan2(@sin(delta), @cos(delta)) / seconds;
    }
}

pub fn init() !void {
    bloodParticleEffectId = try blood.particleEffectId();
}

fn destroyBodies(bodyIds: []const box2d.c.b2BodyId) void {
    for (bodyIds) |bodyId| {
        _ = gibletBloodCooldowns.swapRemove(bodyId);
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;
        if (entity.remove(bodyId)) continue;
        std.log.warn("gibbing.destroyBodies: pooled body has no entity", .{});
    }
}

fn destroyPool(id: pool.Id) void {
    const bodies = pool.takeBodyIds(id) catch |err| {
        std.log.err("gibbing.destroyPool: cannot take pool {d}: {}", .{ id, err });
        return;
    };
    defer allocator.free(bodies);
    destroyBodies(bodies);
}

pub fn destroyPools(pools: []PartPools) void {
    for (pools) |part| {
        for (part.facing) |id| destroyPool(id);
    }
    allocator.free(pools);
}

fn createBody(
    part: character_art.Part,
    part_index: usize,
    facing: bool,
    effect: particle_effect.Id,
) !box2d.c.b2BodyId {
    if (part.sprites[0] == null or part.sprites[1] == null) {
        std.log.warn("gibbing.createBody: part {d} has missing artwork layers", .{part_index});
        return error.MissingCharacterPartSprite;
    }
    var shape = box2d.c.b2DefaultShapeDef();
    shape.material.friction = part.definition.physics.friction;
    shape.density = part.definition.physics.density;
    shape.filter.categoryBits = collision.CATEGORY_GIBLET;
    shape.filter.maskBits = collision.MASK_GIBLET;
    shape.enableHitEvents = true;
    shape.enableContactEvents = true;
    var body_def = box2d.createDynamicBodyDef(vec.zero);
    body_def.isEnabled = false;
    body_def.angularDamping = 0.4;
    const created = try entity.createFromShape(
        part.sprites[0].?,
        collider(part.definition, facing),
        shape,
        body_def,
        "dynamic",
        .rectangle,
    );
    entity.markSpriteUuidsShared(created.bodyId);
    errdefer _ = entity.remove(created.bodyId);
    try entity.addSprite(created.bodyId, part.sprites[1].?);
    const ent = entity.entities.getPtrLocking(created.bodyId) orelse {
        std.log.err("gibbing.createBody: newly created entity is missing", .{});
        return error.EntityNotFound;
    };
    ent.enabled = false;
    try character_art.bodyParts.put(allocator, created.bodyId, .{
        .part = part_index,
        .facing_right = facing,
        .skin_color = .{ .r = 255, .g = 255, .b = 255 },
    });
    try damage.register(created.bodyId, .{
        .model = .{ .health = .{ .current = 1, .maximum = 1 } },
        .onDestroyed = .{ .particle_burst = .{
            .effectId = effect,
            .amount = destroyedPartBloodAmount,
            .spreadRadians = std.math.pi * 0.55,
        } },
        .destructionLifecycle = .return_to_pool,
    });
    try gibletBloodCooldowns.put(allocator, created.bodyId, 0);
    if (comptime config.perf.explosion) {
        pooledBodyCreationCount += 1;
    }
    return created.bodyId;
}

fn createPool(
    pack: *const character_art.Pack,
    index: usize,
    facing: bool,
    effect: particle_effect.Id,
) !pool.Id {
    var count: usize = 0;
    for (pack.bindings) |binding| {
        if (binding.part == index or (index == pack.grip_part and binding.anchor == pack.weapon_joint)) {
            count += 1;
        }
    }
    // Connected corpses reserve their members. Leave room for two complete gib
    // deaths as well, without recycling within a death or stealing a corpse limb.
    const bodies = try allocator.alloc(
        box2d.c.b2BodyId,
        @max(4, count * (2 + damage.rules.maximumRagdolls)),
    );
    defer allocator.free(bodies);
    var created: usize = 0;
    errdefer destroyBodies(bodies[0..created]);
    for (bodies) |*body| {
        body.* = try createBody(pack.parts[index], index, facing, effect);
        created += 1;
        const hair = pack.hair orelse continue;
        if (index != pack.bindings[hair.head_binding].part) continue;
        try character_hair.prepare(body.*, null, hair.definition);
    }
    return pool.create(bodies);
}

// Prepare a complete replacement before touching active pools or artwork.
pub fn preparePools(pack: *const character_art.Pack, effect: particle_effect.Id) ![]PartPools {
    try ragdoll.prepareCapacity();
    const result = try allocator.alloc(PartPools, pack.parts.len);
    errdefer allocator.free(result);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |part| {
            for (part.facing) |id| destroyPool(id);
        }
    }
    for (result, 0..) |*part, index| {
        const left = try createPool(pack, index, false, effect);
        errdefer destroyPool(left);
        const right = try createPool(pack, index, true, effect);
        part.* = .{ .facing = .{ left, right } };
        count += 1;
    }
    return result;
}

pub fn prepareForLevel() !void {
    if (partPools.len != 0) return;
    if (character_art.assets == null or bloodParticleEffectId == null) {
        std.log.err("gibbing.prepareForLevel: artwork or blood is not initialized", .{});
        return error.GibbingNotInitialized;
    }
    try prewarmBlood(&character_art.assets.?, bloodParticleEffectId.?);
    partPools = try preparePools(&character_art.assets.?, bloodParticleEffectId.?);
}

fn prewarmBlood(pack: *const character_art.Pack, effect: particle_effect.Id) !void {
    const preset = particle_effect.presets.get(effect) orelse {
        std.log.warn("gibbing.prewarmBlood: blood preset is missing", .{});
        return error.BloodParticlePresetNotFound;
    };
    // Cover two overlapping direct-hit/explosion deaths and their consumed
    // parts. Connected corpses emit no impact blood. Use the emitter's exact
    // rounding/cap so the reserve follows changes to the artwork and preset.
    const count: f32 = @floatFromInt(pack.bindings.len);
    const per_part = @max(consumedPartBloodAmount, destroyedPartBloodAmount / count);
    const consumed = pack.bindings.len * particle_effect.particleCount(preset, per_part);
    try particle.prewarmBodies(2 * (2 * preset.maxParticles + consumed));
}

pub fn replaceArtwork(pack: *const character_art.Pack) !void {
    // Initial loading precedes blood/world preparation. An empty pool after that
    // can also mean recovery from a failed initial artwork load.
    if (bloodParticleEffectId == null) return;
    const effect = bloodParticleEffectId.?;
    try prewarmBlood(pack, effect);
    const replacement = try preparePools(pack, effect);
    clearBodies();
    partPools = replacement;
}

pub fn clearBodies() void {
    ragdoll.cleanup();
    destroyPools(partPools);
    partPools = &.{};
}

pub fn activatePart(part: PartSnapshot, scatter_velocity: vec.Vec2, scatter_spin: f32) !box2d.c.b2BodyId {
    if (part.placed.part >= partPools.len) {
        std.log.err("gibbing.activatePart: no pool for part {d}", .{part.placed.part});
        return error.MissingGibletPool;
    }
    const id = partPools[part.placed.part].facing[@intFromBool(part.placed.facing_right)];
    const acquired = (try pool.acquire(id, .recycle_oldest)) orelse {
        std.log.err("gibbing.activatePart: pool {d} is empty", .{id});
        return error.EmptyGibletPool;
    };
    const body = acquired.bodyId;
    if (comptime config.perf.explosion) {
        if (acquired.recycled) {
            poolRecycleCount += 1;
        }
    }
    box2d.c.b2Body_Disable(body);
    errdefer pool.release(id, body) catch |err| {
        std.log.err("gibbing.activatePart: cannot return failed activation: {}", .{err});
    };
    const ent = entity.entities.getPtrLocking(body) orelse {
        std.log.err("gibbing.activatePart: entity is missing", .{});
        return error.EntityNotFound;
    };
    ent.enabled = false;
    const cooldown = gibletBloodCooldowns.getPtr(body) orelse {
        std.log.err("gibbing.activatePart: blood cooldown is missing", .{});
        return error.MissingGibletCooldown;
    };
    const visual = character_art.bodyParts.getPtr(body) orelse {
        std.log.err("gibbing.activatePart: body part artwork is missing", .{});
        return error.MissingCharacterPart;
    };
    resetPartDamage(body);
    setCollisionGroup(body, 0);
    cooldown.* = 0;
    visual.* = .{
        .part = part.placed.part,
        .facing_right = part.placed.facing_right,
        .skin_color = part.skin_color,
        .severed = true,
        .hair = part.hair,
    };
    box2d.c.b2Body_SetTransform(
        body,
        vec.toBox2d(part.placed.position),
        box2d.c.b2MakeRot(part.placed.angle),
    );
    character_hair.inherit(part.hair_source, body, part.placed, scatter_velocity);
    ent.state = box2d.getState(body);
    box2d.c.b2Body_Enable(body);
    const center = vec.fromBox2d(box2d.c.b2Body_GetWorldCenterOfMass(body));
    const offset = vec.subtract(center, part.placed.position);
    const rotation_velocity: vec.Vec2 = .{
        .x = -offset.y * part.angular_velocity,
        .y = offset.x * part.angular_velocity,
    };
    const velocity = vec.add(vec.add(part.velocity, rotation_velocity), scatter_velocity);
    box2d.c.b2Body_SetLinearVelocity(body, vec.toBox2d(velocity));
    box2d.c.b2Body_SetAngularVelocity(body, part.angular_velocity + scatter_spin);
    ent.enabled = true;
    return body;
}

// Converting a connected limb to a giblet changes ownership and appearance only.
// Its Box2D transform, velocities, and pool activation identity remain intact.
pub fn resetPartDamage(bodyId: box2d.c.b2BodyId) void {
    const component = damage.components.getPtr(bodyId) orelse {
        std.log.err("gibbing.resetPartDamage: part has no damage component", .{});
        return;
    };
    component.model = .{ .health = .{ .current = 1, .maximum = 1 } };
    component.pendingDestruction = false;
    component.destructionLifecycle = .return_to_pool;
    component.immuneAttack = damage.activeAttack orelse 0;
}

pub fn setCollisionGroup(bodyId: box2d.c.b2BodyId, group: i32) void {
    const ent = entity.entities.getLocking(bodyId) orelse {
        std.log.err("gibbing.setCollisionGroup: part has no entity", .{});
        return;
    };
    for (ent.shapeIds) |shape| {
        var filter = box2d.c.b2Shape_GetFilter(shape);
        filter.groupIndex = group;
        box2d.c.b2Shape_SetFilter(shape, filter);
    }
}

pub fn releasePart(bodyId: box2d.c.b2BodyId) void {
    const ent = entity.entities.getPtrLocking(bodyId) orelse {
        std.log.err("gibbing.releasePart: part has no entity", .{});
        return;
    };
    box2d.c.b2Body_Disable(bodyId);
    ent.enabled = false;
    resetPartDamage(bodyId);
    pool.releaseBody(bodyId) catch |err| {
        std.log.err("gibbing.releasePart: cannot release part: {}", .{err});
    };
}

// Live deaths activate surviving parts. Corpses use selectSurvivors with the
// same binding weights and release their already-active bodies in place.
pub fn gib(snapshot: Snapshot, random: std.Random) void {
    const selected = selectSurvivors(snapshot, random);
    for (snapshot.parts[0..snapshot.count], selected[0..snapshot.count]) |part, survives| {
        if (!survives) {
            blood.createParticles(part.placed.position, consumedPartBloodAmount, part.velocity) catch |err| {
                std.log.err("gibbing.gib: could not emit consumed part: {}", .{err});
            };
            continue;
        }
        const angle = random.float(f32) * 2 * std.math.pi;
        const speed = 2 + random.float(f32) * 3;
        const velocity: vec.Vec2 = .{ .x = @cos(angle) * speed, .y = @sin(angle) * speed };
        const spin = (random.float(f32) * 2 - 1) * 6;
        _ = activatePart(part, velocity, spin) catch |err| {
            std.log.err("gibbing.gib: could not activate binding {d}: {}", .{ part.binding, err });
        };
    }
}

pub fn snapshotPlayer(player_id: usize) ?Snapshot {
    if (character_art.assets == null or character_animation.assets == null) {
        std.log.warn("gibbing.snapshotPlayer: character assets are missing", .{});
        return null;
    }
    const p = player.players.get(player_id) orelse {
        std.log.warn("gibbing.snapshotPlayer: player {d} is missing", .{player_id});
        return null;
    };
    const frame = character_animation.playerFrame(player_id, .physics, null) orelse {
        std.log.warn("gibbing.snapshotPlayer: player {d} pose is missing", .{player_id});
        return null;
    };
    const pack = &character_art.assets.?;
    const rig = character_animation.assets.?.rig;
    const carrying = player.usesProceduralWeapon(p);
    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(p.bodyId));
    const hair = character_art.hairForPlayer(pack, player_id);
    var snapshot = snapshotPose(pack, rig, frame, carrying, p.color, velocity, hair);
    for (snapshot.parts[0..snapshot.count]) |*part| {
        if (part.hair == null) continue;
        part.hair_source = p.bodyId;
    }
    const state = character_animation.states.get(player_id) orelse {
        std.log.warn("gibbing.snapshotPlayer: animation state is missing", .{});
        return null;
    };
    const before = character_animation.playerFrame(player_id, .previous_physics, null) orelse {
        std.log.warn("gibbing.snapshotPlayer: previous pose is missing", .{});
        return null;
    };
    if (state.initialized and state.facing_right == state.previous_facing_right) {
        const previous = snapshotPose(pack, rig, before, carrying, p.color, vec.zero, hair);
        inheritPoseMotion(&snapshot, previous, frame.body, before.body, state.step_seconds);
    }
    return snapshot;
}

pub fn gibPlayer(player_id: usize) void {
    const snapshot = snapshotPlayer(player_id) orelse return;
    gib(snapshot, runtime.random());
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
    // Connected corpses do not bleed from movement or environmental impacts.
    if (ragdoll.corpses.contains(damage.healthOwner(gibletBodyId))) return;
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
    clearBodies();
    gibletBloodCooldowns.clearAndFree(allocator);
    bloodParticleEffectId = null;
}
