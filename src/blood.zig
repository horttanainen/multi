const std = @import("std");

const particle_effect = @import("particle_effect.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

pub const Emission = particle_effect.Emission;

var effectId: ?particle_effect.Id = null;

pub fn init() !void {
    const id = particle_effect.idForName("blood") orelse {
        std.log.err("blood.init: particles.json is missing required particle preset 'blood'", .{});
        return error.BloodParticlePresetNotFound;
    };
    const preset = particle_effect.presets.get(id) orelse {
        std.log.err("blood.init: resolved blood particle preset {d} is missing", .{id});
        return error.BloodParticlePresetNotFound;
    };
    if (preset.stain == null) {
        std.log.err("blood.init: blood particle preset requires a stain behavior", .{});
        return error.BloodStainBehaviorMissing;
    }
    effectId = id;
}

pub fn particleEffectId() !particle_effect.Id {
    return effectId orelse {
        std.log.err("blood.particleEffectId: blood component is not initialized", .{});
        return error.BloodComponentNotInitialized;
    };
}

pub fn currentColor() !sprite.Color {
    return particle_effect.color(try particleEffectId());
}

pub fn emit(emission: Emission) !void {
    try particle_effect.emit(try particleEffectId(), emission);
}

pub fn createParticles(position: vec.Vec2, amount: f32, inheritedVelocity: vec.Vec2) !void {
    try emit(.{
        .position = position,
        .amount = amount,
        .inherited_velocity = inheritedVelocity,
        .inherited_velocity_scale = 0.35,
    });
}

pub fn createParticlesFromImpact(position: vec.Vec2, amount: f32, inheritedVelocity: vec.Vec2) !void {
    try emit(.{
        .position = position,
        .amount = amount,
        .direction = inheritedVelocity,
        .spread_radians = std.math.pi * 0.55,
        .inherited_velocity = inheritedVelocity,
        .inherited_velocity_scale = 0.55,
    });
}
