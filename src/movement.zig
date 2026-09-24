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
    walkableOnly: bool = true,
    translation: vec.Vec2 = .{ .x = 0, .y = 1 },
    blocked: bool = false,
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
    // One fixed-step event, independent of the configurable forced-movement timer.
    wallJumpedDirection: i8 = 0,
    wallJumpMovementStepsRemaining: u32 = 0,
    lateralMovementIntent: i8 = 0,
    airJumpCounter: u32 = 0,
    bufferedJumpUntilMs: ?u64 = null,
    heldJumpGravityActive: bool = false,
    facingRight: bool = false,
    followGround: bool = false,
    groundTargetX: f32 = 0,
    groundVelocityX: f32 = 0,
    traversalContact: ?GroundContact = null,
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
    switch (movementData.mechanism) {
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
            if (!std.math.isFinite(settings.maxStepHeight) or settings.maxStepHeight < 0 or settings.maxStepHeight > 0.75) {
                std.log.err("movement.configure: maxStepHeight must be between 0 and 0.75 meters", .{});
                return error.InvalidStepHeight;
            }
            towerfallSettings = settings;
            bodyMotion = settings.bodyMotion;
            surfaceResponse = settings.surfaceResponse;
        },
    }

    mechanism = movementData.mechanism;
    aimGuideLengthMeters = movementData.aimGuideLengthMeters;
    grounding = movementData.grounding;
    minimumSupportUpAmount = @cos(grounding.maxSlopeAngleDegrees * std.math.pi / 180.0);
    player_input.configure(movementData);
}

fn clearRuntimeState(state: *State) void {
    state.groundState = .{};
    state.leftWallContactCount = 0;
    state.rightWallContactCount = 0;
    state.wallSliding = false;
    state.wallJumpDirection = 0;
    state.wallJumpedDirection = 0;
    state.wallJumpMovementStepsRemaining = 0;
    state.lateralMovementIntent = 0;
    state.airJumpCounter = 0;
    state.bufferedJumpUntilMs = null;
    state.heldJumpGravityActive = false;
    state.followGround = false;
    state.traversalContact = null;
}

pub fn reset(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.reset: movement state is missing for player {d}", .{playerId});
        return;
    };
    clearRuntimeState(state);
    const inputState = player_input.playerInputs.getPtr(playerId) orelse {
        std.log.warn("movement.reset: input state is missing for player {d}", .{playerId});
        return;
    };
    inputState.aimMovementDirection = 0;
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
    state.followGround = false;
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
    state.wallJumpedDirection = direction;
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
    if (state.followGround) {
        const contact = state.groundState.groundContact.?;
        const support = box2d.c.b2Body_GetWorldPointVelocity(contact.bodyId, vec.toBox2d(contact.worldPoint));
        velocity.y = support.y - (velocity.x - support.x) * contact.normal.x / contact.normal.y;
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

// Raw direction remains available to aiming. During an airborne aim hold,
// retain the horizontal input that shaped the jump. Cancel on ground before
// any jump/buffer processing, including fixed steps without a new input poll.
pub fn locomotionDirection(playerId: usize) vec.Vec2 {
    const inputState = player_input.playerInputs.getPtr(playerId) orelse {
        std.log.warn("movement.locomotionDirection: input state is missing for player {d}", .{playerId});
        return vec.zero;
    };
    if (mechanism != .towerfall or !inputState.buttons.get(.shoot).held) return inputState.movementDirection;
    const state = states.get(playerId) orelse {
        std.log.warn("movement.locomotionDirection: movement state is missing for player {d}", .{playerId});
        return vec.zero;
    };
    if (state.groundState.supported) inputState.aimMovementDirection = 0;
    return .{ .x = inputState.aimMovementDirection, .y = 0 };
}

fn applyTowerfallMovement(playerId: usize, state: *State, dt: f32) void {
    var inputState = player_input.playerInputs.get(playerId) orelse {
        std.log.warn("movement.applyTowerfallMovement: input state is missing for player {d}", .{playerId});
        return;
    };
    inputState.movementDirection = locomotionDirection(playerId);
    state.lateralMovementIntent = if (inputState.movementDirection.x < 0) -1 else if (inputState.movementDirection.x > 0) @as(i8, 1) else 0;
    const controlSettings = towerfallSettings.control;
    const movementDirection = towerfallMovementDirection(inputState, state);
    const targetSpeed = movementDirection * controlSettings.maxRunSpeed;
    var velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    const contact = state.groundState.groundContact;
    grounded: {
        if (!state.groundState.supported or contact == null) break :grounded;
        if (!box2d.c.b2Body_IsValid(contact.?.bodyId) or !box2d.c.b2Shape_IsValid(contact.?.shapeId)) break :grounded;
        // Jumps and upward impulses must leave support. Tangential uphill
        // travel has upward velocity too, but does not separate from the floor.
        if (separatingFromGround(state, contact.?)) break :grounded;
        state.followGround = true;
    }
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
    state.groundTargetX = box2d.c.b2Body_GetPosition(state.bodyId).x + velocity.x * dt;
    state.groundVelocityX = velocity.x;
}

fn applyMovement(playerId: usize, state: *State, dt: f32) void {
    state.wallJumpedDirection = 0;
    state.followGround = false;
    state.traversalContact = null;
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

fn bodyContacts(state: *const State) ![]const box2d.c.b2ContactData {
    const contactCapacity = box2d.c.b2Body_GetContactCapacity(state.bodyId);
    if (contactCapacity == 0) return &.{};

    const capacity: usize = @intCast(contactCapacity);
    try contactDataScratch.ensureTotalCapacity(allocator, capacity);
    contactDataScratch.items.len = capacity;

    const contactCount: usize = @intCast(box2d.c.b2Body_GetContactData(
        state.bodyId,
        contactDataScratch.items.ptr,
        contactCapacity,
    ));
    return contactDataScratch.items[0..contactCount];
}

fn findGroundContact(state: *const State) !?GroundContact {
    var bestGroundContact: ?GroundContact = null;
    var bestUpAmount: f32 = -1.0;
    for (try bodyContacts(state)) |contact| {
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
    if (box2d.c.b2Shape_IsSensor(shapeId)) return -1;
    if (normal.x == 0 and normal.y == 0) return -1;
    if (sweepContext.walkableOnly and -normal.y < minimumSupportUpAmount) return -1;
    if (vec.dot(vec.fromBox2d(normal), sweepContext.translation) >= -0.000001) return -1;
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

const groundSkin: f32 = 0.005;

fn traversalProxy(shapeId: box2d.c.b2ShapeId, offset: vec.Vec2) ?box2d.c.b2ShapeProxy {
    var transform = box2d.c.b2Body_GetTransform(box2d.c.b2Shape_GetBody(shapeId));
    transform.p.x += offset.x;
    transform.p.y += offset.y;
    switch (box2d.c.b2Shape_GetType(shapeId)) {
        box2d.c.b2_polygonShape => {
            const polygon = box2d.c.b2Shape_GetPolygon(shapeId);
            return box2d.c.b2MakeOffsetProxy(&polygon.vertices, polygon.count, polygon.radius, transform.p, transform.q);
        },
        box2d.c.b2_circleShape => {
            const circle = box2d.c.b2Shape_GetCircle(shapeId);
            return box2d.c.b2MakeOffsetProxy(&circle.center, 1, circle.radius, transform.p, transform.q);
        },
        box2d.c.b2_capsuleShape => {
            const capsule = box2d.c.b2Shape_GetCapsule(shapeId);
            const points = [_]box2d.c.b2Vec2{ capsule.center1, capsule.center2 };
            return box2d.c.b2MakeOffsetProxy(&points, points.len, capsule.radius, transform.p, transform.q);
        },
        else => {
            std.log.warn("movement.traversalProxy: unsupported character collider type", .{});
            return null;
        },
    }
}

fn collectTraversalOverlap(shapeId: box2d.c.b2ShapeId, context: ?*anyopaque) callconv(.c) bool {
    if (context == null) {
        std.log.err("movement.collectTraversalOverlap: query context is missing", .{});
        return false;
    }
    const result: *GroundSweepContext = @ptrCast(@alignCast(context.?));
    if (box2d.c.B2_ID_EQUALS(box2d.c.b2Shape_GetBody(shapeId), result.playerBodyId) or box2d.c.b2Shape_IsSensor(shapeId)) return true;
    result.blocked = true;
    return false;
}

// Sweep every solid collider, using its real geometry and collision filter.
// The raised origin is overlap-tested because casts ignore initial overlap.
fn castBody(state: *const State, offset: vec.Vec2, translation: vec.Vec2) GroundSweepContext {
    var result = GroundSweepContext{ .playerBodyId = state.bodyId, .walkableOnly = false, .translation = translation };
    var shapes: [16]box2d.c.b2ShapeId = undefined;
    const count = box2d.c.b2Body_GetShapeCount(state.bodyId);
    if (count <= 0 or count > shapes.len) {
        std.log.warn("movement.castBody: unsupported character shape count {d}", .{count});
        result.blocked = true;
        return result;
    }
    const length: usize = @intCast(box2d.c.b2Body_GetShapes(state.bodyId, &shapes, shapes.len));
    for (shapes[0..length]) |shape| {
        if (box2d.c.b2Shape_IsSensor(shape)) continue;
        const proxy = traversalProxy(shape, offset) orelse {
            result.blocked = true;
            return result;
        };
        const sourceFilter = box2d.c.b2Shape_GetFilter(shape);
        var filter = box2d.c.b2DefaultQueryFilter();
        filter.categoryBits = sourceFilter.categoryBits;
        filter.maskBits = sourceFilter.maskBits;
        if (!vec.equals(offset, vec.zero)) box2d.overlapShape(&proxy, filter, collectTraversalOverlap, &result);
        if (result.blocked) return result;
        box2d.castShape(&proxy, vec.toBox2d(translation), filter, collectGroundSweep, &result);
    }
    return result;
}

fn traversableContact(contact: ?GroundContact) bool {
    if (contact == null or -contact.?.normal.y < minimumSupportUpAmount) return false;
    if (!box2d.c.b2Body_IsValid(contact.?.bodyId) or !box2d.c.b2Shape_IsValid(contact.?.shapeId)) return false;
    return box2d.c.b2Body_GetType(contact.?.bodyId) == box2d.c.b2_staticBody;
}

fn alignGroundVelocity(state: *const State, contact: GroundContact) void {
    const support = box2d.c.b2Body_GetWorldPointVelocity(contact.bodyId, vec.toBox2d(contact.worldPoint));
    var velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    velocity.y = support.y - (velocity.x - support.x) * contact.normal.x / contact.normal.y;
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, velocity);
}

fn separatingFromGround(state: *const State, contact: GroundContact) bool {
    const support = box2d.c.b2Body_GetWorldPointVelocity(contact.bodyId, vec.toBox2d(contact.worldPoint));
    const velocity = box2d.c.b2Body_GetLinearVelocity(state.bodyId);
    const relative = vec.subtract(vec.fromBox2d(velocity), vec.fromBox2d(support));
    return relative.y < -0.5 and vec.dot(relative, contact.normal) > 0.5;
}

fn separatingAfterStep(state: *const State) !bool {
    if (!separatingFromGround(state, state.groundState.groundContact.?)) return false;
    // At a seam, the solver can redirect motion along a new face or the radial
    // normal of a rounded foot against a corner. Check every upward contact,
    // rather than mistaking separation from the previous face alone for takeoff.
    for (try bodyContacts(state)) |contact| {
        const ground = groundContactForContact(state, contact) orelse continue;
        if (ground.normal.y >= -0.01) continue;
        if (!separatingFromGround(state, ground)) return false;
    }
    return true;
}

// A rounded character collider hits a stair corner with a radial normal. Use
// the actual walkable polygon face at that point for supported step traversal.
fn stepContact(contact: ?GroundContact) ?GroundContact {
    if (contact == null) return null;
    var result = contact.?;
    if (!box2d.c.b2Body_IsValid(result.bodyId) or !box2d.c.b2Shape_IsValid(result.shapeId)) return null;
    if (box2d.c.b2Body_GetType(result.bodyId) != box2d.c.b2_staticBody) return null;
    if (box2d.c.b2Shape_GetType(result.shapeId) != box2d.c.b2_polygonShape) return if (traversableContact(contact)) contact else null;
    const polygon = box2d.c.b2Shape_GetPolygon(result.shapeId);
    const count: usize = @intCast(polygon.count);
    const local = vec.fromBox2d(box2d.c.b2Body_GetLocalPoint(result.bodyId, vec.toBox2d(result.worldPoint)));
    for (0..count) |index| {
        const normal = vec.fromBox2d(box2d.c.b2Body_GetWorldVector(result.bodyId, polygon.normals[index]));
        if (-normal.y < minimumSupportUpAmount) continue;
        const a = vec.fromBox2d(polygon.vertices[index]);
        const b = vec.fromBox2d(polygon.vertices[(index + 1) % count]);
        const edge = vec.subtract(b, a);
        const from_a = vec.subtract(local, a);
        const along = vec.dot(from_a, edge) / vec.dot(edge, edge);
        if (along < -groundSkin or along > 1 + groundSkin) continue;
        if (@abs(vec.dot(from_a, vec.fromBox2d(polygon.normals[index])) - polygon.radius) > 2 * groundSkin) continue;
        result.normal = normal;
        return result;
    }
    return if (traversableContact(contact)) contact else null;
}

fn climbStep(state: *State, forward: f32) bool {
    const height = towerfallSettings.maxStepHeight;
    if (height == 0 or state.lateralMovementIntent == 0 or forward * state.groundVelocityX <= 0 or @abs(forward) <= groundSkin) return false;
    const upDistance = height + 2 * groundSkin;
    const up = castBody(state, vec.zero, .{ .x = 0, .y = -upDistance });
    if (up.blocked) return false;
    const lift = upDistance * up.fraction - groundSkin;
    if (lift <= groundSkin) return false;
    const across = castBody(state, .{ .x = 0, .y = -lift }, .{ .x = forward, .y = 0 });
    if (across.blocked or across.fraction < 1) return false;
    const downDistance = lift + groundSkin;
    const down = castBody(state, .{ .x = forward, .y = -lift }, .{ .x = 0, .y = downDistance });
    if (down.blocked) return false;
    const candidate = stepContact(down.groundContact) orelse return false;
    const previous = state.groundState.groundContact.?;
    const oldFloor = previous.worldPoint.y - (candidate.worldPoint.x - previous.worldPoint.x) * previous.normal.x / previous.normal.y;
    const rise = oldFloor - candidate.worldPoint.y;
    if (rise < -groundSkin or rise > height + groundSkin) return false;
    const deltaY = -lift + downDistance * down.fraction - groundSkin;
    if (deltaY >= -groundSkin) return false;
    var position = box2d.c.b2Body_GetPosition(state.bodyId);
    position.x += forward;
    position.y += deltaY;
    box2d.c.b2Body_SetTransform(state.bodyId, position, box2d.c.b2Body_GetRotation(state.bodyId));
    box2d.c.b2Body_SetLinearVelocity(state.bodyId, .{ .x = state.groundVelocityX, .y = 0 });
    alignGroundVelocity(state, candidate);
    state.traversalContact = candidate;
    return true;
}

// Resolve only movement that began supported. Jumps, airborne aim momentum and
// large drops retain their ordinary trajectory. Run after Box2D, before fresh
// grounding and animation, so every consumer sees the corrected position.
pub fn resolveGroundMovement() !void {
    if (mechanism != .towerfall) return;
    for (states.values()) |*state| {
        if (!state.followGround or !traversableContact(state.groundState.groundContact)) continue;
        if (try separatingAfterStep(state)) {
            state.followGround = false;
            continue;
        }
        const forward = state.groundTargetX - box2d.c.b2Body_GetPosition(state.bodyId).x;
        if (climbStep(state, forward)) continue;
        const contact = try findGroundContact(state);
        if (traversableContact(contact)) {
            state.traversalContact = contact;
            alignGroundVelocity(state, contact.?);
            continue;
        }
        const limit = @max(towerfallSettings.maxStepHeight, grounding.sweepDistance);
        if (limit == 0) continue;
        const distance = limit + 2 * groundSkin;
        const down = castBody(state, vec.zero, .{ .x = 0, .y = distance });
        if (down.blocked) continue;
        const candidate = stepContact(down.groundContact) orelse continue;
        const previous = stepContact(state.groundState.groundContact) orelse state.groundState.groundContact.?;
        const oldFloor = previous.worldPoint.y - (candidate.worldPoint.x - previous.worldPoint.x) * previous.normal.x / previous.normal.y;
        if (candidate.worldPoint.y - oldFloor > limit + groundSkin) continue;
        const drop = distance * down.fraction - groundSkin;
        if (drop > limit + groundSkin) continue;
        var position = box2d.c.b2Body_GetPosition(state.bodyId);
        position.y += @max(0, drop);
        box2d.c.b2Body_SetTransform(state.bodyId, position, box2d.c.b2Body_GetRotation(state.bodyId));
        state.traversalContact = candidate;
        alignGroundVelocity(state, candidate);
    }
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

    const groundContact = state.traversalContact orelse switch (grounding.mode) {
        .foot_contact => if (state.groundState.footOverlapCount > 0)
            try findGroundContact(state)
        else
            null,
        .body_contact => try findGroundContact(state),
        // Shape casts ignore initial overlap. On slopes the foot probe can
        // overlap a surface already supporting the body; reuse its contacts.
        .ground_sweep => sweepGroundContact(state) orelse try findGroundContact(state),
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
    if (mechanism == .towerfall and supported) {
        const inputState = player_input.playerInputs.getPtr(playerId) orelse {
            std.log.warn("movement.processStateSensorEvents: input state is missing for player {d}", .{playerId});
            return;
        };
        inputState.aimMovementDirection = 0;
        if (inputState.buttons.get(.shoot).held) state.lateralMovementIntent = 0;
    }
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
    // Level changes preserve controllers/input while replacing movement bodies.
    // A continued aim hold must not carry a previous level's jump input forward.
    for (player_input.playerInputs.values()) |*inputState| inputState.aimMovementDirection = 0;
    states.clearAndFree(allocator);
    contactDataScratch.deinit(allocator);
    contactDataScratch = .empty;
}
