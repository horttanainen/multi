const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const collision = @import("collision.zig");
const data = @import("data.zig");
const delay = @import("delay.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");
const player_input = @import("player_input.zig");

pub const GroundContact = struct {
    normal: vec.Vec2,
    shapeId: box2d.c.b2ShapeId,
    bodyId: box2d.c.b2BodyId,
    worldPoint: vec.Vec2,
    localPoint: vec.Vec2,
};

const GroundSweepContext = struct {
    playerBodyId: box2d.c.b2BodyId,
    groundContact: ?GroundContact = null,
    fraction: f32 = 1,
};

pub const GroundState = struct {
    footOverlapCount: usize = 0,
    supported: bool = false,
    jumpAvailable: bool = false,
    supportLostAtMs: ?u64 = null,
    groundContact: ?GroundContact = null,
};

pub const State = struct {
    bodyId: box2d.c.b2BodyId,
    footSensorShapeId: box2d.c.b2ShapeId,
    leftWallSensorId: box2d.c.b2ShapeId,
    rightWallSensorId: box2d.c.b2ShapeId,
    groundState: GroundState = .{},
    leftWallContactCount: usize = 0,
    rightWallContactCount: usize = 0,
    wallSliding: bool = false,
    wallJumpDirection: i8 = 0,
    wallJumpMovementStepsRemaining: u32 = 0,
    lateralMovementIntent: i8 = 0,
    airJumpCounter: u32 = 0,
    bufferedJumpUntilMs: ?u64 = null,
    heldJumpGravityActive: bool = false,
    facingRight: bool = false,
};

pub var states: std.AutoArrayHashMapUnmanaged(usize, State) = .empty;

pub var mechanism: data.MovementMechanism = undefined;
pub var aimGuideLengthMeters: f32 = undefined;
pub var control: data.MovementControlData = undefined;
pub var bodyMotion: data.MovementBodyMotionData = undefined;
pub var surfaceResponse: data.MovementSurfaceResponseData = undefined;
pub var jumpSettings: data.MovementJumpData = undefined;
pub var towerfallSettings: data.TowerfallMovementData = undefined;
pub var grounding: data.MovementGroundingData = undefined;

var minimumSupportUpAmount: f32 = undefined;
var contactDataScratch: std.ArrayListUnmanaged(box2d.c.b2ContactData) = .empty;

pub fn configure(movementData: data.MovementData) !void {
    mechanism = movementData.mechanism;
    aimGuideLengthMeters = movementData.aimGuideLengthMeters;
    grounding = movementData.grounding;

    switch (mechanism) {
        .liero => {
            const settings = movementData.liero orelse {
                std.log.err("movement.configure: liero settings are missing", .{});
                return error.MissingLieroMovementSettings;
            };
            control = settings.control;
            bodyMotion = settings.bodyMotion;
            surfaceResponse = settings.surfaceResponse;
            jumpSettings = settings.jump;
        },
        .towerfall => {
            const settings = movementData.towerfall orelse {
                std.log.err("movement.configure: TowerFall settings are missing", .{});
                return error.MissingTowerfallMovementSettings;
            };
            towerfallSettings = settings;
            bodyMotion = settings.bodyMotion;
            surfaceResponse = settings.surfaceResponse;
        },
    }

    minimumSupportUpAmount = @cos(grounding.maxSlopeAngleDegrees * std.math.pi / 180.0);
}

fn clearRuntimeState(state: *State) void {
    state.groundState = .{};
    state.leftWallContactCount = 0;
    state.rightWallContactCount = 0;
    state.wallSliding = false;
    state.wallJumpDirection = 0;
    state.wallJumpMovementStepsRemaining = 0;
    state.lateralMovementIntent = 0;
    state.airJumpCounter = 0;
    state.bufferedJumpUntilMs = null;
    state.heldJumpGravityActive = false;
}

pub fn reset(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.reset: movement state is missing for player {d}", .{playerId});
        return;
    };
    clearRuntimeState(state);
}

fn canUseGroundJump(state: *const State, currentTimeMs: u64, coyoteTimeMs: u32) bool {
    if (!state.groundState.jumpAvailable) return false;
    if (state.groundState.supported) return true;
    if (coyoteTimeMs == 0) return false;

    const supportLostAtMs = state.groundState.supportLostAtMs orelse return false;
    return currentTimeMs <= supportLostAtMs + @as(u64, coyoteTimeMs);
}

fn executeJump(playerId: usize, state: *State, currentTimeMs: u64, groundOnly: bool) bool {
    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_jump", .{playerId}) catch unreachable;

    if (delay.check(delayKey)) return false;

    const useGroundJump = canUseGroundJump(state, currentTimeMs, jumpSettings.coyoteTimeMs);
    if (groundOnly and !useGroundJump) return false;
    if (!useGroundJump and state.airJumpCounter >= jumpSettings.maxAirJumps) return false;

    if (useGroundJump) {
        state.groundState.jumpAvailable = false;
        state.groundState.supportLostAtMs = null;
    } else {
        state.airJumpCounter += 1;
    }

    var jumpImpulse = box2d.c.b2Vec2{ .x = 0, .y = -jumpSettings.impulse };
    if (state.rightWallContactCount > 0 or state.leftWallContactCount > 0) {
        jumpImpulse = if (state.leftWallContactCount > 0) box2d.c.b2Vec2{
            .x = jumpSettings.impulse / 2,
            .y = -jumpSettings.impulse,
        } else box2d.c.b2Vec2{
            .x = -jumpSettings.impulse / 2,
            .y = -jumpSettings.impulse,
        };
    }

    box2d.c.b2Body_ApplyLinearImpulseToCenter(state.bodyId, jumpImpulse, true);
    delay.action(delayKey, jumpSettings.cooldownMs);
    state.bufferedJumpUntilMs = null;
    return true;
}

pub fn jump(playerId: usize) void {
    if (mechanism != .liero) return;

    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.jump: movement state is missing for player {d}", .{playerId});
        return;
    };
    const currentTimeMs = time.nowMs();
    if (executeJump(playerId, state, currentTimeMs, false)) return;
    if (jumpSettings.bufferTimeMs == 0) return;

    state.bufferedJumpUntilMs = currentTimeMs + jumpSettings.bufferTimeMs;
}

fn processLieroBufferedJump(playerId: usize, state: *State, currentTimeMs: u64) void {
    const bufferedJumpUntilMs = state.bufferedJumpUntilMs orelse return;
    if (currentTimeMs > bufferedJumpUntilMs) {
        state.bufferedJumpUntilMs = null;
        return;
    }
    if (!canUseGroundJump(state, currentTimeMs, jumpSettings.coyoteTimeMs)) return;

    _ = executeJump(playerId, state, currentTimeMs, true);
}

pub fn brake(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.brake: movement state is missing for player {d}", .{playerId});
        return;
    };
    state.lateralMovementIntent = 0;
}

pub fn moveLeft(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.moveLeft: movement state is missing for player {d}", .{playerId});
        return;
    };
    state.lateralMovementIntent = -1;
    state.facingRight = false;
}

pub fn moveRight(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.moveRight: movement state is missing for player {d}", .{playerId});
        return;
    };
    state.lateralMovementIntent = 1;
    state.facingRight = true;
}

fn applyLieroMovement(state: *State, dt: f32) void {
    if (state.lateralMovementIntent == 0) return;

    const direction: f32 = @floatFromInt(state.lateralMovementIntent);
    const velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    const currentSpeed = velocity.x * direction;
    if (currentSpeed >= control.maxLateralSpeed) return;

    const remainingSpeed = control.maxLateralSpeed - currentSpeed;
    const bodyMass = box2d.c.b2Body_GetMass(state.bodyId);
    const forceMagnitude = @min(control.lateralForce, remainingSpeed * bodyMass / dt);
    const force = box2d.c.b2Vec2{ .x = direction * forceMagnitude, .y = 0 };
    box2d.c.b2Body_ApplyForceToCenter(state.bodyId, force, true);
}

fn finishTowerfallJump(state: *State) void {
    state.groundState.jumpAvailable = false;
    state.groundState.supportLostAtMs = null;
    state.bufferedJumpUntilMs = null;
    state.heldJumpGravityActive = true;
    state.wallSliding = false;
}

fn executeTowerfallGroundJump(state: *State) void {
    var velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    velocity.y = -towerfallSettings.jump.speed;
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, velocity);

    state.wallJumpDirection = 0;
    state.wallJumpMovementStepsRemaining = 0;
    finishTowerfallJump(state);
}

fn availableWallJumpDirection(state: *const State) i8 {
    if (state.groundState.supported) return 0;

    const touchesLeftWall = state.leftWallContactCount > 0;
    const touchesRightWall = state.rightWallContactCount > 0;
    if (touchesLeftWall and !touchesRightWall) return 1;
    if (touchesRightWall and !touchesLeftWall) return -1;
    if (!touchesLeftWall and !touchesRightWall) return 0;

    if (state.lateralMovementIntent < 0) return 1;
    if (state.lateralMovementIntent > 0) return -1;
    return if (state.facingRight) -1 else 1;
}

fn executeTowerfallWallJump(state: *State, direction: i8) void {
    const wallJump = towerfallSettings.wallJump;
    var velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    velocity.x = @as(f32, @floatFromInt(direction)) * wallJump.horizontalSpeed;
    velocity.y = -towerfallSettings.jump.speed;
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, velocity);

    state.wallJumpDirection = direction;
    state.wallJumpMovementStepsRemaining = wallJump.forcedMovementSteps;
    // The launch step is the first forced-movement step.
    if (state.wallJumpMovementStepsRemaining > 0) state.wallJumpMovementStepsRemaining -= 1;
    if (state.wallJumpMovementStepsRemaining == 0) state.wallJumpDirection = 0;
    state.facingRight = direction > 0;
    finishTowerfallJump(state);
}

fn executeTowerfallJump(state: *State, currentTimeMs: u64) bool {
    if (state.groundState.supported and state.groundState.jumpAvailable) {
        executeTowerfallGroundJump(state);
        return true;
    }

    const wallDirection = availableWallJumpDirection(state);
    if (wallDirection != 0) {
        executeTowerfallWallJump(state, wallDirection);
        return true;
    }

    if (!canUseGroundJump(state, currentTimeMs, towerfallSettings.jump.coyoteTimeMs)) return false;
    executeTowerfallGroundJump(state);
    return true;
}

fn requestTowerfallJump(state: *State, currentTimeMs: u64) void {
    if (executeTowerfallJump(state, currentTimeMs)) return;

    const bufferTimeMs = towerfallSettings.jump.bufferTimeMs;
    if (bufferTimeMs == 0) return;
    state.bufferedJumpUntilMs = currentTimeMs + bufferTimeMs;
}

fn processTowerfallBufferedJump(state: *State, currentTimeMs: u64) void {
    const bufferedJumpUntilMs = state.bufferedJumpUntilMs orelse return;
    if (currentTimeMs > bufferedJumpUntilMs) {
        state.bufferedJumpUntilMs = null;
        return;
    }
    _ = executeTowerfallJump(state, currentTimeMs);
}

fn moveTowards(current: f32, target: f32, maxChange: f32) f32 {
    if (current < target) return @min(current + maxChange, target);
    if (current > target) return @max(current - maxChange, target);
    return target;
}

fn isHoldingTowardsWall(inputState: player_input.PlayerInput, state: *const State) bool {
    const horizontalDirection = inputState.movementDirection.x;
    if (horizontalDirection < 0 and state.leftWallContactCount > 0) return true;
    return horizontalDirection > 0 and state.rightWallContactCount > 0;
}

fn towerfallMovementDirection(inputState: player_input.PlayerInput, state: *State) f32 {
    const inputDirection = std.math.clamp(inputState.movementDirection.x, -1, 1);
    if (state.groundState.supported) {
        state.wallJumpDirection = 0;
        state.wallJumpMovementStepsRemaining = 0;
        return inputDirection;
    }
    if (state.wallJumpMovementStepsRemaining == 0) return inputDirection;

    const forcedDirection: f32 = @floatFromInt(state.wallJumpDirection);
    state.wallJumpMovementStepsRemaining -= 1;
    if (state.wallJumpMovementStepsRemaining == 0) state.wallJumpDirection = 0;
    return forcedDirection;
}

fn applyTowerfallFalling(inputState: player_input.PlayerInput, state: *State, velocity: *box2d.c.b2Vec2, dt: f32) void {
    if (state.groundState.supported and velocity.y >= 0) {
        velocity.y = 0;
        state.heldJumpGravityActive = false;
        state.wallSliding = false;
        return;
    }

    state.wallSliding = velocity.y >= 0 and isHoldingTowardsWall(inputState, state);
    if (state.wallSliding) {
        const wallSlide = towerfallSettings.wallSlide;
        velocity.y = @min(velocity.y + wallSlide.acceleration * dt, wallSlide.maxFallSpeed);
        return;
    }

    const controlSettings = towerfallSettings.control;
    const fastFalling = inputState.movementDirection.y < 0 and velocity.y >= 0;
    const holdingJump = inputState.buttons.get(.jump).held;
    if (!holdingJump) state.heldJumpGravityActive = false;

    const acceleration = if (fastFalling)
        controlSettings.fastFallAcceleration
    else if (state.heldJumpGravityActive)
        towerfallSettings.jump.heldGravity
    else
        controlSettings.gravity;
    const terminalSpeed = if (fastFalling) controlSettings.fastFallSpeed else controlSettings.maxFallSpeed;

    if (velocity.y > terminalSpeed) {
        velocity.y = moveTowards(velocity.y, terminalSpeed, controlSettings.excessFallSpeedDeceleration * dt);
        return;
    }
    velocity.y = @min(velocity.y + acceleration * dt, terminalSpeed);
}

fn applyTowerfallMovement(playerId: usize, state: *State, dt: f32) void {
    const inputState = player_input.playerInputs.get(playerId) orelse {
        std.log.warn("movement.applyTowerfallMovement: input state is missing for player {d}", .{playerId});
        return;
    };
    const controlSettings = towerfallSettings.control;
    const movementDirection = towerfallMovementDirection(inputState, state);
    const targetSpeed = movementDirection * controlSettings.maxRunSpeed;
    var velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    const reversing = movementDirection != 0 and velocity.x * movementDirection < 0;
    const acceleration = if (movementDirection == 0)
        if (state.groundState.supported) controlSettings.groundDeceleration else controlSettings.airDeceleration
    else if (!state.groundState.supported)
        controlSettings.airAcceleration
    else if (reversing)
        controlSettings.groundReversalAcceleration
    else
        controlSettings.groundAcceleration;

    velocity.x = moveTowards(velocity.x, targetSpeed, acceleration * dt);
    applyTowerfallFalling(inputState, state, &velocity, dt);
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, velocity);

    const currentTimeMs = time.nowMs();
    if (inputState.buttons.get(.jump).pressed) requestTowerfallJump(state, currentTimeMs);
    processTowerfallBufferedJump(state, currentTimeMs);
}

fn applyMovement(playerId: usize, state: *State, dt: f32) void {
    if (!box2d.c.b2Body_IsEnabled(state.bodyId)) return;

    switch (mechanism) {
        .liero => applyLieroMovement(state, dt),
        .towerfall => applyTowerfallMovement(playerId, state, dt),
    }
}

fn clampLinearSpeed(state: *State) void {
    const maxLinearSpeed = bodyMotion.maxLinearSpeed orelse return;
    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(state.bodyId));
    const speed = vec.magnitude(velocity);
    if (speed <= maxLinearSpeed) return;

    const clampedVelocity = vec.mul(velocity, maxLinearSpeed / speed);
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, vec.toBox2d(clampedVelocity));
}

pub fn surfaceFriction(playerId: usize) ?f32 {
    const state = states.get(playerId) orelse {
        std.log.warn("movement.surfaceFriction: movement state is missing for player {d}", .{playerId});
        return null;
    };
    return if (state.lateralMovementIntent != 0) surfaceResponse.movingFriction else surfaceResponse.restingFriction;
}

fn groundContactForContact(state: *const State, contact: box2d.c.b2ContactData) ?GroundContact {
    if (contact.manifold.pointCount == 0) return null;

    const bodyA = box2d.c.b2Shape_GetBody(contact.shapeIdA);
    const playerIsShapeA = box2d.c.B2_ID_EQUALS(bodyA, state.bodyId);
    const bodyB = box2d.c.b2Shape_GetBody(contact.shapeIdB);
    const playerIsShapeB = box2d.c.B2_ID_EQUALS(bodyB, state.bodyId);
    if (!playerIsShapeA and !playerIsShapeB) {
        std.log.warn("movement.groundContactForContact: contact does not contain the player body", .{});
        return null;
    }

    const contactShapeId = if (playerIsShapeA) contact.shapeIdB else contact.shapeIdA;
    const contactFilter = box2d.c.b2Shape_GetFilter(contactShapeId);
    if (contactFilter.categoryBits & collision.MASK_SENSOR_FOOT == 0) return null;

    const manifoldNormal = vec.fromBox2d(contact.manifold.normal);
    const contactNormal = if (playerIsShapeA) vec.mul(manifoldNormal, -1) else manifoldNormal;

    var strongestPointIndex: usize = 0;
    var strongestPointImpulse = contact.manifold.points[0].totalNormalImpulse;
    for (contact.manifold.points[1..@intCast(contact.manifold.pointCount)], 1..) |point, pointIndex| {
        if (point.totalNormalImpulse <= strongestPointImpulse) continue;
        strongestPointIndex = pointIndex;
        strongestPointImpulse = point.totalNormalImpulse;
    }

    const worldPoint = contact.manifold.points[strongestPointIndex].point;
    const contactBodyId = box2d.c.b2Shape_GetBody(contactShapeId);
    const localPoint = box2d.c.b2Body_GetLocalPoint(contactBodyId, worldPoint);
    return .{
        .normal = contactNormal,
        .shapeId = contactShapeId,
        .bodyId = contactBodyId,
        .worldPoint = vec.fromBox2d(worldPoint),
        .localPoint = vec.fromBox2d(localPoint),
    };
}

fn findGroundContact(state: *const State) !?GroundContact {
    const contactCapacity = box2d.c.b2Body_GetContactCapacity(state.bodyId);
    if (contactCapacity == 0) return null;

    const capacity: usize = @intCast(contactCapacity);
    try contactDataScratch.ensureTotalCapacity(allocator, capacity);
    contactDataScratch.items.len = capacity;

    const contactCount: usize = @intCast(box2d.c.b2Body_GetContactData(
        state.bodyId,
        contactDataScratch.items.ptr,
        contactCapacity,
    ));

    var bestGroundContact: ?GroundContact = null;
    var bestUpAmount: f32 = -1.0;
    for (contactDataScratch.items[0..contactCount]) |contact| {
        const groundContact = groundContactForContact(state, contact) orelse continue;
        const upAmount = vec.dot(groundContact.normal, .{ .x = 0, .y = -1 });
        if (bestGroundContact != null and upAmount <= bestUpAmount) continue;

        bestGroundContact = groundContact;
        bestUpAmount = upAmount;
    }
    return bestGroundContact;
}

fn collectGroundSweep(
    shapeId: box2d.c.b2ShapeId,
    point: box2d.c.b2Vec2,
    normal: box2d.c.b2Vec2,
    fraction: f32,
    context: ?*anyopaque,
) callconv(.c) f32 {
    if (context == null) {
        std.log.err("movement.collectGroundSweep: shape cast context is missing", .{});
        return 0;
    }

    const sweepContext: *GroundSweepContext = @ptrCast(@alignCast(context.?));
    const bodyId = box2d.c.b2Shape_GetBody(shapeId);
    if (box2d.c.B2_ID_EQUALS(bodyId, sweepContext.playerBodyId)) return -1;
    if (normal.x == 0 and normal.y == 0) return -1;
    if (sweepContext.groundContact != null and sweepContext.fraction <= fraction) return sweepContext.fraction;

    sweepContext.groundContact = .{
        .normal = vec.fromBox2d(normal),
        .shapeId = shapeId,
        .bodyId = bodyId,
        .worldPoint = vec.fromBox2d(point),
        .localPoint = vec.fromBox2d(box2d.c.b2Body_GetLocalPoint(bodyId, point)),
    };
    sweepContext.fraction = fraction;
    return fraction;
}

fn sweepGroundContact(state: *const State) ?GroundContact {
    const radius = grounding.probeHalfHeight;
    const segmentHalfLength = @max(0, grounding.probeHalfWidth - radius);
    const points = [_]box2d.c.b2Vec2{
        .{ .x = -segmentHalfLength, .y = 0 },
        .{ .x = segmentHalfLength, .y = 0 },
    };
    const probeCenter = box2d.c.b2Body_GetWorldPoint(state.bodyId, vec.toBox2d(grounding.probeOffset));
    const proxy = box2d.c.b2MakeOffsetProxy(
        &points,
        points.len,
        radius,
        probeCenter,
        box2d.c.b2Body_GetRotation(state.bodyId),
    );

    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_SENSOR;
    filter.maskBits = collision.MASK_SENSOR_FOOT;

    var context = GroundSweepContext{ .playerBodyId = state.bodyId };
    box2d.castShape(
        &proxy,
        .{ .x = 0, .y = grounding.sweepDistance },
        filter,
        collectGroundSweep,
        &context,
    );
    return context.groundContact;
}

fn visitorBelongsToBody(visitorShapeId: box2d.c.b2ShapeId, bodyId: box2d.c.b2BodyId) bool {
    if (!box2d.c.b2Shape_IsValid(visitorShapeId)) return false;

    const visitorBodyId = box2d.c.b2Shape_GetBody(visitorShapeId);
    return box2d.c.B2_ID_EQUALS(visitorBodyId, bodyId);
}

fn processStateSensorEvents(playerId: usize, state: *State, currentTimeMs: u64) !void {
    const sensorEvents = box2d.getSensorEvents();
    const wasSupported = state.groundState.supported;

    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const event = sensorEvents.beginEvents[i];

        if (visitorBelongsToBody(event.visitorShapeId, state.bodyId)) continue;

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.footSensorShapeId)) {
            state.groundState.footOverlapCount += 1;
        }

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.leftWallSensorId)) {
            state.airJumpCounter = 0;
            state.leftWallContactCount += 1;
        }
        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.rightWallSensorId)) {
            state.airJumpCounter = 0;
            state.rightWallContactCount += 1;
        }
    }

    for (0..@intCast(sensorEvents.endCount)) |i| {
        const event = sensorEvents.endEvents[i];

        if (visitorBelongsToBody(event.visitorShapeId, state.bodyId)) continue;

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.footSensorShapeId) and state.groundState.footOverlapCount > 0) {
            state.groundState.footOverlapCount -= 1;
        }

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.leftWallSensorId) and state.leftWallContactCount > 0) {
            state.leftWallContactCount -= 1;
        }
        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.rightWallSensorId) and state.rightWallContactCount > 0) {
            state.rightWallContactCount -= 1;
        }
    }

    const groundContact = switch (grounding.mode) {
        .foot_contact => if (state.groundState.footOverlapCount > 0)
            try findGroundContact(state)
        else
            null,
        .body_contact => try findGroundContact(state),
        .ground_sweep => sweepGroundContact(state),
        .none => null,
    };
    const supported = groundContact != null and vec.dot(groundContact.?.normal, .{ .x = 0, .y = -1 }) >= minimumSupportUpAmount;
    if (wasSupported and !supported) {
        state.groundState.supportLostAtMs = currentTimeMs;
    }
    if (!wasSupported and supported) {
        state.groundState.supportLostAtMs = null;
        state.groundState.jumpAvailable = true;
        state.airJumpCounter = 0;
    }

    state.groundState.supported = supported;
    state.groundState.groundContact = groundContact;
    if (mechanism == .liero) processLieroBufferedJump(playerId, state, currentTimeMs);
}

pub fn processSensorEvents() !void {
    const currentTimeMs = time.nowMs();
    for (states.keys(), states.values()) |playerId, *state| {
        try processStateSensorEvents(playerId, state, currentTimeMs);
    }
}

pub fn applyAll(dt: f32) void {
    for (states.keys(), states.values()) |playerId, *state| {
        applyMovement(playerId, state, dt);
    }
}

pub fn clampAllSpeeds() void {
    for (states.values()) |*state| {
        clampLinearSpeed(state);
    }
}

pub fn clearAllMovementIntents() void {
    for (states.values()) |*state| {
        state.lateralMovementIntent = 0;
    }
}

pub fn cleanup() void {
    states.clearAndFree(allocator);
    contactDataScratch.deinit(allocator);
    contactDataScratch = .empty;
}
