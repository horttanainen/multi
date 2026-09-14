const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const data = @import("data.zig");
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
    // Device direction after its deadzone, before the configured aim snapping.
    aimDirection: vec.Vec2 = vec.zero,
    buttons: ButtonValues = ButtonValues.initFill(false),
};

pub const PlayerInput = struct {
    movementDirection: vec.Vec2 = vec.zero,
    aimDirection: vec.Vec2 = vec.zero,
    heldAimDirection: vec.Vec2 = vec.zero,
    releasedAimDirection: vec.Vec2 = vec.zero,
    // Horizontal input immediately before this aim hold. Movement cancels it
    // when grounded; release and input neutralization also clear it.
    aimMovementDirection: f32 = 0,
    buttons: ButtonStates = ButtonStates.initFill(.{}),
};

pub var playerInputs: std.AutoArrayHashMapUnmanaged(usize, PlayerInput) = .empty;
pub var directionSettings: data.DirectionalInputData = .{ .aimMode = .free };
var profileDirectionSettings: data.DirectionalInputData = .{ .aimMode = .free };

pub fn configure(settings: data.MovementData) void {
    profileDirectionSettings = settings.input orelse .{
        .aimMode = switch (settings.mechanism) {
            .liero => .free,
            .towerfall => .eight_directions,
        },
    };
    resetDirectionSettings();
}

pub fn resetDirectionSettings() void {
    directionSettings = profileDirectionSettings;
}

// Exact cardinal zeros prevent vertical aim from requesting a horizontal turn.
// Diagonal movement keeps full horizontal intent instead of slowing to 1/sqrt(2).
pub fn eightDirection(direction: vec.Vec2) vec.Vec2 {
    if (vec.equals(direction, vec.zero)) return vec.zero;
    if (!std.math.isFinite(direction.x) or !std.math.isFinite(direction.y)) {
        std.log.warn("player_input.eightDirection: non-finite direction {any}", .{direction});
        return vec.zero;
    }
    const directions = [_]vec.Vec2{
        vec.east, .{ .x = 1, .y = 1 },   vec.north, .{ .x = -1, .y = 1 },
        vec.west, .{ .x = -1, .y = -1 }, vec.south, .{ .x = 1, .y = -1 },
    };
    const sector: i32 = @intFromFloat(@round(std.math.atan2(direction.y, direction.x) / (std.math.pi / 4.0)));
    return directions[@intCast(@mod(sector, 8))];
}

fn resolveAim(direction: vec.Vec2) vec.Vec2 {
    if (directionSettings.aimMode == .free or vec.equals(direction, vec.zero)) return direction;
    const snapped = eightDirection(direction);
    if (vec.equals(snapped, vec.zero)) return vec.zero;
    // Preserve stick strength for consumers such as camera look-ahead.
    return vec.mul(vec.normalize(snapped), vec.magnitude(direction));
}

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
    const inputState = playerInputs.getPtr(playerId) orelse {
        std.log.warn("player_input.neutralize: input state is missing for player {d}", .{playerId});
        return;
    };
    inputState.* = .{};
}

pub fn neutralizeAll() void {
    for (playerInputs.values()) |*inputState| {
        inputState.* = .{};
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
    const aimDirection = resolveAim(sample.aimDirection);
    const wasAiming = inputState.buttons.get(.shoot).held;
    const aiming = sample.buttons.get(.shoot);
    const hasDirection = !vec.equals(aimDirection, vec.zero);
    if (!aiming) inputState.aimMovementDirection = 0;
    if (aiming and !wasAiming) inputState.aimMovementDirection = inputState.movementDirection.x;
    if (aiming and (!wasAiming or hasDirection)) inputState.heldAimDirection = aimDirection;
    if (wasAiming and !aiming) {
        // Keep the release direction until the fixed step consumes the edge.
        // Subsequent movement or a new aim press must not redirect this shot.
        inputState.releasedAimDirection = if (hasDirection) aimDirection else inputState.heldAimDirection;
    }
    inputState.movementDirection = sample.movementDirection;
    inputState.aimDirection = aimDirection;

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
