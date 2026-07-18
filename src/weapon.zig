const std = @import("std");
const audio = @import("audio.zig");
const delay = @import("delay.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const runtime = @import("runtime.zig");
const collision = @import("collision.zig");
const animation = @import("animation.zig");
const allocator = @import("allocator.zig").allocator;
const camera = @import("camera.zig");
const time = @import("time.zig");
const gpu = @import("gpu.zig");

pub const Projectile = struct {
    gravityScale: f32,
    density: f32,
    propulsion: f32,
    lateralDamping: f32,
    animation: animation.Animation,
    explosion: ?projectile.Explosion = null,
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
    explosion: ?projectile.Explosion = null,
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
    penetration: projectile.PenetrationMode = .non_penetrating,
};

const Trail = struct {
    startPos: vec.Vec2,
    endPos: vec.Vec2,
    color: sprite.Color,
    createdAt: f64,
    durationMs: u32,
};

var activeTrails: std.ArrayListUnmanaged(Trail) = .empty;

const maxHitscanPlayers: usize = 64;

const HitscanPlayerHit = struct {
    point: vec.Vec2,
    fraction: f32,
};

const HitscanContext = struct {
    player_hits: [maxHitscanPlayers]?HitscanPlayerHit = [_]?HitscanPlayerHit{null} ** maxHitscanPlayers,
};

fn collectHitscanPlayer(
    shapeId: box2d.c.b2ShapeId,
    point: box2d.c.b2Vec2,
    _: box2d.c.b2Vec2,
    fraction: f32,
    context: ?*anyopaque,
) callconv(.c) f32 {
    if (context == null) {
        std.log.err("collectHitscanPlayer: ray cast context is missing", .{});
        return 0;
    }

    if (!box2d.c.b2Shape_IsValid(shapeId)) {
        std.log.warn("collectHitscanPlayer: player shape is invalid", .{});
        return 1;
    }

    const hitscanContext: *HitscanContext = @ptrCast(@alignCast(context.?));
    const bodyId = box2d.c.b2Shape_GetBody(shapeId);
    const hitPlayerId = projectile.playerIdForBody(bodyId) orelse {
        std.log.warn("collectHitscanPlayer: ray cast player shape has no player", .{});
        return 1;
    };
    if (hitPlayerId >= hitscanContext.player_hits.len) {
        std.log.err("collectHitscanPlayer: player id {d} does not fit the hit array", .{hitPlayerId});
        return 1;
    }

    const existingHit = hitscanContext.player_hits[hitPlayerId];
    if (existingHit != null and existingHit.?.fraction <= fraction) return 1;

    hitscanContext.player_hits[hitPlayerId] = .{
        .point = vec.fromBox2d(point),
        .fraction = fraction,
    };
    return 1;
}

pub fn shoot(w: Weapon, position: vec.IVec2, direction: vec.Vec2, initialVelocity: vec.Vec2, playerId: usize) !void {
    if (w.projectile != null) {
        try shootProjectile(w, position, direction, initialVelocity, playerId);
    } else if (w.pellet != null) {
        try shootPellets(w, position, direction, initialVelocity, playerId);
    } else {
        try shootHitscan(w, position, direction, playerId);
    }
    try audio.playFor(w.sound);
}

fn shootProjectile(w: Weapon, position: vec.IVec2, direction: vec.Vec2, initialVelocity: vec.Vec2, playerId: usize) !void {
    const proj = w.projectile.?;

    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = 0.5;
    shapeDef.density = proj.density;
    shapeDef.enableHitEvents = true;
    shapeDef.enableContactEvents = true;
    shapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
    shapeDef.filter.maskBits = collision.MASK_PROJECTILE;
    if (w.penetration == .non_penetrating) {
        shapeDef.filter.maskBits |= collision.otherPlayersMask(playerId);
    }

    const animCopy = try animation.copyAnimationSharedFrames(proj.animation);

    const firstFrameUuid = animCopy.frames[0];
    const pos = conv.pixel2M(position);
    var bodyDef = box2d.createDynamicBodyDef(pos);
    bodyDef.isBullet = true;
    bodyDef.gravityScale = proj.gravityScale;

    const angle = std.math.atan2(-direction.y, direction.x);
    bodyDef.rotation = box2d.c.b2MakeRot(angle + std.math.pi * 0.5);

    const projectileEntity = try entity.createFromImg(firstFrameUuid, shapeDef, bodyDef, "projectile");
    entity.markSpriteUuidsShared(projectileEntity.bodyId);

    if (w.penetration == .penetrating) {
        var sensorShapeDef = box2d.c.b2DefaultShapeDef();
        sensorShapeDef.isSensor = true;
        sensorShapeDef.enableSensorEvents = true;
        sensorShapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
        sensorShapeDef.filter.maskBits = collision.otherPlayersMask(playerId);

        for (projectileEntity.shapeIds) |shapeId| {
            if (!box2d.c.b2Shape_IsValid(shapeId)) {
                std.log.warn("shootProjectile: projectile shape became invalid before sensor creation", .{});
                continue;
            }
            const polygon = box2d.c.b2Shape_GetPolygon(shapeId);
            _ = box2d.c.b2CreatePolygonShape(projectileEntity.bodyId, &sensorShapeDef, &polygon);
        }
    }

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

    try projectile.create(projectileEntity.bodyId, .{
        .owner_id = playerId,
        .direct_damage = w.directDamage,
        .penetration = w.penetration,
        .explosion = proj.explosion,
    });
    try projectile.registerPropulsion(projectileEntity.bodyId, proj.propulsion, proj.lateralDamping);

    var animations = std.StringHashMap(animation.Animation).init(allocator);
    try animations.put("main", animCopy);

    if (proj.propulsionAnimation) |propAnim| {
        const propAnimCopy = try animation.copyAnimationSharedFrames(propAnim);

        try entity.addSprite(projectileEntity.bodyId, propAnimCopy.frames[0]);

        try animations.put("propulsion", propAnimCopy);
    }

    try animation.registerAnimationSet(projectileEntity.bodyId, animations, "main", false);
}

fn shootHitscan(w: Weapon, position: vec.IVec2, direction: vec.Vec2, playerId: usize) !void {
    const origin = conv.pixel2M(position);
    // direction uses screen coords (y-up for aim), box2d uses y-down
    const dir = vec.Vec2{ .x = direction.x, .y = -direction.y };
    const normDir = vec.normalize(dir);
    const translation = vec.mul(normDir, w.range);

    var hitPoint = vec.add(origin, translation);
    if (w.penetration == .penetrating) {
        hitPoint = try shootPenetratingHitscan(w, origin, translation, normDir, playerId);
    } else {
        hitPoint = try shootNonPenetratingHitscan(w, origin, translation, normDir, playerId);
    }

    if (w.hitscanExplosion) |explosion| {
        try projectile.explodeAt(hitPoint, explosion, playerId);
    }

    if (w.trailDurationMs > 0) {
        try activeTrails.append(allocator, .{
            .startPos = origin,
            .endPos = hitPoint,
            .color = w.trailColor,
            .createdAt = time.now(),
            .durationMs = w.trailDurationMs,
        });
    }
}

fn shootNonPenetratingHitscan(
    w: Weapon,
    origin: vec.Vec2,
    translation: vec.Vec2,
    direction: vec.Vec2,
    playerId: usize,
) !vec.Vec2 {
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_PROJECTILE;
    filter.maskBits = collision.MASK_PROJECTILE | collision.otherPlayersMask(playerId);

    const result = box2d.castRayClosest(vec.toBox2d(origin), vec.toBox2d(translation), filter);
    if (!result.hit) return vec.add(origin, translation);

    const hitPoint = vec.fromBox2d(result.point);
    if (w.directDamage <= 0 or !box2d.c.b2Shape_IsValid(result.shapeId)) return hitPoint;

    const hitBodyId = box2d.c.b2Shape_GetBody(result.shapeId);
    const hitPlayerId = projectile.playerIdForBody(hitBodyId) orelse return hitPoint;
    try projectile.damagePlayerFromHitscan(
        hitPlayerId,
        w.directDamage,
        playerId,
        hitPoint,
        direction,
        .non_penetrating,
    );
    return hitPoint;
}

fn shootPenetratingHitscan(
    w: Weapon,
    origin: vec.Vec2,
    translation: vec.Vec2,
    direction: vec.Vec2,
    playerId: usize,
) !vec.Vec2 {
    var worldFilter = box2d.c.b2DefaultQueryFilter();
    worldFilter.categoryBits = collision.CATEGORY_PROJECTILE;
    worldFilter.maskBits = collision.MASK_PROJECTILE;

    const worldHit = box2d.castRayClosest(vec.toBox2d(origin), vec.toBox2d(translation), worldFilter);
    const visibleTranslation = if (worldHit.hit)
        vec.subtract(vec.fromBox2d(worldHit.point), origin)
    else
        translation;
    const endPoint = vec.add(origin, visibleTranslation);

    var playerFilter = box2d.c.b2DefaultQueryFilter();
    playerFilter.categoryBits = collision.CATEGORY_PROJECTILE;
    playerFilter.maskBits = collision.otherPlayersMask(playerId);

    var context = HitscanContext{};
    box2d.castRay(
        vec.toBox2d(origin),
        vec.toBox2d(visibleTranslation),
        playerFilter,
        collectHitscanPlayer,
        &context,
    );

    for (context.player_hits, 0..) |maybeHit, hitPlayerId| {
        if (maybeHit == null) continue;
        const hit = maybeHit.?;
        try projectile.damagePlayerFromHitscan(
            hitPlayerId,
            w.directDamage,
            playerId,
            hit.point,
            direction,
            .penetrating,
        );
    }

    return endPoint;
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
        const randAngle = runtime.random().float(f32) * 2.0 * std.math.pi;
        const randDist = runtime.random().float(f32) * pel.spawnRadius;
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
        shapeDef.material.friction = pel.friction;
        shapeDef.enableHitEvents = true;
        shapeDef.enableContactEvents = true;
        shapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
        shapeDef.filter.maskBits = collision.MASK_PROJECTILE;
        if (w.penetration == .non_penetrating) {
            shapeDef.filter.maskBits |= collision.otherPlayersMask(playerId);
        }

        const circleShape = box2d.c.b2Circle{
            .center = .{ .x = 0, .y = 0 },
            .radius = pel.radius,
        };
        _ = box2d.c.b2CreateCircleShape(bodyId, &shapeDef, &circleShape);

        if (w.penetration == .penetrating) {
            var sensorShapeDef = box2d.c.b2DefaultShapeDef();
            sensorShapeDef.isSensor = true;
            sensorShapeDef.enableSensorEvents = true;
            sensorShapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
            sensorShapeDef.filter.maskBits = collision.otherPlayersMask(playerId);
            _ = box2d.c.b2CreateCircleShape(bodyId, &sensorShapeDef, &circleShape);
        }

        const spriteUuid = try sprite.createFromImg(
            "particles/circle.png",
            .{ .x = pel.spriteScale, .y = pel.spriteScale },
            .{ .x = 0, .y = 0 },
        );

        var spriteUuids = try allocator.alloc(u64, 1);
        spriteUuids[0] = spriteUuid;
        const shapeIds = try allocator.alloc(box2d.c.b2ShapeId, 0);

        try entity.entities.putLocking(bodyId, entity.Entity{
            .type = try allocator.dupe(u8, "projectile"),
            .friction = shapeDef.material.friction,
            .bodyId = bodyId,
            .spriteUuids = spriteUuids,
            .shapeIds = shapeIds,
            .colliderChunks = try allocator.alloc(entity.ColliderChunk, 0),
            .state = null,
            .highlighted = false,
            .hovered = false,
            .animated = false,
            .flipEntityHorizontally = false,
            .categoryBits = shapeDef.filter.categoryBits,
            .maskBits = shapeDef.filter.maskBits,
            .enabled = true,
            .color = pel.color,
            .glow = true,
        });

        const impulse = vec.mul(pelletDir, w.impulse);
        box2d.c.b2Body_ApplyLinearImpulseToCenter(bodyId, vec.toBox2d(impulse), true);

        const currentVel = box2d.c.b2Body_GetLinearVelocity(bodyId);
        box2d.c.b2Body_SetLinearVelocity(bodyId, .{
            .x = currentVel.x + initialVelocity.x,
            .y = currentVel.y + initialVelocity.y,
        });

        try projectile.create(bodyId, .{
            .owner_id = playerId,
            .direct_damage = w.directDamage,
            .penetration = w.penetration,
            .explosion = pel.explosion,
        });
    }
}

pub fn drawTrails() !void {
    const currentTime = time.now();

    const prevBlendMode = try gpu.getRenderDrawBlendMode();
    try gpu.setRenderDrawBlendMode(.blend);

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

            try gpu.setRenderDrawColor(.{ .r = colorR, .g = colorG, .b = colorB, .a = lineAlpha });
            try gpu.renderDrawLine(startPx.x + ox, startPx.y + oy, endPx.x + ox, endPx.y + oy);
        }

        i += 1;
    }

    try gpu.setRenderDrawBlendMode(prevBlendMode);
}

pub fn cleanupTrails() void {
    activeTrails.clearAndFree(allocator);
}
