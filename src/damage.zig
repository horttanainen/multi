const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const particle_effect = @import("particle_effect.zig");
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
    radius: f32 = 0,
    attackerId: ?usize = null,
};

pub const Health = struct {
    current: f32,
    maximum: f32,
};

pub const SurfaceCutout = struct {
    radiusScale: f32 = 1,
    minimumRadius: f32 = 0.01,
};

pub const Model = union(enum) {
    health: Health,
    surface_cutout: SurfaceCutout,
};

pub const ParticleBurst = struct {
    effectId: particle_effect.Id,
    amount: f32,
    spreadRadians: f32,
    inheritedVelocityScale: f32 = 0.55,
};

pub const DestructionEffect = union(enum) {
    none,
    particle_burst: ParticleBurst,
};

pub const Component = struct {
    model: Model,
    onDestroyed: DestructionEffect = .none,
    pendingDestruction: bool = false,
};

pub const Outcome = union(enum) {
    ignored,
    damaged,
    surface_cutout: SurfaceCutout,
    destroyed: DestructionEffect,
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
        .surface_cutout => {},
    }
}

pub fn apply(bodyId: box2d.c.b2BodyId, event: Event) Outcome {
    const component = components.getPtr(bodyId) orelse return .ignored;
    if (component.pendingDestruction) return .ignored;

    switch (component.model) {
        .health => |*health| {
            if (!std.math.isFinite(event.amount) or event.amount <= 0) return .ignored;

            health.current -= event.amount;
            if (health.current > 0) return .damaged;

            health.current = 0;
            component.pendingDestruction = true;
            return .{ .destroyed = component.onDestroyed };
        },
        .surface_cutout => |surfaceCutout| {
            if (!std.math.isFinite(event.radius) or event.radius <= 0) return .ignored;
            return .{ .surface_cutout = surfaceCutout };
        },
    }
}

pub fn markDestroyed(bodyId: box2d.c.b2BodyId) ?DestructionEffect {
    const component = components.getPtr(bodyId) orelse return null;
    if (component.pendingDestruction) return null;

    component.pendingDestruction = true;
    return component.onDestroyed;
}

pub fn cleanup() void {
    components.deinit(allocator);
    components = .empty;
}
