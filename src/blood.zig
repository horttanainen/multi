const std = @import("std");

const collision = @import("collision.zig");
const data = @import("data.zig");
const particle = @import("particle.zig");
const runtime = @import("runtime.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

var config: ?data.ParticleData = null;

pub fn init() !void {
    const loadedConfig = data.getParticleData("blood") orelse {
        std.log.err("blood.init: particles.json is missing required particle data 'blood'", .{});
        return error.BloodParticleDataNotFound;
    };
    if (loadedConfig.minScale <= 0 or loadedConfig.maxScale < loadedConfig.minScale) {
        std.log.err("blood.init: blood particle scale range is invalid", .{});
        return error.InvalidBloodParticleSize;
    }
    const stain = loadedConfig.stain orelse {
        std.log.err("blood.init: blood particles require a stain behavior", .{});
        return error.BloodStainBehaviorMissing;
    };
    if (stain.minRadius <= 0 or stain.maxRadius < stain.minRadius) {
        std.log.err("blood.init: blood stain radius range is invalid", .{});
        return error.InvalidBloodStainRadius;
    }

    config = loadedConfig;
}

fn requireConfig(functionName: []const u8) !data.ParticleData {
    const loadedConfig = config orelse {
        std.log.err("{s}: blood component is not initialized", .{functionName});
        return error.BloodComponentNotInitialized;
    };
    return loadedConfig;
}

pub fn currentColor() !sprite.Color {
    const loadedConfig = try requireConfig("currentColor");
    return loadedConfig.color;
}

fn randomRange(min: f32, max: f32) f32 {
    return min + runtime.random().float(f32) * (max - min);
}

fn randomBaseDirection() vec.Vec2 {
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

fn randomDirection(directionBias: vec.Vec2, biasStrength: f32) vec.Vec2 {
    const base = randomBaseDirection();
    const biasLength = vec.magnitude(directionBias);
    if (biasLength < 0.001 or biasStrength <= 0.0) {
        return base;
    }

    const bias = vec.Vec2{
        .x = directionBias.x / biasLength,
        .y = directionBias.y / biasLength,
    };
    const mix = std.math.clamp(biasStrength, 0.0, 0.9) * (0.35 + runtime.random().float(f32) * 0.65);
    const mixed = vec.Vec2{
        .x = base.x * (1.0 - mix) + bias.x * mix,
        .y = base.y * (1.0 - mix) + bias.y * mix,
    };
    const length = vec.magnitude(mixed);
    if (length < 0.001) {
        return base;
    }

    return .{
        .x = mixed.x / length,
        .y = mixed.y / length,
    };
}

fn randomSpawnPosition(position: vec.Vec2) vec.Vec2 {
    const angle = runtime.random().float(f32) * std.math.pi * 2.0;
    const distance = runtime.random().float(f32) * 0.18;
    return .{
        .x = position.x + @cos(angle) * distance,
        .y = position.y + @sin(angle) * distance,
    };
}

fn createBiased(position: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2, directionBiasStrength: f32, inheritedVelocityScale: f32) !void {
    if (damage <= 0.0) {
        return;
    }

    const loadedConfig = try requireConfig("createBiased");
    const stain = loadedConfig.stain orelse {
        std.log.err("createBiased: blood stain behavior is missing", .{});
        return error.BloodStainBehaviorMissing;
    };
    const scaledParticleCount = @ceil(damage * loadedConfig.particlesPerUnit);
    const particleCount: u32 = @min(loadedConfig.maxParticles, @max(1, @as(u32, @intFromFloat(scaledParticleCount))));
    const color = try currentColor();

    for (0..particleCount) |_| {
        const direction = randomDirection(inheritedVelocity, directionBiasStrength);
        const speedRoll = runtime.random().float(f32);
        const speed = loadedConfig.minSpeedVariation +
            (loadedConfig.maxSpeedVariation - loadedConfig.minSpeedVariation) * speedRoll * speedRoll;
        const velocity = vec.add(
            vec.mul(direction, speed),
            vec.mul(inheritedVelocity, inheritedVelocityScale),
        );
        const visualScale = loadedConfig.minScale +
            runtime.random().float(f32) * (loadedConfig.maxScale - loadedConfig.minScale);
        const stainRadius = stain.minRadius +
            runtime.random().float(f32) * (stain.maxRadius - stain.minRadius);

        _ = try particle.spawnCircle(.{
            .position = randomSpawnPosition(position),
            .velocity = velocity,
            .visual_scale = visualScale,
            .lifetime_ms = loadedConfig.lifetimeMs,
            .color = color,
            .linear_damping = loadedConfig.linearDamping,
            .gravity_scale = loadedConfig.gravityScale,
            .density = loadedConfig.density,
            .friction = loadedConfig.friction,
            .restitution = loadedConfig.restitution,
            .group_index = loadedConfig.groupIndex,
            .category_bits = collision.CATEGORY_BLOOD,
            .mask_bits = collision.MASK_BLOOD,
            .is_bullet = true,
            .behaviors = .{
                .stain = .{
                    .color = stain.color,
                    .radius = stainRadius,
                    .target_mask = collision.MASK_BLOOD_QUERY,
                    .destroy_on_contact = true,
                },
            },
            .seed = runtime.random().int(u64),
        });
    }
}

pub fn createParticles(position: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2) !void {
    try createBiased(position, damage, inheritedVelocity, 0.25, 0.35);
}

pub fn createParticlesFromImpact(position: vec.Vec2, damage: f32, inheritedVelocity: vec.Vec2) !void {
    try createBiased(position, damage, inheritedVelocity, 0.85, 0.55);
}
