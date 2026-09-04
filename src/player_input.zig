const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const vec = @import("vector.zig");

pub const ButtonState = struct {
    held: bool = false,
    pressed: bool = false,
    released: bool = false,
    pendingPressed: bool = false,
    pendingReleased: bool = false,
};

pub const Button = enum {
    jump,
    dodge,
    shoot,
    zoom,
    rope,
    sprayPaint,
    weaponNext,
    weaponPrev,
};

pub const ButtonValues = std.EnumArray(Button, bool);
pub const ButtonStates = std.EnumArray(Button, ButtonState);

pub const Sample = struct {
    movementDirection: vec.Vec2 = vec.zero,
    aimDirection: vec.Vec2 = vec.zero,
    buttons: ButtonValues = ButtonValues.initFill(false),
};

pub const PlayerInput = struct {
    movementDirection: vec.Vec2 = vec.zero,
    aimDirection: vec.Vec2 = vec.zero,
    buttons: ButtonStates = ButtonStates.initFill(.{}),
};

pub var playerInputs: std.AutoArrayHashMapUnmanaged(usize, PlayerInput) = .empty;

pub fn register(playerId: usize) !void {
    try playerInputs.put(allocator, playerId, .{});
}

pub fn submit(playerId: usize, sample: Sample) void {
    const inputState = playerInputs.getPtr(playerId) orelse {
        std.log.warn("player_input.submit: input state is missing for player {d}", .{playerId});
        return;
    };

    applySample(inputState, sample);
}

pub fn neutralize(playerId: usize) void {
    submit(playerId, .{});
}

pub fn neutralizeAll() void {
    for (playerInputs.values()) |*inputState| {
        applySample(inputState, .{});
    }
}

pub fn beginPhysicsStep() void {
    for (playerInputs.values()) |*inputState| {
        var iterator = inputState.buttons.iterator();
        while (iterator.next()) |entry| {
            beginButtonStep(entry.value);
        }
    }
}

pub fn endPhysicsStep() void {
    for (playerInputs.values()) |*inputState| {
        var iterator = inputState.buttons.iterator();
        while (iterator.next()) |entry| {
            endButtonStep(entry.value);
        }
    }
}

pub fn cleanup() void {
    playerInputs.deinit(allocator);
}

fn applySample(inputState: *PlayerInput, sample: Sample) void {
    inputState.movementDirection = sample.movementDirection;
    inputState.aimDirection = sample.aimDirection;

    var iterator = inputState.buttons.iterator();
    while (iterator.next()) |entry| {
        updateButton(entry.value, sample.buttons.get(entry.key));
    }
}

fn updateButton(button: *ButtonState, held: bool) void {
    if (button.held == held) return;

    button.held = held;
    if (held) {
        button.pendingPressed = true;
        return;
    }
    button.pendingReleased = true;
}

fn beginButtonStep(button: *ButtonState) void {
    button.pressed = button.pendingPressed;
    button.released = button.pendingReleased;
    button.pendingPressed = false;
    button.pendingReleased = false;
}

fn endButtonStep(button: *ButtonState) void {
    button.pressed = false;
    button.released = false;
}
