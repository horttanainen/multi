const std = @import("std");
const audio = @import("audio.zig");
const delay = @import("delay.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const collision = @import("collision.zig");
const animation = @import("animation.zig");
const shared = @import("shared.zig");
const camera = @import("camera.zig");
const time = @import("time.zig");
const sdl = @import("zsdl");

pub const Projectile = struct {
    gravityScale: f32,
    density: f32,
    propulsion: f32,
    lateralDamping: f32,
    animation: animation.Animation,
    explosion: projectile.Explosion,
    propulsionAnimation: ?animation.Animation = null,
};

pub const Pellet = struct {
    gravityScale: f32 = 0.5,
    density: f32 = 2.0,
    friction: f32 = 0.3,
    radius: f32 = 0.05,
    spriteScale: f32 = 0.3,
    count: u32 = 1,
    spreadAngle: f32 = 0,
    spawnRadius: f32 = 0.15,
    explosion: projectile.Explosion,
    color: sprite.Color = .{ .r = 255, .g = 255, .b = 255 },
};

pub const Weapon = struct {
    name: []const u8,
    delay: u32,
    sound: audio.Audio,
    impulse: f32,
    projectile: ?Projectile = null,
    pellet: ?Pellet = null,
    spriteUuid: u64 = 0,
    hitscanExplosion: ?projectile.Explosion = null,
    range: f32 = 50,
    trailDurationMs: u32 = 0,
    trailColor: sprite.Color = .{ .r = 255, .g = 255, .b = 255 },
    directDamage: f32 = 0,
};

const Trail = struct {
    startPos: vec.Vec2,
    endPos: vec.Vec2,
    color: sprite.Color,
    createdAt: f64,
    durationMs: u32,
};

var activeTrails: std.ArrayListUnmanaged(Trail) = .{};

pub fn shoot(w: Weapon, position: vec.IVec2, direction: vec.Vec2, initialVelocity: vec.Vec2, playerId: usize) !void {
    if (w.hitscanExplosion != null) {
        try shootHitscan(w, position, direction, playerId);
    } else if (w.pellet) |_| {
        try shootPellets(w, position, direction, initialVelocity, playerId);
    } else if (w.projectile) |_| {
        try shootProjectile(w, position, direction, initialVelocity, playerId);
    }
    try audio.playFor(w.sound);
}

fn shootProjectile(w: Weapon, position: vec.IVec2, direction: vec.Vec2, initialVelocity: vec.Vec2, playerId: usize) !void {
    const proj = w.projectile.?;

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    shapeDef.density = proj.density;
    shapeDef.enableHitEvents = true;
    shapeDef.enableContactEvents = true;
    shapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
    shapeDef.filter.maskBits = collision.MASK_PROJECTILE | collision.otherPlayersMask(playerId);

    const animCopy = try animation.copyAnimation(proj.animation);

    const firstFrameUuid = animCopy.frames[0];
    const pos = conv.pixel2M(position);
    var bodyDef = box2d.createDynamicBodyDef(pos);
    bodyDef.isBullet = true;
    bodyDef.gravityScale = proj.gravityScale;

    const angle = std.math.atan2(-direction.y, direction.x);
    bodyDef.rotation = box2d.c.b2MakeRot(angle + std.math.pi * 0.5);

    const projectileEntity = try entity.createFromImg(firstFrameUuid, shapeDef, bodyDef, "projectile");

    const impulse = vec.mul(vec.normalize(.{
        .x = direction.x,
        .y = -direction.y,
    }), w.impulse);

    box2d.c.b2Body_ApplyLinearImpulseToCenter(projectileEntity.bodyId, vec.toBox2d(impulse), true);

    const currentVel = box2d.c.b2Body_GetLinearVelocity(projectileEntity.bodyId);
    box2d.c.b2Body_SetLinearVelocity(projectileEntity.bodyId, .{
        .x = currentVel.x + initialVelocity.x,
        .y = currentVel.y + initialVelocity.y,
    });

    try projectile.create(projectileEntity.bodyId, proj.explosion);
    try projectile.registerPropulsion(projectileEntity.bodyId, proj.propulsion, proj.lateralDamping);
    try projectile.registerOwner(projectileEntity.bodyId, playerId);

    var animations = std.StringHashMap(animation.Animation).init(shared.allocator);
    try animations.put("main", animCopy);

    if (proj.propulsionAnimation) |propAnim| {
        const propAnimCopy = try animation.copyAnimation(propAnim);

        try entity.addSprite(projectileEntity.bodyId, propAnimCopy.frames[0]);

        try animations.put("propulsion", propAnimCopy);
    }

    try animation.registerAnimationSet(projectileEntity.bodyId, animations, "main", false);
}

fn shootHitscan(w: Weapon, position: vec.IVec2, direction: vec.Vec2, playerId: usize) !void {
    const resources = try shared.getResources();
    const explosion = w.hitscanExplosion.?;

    const origin = conv.pixel2M(position);
    // direction uses screen coords (y-up for aim), box2d uses y-down
    const dir = vec.Vec2{ .x = direction.x, .y = -direction.y };
    const normDir = vec.normalize(dir);
    const translation = vec.mul(normDir, w.range);

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_PROJECTILE;
    filter.maskBits = collision.MASK_PROJECTILE | collision.otherPlayersMask(playerId);

    const result = box2d.c.b2World_CastRayClosest(
        resources.worldId,
        vec.toBox2d(origin),
        vec.toBox2d(translation),
        filter,
    );

    var hitPoint = vec.add(origin, translation);
    if (result.hit) {
        hitPoint = vec.fromBox2d(result.point);
        // Apply direct damage to hit player
        if (w.directDamage > 0 and box2d.c.b2Shape_IsValid(result.shapeId)) {
            const hitBodyId = box2d.c.b2Shape_GetBody(result.shapeId);
            try projectile.damagePlayerDirect(hitBodyId, w.directDamage, playerId);
        }
    } 

    try projectile.explodeAt(hitPoint, explosion, playerId);

    if (w.trailDurationMs > 0) {
        try activeTrails.append(shared.allocator, .{
            .startPos = origin,
            .endPos = hitPoint,
            .color = w.trailColor,
            .createdAt = time.now(),
            .durationMs = w.trailDurationMs,
        });
    }
}

fn shootPellets(w: Weapon, position: vec.IVec2, direction: vec.Vec2, initialVelocity: vec.Vec2, playerId: usize) !void {
    const pel = w.pellet.?;

    const pos = conv.pixel2M(position);
    const baseAngle = std.math.atan2(-direction.y, direction.x);
    const spreadRad = std.math.degreesToRadians(pel.spreadAngle);
    const count = pel.count;

    for (0..count) |i| {
        const t: f32 = if (count > 1)
            @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)) - 0.5
        else
            0;
        const pelletAngle = baseAngle + t * spreadRad;
        const pelletDir = vec.Vec2{
            .x = @cos(pelletAngle),
            .y = @sin(pelletAngle),
        };

        // Randomly offset spawn position within a small circle
        const randAngle = std.crypto.random.float(f32) * 2.0 * std.math.pi;
        const randDist = std.crypto.random.float(f32) * pel.spawnRadius;
        const pelletPos = vec.Vec2{
            .x = pos.x + @cos(randAngle) * randDist,
            .y = pos.y + @sin(randAngle) * randDist,
        };

        var bodyDef = box2d.createDynamicBodyDef(pelletPos);
        bodyDef.isBullet = true;
        bodyDef.gravityScale = pel.gravityScale;

        const bodyId = try box2d.createBody(bodyDef);

        var shapeDef = box2d.c.b2DefaultShapeDef();
        shapeDef.density = pel.density;
        shapeDef.friction = pel.friction;
        shapeDef.enableHitEvents = true;
        shapeDef.enableContactEvents = true;
        shapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
        shapeDef.filter.maskBits = collision.MASK_PROJECTILE | collision.otherPlayersMask(playerId);

        const circleShape = box2d.c.b2Circle{
            .center = .{ .x = 0, .y = 0 },
            .radius = pel.radius,
        };
        _ = box2d.c.b2CreateCircleShape(bodyId, &shapeDef, &circleShape);

        const spriteUuid = try sprite.createFromImg(
            "particles/circle.png",
            .{ .x = pel.spriteScale, .y = pel.spriteScale },
            .{ .x = 0, .y = 0 },
        );

        var spriteUuids = try shared.allocator.alloc(u64, 1);
        spriteUuids[0] = spriteUuid;
        const shapeIds = try shared.allocator.alloc(box2d.c.b2ShapeId, 0);

        try entity.entities.putLocking(bodyId, entity.Entity{
            .type = try shared.allocator.dupe(u8, "projectile"),
            .friction = shapeDef.friction,
            .bodyId = bodyId,
            .spriteUuids = spriteUuids,
            .shapeIds = shapeIds,
            .state = null,
            .highlighted = false,
            .animated = false,
            .flipEntityHorizontally = false,
            .categoryBits = shapeDef.filter.categoryBits,
            .maskBits = shapeDef.filter.maskBits,
            .enabled = true,
            .color = pel.color,
        });

        const impulse = vec.mul(pelletDir, w.impulse);
        box2d.c.b2Body_ApplyLinearImpulseToCenter(bodyId, vec.toBox2d(impulse), true);

        const currentVel = box2d.c.b2Body_GetLinearVelocity(bodyId);
        box2d.c.b2Body_SetLinearVelocity(bodyId, .{
            .x = currentVel.x + initialVelocity.x,
            .y = currentVel.y + initialVelocity.y,
        });

        try projectile.create(bodyId, pel.explosion);
        try projectile.registerOwner(bodyId, playerId);
        if (w.directDamage > 0) {
            try projectile.registerDirectDamage(bodyId, w.directDamage);
        }
    }
}

pub fn drawTrails() !void {
    const resources = try shared.getResources();
    const currentTime = time.now();

    const prevBlendMode = try sdl.getRenderDrawBlendMode(resources.renderer);
    try sdl.setRenderDrawBlendMode(resources.renderer, .blend);

    var i: usize = 0;
    while (i < activeTrails.items.len) {
        const trail = activeTrails.items[i];
        const elapsed = (currentTime - trail.createdAt) * 1000.0;
        const duration: f64 = @floatFromInt(trail.durationMs);
        if (elapsed >= duration) {
            _ = activeTrails.swapRemove(i);
            continue;
        }

        const t: f32 = @floatCast(elapsed / duration);

        const startPx = camera.relativePosition(conv.m2Pixel(.{ .x = trail.startPos.x, .y = trail.startPos.y }));
        const endPx = camera.relativePosition(conv.m2Pixel(.{ .x = trail.endPos.x, .y = trail.endPos.y }));

        // Perpendicular direction for line thickness
        const dx: f32 = @floatFromInt(endPx.x - startPx.x);
        const dy: f32 = @floatFromInt(endPx.y - startPx.y);
        const len = @sqrt(dx * dx + dy * dy);
        const perpX: f32 = if (len > 0) -dy / len else 0;
        const perpY: f32 = if (len > 0) dx / len else 0;

        // Width grows from 1 to max over time
        const maxHalfWidth: f32 = 4.0;
        const halfWidth: f32 = 1.0 + (maxHalfWidth - 1.0) * t;

        // Color: white → trail color (dark blue) over time
        const colorR: u8 = @intFromFloat(@max(0, @min(255, 255.0 - @as(f32, @floatFromInt(255 - trail.color.r)) * t)));
        const colorG: u8 = @intFromFloat(@max(0, @min(255, 255.0 - @as(f32, @floatFromInt(255 - trail.color.g)) * t)));
        const colorB: u8 = @intFromFloat(@max(0, @min(255, 255.0 - @as(f32, @floatFromInt(255 - trail.color.b)) * t)));

        // Alpha fades out in last 40% of lifetime
        const alpha: u8 = if (t < 0.6) 255 else @intFromFloat(255.0 * (1.0 - (t - 0.6) / 0.4));

        // Draw multiple parallel lines to create width
        const steps: i32 = @intFromFloat(@ceil(halfWidth * 2));
        var s: i32 = -steps;
        while (s <= steps) : (s += 1) {
            const offset: f32 = @as(f32, @floatFromInt(s)) * halfWidth / @as(f32, @floatFromInt(@max(steps, 1)));

            // Lines near center are brighter
            const distFromCenter = @abs(offset) / @max(halfWidth, 0.001);
            const lineAlpha: u8 = @intFromFloat(@as(f32, @floatFromInt(alpha)) * (1.0 - distFromCenter * distFromCenter));
            if (lineAlpha == 0) continue;

            const ox: i32 = @intFromFloat(perpX * offset);
            const oy: i32 = @intFromFloat(perpY * offset);

            try sdl.setRenderDrawColor(resources.renderer, .{ .r = colorR, .g = colorG, .b = colorB, .a = lineAlpha });
            try sdl.renderDrawLine(resources.renderer, startPx.x + ox, startPx.y + oy, endPx.x + ox, endPx.y + oy);
        }

        i += 1;
    }

    try sdl.setRenderDrawBlendMode(resources.renderer, prevBlendMode);
}

pub fn cleanupTrails() void {
    activeTrails.clearAndFree(shared.allocator);
}
