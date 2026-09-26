const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const data = @import("data.zig");
const particle_effect = @import("particle_effect.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

pub const Source = enum {
    hitscan,
    projectile,
    explosion,
};

pub const Event = struct {
    source: Source,
    amount: f32,
    position: vec.Vec2,
    direction: vec.Vec2 = vec.zero,
    debrisVelocity: vec.Vec2 = vec.zero,
    radius: f32 = 0,
    cutoutIrregularity: f32 = 0,
    cutoutCharWidth: f32 = 0,
    cutoutCharStrength: f32 = 0,
    cutoutHotRimWidth: f32 = 0,
    cutoutHotRimDurationMs: u32 = 0,
    cutoutSeed: u64 = 0,
    attackerId: ?usize = null,
};

pub const Health = struct {
    current: f32,
    maximum: f32,
};

pub const HealthOutcome = enum { alive, dead, gibbed };
pub const HealthResult = struct {
    remaining: f32,
    outcome: HealthOutcome,
};

pub var rules: data.DamageRulesData = .{};
pub var activeAttack: ?u64 = null;
var nextAttack: u64 = 1;

pub fn newAttackId() u64 {
    const id = nextAttack;
    nextAttack += 1;
    return id;
}

// Nested direct-hit/explosion work belongs to the same attack. Each physical
// projectile keeps its ID across contacts; separate pellets have separate IDs.
pub fn beginAttack(id: ?u64) ?u64 {
    const previous = activeAttack;
    activeAttack = previous orelse id orelse newAttackId();
    return previous;
}

pub fn configure(candidate: data.DamageRulesData) !void {
    if (!std.math.isFinite(candidate.gibHealthThreshold) or candidate.gibHealthThreshold >= 0) {
        std.log.warn("damage.configure: gibHealthThreshold must be finite and below zero, got {d}", .{candidate.gibHealthThreshold});
        return error.InvalidDamageRules;
    }
    if (!std.math.isFinite(candidate.ragdollHealth) or candidate.ragdollHealth <= 0 or
        candidate.maximumRagdolls == 0 or candidate.maximumRagdolls > 64)
    {
        std.log.warn("damage.configure: expected positive ragdollHealth and 1..64 maximumRagdolls", .{});
        return error.InvalidDamageRules;
    }
    rules = candidate;
}

// Shared subtraction and classification. Owners choose the actual death effect.
pub fn applyHealth(current: f32, amount: f32) ?HealthResult {
    if (!std.math.isFinite(current) or !std.math.isFinite(amount)) {
        std.log.warn("damage.applyHealth: non-finite health or damage ({d}, {d})", .{ current, amount });
        return null;
    }
    if (amount <= 0) return null; // Healing is not a damage event.
    const remaining = current - amount;
    if (!std.math.isFinite(remaining)) {
        std.log.warn("damage.applyHealth: health subtraction overflow ({d}, {d})", .{ current, amount });
        return null;
    }
    const outcome: HealthOutcome = if (remaining > 0) .alive else if (remaining <= rules.gibHealthThreshold) .gibbed else .dead;
    return .{ .remaining = remaining, .outcome = outcome };
}

pub const SurfaceCutout = struct {
    radiusScale: f32 = 1,
    minimumRadius: f32 = 0.01,
};

pub const Model = union(enum) {
    health: Health,
    shared_health: box2d.c.b2BodyId,
    surface_cutout: SurfaceCutout,
};

pub const ParticleBurst = struct {
    effectId: particle_effect.Id,
    amount: f32,
    spreadRadians: f32,
    inheritedVelocityScale: f32 = 0.55,
    color: ?sprite.Color = null,
};

pub const DestructionEffect = union(enum) {
    none,
    particle_burst: ParticleBurst,
    spawn_rubble: u64,
};

pub const DestructionLifecycle = enum {
    remove,
    return_to_pool,
    ragdoll,
};

pub const DestructionResponse = struct {
    effect: DestructionEffect,
    lifecycle: DestructionLifecycle,
};

pub const Component = struct {
    model: Model,
    onDestroyed: DestructionEffect = .none,
    destructionLifecycle: DestructionLifecycle = .remove,
    pendingDestruction: bool = false,
    immuneAttack: u64 = 0,
};

pub const Outcome = union(enum) {
    ignored,
    damaged,
    surface_cutout: SurfaceCutout,
    destroyed: DestructionResponse,
};

pub var components = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, Component).empty;

pub fn register(bodyId: box2d.c.b2BodyId, component: Component) !void {
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.err("damage.register: body is invalid", .{});
        return error.InvalidBody;
    }
    if (components.contains(bodyId)) {
        std.log.err("damage.register: body already has a damage component", .{});
        return error.DamageComponentAlreadyRegistered;
    }

    try components.put(allocator, bodyId, component);
}

pub fn unregister(bodyId: box2d.c.b2BodyId) bool {
    return components.swapRemove(bodyId);
}

pub fn reset(bodyId: box2d.c.b2BodyId) !void {
    const component = components.getPtr(bodyId) orelse {
        std.log.err("damage.reset: body has no damage component", .{});
        return error.DamageComponentNotFound;
    };

    component.pendingDestruction = false;
    switch (component.model) {
        .health => |*health| health.current = health.maximum,
        .surface_cutout, .shared_health => {},
    }
}

pub fn apply(bodyId: box2d.c.b2BodyId, event: Event) Outcome {
    const previous = beginAttack(null);
    defer activeAttack = previous;
    const target = healthOwner(bodyId);
    const component = components.getPtr(target) orelse return .ignored;
    if (component.pendingDestruction) return .ignored;
    if (component.immuneAttack == activeAttack.?) return .ignored;

    switch (component.model) {
        .health => |*health| {
            const result = applyHealth(health.current, event.amount) orelse return .ignored;
            health.current = result.remaining;
            if (result.outcome == .alive) return .damaged;

            // Preserve overkill for owners that distinguish ordinary destruction
            // from gibbing. Ordinary objects retain their registered effect.
            component.pendingDestruction = true;
            return .{ .destroyed = .{
                .effect = component.onDestroyed,
                .lifecycle = component.destructionLifecycle,
            } };
        },
        .surface_cutout => |surfaceCutout| {
            if (!std.math.isFinite(event.radius) or event.radius <= 0) return .ignored;
            return .{ .surface_cutout = surfaceCutout };
        },
        .shared_health => {
            std.log.err("damage.apply: shared health must point directly to its owner", .{});
            return .ignored;
        },
    }
}

pub fn healthOwner(bodyId: box2d.c.b2BodyId) box2d.c.b2BodyId {
    const component = components.get(bodyId) orelse return bodyId;
    return switch (component.model) {
        .shared_health => |owner| owner,
        else => bodyId,
    };
}

pub fn markDestroyed(bodyId: box2d.c.b2BodyId) ?DestructionResponse {
    const component = components.getPtr(bodyId) orelse return null;
    if (component.pendingDestruction) return null;

    component.pendingDestruction = true;
    return .{
        .effect = component.onDestroyed,
        .lifecycle = component.destructionLifecycle,
    };
}

pub fn cleanup() void {
    components.deinit(allocator);
    components = .empty;
}
