const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const sprite = @import("sprite.zig");
const tex = @import("texture.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

const maxParticles: usize = 512;

pub const BlendMode = enum {
    alpha,
    additive,
};

pub const Spawn = struct {
    sprite_uuid: u64,
    position: vec.Vec2,
    velocity: vec.Vec2,
    gravity: vec.Vec2 = vec.zero,
    drag: f32 = 0,
    start_diameter: f32,
    end_diameter: f32,
    start_color: sprite.Color,
    end_color: sprite.Color,
    start_alpha: u8 = 255,
    end_alpha: u8 = 0,
    lifetime_ms: u32,
    angle: f32 = 0,
    angular_velocity: f32 = 0,
    blend_mode: BlendMode = .alpha,
};

pub const Particle = struct {
    spawn: Spawn,
    started_at: f64,
};

pub var particles = std.ArrayListUnmanaged(Particle).empty;

pub fn spawn(spawnData: Spawn) !void {
    if (particles.items.len >= maxParticles) return;
    try particles.append(allocator, .{
        .spawn = spawnData,
        .started_at = time.realNow(),
    });
}

fn lifetimeSeconds(particle: Particle) f64 {
    return @as(f64, @floatFromInt(particle.spawn.lifetime_ms)) / 1000.0;
}

pub fn update() void {
    const now = time.realNow();
    var index: usize = 0;
    while (index < particles.items.len) {
        if (now - particles.items[index].started_at < lifetimeSeconds(particles.items[index])) {
            index += 1;
            continue;
        }
        _ = particles.swapRemove(index);
    }
}

fn lerp(start: f32, end: f32, progress: f32) f32 {
    return start + (end - start) * progress;
}

fn lerpChannel(start: u8, end: u8, progress: f32) u8 {
    const value = lerp(@floatFromInt(start), @floatFromInt(end), progress);
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

fn positionAtAge(particle: Particle, age: f32) vec.Vec2 {
    const drag = particle.spawn.drag;
    const velocityTime = if (drag > 0.0001) (1.0 - @exp(-drag * age)) / drag else age;
    return vec.add(
        particle.spawn.position,
        vec.add(
            vec.mul(particle.spawn.velocity, velocityTime),
            vec.mul(particle.spawn.gravity, 0.5 * age * age),
        ),
    );
}

fn drawParticle(particle: Particle, now: f64) !void {
    const particleSprite = sprite.getSprite(particle.spawn.sprite_uuid) orelse {
        std.log.err("visual_particle.drawParticle: sprite {d} is missing", .{particle.spawn.sprite_uuid});
        return error.VisualParticleSpriteNotFound;
    };

    const ageSeconds = std.math.clamp(now - particle.started_at, 0, lifetimeSeconds(particle));
    const progress: f32 = @floatCast(ageSeconds / lifetimeSeconds(particle));
    const diameter = lerp(particle.spawn.start_diameter, particle.spawn.end_diameter, progress);
    const alpha = lerpChannel(particle.spawn.start_alpha, particle.spawn.end_alpha, progress);
    if (alpha == 0) return;

    const color = sprite.Color{
        .r = lerpChannel(particle.spawn.start_color.r, particle.spawn.end_color.r, progress),
        .g = lerpChannel(particle.spawn.start_color.g, particle.spawn.end_color.g, progress),
        .b = lerpChannel(particle.spawn.start_color.b, particle.spawn.end_color.b, progress),
    };
    const position = positionAtAge(particle, @floatCast(ageSeconds));
    const center = camera.relativePosition(conv.m2Pixel(vec.toBox2d(position)));
    const diameterPixels = diameter * conv.met2pix;
    const spriteScale = diameterPixels / @as(f32, @floatFromInt(particleSprite.surface.w));
    const scale = vec.Vec2{ .x = spriteScale, .y = spriteScale };
    const angle = particle.spawn.angle + particle.spawn.angular_velocity * @as(f32, @floatCast(ageSeconds));

    const previousBlendMode = particleSprite.texture.blend_mode;
    const previousColor = particleSprite.texture.color_mod;
    const blendMode: @TypeOf(previousBlendMode) = switch (particle.spawn.blend_mode) {
        .alpha => .blend,
        .additive => .add,
    };
    try tex.setTextureBlendMode(particleSprite.texture, blendMode);
    try tex.setTextureAlphaMod(particleSprite.texture, alpha);
    defer {
        tex.setTextureBlendMode(particleSprite.texture, previousBlendMode) catch |err| {
            std.log.err("visual_particle.drawParticle: failed to restore blend mode: {}", .{err});
        };
        tex.setTextureColorMod(particleSprite.texture, previousColor.r, previousColor.g, previousColor.b) catch |err| {
            std.log.err("visual_particle.drawParticle: failed to restore color: {}", .{err});
        };
        tex.setTextureAlphaMod(particleSprite.texture, previousColor.a) catch |err| {
            std.log.err("visual_particle.drawParticle: failed to restore opacity: {}", .{err});
        };
    }

    try sprite.drawWithScale(particleSprite, center, angle, scale, color);
}

pub fn draw() !void {
    if (particles.items.len == 0) return;

    const now = time.realNow();
    for (particles.items) |particle| {
        try drawParticle(particle, now);
    }
}

pub fn cleanup() void {
    particles.clearAndFree(allocator);
}
