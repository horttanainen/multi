const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const collision = @import("collision.zig");
const data = @import("data.zig");
const particle = @import("particle.zig");
const runtime = @import("runtime.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

pub const Id = u64;

pub const Emission = struct {
    position: vec.Vec2,
    amount: f32,
    direction: ?vec.Vec2 = null,
    spread_radians: f32 = std.math.pi * 2.0,
    inherited_velocity: vec.Vec2 = vec.zero,
    inherited_velocity_scale: f32 = 0,
    carried_velocity: ?vec.Vec2 = null,
    carried_fraction: f32 = 0,
    carried_spread_radians: f32 = 0,
};

pub var presets = std.AutoArrayHashMapUnmanaged(Id, data.ParticleData).empty;
var presetNames = std.AutoArrayHashMapUnmanaged(Id, []const u8).empty;

fn idFromName(name: []const u8) Id {
    return std.hash.Wyhash.hash(0, name);
}

fn validatePreset(name: []const u8, preset: data.ParticleData) !void {
    if (!std.math.isFinite(preset.particlesPerUnit) or preset.particlesPerUnit <= 0) {
        std.log.err("particle_effect.validatePreset: preset '{s}' has invalid particles per unit", .{name});
        return error.InvalidParticleCountScale;
    }
    if (preset.maxParticles == 0) {
        std.log.err("particle_effect.validatePreset: preset '{s}' has no particle capacity", .{name});
        return error.InvalidMaximumParticleCount;
    }
    if (!std.math.isFinite(preset.minSpeedVariation) or !std.math.isFinite(preset.maxSpeedVariation) or
        preset.minSpeedVariation < 0 or preset.maxSpeedVariation < preset.minSpeedVariation)
    {
        std.log.err("particle_effect.validatePreset: preset '{s}' has an invalid speed range", .{name});
        return error.InvalidParticleSpeedRange;
    }
    if (!std.math.isFinite(preset.minScale) or !std.math.isFinite(preset.maxScale) or
        preset.minScale <= 0 or preset.maxScale < preset.minScale)
    {
        std.log.err("particle_effect.validatePreset: preset '{s}' has an invalid scale range", .{name});
        return error.InvalidParticleScaleRange;
    }
    if (preset.lifetimeMs == 0) {
        std.log.err("particle_effect.validatePreset: preset '{s}' has no lifetime", .{name});
        return error.InvalidParticleLifetime;
    }
    if (!std.math.isFinite(preset.linearDamping) or preset.linearDamping < 0 or
        !std.math.isFinite(preset.gravityScale) or
        !std.math.isFinite(preset.density) or preset.density <= 0 or
        !std.math.isFinite(preset.friction) or preset.friction < 0 or
        !std.math.isFinite(preset.restitution) or preset.restitution < 0)
    {
        std.log.err("particle_effect.validatePreset: preset '{s}' has invalid physical properties", .{name});
        return error.InvalidParticlePhysics;
    }

    if (preset.stain == null) return;
    const stain = preset.stain.?;
    if (!std.math.isFinite(stain.minRadius) or !std.math.isFinite(stain.maxRadius) or
        stain.minRadius <= 0 or stain.maxRadius < stain.minRadius)
    {
        std.log.err("particle_effect.validatePreset: preset '{s}' has an invalid stain radius range", .{name});
        return error.InvalidParticleStainRange;
    }
}

pub fn init() !void {
    errdefer cleanup();

    var presetIterator = data.particleDataMap.iterator();
    while (presetIterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const preset = entry.value_ptr.*;
        try validatePreset(name, preset);

        const id = idFromName(name);
        if (presets.contains(id)) {
            const existingName = presetNames.get(id) orelse "unknown";
            std.log.err("particle_effect.init: preset ID collision between '{s}' and '{s}'", .{ existingName, name });
            return error.ParticlePresetIdCollision;
        }

        try presets.put(allocator, id, preset);
        try presetNames.put(allocator, id, name);
    }
}

pub fn idForName(name: []const u8) ?Id {
    const id = idFromName(name);
    if (!presets.contains(id)) return null;

    const registeredName = presetNames.get(id) orelse {
        std.log.err("particle_effect.idForName: preset {d} has no registered name", .{id});
        return null;
    };
    if (!std.mem.eql(u8, registeredName, name)) {
        std.log.err("particle_effect.idForName: preset ID collision for '{s}'", .{name});
        return null;
    }
    return id;
}

pub fn color(effectId: Id) !sprite.Color {
    const preset = presets.get(effectId) orelse {
        std.log.err("particle_effect.color: preset {d} is missing", .{effectId});
        return error.ParticlePresetNotFound;
    };
    return preset.color;
}

fn randomRange(min: f32, max: f32) f32 {
    return min + runtime.random().float(f32) * (max - min);
}

fn randomDefaultDirection(direction: data.ParticleDirection) vec.Vec2 {
    if (direction == .radial) {
        const angle = runtime.random().float(f32) * std.math.pi * 2.0;
        return .{ .x = @cos(angle), .y = @sin(angle) };
    }

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

    return .{ .x = @cos(angle), .y = @sin(angle) };
}

fn randomDirection(preset: data.ParticleData, direction: ?vec.Vec2, spreadRadians: f32) vec.Vec2 {
    if (direction == null) return randomDefaultDirection(preset.defaultDirection);

    const requestedDirection = direction.?;
    if (vec.magnitude(requestedDirection) < 0.001) return randomDefaultDirection(preset.defaultDirection);

    const centerAngle = std.math.atan2(requestedDirection.y, requestedDirection.x);
    const spread = std.math.clamp(spreadRadians, 0.0, std.math.pi * 2.0);
    const angle = centerAngle + randomRange(-spread * 0.5, spread * 0.5);
    return .{ .x = @cos(angle), .y = @sin(angle) };
}

fn randomSpawnPosition(position: vec.Vec2) vec.Vec2 {
    const angle = runtime.random().float(f32) * std.math.pi * 2.0;
    const distance = runtime.random().float(f32) * 0.18;
    return .{
        .x = position.x + @cos(angle) * distance,
        .y = position.y + @sin(angle) * distance,
    };
}

fn stainBehavior(preset: data.ParticleData, stainRadius: f32) ?particle.StainBehavior {
    if (preset.stain == null) return null;
    const stain = preset.stain.?;
    return .{
        .color = stain.color,
        .radius = stainRadius,
        .target_mask = collision.MASK_PARTICLE_STAIN_TARGET,
        .destroy_on_contact = true,
    };
}

fn randomStainRadius(preset: data.ParticleData) f32 {
    if (preset.stain == null) return 0;
    const stain = preset.stain.?;
    return randomRange(stain.minRadius, stain.maxRadius);
}

pub fn emit(effectId: Id, emission: Emission) !void {
    if (emission.amount <= 0) return;

    const preset = presets.get(effectId) orelse {
        std.log.err("particle_effect.emit: preset {d} is missing", .{effectId});
        return error.ParticlePresetNotFound;
    };
    const scaledParticleCount = @ceil(emission.amount * preset.particlesPerUnit);
    const particleCount: u32 = @min(preset.maxParticles, @max(1, @as(u32, @intFromFloat(scaledParticleCount))));
    const carriedFraction = std.math.clamp(emission.carried_fraction, 0.0, 1.0);

    for (0..particleCount) |_| {
        const useCarriedVelocity = emission.carried_velocity != null and
            runtime.random().float(f32) < carriedFraction and
            vec.magnitude(emission.carried_velocity.?) >= 0.001;
        const direction = if (useCarriedVelocity)
            randomDirection(preset, emission.carried_velocity, emission.carried_spread_radians)
        else
            randomDirection(preset, emission.direction, emission.spread_radians);
        const speed = if (useCarriedVelocity) blk: {
            const carriedSpeed = vec.magnitude(emission.carried_velocity.?);
            break :blk carriedSpeed * randomRange(0.85, 1.05);
        } else blk: {
            const speedRoll = runtime.random().float(f32);
            break :blk preset.minSpeedVariation +
                (preset.maxSpeedVariation - preset.minSpeedVariation) * speedRoll * speedRoll;
        };
        const velocity = vec.add(
            vec.mul(direction, speed),
            vec.mul(emission.inherited_velocity, emission.inherited_velocity_scale),
        );
        const visualScale = preset.minScale +
            runtime.random().float(f32) * (preset.maxScale - preset.minScale);
        const stainRadius = randomStainRadius(preset);

        _ = try particle.spawnCircle(.{
            .position = randomSpawnPosition(emission.position),
            .velocity = velocity,
            .visual_scale = visualScale,
            .lifetime_ms = preset.lifetimeMs,
            .color = preset.color,
            .linear_damping = preset.linearDamping,
            .gravity_scale = preset.gravityScale,
            .density = preset.density,
            .friction = preset.friction,
            .restitution = preset.restitution,
            .group_index = preset.groupIndex,
            .category_bits = collision.CATEGORY_PARTICLE,
            .mask_bits = collision.MASK_PARTICLE,
            .is_bullet = false,
            .behaviors = .{ .stain = stainBehavior(preset, stainRadius) },
            .seed = runtime.random().int(u64),
        });
    }
}

pub fn cleanup() void {
    presets.deinit(allocator);
    presets = .empty;
    presetNames.deinit(allocator);
    presetNames = .empty;
}
