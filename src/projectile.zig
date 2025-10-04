const std = @import("std");
const timer = @import("sdl_timer.zig");

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

pub const Projectile = struct {
    bodyId: box2d.c.b2BodyId,
    explosion: ?Explosion,
};

pub var projectiles = std.AutoArrayHashMap(box2d.c.b2BodyId, Projectile).init(shared.allocator);

pub var id: usize = 1;
pub const Shrapnel = struct {
    id: usize,
    cleaned: bool,
    bodies: []box2d.c.b2BodyId,
};

pub var shrapnel = std.array_list.Managed(Shrapnel).init(shared.allocator);

var shrapnelToCleanup = std.array_list.Managed(box2d.c.b2BodyId).init(shared.allocator);

fn createExplosion(pos: vec.Vec2, explosion: Explosion) ![]box2d.c.b2BodyId {
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

    return try bodyIds.toOwnedSlice();
}

pub fn explode(p: Projectile) !void {
    _ = projectiles.fetchSwapRemove(p.bodyId);
    const maybeE = entity.entities.get(p.bodyId);

    var pos = vec.zero;
    if (maybeE) |e| {
        if (e.state) |state| {
            pos = vec.fromBox2d(state.pos);
        }
        entity.cleanupLater(e);
    }

    if (p.explosion) |explosion| {
        const explosionBodies = try createExplosion(pos, explosion);

        try shrapnel.append(.{
            .id = id,
            .cleaned = false,
            .bodies = explosionBodies,
        });
        _ = timer.addTimer(500, markShrapnelForCleanup, @ptrFromInt(id));
        id = id + 1;
    }
}

fn markShrapnelForCleanup(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const maybeId = param.?;
    const shrapnelId: usize = @intFromPtr(maybeId);

    for (shrapnel.items) |*item| {
        if (item.id == shrapnelId) {
            shrapnelToCleanup.appendSlice(item.bodies) catch {};
            item.cleaned = true;
        }
    }
    return 0;
}

pub fn cleanupShrapnel() !void {
    var shrapnelToKeep = std.array_list.Managed(Shrapnel).init(shared.allocator);
    var shrapnelToDiscard = std.array_list.Managed(Shrapnel).init(shared.allocator);
    defer shrapnelToDiscard.deinit();

    for (shrapnel.items) |item| {
        if (item.cleaned) {
            try shrapnelToDiscard.append(item);
            continue;
        }
        try shrapnelToKeep.append(item);
    }

    shrapnel.deinit();
    shrapnel = shrapnelToKeep;

    for (shrapnelToCleanup.items) |toClean| {
        box2d.c.b2DestroyBody(toClean);
    }
    shrapnelToCleanup.deinit();
    shrapnelToCleanup = std.array_list.Managed(box2d.c.b2BodyId).init(shared.allocator);

    for (shrapnelToDiscard.items) |item| {
        if (item.cleaned) {
            shared.allocator.free(item.bodies);
        }
    }
}

pub fn create(bodyId: box2d.c.b2BodyId, ex: ?Explosion) !void {
    try projectiles.put(bodyId, Projectile{
        .bodyId = bodyId,
        .explosion = ex,
    });
}

pub fn cleanup() void {
    projectiles.clearAndFree();

    for (shrapnel.items) |item| {
        shared.allocator.free(item.bodies);
    }

    shrapnelToCleanup.deinit();
    shrapnel.deinit();
}
