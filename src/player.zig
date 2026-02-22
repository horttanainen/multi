const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const camera = @import("camera.zig");
const delay = @import("delay.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const uuid = @import("uuid.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const animation = @import("animation.zig");
const time = @import("time.zig");
const audio = @import("audio.zig");
const weapon = @import("weapon.zig");
const projectile = @import("projectile.zig");
const viewport = @import("viewport.zig");
const level = @import("level.zig");
const particle = @import("particle.zig");
const timer = @import("sdl_timer.zig");
const thread_safe = @import("thread_safe_array_list.zig");
const gibbing = @import("gibbing.zig");
const rope = @import("rope.zig");
const score = @import("score.zig");

const config = @import("config.zig");
const collision = @import("collision.zig");

const conv = @import("conversion.zig");

const vec = @import("vector.zig");

pub const Player = struct {
    id: usize,
    bodyId: box2d.c.b2BodyId,
    cameraId: usize,
    bodyShapeId: box2d.c.b2ShapeId,
    lowerBodyShapeId: box2d.c.b2ShapeId,
    footSensorShapeId: box2d.c.b2ShapeId,
    leftWallSensorId: box2d.c.b2ShapeId,
    rightWallSensorId: box2d.c.b2ShapeId,
    weapons: []weapon.Weapon,
    selectedWeaponIndex: usize,

    groundContactCount: usize,
    leftWallContactCount: usize,
    rightWallContactCount: usize,
    isMoving: bool,
    touchesGround: bool,
    touchesWallOnLeft: bool,
    touchesWallOnRight: bool,
    aimDirection: vec.Vec2,
    isAiming: bool,
    aimMagnitude: f32,
    airJumpCounter: i32,
    movingRight: bool,
    crosshairUuid: u64,
    health: f32,
    isDead: bool,
    respawnTimerId: i32,
    isZooming: bool,
    zoomOffset: vec.Vec2,
};

pub var players: std.AutoArrayHashMapUnmanaged(usize, Player) = .{};
const PlayerError = error{PlayerUnspawned};

var playersToRespawn = thread_safe.ThreadSafeArrayList(usize).init(shared.allocator);

fn markPlayerForRespawn(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    if (param) |p| {
        // Subtract 1 because we added 1 to avoid null pointer (player ID 0 would be null)
        const playerId: usize = @intFromPtr(p) - 1;
        playersToRespawn.appendLocking(playerId) catch {};
    }
    return 0;
}

pub fn drawCrosshair(player: *Player) !void {
    const crosshairSprite = sprite.getSprite(player.crosshairUuid) orelse return;
    const pos = calcCrosshairPosition(player.*);
    try sprite.drawWithOptions(crosshairSprite, pos, 0, false, false, 0, null, null);
}

fn calcCrosshairPosition(p: Player) vec.IVec2 {
    const maybeEntity = entity.getEntity(p.bodyId);
    if (maybeEntity) |ent| {
        const currentState = box2d.getState(p.bodyId);
        const state = box2d.getInterpolatedState(ent.state, currentState);
        const playerPos = camera.relativePosition(conv.m2Pixel(state.pos));

        const crosshairPos = vec.iadd(vec.iadd(playerPos, getCrosshairOffset(p)), config.aimCircleOffset);

        if (ent.spriteUuids.len > 0) {
            const firstSprite = sprite.getSprite(ent.spriteUuids[0]) orelse return crosshairPos;
            return vec.iadd(crosshairPos, firstSprite.offset);
        }
        return crosshairPos;
    }
    return vec.izero;
}

pub fn getCrosshairOffset(p: Player) vec.IVec2 {
    const baseDistance: f32 = if (p.isAiming) p.aimMagnitude * config.aimCircleRadius else config.aimRestingDistance;
    const distance: f32 = if (p.isZooming) baseDistance * 2 else baseDistance;
    const displacement = vec.mul(vec.normalize(p.aimDirection), distance);
    return .{
        .x = @intFromFloat(displacement.x),
        .y = @intFromFloat(-displacement.y),
    };
}

fn calcProjectileSpawnPosition(p: Player) vec.IVec2 {
    const maybeEntity = entity.getEntity(p.bodyId);
    if (maybeEntity) |ent| {
        const currentState = box2d.getState(p.bodyId);
        const state = box2d.getInterpolatedState(ent.state, currentState);
        const playerPos = camera.relativePosition(conv.m2Pixel(state.pos));

        const spawnPos = vec.iadd(playerPos, config.aimCircleOffset);

        if (ent.spriteUuids.len > 0) {
            const firstSprite = sprite.getSprite(ent.spriteUuids[0]) orelse return spawnPos;
            return vec.iadd(spawnPos, firstSprite.offset);
        }
        return spawnPos;
    }
    return vec.izero;
}

pub fn spawn(position: vec.IVec2) !usize {
    const resources = try shared.getResources();
    const surface = try image.load(shared.lieroImgSrc);
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);

    const pos = conv.pixel2M(position);

    const bodyDef = box2d.createNonRotatingDynamicBodyDef(pos);
    const bodyId = try box2d.createBody(bodyDef);

    const playerId = players.values().len;
    const playerMaterialId: i32 = @intCast(playerId + config.player.materialOffset);

    const dynamicBox = box2d.c.b2MakeOffsetBox(0.2, 0.6, .{ .x = 0, .y = -0.5 }, .{ .c = 1, .s = 0 });
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.density = 0.45;
    shapeDef.friction = config.player.movementFriction;
    shapeDef.material = playerMaterialId;
    shapeDef.filter.categoryBits = collision.CATEGORY_PLAYER | collision.playerCategory(playerId);
    shapeDef.filter.maskBits = collision.MASK_PLAYER;
    const bodyShapeId = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const lowerBodyCircle: box2d.c.b2Circle = .{
        .center = .{
            .x = 0,
            .y = 0,
        },
        .radius = 0.3,
    };
    var lowerBodyShapeDef = box2d.c.b2DefaultShapeDef();
    lowerBodyShapeDef.density = 0;
    lowerBodyShapeDef.friction = config.player.movementFriction;
    lowerBodyShapeDef.material = playerMaterialId;
    lowerBodyShapeDef.filter.categoryBits = collision.CATEGORY_PLAYER | collision.playerCategory(playerId);
    lowerBodyShapeDef.filter.maskBits = collision.MASK_PLAYER_LOWER_BODY;
    const lowerBodyShapeId = box2d.c.b2CreateCircleShape(bodyId, &lowerBodyShapeDef, &lowerBodyCircle);

    const footBox = box2d.c.b2MakeOffsetBox(0.2, 0.1, .{ .x = 0, .y = 0.4 }, .{ .c = 1, .s = 0 });
    var footShapeDef = box2d.c.b2DefaultShapeDef();
    footShapeDef.isSensor = true;
    footShapeDef.density = 0;
    footShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
    footShapeDef.filter.maskBits = collision.MASK_SENSOR_FOOT;
    const footSensorShapeId = box2d.c.b2CreatePolygonShape(bodyId, &footShapeDef, &footBox);

    const leftWallBox = box2d.c.b2MakeOffsetBox(0.15, 0.4, .{ .x = -0.2, .y = -0.5 }, .{ .c = 1, .s = 0 });
    var leftWallShapeDef = box2d.c.b2DefaultShapeDef();
    leftWallShapeDef.isSensor = true;
    leftWallShapeDef.density = 0;
    leftWallShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
    leftWallShapeDef.filter.maskBits = collision.MASK_SENSOR_WALL;
    const leftWallSensorId = box2d.c.b2CreatePolygonShape(bodyId, &leftWallShapeDef, &leftWallBox);

    const rightWallBox = box2d.c.b2MakeOffsetBox(0.15, 0.4, .{ .x = 0.2, .y = -0.5 }, .{ .c = 1, .s = 0 });
    var rightWallShapeDef = box2d.c.b2DefaultShapeDef();
    rightWallShapeDef.isSensor = true;
    rightWallShapeDef.density = 0;
    rightWallShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
    rightWallShapeDef.filter.maskBits = collision.MASK_SENSOR_WALL;
    const rightWallSensorId = box2d.c.b2CreatePolygonShape(bodyId, &rightWallShapeDef, &rightWallBox);

    var shapeIds = std.array_list.Managed(box2d.c.b2ShapeId).init(shared.allocator);
    try shapeIds.append(bodyShapeId);
    try shapeIds.append(lowerBodyShapeId);
    try shapeIds.append(footSensorShapeId);
    try shapeIds.append(leftWallSensorId);
    try shapeIds.append(rightWallSensorId);

    var animations = std.StringHashMap(animation.Animation).init(shared.allocator);

    var idleAnim = try animation.load(
        "animations/red/idle",
        2,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
        true,
        0,
    );
    idleAnim.switchDelay = 0.25;
    try animations.put("idle", idleAnim);

    const runAnim = try animation.load(
        "animations/red/run",
        12,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
        true,
        0,
    );
    try animations.put("run", runAnim);

    const fallAnim = try animation.load(
        "animations/red/fall",
        4,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
        true,
        0,
    );
    try animations.put("fall", fallAnim);

    const afterJumpAnim = try animation.load(
        "animations/red/after_jump",
        8,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
        true,
        0,
    );
    try animations.put("afterjump", afterJumpAnim);

    const missileAnimation = try animation.load(
        "weapons/rocket_launcher/projectile",
        8,
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 0 },
        true,
        0,
    );

    const missileExplosionAnimation = try animation.load(
        "weapons/rocket_launcher/explosion",
        10,
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0, .y = 0 },
        false,
        0,
    );

    const missilePropulsionAnimation = try animation.load(
        "weapons/rocket_launcher/propulsion_flame",
        2,
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0, .y = 50 },
        false,
        1,
    );

    const weaponScale: vec.Vec2 = .{ .x = 0.2, .y = 0.2 };
    const weaponSpriteUuid = try sprite.createFromImg("weapons/rocket_launcher/weapon_with_arm.png", weaponScale, vec.izero);

    const rocketLauncher: weapon.Weapon = .{
        .name = "rocket_launcher",
        .scale = weaponScale,
        .delay = config.shootDelayMs,
        .sound = .{
            .file = "sounds/cannon_fire.mp3",
            .durationMs = config.cannonFireSoundDurationMs,
        },
        .impulse = 10,
        .spriteUuid = weaponSpriteUuid,
        .projectile = .{
            .gravityScale = 0.2,
            .density = 10,
            .propulsion = 40,
            .animation = missileAnimation,
            .propulsionAnimation = missilePropulsionAnimation,
            .explosion = .{
                .sound = .{
                    .file = "sounds/cannon_hit.mp3",
                    .durationMs = config.cannonHitSoundDurationMs,
                },
                .animation = missileExplosionAnimation,
                .blastPower = 100,
                .blastRadius = 2.0,
                .particleCount = 100,
                .particleDensity = 1.5,
                .particleFriction = 0,
                .particleRestitution = 0.99,
                .particleRadius = 0.05,
                .particleLinearDamping = 10,
                .particleGravityScale = 0,
            },
        },
    };

    var weapons = std.array_list.Managed(weapon.Weapon).init(shared.allocator);
    try weapons.append(rocketLauncher);

    var playerSpriteUuids = try shared.allocator.alloc(u64, 1);
    playerSpriteUuids[0] = try sprite.createCopy(idleAnim.frames[0]);

    const playerEntity = entity.Entity{
        .type = try shared.allocator.dupe(u8, "dynamic"),
        .friction = config.player.movementFriction,
        .bodyId = bodyId,
        .spriteUuids = playerSpriteUuids,
        .shapeIds = try shapeIds.toOwnedSlice(),
        .state = null,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = collision.CATEGORY_PLAYER,
        .maskBits = collision.CATEGORY_TERRAIN | collision.CATEGORY_DYNAMIC | collision.CATEGORY_PROJECTILE | collision.CATEGORY_BLOOD,
        .enabled = true,
    };

    const crosshairUuid = try sprite.createFromImg(shared.crosshairImgSrc, .{
        .x = 1,
        .y = 1,
    }, vec.izero);

    // Create camera for this player
    const cameraId = try camera.spawnForPlayer(playerId, position);
    try viewport.addViewportForCamera(cameraId);

    try players.put(shared.allocator, playerId, Player{
        .id = playerId,
        .bodyId = bodyId,
        .bodyShapeId = bodyShapeId,
        .lowerBodyShapeId = lowerBodyShapeId,
        .footSensorShapeId = footSensorShapeId,
        .leftWallSensorId = leftWallSensorId,
        .rightWallSensorId = rightWallSensorId,
        .weapons = try weapons.toOwnedSlice(),
        .selectedWeaponIndex = 0,
        // Initialize per-player state
        .groundContactCount = 0,
        .leftWallContactCount = 0,
        .rightWallContactCount = 0,
        .isMoving = false,
        .touchesGround = false,
        .touchesWallOnLeft = false,
        .touchesWallOnRight = false,
        .aimDirection = vec.west,
        .isAiming = false,
        .aimMagnitude = 0,
        .airJumpCounter = 0,
        .movingRight = false,
        .crosshairUuid = crosshairUuid,
        .cameraId = cameraId,
        .health = 100,
        .isDead = false,
        .respawnTimerId = -1,
        .isZooming = false,
        .zoomOffset = vec.zero,
    });

    // Register player entity with entity system (needed for animation sprite updates)
    try entity.entities.putLocking(bodyId, playerEntity);

    // Register player with central animation system
    try animation.registerAnimationSet(bodyId, animations, "idle", false);

    try score.registerPlayer(playerId);

    return playerId;
}

pub fn updateAnimationState(player: *Player) void {
    const velocity = box2d.c.b2Body_GetLinearVelocity(player.bodyId);
    const movingUpward = velocity.y < 0; // Negative y = upward in Box2D
    const movingDownward = velocity.y > 0; // Positive y = downward in Box2D

    const targetAnimationKey = if (!player.touchesGround and movingUpward)
        "afterjump"
    else if (!player.touchesGround and movingDownward)
        "fall"
    else if (player.isMoving)
        "run"
    else
        "idle";

    animation.switchAnimation(player.bodyId, targetAnimationKey) catch {};
}

pub fn jump(player: *Player) void {
    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_jump", .{player.id}) catch unreachable;

    if (delay.check(delayKey)) {
        return;
    }

    player.groundContactCount = 0;

    if (!player.touchesGround and player.airJumpCounter < config.player.maxAirJumps) {
        player.airJumpCounter += 1;
    } else if (!player.touchesGround and player.airJumpCounter >= config.player.maxAirJumps) {
        return;
    }

    var jumpImpulse = box2d.c.b2Vec2{ .x = 0, .y = -config.player.jumpImpulse };
    if (player.touchesWallOnRight or player.touchesWallOnLeft) {
        jumpImpulse = if (player.touchesWallOnLeft) box2d.c.b2Vec2{
            .x = config.player.jumpImpulse / 2,
            .y = -config.player.jumpImpulse,
        } else box2d.c.b2Vec2{
            .x = -config.player.jumpImpulse / 2,
            .y = -config.player.jumpImpulse,
        };
        player.leftWallContactCount = 0;
        player.rightWallContactCount = 0;
    }

    box2d.c.b2Body_ApplyLinearImpulseToCenter(player.bodyId, jumpImpulse, true);
    delay.action(delayKey, config.jumpDelayMs);
}

pub fn brake(player: *Player) void {
    player.isMoving = false;
}

pub fn moveLeft(player: *Player) void {
    player.movingRight = false;
    applyForce(player, box2d.c.b2Vec2{ .x = -config.player.sidewaysMovementForce, .y = 0 });
}

pub fn moveRight(player: *Player) void {
    player.movingRight = true;
    applyForce(player, box2d.c.b2Vec2{ .x = config.player.sidewaysMovementForce, .y = 0 });
}

fn applyForce(player: *Player, force: box2d.c.b2Vec2) void {
    player.isMoving = true;
    box2d.c.b2Body_ApplyForceToCenter(player.bodyId, force, true);
}

pub fn clampSpeed(player: *Player) void {
    var velocity = box2d.c.b2Body_GetLinearVelocity(player.bodyId);
    if (velocity.x > config.player.maxMovementSpeed) {
        velocity.x = config.player.maxMovementSpeed;
        box2d.c.b2Body_SetLinearVelocity(player.bodyId, velocity);
    } else if (velocity.x < -config.player.maxMovementSpeed) {
        velocity.x = -config.player.maxMovementSpeed;
        box2d.c.b2Body_SetLinearVelocity(player.bodyId, velocity);
    }
}

pub fn getFrictionForPlayer(player: *Player) f32 {
    return if (player.isMoving) config.player.movementFriction else config.player.restingFriction;
}

pub fn checkSensors(player: *Player) !void {
    const resources = try shared.getResources();
    const sensorEvents = box2d.c.b2World_GetSensorEvents(resources.worldId);

    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const e = sensorEvents.beginEvents[i];

        if (box2d.c.B2_ID_EQUALS(e.visitorShapeId, player.bodyShapeId)) {
            continue;
        }
        if (box2d.c.B2_ID_EQUALS(e.visitorShapeId, player.lowerBodyShapeId)) {
            continue;
        }

        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.footSensorShapeId)) {
            player.airJumpCounter = 0;
            player.groundContactCount += 1;
        }

        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.leftWallSensorId)) {
            player.airJumpCounter = 0;
            player.leftWallContactCount += 1;
        }
        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.rightWallSensorId)) {
            player.airJumpCounter = 0;
            player.rightWallContactCount += 1;
        }
    }

    for (0..@intCast(sensorEvents.endCount)) |i| {
        const e = sensorEvents.endEvents[i];

        if (box2d.c.B2_ID_EQUALS(e.visitorShapeId, player.bodyShapeId)) {
            continue;
        }
        if (box2d.c.B2_ID_EQUALS(e.visitorShapeId, player.lowerBodyShapeId)) {
            continue;
        }

        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.footSensorShapeId)) {
            if (player.groundContactCount > 0) {
                player.groundContactCount -= 1;
            }
        }

        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.leftWallSensorId)) {
            if (player.leftWallContactCount > 0) {
                player.leftWallContactCount -= 1;
            }
        }
        if (box2d.c.B2_ID_EQUALS(e.sensorShapeId, player.rightWallSensorId)) {
            if (player.rightWallContactCount > 0) {
                player.rightWallContactCount -= 1;
            }
        }
    }
    player.touchesGround = player.groundContactCount > 0;
    player.touchesWallOnRight = player.rightWallContactCount > 0;
    player.touchesWallOnLeft = player.leftWallContactCount > 0;
}

pub fn aim(p: *Player, direction: vec.Vec2) void {
    var dir = direction;
    if (vec.equals(dir, vec.zero)) {
        dir = vec.add(dir, if (p.movingRight) vec.east else vec.west);
    }
    p.isAiming = true;
    p.aimMagnitude = std.math.clamp(vec.magnitude(dir), 0, 1);
    p.aimDirection = vec.normalize(dir);

    // Update entity flip based on aim direction
    const maybeEntity = entity.entities.getPtrLocking(p.bodyId);
    if (maybeEntity) |ent| {
        ent.flipEntityHorizontally = dir.x > 0;
    }
}

pub fn aimRelease(p: *Player) void {
    p.isAiming = false;
}

pub fn zoom(p: *Player) void {
    p.isZooming = true;
}

pub fn zoomRelease(p: *Player) void {
    p.isZooming = false;
}

pub fn shoot(player: *Player) !void {
    if (player.weapons.len == 0) return;

    var buf: [64:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_{s}", .{ player.id, "shoot" }) catch unreachable;

    if (delay.check(delayKey)) {
        return;
    }

    const selectedWeapon = player.weapons[player.selectedWeaponIndex];
    const spawnPos = calcProjectileSpawnPosition(player.*);
    const position = camera.relativePositionForCreating(spawnPos);

    const playerVelocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(player.bodyId));
    try weapon.shoot(selectedWeapon, position, player.aimDirection, playerVelocity, player.id);

    const recoilImpulse = vec.mul(vec.normalize(.{
        .x = player.aimDirection.x,
        .y = -player.aimDirection.y,
    }), selectedWeapon.impulse * -0.1);

    box2d.c.b2Body_ApplyLinearImpulseToCenter(player.bodyId, vec.toBox2d(recoilImpulse), true);
    delay.action(delayKey, selectedWeapon.delay);
}

pub fn toggleRope(p: *Player) !void {
    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_rope", .{p.id}) catch unreachable;
    if (delay.check(delayKey)) return;

    const currentRope = rope.ropes.get(p.id);
    if (currentRope != null and currentRope.?.state != .inactive) {
        rope.releaseRope(p.id);
    } else {
        const spawnPos = calcProjectileSpawnPosition(p.*);
        const worldPixelPos = camera.relativePositionForCreating(spawnPos);
        const originM = conv.p2m(worldPixelPos);
        try rope.shootHook(p.id, .{ .x = originM.x, .y = originM.y }, p.aimDirection);
    }
    delay.action(delayKey, config.ropeToggleDelayMs);
}

pub fn setColor(playerId: usize, color: sprite.Color) void {
    const maybePlayer = players.getPtr(playerId);
    if (maybePlayer) |player| {
        animation.colorAllFrames(player.bodyId, color) catch |err| {
            std.debug.print("Warning: Failed to color animation frames for player {}: {}\n", .{ playerId, err });
        };

        const selectedWeapon = player.weapons[player.selectedWeaponIndex];
        if (selectedWeapon.spriteUuid != 0) {
            sprite.colorMatchingPixels(selectedWeapon.spriteUuid, color, sprite.isWhite) catch |err| {
                std.debug.print("Warning: Failed to color weapon sprite for player {}: {}\n", .{ playerId, err });
            };
        }

        sprite.colorMatchingPixels(player.crosshairUuid, color, sprite.isAny) catch |err| {
            std.debug.print("Warning: Failed to color crosshair for player {}: {}\n", .{ playerId, err });
        };

        gibbing.prepareGibletsForPlayer(playerId, color) catch |err| {
            std.debug.print("Warning: Failed to prepare giblets for player {}: {}\n", .{ playerId, err });
        };
    }
}

// Iteration helpers for operating on all players
pub fn updateAllStates() void {
    for (players.values()) |*p| {
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            ent.state = box2d.getState(p.bodyId);
        }
    }
}

pub fn updateAllAnimationStates() void {
    for (players.values()) |*p| {
        updateAnimationState(p);
    }
}

pub fn checkAllSensors() !void {
    for (players.values()) |*p| {
        try checkSensors(p);
    }
}

pub fn clampAllSpeeds() void {
    for (players.values()) |*p| {
        clampSpeed(p);
    }
}

pub fn drawAllCrosshairs() !void {
    for (players.values()) |*p| {
        if (p.isDead) {
            continue;
        }
        try drawCrosshair(p);
    }
}

pub fn drawWeapon(player: *Player) !void {
    if (player.weapons.len == 0) return;
    const selectedWeapon = player.weapons[player.selectedWeaponIndex];
    if (selectedWeapon.spriteUuid == 0) return;
    const weaponSprite = sprite.getSprite(selectedWeapon.spriteUuid) orelse return;

    const maybeEntity = entity.getEntity(player.bodyId);
    if (maybeEntity == null) {
        return;
    }
    const ent = maybeEntity.?;
    const currentState = box2d.getState(player.bodyId);
    const state = box2d.getInterpolatedState(ent.state, currentState);
    const playerPos = camera.relativePosition(conv.m2Pixel(state.pos));

    const playerSprite = if (ent.spriteUuids.len > 0) sprite.getSprite(ent.spriteUuids[0]) else null;

    const playerFlip = ent.flipEntityHorizontally;
    const weaponFlip = !ent.flipEntityHorizontally;

    // Use left shoulder anchor when facing right (flipped), right shoulder when facing left (default)
    const playerAnchor = if (playerSprite) |ps| (if (playerFlip) ps.anchorPointLeft else ps.anchorPointRight orelse ps.anchorPointLeft) else null;
    const weaponAnchor = weaponSprite.anchorPointLeft;

    if (playerAnchor == null or weaponAnchor == null or playerSprite == null) {
        const weaponPos = vec.iadd(playerPos, weaponSprite.offset);
        try sprite.drawWithOptions(weaponSprite, weaponPos, 0, false, weaponFlip, 0, null, null);
        return;
    }
    const pAnchor = playerAnchor.?;
    const wAnchor = weaponAnchor.?;
    const ps = playerSprite.?;

    const playerHalfW = @divTrunc(ps.sizeP.x, 2);
    const playerHalfH = @divTrunc(ps.sizeP.y, 2);
    const playerOffsetX: i32 = if (playerFlip) ps.offset.x else -ps.offset.x;
    const playerUpperLeft = vec.IVec2{
        .x = playerPos.x - playerHalfW + playerOffsetX,
        .y = playerPos.y - playerHalfH + ps.offset.y,
    };

    // When flipped, mirror the anchor X within the sprite
    const shoulderPos = if (playerFlip)
        vec.iadd(playerUpperLeft, .{ .x = ps.sizeP.x - pAnchor.x, .y = pAnchor.y })
    else
        vec.iadd(playerUpperLeft, pAnchor);

    const effectiveWAnchorX: i32 = if (weaponFlip) weaponSprite.sizeP.x - wAnchor.x else wAnchor.x;

    const weaponHalfW = @divTrunc(weaponSprite.sizeP.x, 2);
    const weaponHalfH = @divTrunc(weaponSprite.sizeP.y, 2);
    const weaponCenterPos = vec.IVec2{
        .x = shoulderPos.x - effectiveWAnchorX + weaponHalfW,
        .y = shoulderPos.y - wAnchor.y + weaponHalfH,
    };

    const aimAngle = std.math.atan2(-player.aimDirection.y, player.aimDirection.x);
    const weaponAngle: f32 = if (weaponFlip) std.math.pi + aimAngle else aimAngle;

    const pivotPoint: sdl.Point = .{ .x = effectiveWAnchorX, .y = wAnchor.y };
    try sprite.drawWithOptions(weaponSprite, weaponCenterPos, weaponAngle, false, weaponFlip, 0, null, pivotPoint);
}

pub fn drawAllWeaponsBehind() !void {
    for (players.values()) |*p| {
        if (p.isDead) continue;
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            // Draw behind when facing left (flipEntityHorizontally == false)
            if (!ent.flipEntityHorizontally) try drawWeapon(p);
        }
    }
}

pub fn drawAllWeaponsFront() !void {
    for (players.values()) |*p| {
        if (p.isDead) continue;
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            // Draw in front when facing right (flipEntityHorizontally == true)
            if (ent.flipEntityHorizontally) try drawWeapon(p);
        }
    }
}

pub fn damage(p: *Player, d: f32, attackerId: ?usize) !void {
    p.health -= d;

    const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));

    // Generate blood if player took damage
    if (d > 0) {
        try particle.createBloodParticles(playerPosM, d);
    }

    if (p.health <= 0 and !p.isDead) {
        try kill(p, attackerId);
    }

    if (p.health <= -5) {
        try gib(p);
    }
}

pub fn kill(p: *Player, killerId: ?usize) !void {
    if (p.health <= 0 and !p.isDead) {
        box2d.c.b2Body_Disable(p.bodyId);

        const maybeEntity = entity.entities.getPtrLocking(p.bodyId);
        if (maybeEntity) |ent| {
            ent.enabled = false;
        }

        // Release rope on death
        rope.releaseRope(p.id);

        p.isDead = true;

        score.recordKill(killerId, p.id);

        //TODO: remove this silly stuff when we have a proper map of players and uuids for IDs
        // Add 1 to player ID to avoid null pointer (player ID 0 would become null)
        p.respawnTimerId = timer.addTimer(config.respawnDelayMs, markPlayerForRespawn, @ptrFromInt(p.id + 1));
    }
}

fn gib(p: *Player) !void {
    const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
    gibbing.gib(playerPosM, p.id);
}

pub fn processRespawns() !void {
    playersToRespawn.mutex.lock();
    defer playersToRespawn.mutex.unlock();

    for (playersToRespawn.list.items) |playerId| {
        const maybePlayer = players.getPtr(playerId);
        if (maybePlayer) |p| {
            p.health = 100;

            const spawnPosM = conv.p2m(level.spawnLocation);
            box2d.c.b2Body_SetTransform(p.bodyId, spawnPosM, box2d.c.b2Rot_identity);

            box2d.c.b2Body_SetLinearVelocity(p.bodyId, box2d.c.b2Vec2_zero);
            box2d.c.b2Body_SetAngularVelocity(p.bodyId, 0);

            box2d.c.b2Body_Enable(p.bodyId);

            const maybeEntity = entity.entities.getPtrLocking(p.bodyId);
            if (maybeEntity) |ent| {
                ent.enabled = true;
            }

            p.isDead = false;
            p.respawnTimerId = -1;
        }
    }

    playersToRespawn.list.clearAndFree();
}

pub fn cleanup() void {
    for (players.values()) |*p| {
        if (p.respawnTimerId != -1) {
            _ = timer.removeTimer(p.respawnTimerId);
        }

        camera.destroyCamera(p.cameraId);

        // Cleanup weapon animations and sprites
        for (p.weapons) |w| {
            animation.cleanupOne(w.projectile.animation);
            animation.cleanupOne(w.projectile.explosion.animation);
            if (w.projectile.propulsionAnimation) |propAnim| {
                animation.cleanupOne(propAnim);
            }
            if (w.spriteUuid != 0) {
                sprite.cleanupLater(w.spriteUuid);
            }
        }

        // Cleanup player resources
        shared.allocator.free(p.weapons);
        sprite.cleanupLater(p.crosshairUuid);
    }

    players.clearAndFree(shared.allocator);

    score.cleanup();

    playersToRespawn.mutex.lock();
    defer playersToRespawn.mutex.unlock();
    playersToRespawn.list.clearAndFree();
}
