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

const weapon = @import("weapon.zig");

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
const data = @import("data.zig");

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
    leftHandSpriteUuid: u64,
    leftHandNoHookSpriteUuid: u64,
    sprayPaintSpriteUuid: ?u64,
};

pub var players: std.AutoArrayHashMapUnmanaged(usize, Player) = .{};
const PlayerError = error{PlayerUnspawned};

var runAnimationFrameCount: usize = 10;
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

    const idleAnim = try data.createAnimationFrom("player_idle");
    try animations.put("idle", idleAnim);

    const runAnim = try data.createAnimationFrom("player_run");
    runAnimationFrameCount = runAnim.frames.len;
    try animations.put("run", runAnim);

    const fallAnim = try data.createAnimationFrom("player_fall");
    try animations.put("fall", fallAnim);

    const afterJumpAnim = try data.createAnimationFrom("player_afterjump");
    try animations.put("afterjump", afterJumpAnim);

    const rocketLauncher = try data.createWeaponFrom("rocket_launcher");
    const shotgun = try data.createWeaponFrom("shotgun");
    const railgun = try data.createWeaponFrom("railgun");

    var weapons = std.array_list.Managed(weapon.Weapon).init(shared.allocator);
    try weapons.append(rocketLauncher);
    try weapons.append(shotgun);
    try weapons.append(railgun);

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

    const leftHandSpriteUuid = data.createSpriteFrom("arm_with_hook") orelse return error.SpriteNotFound;
    const leftHandNoHookSpriteUuid = data.createSpriteFrom("arm_without_hook") orelse return error.SpriteNotFound;

    // Load spray paint sprite from data
    var sprayPaintSpriteUuid: ?u64 = null;
    {
        var keyBuf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&keyBuf, "player_{d}_spray", .{playerId + 1})) |key| {
            sprayPaintSpriteUuid = data.createSpriteFrom(key);
        } else |_| {}
    }

    const crosshairUuid = data.createSpriteFrom("crosshair") orelse return error.SpriteNotFound;

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
        .leftHandSpriteUuid = leftHandSpriteUuid,
        .leftHandNoHookSpriteUuid = leftHandNoHookSpriteUuid,
        .sprayPaintSpriteUuid = sprayPaintSpriteUuid,
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

pub fn cycleWeapon(p: *Player, direction: i32) void {
    if (p.weapons.len == 0) return;
    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_wpn", .{p.id}) catch unreachable;
    if (delay.check(delayKey)) return;
    const len: i32 = @intCast(p.weapons.len);
    const current: i32 = @intCast(p.selectedWeaponIndex);
    p.selectedWeaponIndex = @intCast(@mod(current + direction, len));
    delay.action(delayKey, 300);
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

pub fn sprayPaint(p: *Player) !void {
    const sprayPaintSpriteUuid = p.sprayPaintSpriteUuid orelse return;

    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_spray", .{p.id}) catch unreachable;
    if (delay.check(delayKey)) return;

    const resources = try shared.getResources();

    // Get crosshair world position in meters
    const maybeEntity = entity.getEntity(p.bodyId);
    if (maybeEntity == null) return;
    const ent = maybeEntity.?;
    const currentState = box2d.getState(p.bodyId);
    const state = box2d.getInterpolatedState(ent.state, currentState);
    const playerPixelPos = conv.m2Pixel(state.pos);

    const crosshairOffset = getCrosshairOffset(p.*);
    var crosshairPixelPos = vec.iadd(playerPixelPos, crosshairOffset);
    crosshairPixelPos = vec.iadd(crosshairPixelPos, config.aimCircleOffset);
    if (ent.spriteUuids.len > 0) {
        if (sprite.getSprite(ent.spriteUuids[0])) |firstSprite| {
            crosshairPixelPos = vec.iadd(crosshairPixelPos, firstSprite.offset);
        }
    }

    const crosshairWorldPos = conv.pixel2M(crosshairPixelPos);

    // Overlap query to find terrain entities
    const OverlapContext = struct {
        bodies: [100]box2d.c.b2BodyId,
        count: usize,
    };

    var context = OverlapContext{
        .bodies = undefined,
        .count = 0,
    };

    const circle = box2d.c.b2Circle{
        .center = box2d.c.b2Vec2_zero,
        .radius = config.sprayPaintWorldSize / 2.0,
    };

    const transform = box2d.c.b2Transform{
        .p = .{ .x = crosshairWorldPos.x, .y = crosshairWorldPos.y },
        .q = box2d.c.b2Rot_identity,
    };

    var filter = box2d.c.b2DefaultQueryFilter();
    const sprayMask = collision.CATEGORY_TERRAIN | collision.CATEGORY_DYNAMIC | collision.CATEGORY_UNBREAKABLE | collision.CATEGORY_GIBLET;
    filter.categoryBits = sprayMask;
    filter.maskBits = sprayMask;

    const overlapCallback = struct {
        fn cb(shapeId: box2d.c.b2ShapeId, ctx: ?*anyopaque) callconv(.c) bool {
            const c: *OverlapContext = @ptrCast(@alignCast(ctx.?));
            const bodyId = box2d.c.b2Shape_GetBody(shapeId);

            for (c.bodies[0..c.count]) |existingBody| {
                if (box2d.c.b2Body_IsValid(existingBody) and
                    box2d.c.B2_ID_EQUALS(existingBody, bodyId))
                {
                    return true;
                }
            }

            if (c.count < 100) {
                c.bodies[c.count] = bodyId;
                c.count += 1;
            }
            return true;
        }
    }.cb;

    _ = box2d.c.b2World_OverlapCircle(
        resources.worldId,
        &circle,
        transform,
        filter,
        overlapCallback,
        &context,
    );

    // Get source sprite dimensions to compute natural world size
    const spraySprite = sprite.getSprite(sprayPaintSpriteUuid) orelse return;

    for (context.bodies[0..context.count]) |bodyId| {
        if (!box2d.c.b2Body_IsValid(bodyId)) continue;

        const maybeEnt = entity.entities.getPtrLocking(bodyId);
        if (maybeEnt) |e| {
            if (e.spriteUuids.len == 0) continue;

            // Natural world size: source pixels at fixed met2pix ratio, then apply player scale
            var sizeWorldX = @as(f32, @floatFromInt(spraySprite.surface.w)) / config.met2pix * spraySprite.scale.x;
            var sizeWorldY = @as(f32, @floatFromInt(spraySprite.surface.h)) / config.met2pix * spraySprite.scale.y;

            // Scale down proportionally if either dimension exceeds the max
            const maxDim = @max(sizeWorldX, sizeWorldY);
            if (maxDim > config.sprayPaintWorldSize) {
                const scaleFactor = config.sprayPaintWorldSize / maxDim;
                sizeWorldX *= scaleFactor;
                sizeWorldY *= scaleFactor;
            }

            const entState = box2d.getState(bodyId);
            const entityPos = vec.fromBox2d(entState.pos);
            const rotation = entState.rotAngle;

            try sprite.paintSpriteOnSurface(
                e.spriteUuids[0],
                sprayPaintSpriteUuid,
                crosshairWorldPos,
                sizeWorldX,
                sizeWorldY,
                entityPos,
                rotation,
            );
            try sprite.updateTextureFromSurface(e.spriteUuids[0]);
        }
    }

    delay.action(delayKey, config.sprayPaintDelayMs);
}

pub fn setColor(playerId: usize, color: sprite.Color) void {
    const maybePlayer = players.getPtr(playerId);
    if (maybePlayer) |player| {
        animation.colorAllFrames(player.bodyId, color) catch |err| {
            std.debug.print("Warning: Failed to color animation frames for player {}: {}\n", .{ playerId, err });
        };

        for (player.weapons) |w| {
            if (w.spriteUuid != 0) {
                sprite.colorMatchingPixels(w.spriteUuid, color, sprite.isWhite) catch |err| {
                    std.debug.print("Warning: Failed to color weapon sprite for player {}: {}\n", .{ playerId, err });
                };
            }
        }

        sprite.colorMatchingPixels(player.leftHandSpriteUuid, color, sprite.isWhite) catch |err| {
            std.debug.print("Warning: Failed to color left hand sprite for player {}: {}\n", .{ playerId, err });
        };

        sprite.colorMatchingPixels(player.leftHandNoHookSpriteUuid, color, sprite.isWhite) catch |err| {
            std.debug.print("Warning: Failed to color left hand no-hook sprite for player {}: {}\n", .{ playerId, err });
        };

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

const LeftArmPlacement = struct {
    shoulderPos: vec.IVec2,
    handCenterPos: vec.IVec2,
    effectiveHAnchorX: i32,
    hAnchor: vec.IVec2,
    playerFlip: bool,
    handFlip: bool,
};

fn calcLeftArmPlacement(p: Player, handSprite: sprite.Sprite) ?LeftArmPlacement {
    const maybeEntity = entity.getEntity(p.bodyId);
    if (maybeEntity == null) return null;
    const ent = maybeEntity.?;
    const currentState = box2d.getState(p.bodyId);
    const state = box2d.getInterpolatedState(ent.state, currentState);
    const playerPos = camera.relativePosition(conv.m2Pixel(state.pos));

    const ps = if (ent.spriteUuids.len > 0) sprite.getSprite(ent.spriteUuids[0]) orelse return null else return null;

    const playerFlip = ent.flipEntityHorizontally;
    const handFlip = !playerFlip;

    const pAnchor = (if (playerFlip) ps.anchorPointRight orelse ps.anchorPointLeft else ps.anchorPointLeft) orelse return null;
    const hAnchor = handSprite.anchorPointLeft orelse return null;

    const shoulderPos = calcShoulderPos(ps, playerPos, pAnchor, playerFlip);
    const effectiveHAnchorX: i32 = if (handFlip) handSprite.sizeP.x - hAnchor.x else hAnchor.x;

    const handCenterPos = vec.IVec2{
        .x = shoulderPos.x - effectiveHAnchorX + @divTrunc(handSprite.sizeP.x, 2),
        .y = shoulderPos.y - hAnchor.y + @divTrunc(handSprite.sizeP.y, 2),
    };

    return .{
        .shoulderPos = shoulderPos,
        .handCenterPos = handCenterPos,
        .effectiveHAnchorX = effectiveHAnchorX,
        .hAnchor = hAnchor,
        .playerFlip = playerFlip,
        .handFlip = handFlip,
    };
}

fn calcArmAngleTowardHook(placement: LeftArmPlacement, hookScreenPos: vec.IVec2) f32 {
    const dx = @as(f32, @floatFromInt(hookScreenPos.x - placement.shoulderPos.x));
    const dy = @as(f32, @floatFromInt(hookScreenPos.y - placement.shoulderPos.y));
    const angle = std.math.atan2(dy, dx);
    const flipSign: f32 = if (placement.playerFlip) -1 else 1;
    const rotationOffset: f32 = flipSign * std.math.pi / 2.0;
    return if (placement.handFlip) std.math.pi + angle + rotationOffset else angle + rotationOffset;
}

fn drawLeftArm(handSprite: sprite.Sprite, placement: LeftArmPlacement, angle: f32) !void {
    const pivotPoint: sdl.Point = .{ .x = placement.effectiveHAnchorX, .y = placement.hAnchor.y };
    try sprite.drawWithOptions(handSprite, placement.handCenterPos, angle, false, placement.handFlip, 0, null, pivotPoint);
}

pub fn drawLeftHand(p: *Player) !void {
    const hasRope = if (rope.ropes.get(p.id)) |r| r.state != .inactive else false;
    if (hasRope) {
        try drawLeftArmWithHookDeployed(p);
    } else {
        try drawLeftArmWithHook(p);
    }
}

fn drawLeftArmWithHook(p: *Player) !void {
    const handSprite = sprite.getSprite(p.leftHandSpriteUuid) orelse return;
    const placement = calcLeftArmPlacement(p.*, handSprite) orelse return;

    // Swing arm back and forth when running
    const armSwingSpeed = 2.0 * std.math.pi * @as(f64, @floatFromInt(config.runAnimationFps)) / @as(f64, @floatFromInt(runAnimationFrameCount));
    const swingAngle: f32 = if (p.isMoving and p.touchesGround)
        @as(f32, @floatCast(std.math.sin(time.now() * armSwingSpeed))) * 0.6
    else
        0;
    const finalAngle: f32 = if (placement.handFlip) -swingAngle else swingAngle;

    try drawLeftArm(handSprite, placement, finalAngle);
}

fn drawLeftArmWithHookDeployed(p: *Player) !void {
    const handSprite = sprite.getSprite(p.leftHandNoHookSpriteUuid) orelse return;
    const r = rope.ropes.get(p.id) orelse return;
    const placement = calcLeftArmPlacement(p.*, handSprite) orelse return;

    const hookPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(r.hookBodyId));
    const hookPosPx = camera.relativePosition(conv.m2Pixel(.{ .x = hookPosM.x, .y = hookPosM.y }));
    const finalAngle = calcArmAngleTowardHook(placement, hookPosPx);

    try drawLeftArm(handSprite, placement, finalAngle);
}

pub fn getLeftArmRopeAttachPoint(p: Player, hookScreenPos: vec.IVec2) ?vec.IVec2 {
    const handSprite = sprite.getSprite(p.leftHandNoHookSpriteUuid) orelse return null;
    const placement = calcLeftArmPlacement(p, handSprite) orelse return null;

    const greenAnchor = handSprite.anchorPointRight orelse return placement.shoulderPos;

    const finalAngle = calcArmAngleTowardHook(placement, hookScreenPos);

    // Green pixel position relative to pivot, rotated by arm angle
    const effectiveGreenX: i32 = if (placement.handFlip) handSprite.sizeP.x - greenAnchor.x else greenAnchor.x;
    const relX = @as(f32, @floatFromInt(effectiveGreenX - placement.effectiveHAnchorX));
    const relY = @as(f32, @floatFromInt(greenAnchor.y - placement.hAnchor.y));

    const cosA = @cos(finalAngle);
    const sinA = @sin(finalAngle);

    return vec.IVec2{
        .x = placement.shoulderPos.x + @as(i32, @intFromFloat(relX * cosA - relY * sinA)),
        .y = placement.shoulderPos.y + @as(i32, @intFromFloat(relX * sinA + relY * cosA)),
    };
}

fn calcShoulderPos(ps: sprite.Sprite, playerPos: vec.IVec2, pAnchor: vec.IVec2, playerFlip: bool) vec.IVec2 {
    const playerHalfW = @divTrunc(ps.sizeP.x, 2);
    const playerHalfH = @divTrunc(ps.sizeP.y, 2);
    const playerOffsetX: i32 = if (playerFlip) ps.offset.x else -ps.offset.x;
    const playerUpperLeft = vec.IVec2{
        .x = playerPos.x - playerHalfW + playerOffsetX,
        .y = playerPos.y - playerHalfH + ps.offset.y,
    };

    return if (playerFlip)
        vec.iadd(playerUpperLeft, .{ .x = ps.sizeP.x - pAnchor.x, .y = pAnchor.y })
    else
        vec.iadd(playerUpperLeft, pAnchor);
}

pub fn drawAllLeftHandsBehind() !void {
    for (players.values()) |*p| {
        if (p.isDead) continue;
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            if (ent.flipEntityHorizontally) try drawLeftHand(p);
        }
    }
}

pub fn drawAllLeftHandsFront() !void {
    for (players.values()) |*p| {
        if (p.isDead) continue;
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            if (!ent.flipEntityHorizontally) try drawLeftHand(p);
        }
    }
}

pub fn damage(p: *Player, d: f32, attackerId: ?usize) !void {
    if (p.isDead) return;

    p.health -= d;

    const playerPosM = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));

    // Generate blood if player took damage
    if (d > 0) {
        try particle.createBloodParticles(playerPosM, d);
    }

    if (p.health <= 0) {
        if (p.health <= -5) {
            try gib(p);
        }
        try kill(p, attackerId);
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
            if (w.projectile) |proj| {
                animation.cleanupOne(proj.animation);
                if (proj.explosion.animation) |expAnim| {
                    animation.cleanupOne(expAnim);
                }
                if (proj.propulsionAnimation) |propAnim| {
                    animation.cleanupOne(propAnim);
                }
            }
            if (w.pellet) |pel| {
                if (pel.explosion.animation) |peAnim| {
                    animation.cleanupOne(peAnim);
                }
            }
            if (w.hitscanExplosion) |he| {
                if (he.animation) |heAnim| {
                    animation.cleanupOne(heAnim);
                }
            }
            if (w.spriteUuid != 0) {
                sprite.cleanupLater(w.spriteUuid);
            }
        }

        // Cleanup player resources
        shared.allocator.free(p.weapons);
        sprite.cleanupLater(p.crosshairUuid);
        if (p.sprayPaintSpriteUuid) |sprayUuid| {
            sprite.cleanupLater(sprayUuid);
        }
    }

    players.clearAndFree(shared.allocator);

    score.cleanup();

    playersToRespawn.mutex.lock();
    defer playersToRespawn.mutex.unlock();
    playersToRespawn.list.clearAndFree();
}
