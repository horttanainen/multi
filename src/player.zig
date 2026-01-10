const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const camera = @import("camera.zig");
const delay = @import("delay.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
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

const config = @import("config.zig");

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
    airJumpCounter: i32,
    movingRight: bool,
    crosshair: sprite.Sprite,
    health: f32,
    isDead: bool,
    respawnTimerId: i32,
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
    const pos = calcCrosshairPosition(player.*);
    try sprite.drawWithOptions(player.crosshair, pos, 0, false, false, 0, null);
}

fn calcCrosshairPosition(player: Player) vec.IVec2 {
    const maybeEntity = entity.getEntity(player.bodyId);
    if (maybeEntity) |ent| {
        const currentState = box2d.getState(player.bodyId);
        const state = box2d.getInterpolatedState(ent.state, currentState);
        const playerPos = camera.relativePosition(
            conv.m2PixelPos(
                state.pos.x,
                state.pos.y,
                player.crosshair.sizeM.x / player.crosshair.scale.x,
                player.crosshair.sizeM.y / player.crosshair.scale.y,
            ),
        );

        const crosshairDisplacement = vec.mul(vec.normalize(player.aimDirection), 100);
        const crosshairDisplacementI: vec.IVec2 = .{
            .x = @intFromFloat(crosshairDisplacement.x),
            .y = @intFromFloat(-crosshairDisplacement.y), //inverse y-axel
        };

        const crosshairPos = vec.iadd(playerPos, crosshairDisplacementI);
        return vec.iadd(crosshairPos, ent.sprite.offset);
    }
    return vec.izero; // Fallback if entity not found
}

pub fn spawn(position: vec.IVec2) !usize {
    const resources = try shared.getResources();
    const surface = try image.load(shared.lieroImgSrc);
    const texture = try sdl.createTextureFromSurface(resources.renderer, surface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const sizeM = conv.p2m(.{ .x = size.x, .y = size.y });

    const pos = conv.pixel2MPos(position.x, position.y, sizeM.x, sizeM.y);

    const bodyDef = box2d.createNonRotatingDynamicBodyDef(pos);
    const bodyId = try box2d.createBody(bodyDef);

    const playerId = players.values().len;
    const playerMaterialId: i32 = @intCast(playerId + config.player.materialOffset);

    const dynamicBox = box2d.c.b2MakeBox(0.1, 0.25);
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.density = 1.0;
    shapeDef.friction = config.player.movementFriction;
    shapeDef.material = playerMaterialId;
    shapeDef.filter.categoryBits = config.CATEGORY_PLAYER;
    shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_GIBLET | config.CATEGORY_PROJECTILE | config.CATEGORY_BLOOD | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;
    const bodyShapeId = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const lowerBodyCircle: box2d.c.b2Circle = .{
        .center = .{
            .x = 0,
            .y = 0.25,
        },
        .radius = 0.1,
    };
    var lowerBodyShapeDef = box2d.c.b2DefaultShapeDef();
    lowerBodyShapeDef.density = 1.0;
    lowerBodyShapeDef.friction = config.player.movementFriction;
    lowerBodyShapeDef.material = playerMaterialId;
    lowerBodyShapeDef.filter.categoryBits = config.CATEGORY_PLAYER;
    lowerBodyShapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_GIBLET | config.CATEGORY_PROJECTILE | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;
    const lowerBodyShapeId = box2d.c.b2CreateCircleShape(bodyId, &lowerBodyShapeDef, &lowerBodyCircle);

    const footBox = box2d.c.b2MakeOffsetBox(0.1, 0.1, .{ .x = 0, .y = 0.4 }, .{ .c = 1, .s = 0 });
    var footShapeDef = box2d.c.b2DefaultShapeDef();
    footShapeDef.isSensor = true;
    footShapeDef.filter.categoryBits = config.CATEGORY_SENSOR;
    footShapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_GIBLET | config.CATEGORY_UNBREAKABLE;
    const footSensorShapeId = box2d.c.b2CreatePolygonShape(bodyId, &footShapeDef, &footBox);

    const leftWallBox = box2d.c.b2MakeOffsetBox(0.1, 0.1, .{ .x = -0.1, .y = 0 }, .{ .c = 1, .s = 0 });
    var leftWallShapeDef = box2d.c.b2DefaultShapeDef();
    leftWallShapeDef.isSensor = true;
    leftWallShapeDef.filter.categoryBits = config.CATEGORY_SENSOR;
    leftWallShapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_UNBREAKABLE;
    const leftWallSensorId = box2d.c.b2CreatePolygonShape(bodyId, &leftWallShapeDef, &leftWallBox);

    const rightWallBox = box2d.c.b2MakeOffsetBox(0.1, 0.1, .{ .x = 0.1, .y = 0 }, .{ .c = 1, .s = 0 });
    var rightWallShapeDef = box2d.c.b2DefaultShapeDef();
    rightWallShapeDef.isSensor = true;
    rightWallShapeDef.filter.categoryBits = config.CATEGORY_SENSOR;
    rightWallShapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_UNBREAKABLE;
    const rightWallSensorId = box2d.c.b2CreatePolygonShape(bodyId, &rightWallShapeDef, &rightWallBox);

    const s = sprite.Sprite{
        .surface = surface,
        .texture = texture,
        .imgPath = shared.lieroImgSrc,
        .scale = .{
            .x = 0.5,
            .y = 0.5,
        },
        .sizeM = .{
            .x = sizeM.x,
            .y = sizeM.y,
        },
        .sizeP = .{
            .x = size.x,
            .y = size.y,
        },
        .offset = vec.izero,
    };

    var shapeIds = std.array_list.Managed(box2d.c.b2ShapeId).init(shared.allocator);
    try shapeIds.append(bodyShapeId);
    try shapeIds.append(lowerBodyShapeId);
    try shapeIds.append(footSensorShapeId);
    try shapeIds.append(leftWallSensorId);
    try shapeIds.append(rightWallSensorId);

    var animations = std.StringHashMap(animation.Animation).init(shared.allocator);

    const idleAnim = try animation.load(
        "animations/red/idle",
        2,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
    );
    try animations.put("idle", idleAnim);

    const runAnim = try animation.load(
        "animations/red/run",
        12,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
    );
    try animations.put("run", runAnim);

    const fallAnim = try animation.load(
        "animations/red/fall",
        4,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
    );
    try animations.put("fall", fallAnim);

    const afterJumpAnim = try animation.load(
        "animations/red/after_jump",
        8,
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0, .y = -30 },
    );
    try animations.put("afterjump", afterJumpAnim);

    const missileAnimation = try animation.load(
        "weapons/rocket_launcher/projectile",
        8,
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 0 },
    );

    const missileExplosionAnimation = try animation.load(
        "weapons/rocket_launcher/explosion",
        10,
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0, .y = 0 },
    );

    const rocketLauncher: weapon.Weapon = .{
        .name = "rocket_launcher",
        .scale = .{ .x = 0.5, .y = 0.5 },
        .delay = config.shootDelayMs,
        .sound = .{
            .file = "sounds/cannon_fire.mp3",
            .durationMs = config.cannonFireSoundDurationMs,
        },
        .impulse = 1,
        .projectile = .{
            .gravityScale = 0,
            .propulsion = 1,
            .animation = missileAnimation,
            .explosion = .{
                .sound = .{
                    .file = "sounds/cannon_hit.mp3",
                    .durationMs = config.cannonHitSoundDurationMs,
                },
                .animation = missileExplosionAnimation,
                .blastPower = 50,
                .blastRadius = 2.0,
                .particleCount = 100,
                .particleDensity = 0.6,
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

    const playerEntity = entity.Entity{
        .type = "dynamic",
        .friction = config.player.movementFriction,
        .bodyId = bodyId,
        .sprite = s,
        .shapeIds = try shapeIds.toOwnedSlice(),
        .state = null,
        .highlighted = false,
        .animated = false,
        .flipEntityHorizontally = false,
        .categoryBits = config.CATEGORY_PLAYER,
        .maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_DYNAMIC | config.CATEGORY_PROJECTILE | config.CATEGORY_BLOOD,
        .color = null,
        .enabled = true,
    };

    const crosshair = try sprite.createFromImg(shared.crosshairImgSrc, .{
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
        .airJumpCounter = 0,
        .movingRight = false,
        .crosshair = crosshair,
        .cameraId = cameraId,
        .health = 100,
        .isDead = false,
        .respawnTimerId = -1,
    });

    // Register player entity with entity system (needed for animation sprite updates)
    try entity.entities.putLocking(bodyId, playerEntity);

    // Register player with central animation system
    try animation.registerAnimationSet(bodyId, animations, "idle", true, false);
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
    const delayKey = if (player.id == 0) "p0_jump" else "p1_jump";

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

pub fn aim(player: *Player, direction: vec.Vec2) void {
    var dir = direction;
    if (vec.equals(dir, vec.zero)) {
        dir = vec.add(dir, if (player.movingRight) vec.east else vec.west);
    }
    player.aimDirection = dir;

    // Update entity flip based on aim direction
    const maybeEntity = entity.entities.getPtrLocking(player.bodyId);
    if (maybeEntity) |ent| {
        ent.flipEntityHorizontally = dir.x > 0;
    }
}

pub fn shoot(player: *Player) !void {
    if (player.weapons.len == 0) return;

    const selectedWeapon = player.weapons[player.selectedWeaponIndex];
    const crosshairPos = calcCrosshairPosition(player.*);
    const position = camera.relativePositionForCreating(crosshairPos);

    try weapon.shoot(selectedWeapon, position, player.aimDirection);

    const recoilImpulse = vec.mul(vec.normalize(.{
        .x = player.aimDirection.x,
        .y = -player.aimDirection.y,
    }), selectedWeapon.impulse * -0.1);

    box2d.c.b2Body_ApplyLinearImpulseToCenter(player.bodyId, vec.toBox2d(recoilImpulse), true);
}

pub fn setColor(playerId: usize, color: sprite.Color) void {
    const maybePlayer = players.getPtr(playerId);
    if (maybePlayer) |player| {
        const maybeE = entity.getEntity(player.bodyId);
        if (maybeE) |e| {
            e.color = color;
        }
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

pub fn damage(p: *Player, d: f32) !void {
    p.health -= d;

    const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));

    // Generate blood if player took damage
    if (d > 0) {
        try particle.createBloodParticles(playerPosM, d);
    }

    if (p.health <= 0 and !p.isDead) {
        try kill(p);
    }

    if (p.health <= -5) {
        try gib(p);
    }
}

pub fn kill(p: *Player) !void {
    if (p.health <= 0 and !p.isDead) {
        box2d.c.b2Body_Disable(p.bodyId);

        const maybeEntity = entity.entities.getPtrLocking(p.bodyId);
        if (maybeEntity) |ent| {
            ent.enabled = false;
        }

        p.isDead = true;

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

        // Remove player entity from entity system
        const maybeEntity = entity.entities.fetchSwapRemoveLocking(p.bodyId);

        camera.destroyCamera(p.cameraId);

        // Cleanup player resources
        shared.allocator.free(p.weapons);
        box2d.c.b2DestroyBody(p.bodyId);
        if (maybeEntity) |ent| {
            shared.allocator.free(ent.value.shapeIds);
        }
        sprite.cleanup(p.crosshair);
    }

    players.clearAndFree(shared.allocator);

    playersToRespawn.mutex.lock();
    defer playersToRespawn.mutex.unlock();
    playersToRespawn.list.clearAndFree();
}
