const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const data = @import("data.zig");
const delay = @import("delay.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

pub const GroundState = struct {
    contactCount: usize = 0,
    supported: bool = false,
    jumpAvailable: bool = false,
    supportLostAtMs: ?u64 = null,
};

pub const State = struct {
    bodyId: box2d.c.b2BodyId,
    footSensorShapeId: box2d.c.b2ShapeId,
    leftWallSensorId: box2d.c.b2ShapeId,
    rightWallSensorId: box2d.c.b2ShapeId,
    groundState: GroundState = .{},
    leftWallContactCount: usize = 0,
    rightWallContactCount: usize = 0,
    lateralMovementIntent: i8 = 0,
    airJumpCounter: u32 = 0,
    bufferedJumpUntilMs: ?u64 = null,
    facingRight: bool = false,
};

pub var states: std.AutoArrayHashMapUnmanaged(usize, State) = .empty;

pub var mechanism: data.MovementMechanism = undefined;
pub var control: data.MovementControlData = undefined;
pub var bodyMotion: data.MovementBodyMotionData = undefined;
pub var surfaceResponse: data.MovementSurfaceResponseData = undefined;
pub var jumpSettings: data.MovementJumpData = undefined;
pub var grounding: data.MovementGroundingData = undefined;

pub fn configure(movementData: data.MovementData) void {
    mechanism = movementData.mechanism;
    control = movementData.control;
    bodyMotion = movementData.bodyMotion;
    surfaceResponse = movementData.surfaceResponse;
    jumpSettings = movementData.jump;
    grounding = movementData.grounding;
}

fn clearRuntimeState(state: *State) void {
    state.groundState = .{};
    state.leftWallContactCount = 0;
    state.rightWallContactCount = 0;
    state.lateralMovementIntent = 0;
    state.airJumpCounter = 0;
    state.bufferedJumpUntilMs = null;
}

pub fn reset(playerId: usize) void {
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.reset: movement state is missing for player {d}", .{playerId});
        return;
    };
    clearRuntimeState(state);
}

fn canUseGroundJump(state: *const State, currentTimeMs: u64) bool {
    if (!state.groundState.jumpAvailable) return false;
    if (state.groundState.supported) return true;
    if (jumpSettings.coyoteTimeMs == 0) return false;

    const supportLostAtMs = state.groundState.supportLostAtMs orelse return false;
    return currentTimeMs <= supportLostAtMs + @as(u64, jumpSettings.coyoteTimeMs);
}

fn executeJump(playerId: usize, state: *State, currentTimeMs: u64, groundOnly: bool) bool {
    var buf: [32:0]u8 = undefined;
    const delayKey = std.fmt.bufPrintZ(&buf, "p{d}_jump", .{playerId}) catch unreachable;

    if (delay.check(delayKey)) return false;

    const useGroundJump = canUseGroundJump(state, currentTimeMs);
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
    const state = states.getPtr(playerId) orelse {
        std.log.warn("movement.jump: movement state is missing for player {d}", .{playerId});
        return;
    };
    const currentTimeMs = time.nowMs();
    if (executeJump(playerId, state, currentTimeMs, false)) return;
    if (jumpSettings.bufferTimeMs == 0) return;

    state.bufferedJumpUntilMs = currentTimeMs + jumpSettings.bufferTimeMs;
}

fn processBufferedJump(playerId: usize, state: *State, currentTimeMs: u64) void {
    const bufferedJumpUntilMs = state.bufferedJumpUntilMs orelse return;
    if (currentTimeMs > bufferedJumpUntilMs) {
        state.bufferedJumpUntilMs = null;
        return;
    }
    if (!canUseGroundJump(state, currentTimeMs)) return;

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

fn applyMovement(state: *State, dt: f32) void {
    switch (mechanism) {
        .liero => applyLieroMovement(state, dt),
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

fn processStateSensorEvents(playerId: usize, state: *State, currentTimeMs: u64) void {
    const sensorEvents = box2d.getSensorEvents();
    const wasSupported = state.groundState.supported;

    for (0..@intCast(sensorEvents.beginCount)) |i| {
        const event = sensorEvents.beginEvents[i];

        const visitorBodyId = box2d.c.b2Shape_GetBody(event.visitorShapeId);
        if (box2d.c.B2_ID_EQUALS(visitorBodyId, state.bodyId)) continue;

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.footSensorShapeId)) {
            if (state.groundState.contactCount == 0) {
                state.groundState.supported = true;
                state.groundState.jumpAvailable = true;
                state.airJumpCounter = 0;
            }
            state.groundState.contactCount += 1;
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

        const visitorBodyId = box2d.c.b2Shape_GetBody(event.visitorShapeId);
        if (box2d.c.B2_ID_EQUALS(visitorBodyId, state.bodyId)) continue;

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.footSensorShapeId) and state.groundState.contactCount > 0) {
            state.groundState.contactCount -= 1;
        }

        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.leftWallSensorId) and state.leftWallContactCount > 0) {
            state.leftWallContactCount -= 1;
        }
        if (box2d.c.B2_ID_EQUALS(event.sensorShapeId, state.rightWallSensorId) and state.rightWallContactCount > 0) {
            state.rightWallContactCount -= 1;
        }
    }

    const supported = state.groundState.contactCount > 0;
    if (wasSupported and !supported) {
        state.groundState.supportLostAtMs = currentTimeMs;
    }
    if (!wasSupported and supported) {
        state.groundState.supportLostAtMs = null;
    }

    state.groundState.supported = supported;
    processBufferedJump(playerId, state, currentTimeMs);
}

pub fn processSensorEvents() void {
    const currentTimeMs = time.nowMs();
    for (states.keys(), states.values()) |playerId, *state| {
        processStateSensorEvents(playerId, state, currentTimeMs);
    }
}

pub fn applyAll(dt: f32) void {
    for (states.values()) |*state| {
        applyMovement(state, dt);
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
}
