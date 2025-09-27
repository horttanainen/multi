const std = @import("std");

const audio = @import("audio.zig");
const vec = @import("vector.zig");
const entity = @import("entity.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");

pub const Explosion = struct {
    sound: audio.Audio,
    blastPower: f32,
    particleCount: u32,
    particleDensity: f32,
    particleFriction: f32,
    particleRestitution: f32,
    particleRadius: f32,
    particleLinearDamping: f32,
    particleGravityScale: f32,
};

pub const Particle = struct {
    bodyId: box2d.c.b2BodyId,
    explosion: ?Explosion,
};

pub const MarkedParticle = struct { particle: Particle, counter: i32, linkedBodies: []box2d.c.b2BodyId };

pub var markedParticles = std.array_list.Managed(MarkedParticle).init(shared.allocator);

pub var particles = std.HashMap(box2d.c.b2BodyId, Particle, BodyIdContext, std.hash_map.default_max_load_percentage).init(shared.allocator);

const BodyIdContext = struct {
    pub fn hash(self: @This(), bodyId: box2d.c.b2BodyId) u64 {
        _ = self;
        return @as(u64, @intCast(bodyId.index1));
    }

    pub fn eql(self: @This(), a: box2d.c.b2BodyId, b: box2d.c.b2BodyId) bool {
        _ = self;
        return box2d.c.B2_ID_EQUALS(a, b);
    }
};

pub fn explode(p: Particle) !void {
    if (p.explosion) |explosion| {
        const maybeE = entity.entities.get(p.bodyId);

        var pos = vec.zero;
        if (maybeE) |e| {
            if (e.state) |state| {
                pos = vec.fromBox2d(state.pos);
            }
        }

        try audio.playFor(explosion.sound);

        var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(shared.allocator);

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
            circleShapeDef.friction = explosion.particleFriction;
            circleShapeDef.restitution = explosion.particleRestitution;
            circleShapeDef.filter.groupIndex = -1;

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

        try cleanupLater(p, try bodyIds.toOwnedSlice());
    }
}

pub fn create(bodyId: box2d.c.b2BodyId, ex: ?Explosion) !void {
    try particles.put(bodyId, Particle{
        .bodyId = bodyId,
        .explosion = ex,
    });
}

pub fn cleanup() void {
    particles.clearAndFree();

    for (markedParticles.items) |*marked| {
        shared.allocator.free(marked.linkedBodies);
    }
    markedParticles.deinit();
}

pub fn cleanupLater(particle: Particle, linkedBodies: []box2d.c.b2BodyId) !void {
    _ = particles.remove(particle.bodyId);
    box2d.c.b2Body_SetAwake(particle.bodyId, false);
    try markedParticles.append(.{
        .particle = particle,
        .counter = 0,
        .linkedBodies = linkedBodies,
    });
}
