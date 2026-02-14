const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const control = @import("control.zig");
const vec = @import("vector.zig");

pub const KeyboardBindings = struct {
    moveLeft: sdl.Scancode,
    moveRight: sdl.Scancode,

    jump: sdl.Scancode,

    aimLeft: sdl.Scancode,
    aimRight: sdl.Scancode,
    aimUp: sdl.Scancode,
    aimDown: sdl.Scancode,

    shoot: sdl.Scancode,
    rope: sdl.Scancode,
};

pub const player1Bindings = KeyboardBindings{
    .moveLeft = .a,
    .moveRight = .d,
    .jump = .w,
    .aimLeft = .f,
    .aimRight = .h,
    .aimUp = .t,
    .aimDown = .g,
    .shoot = .lshift,
    .rope = .q,
};

pub const player2Bindings = KeyboardBindings{
    .moveLeft = .j,
    .moveRight = .l,
    .jump = .i,
    .aimLeft = .left,
    .aimRight = .right,
    .aimUp = .up,
    .aimDown = .down,
    .shoot = .rshift,
    .rope = .o,
};

pub var keyboardBindings: std.ArrayList(KeyboardBindings) = .{};

pub fn init() !void {
    try keyboardBindings.append(shared.allocator, player2Bindings);
    try keyboardBindings.append(shared.allocator, player1Bindings);
}

pub fn cleanup() void {
    keyboardBindings.deinit(shared.allocator);
}

pub fn createController(playerId: usize, color: sprite.Color) ?controller.Controller {
    const maybeKeybindings = keyboardBindings.pop();

    if (maybeKeybindings) |keyBindings| {
        const ctrl: controller.Controller = .{
            .playerId = playerId,
            .color = color,
            .inputType = .keyboard,
            .keyBindings = keyBindings,
            .gamepadBindings = null,
        };
        return ctrl;
    }
    return null;
}

pub fn handle(ctrl: *const controller.Controller) void {
    const bindings = ctrl.keyBindings orelse return;

    const keyStates = sdl.getKeyboardState();
    var aimDirection = vec.zero;

    // Movement
    const movingLeft = keyStates[@intFromEnum(bindings.moveLeft)] == 1;
    const movingRight = keyStates[@intFromEnum(bindings.moveRight)] == 1;

    if (movingLeft) {
        control.executeAction(ctrl.playerId, .move_left);
    }
    if (movingRight) {
        control.executeAction(ctrl.playerId, .move_right);
    }

    if (!movingLeft and !movingRight) {
        control.executeAction(ctrl.playerId, .brake);
    }

    // Jump
    if (keyStates[@intFromEnum(bindings.jump)] == 1) {
        control.executeAction(ctrl.playerId, .jump);
    }

    // Aiming - accumulate directions
    if (keyStates[@intFromEnum(bindings.aimLeft)] == 1) {
        aimDirection = vec.add(aimDirection, vec.west);
    }
    if (keyStates[@intFromEnum(bindings.aimRight)] == 1) {
        aimDirection = vec.add(aimDirection, vec.east);
    }
    if (keyStates[@intFromEnum(bindings.aimUp)] == 1) {
        aimDirection = vec.add(aimDirection, vec.north);
    }
    if (keyStates[@intFromEnum(bindings.aimDown)] == 1) {
        aimDirection = vec.add(aimDirection, vec.south);
    }

    if (aimDirection.x != 0 or aimDirection.y != 0) {
        control.executeAim(ctrl.playerId, aimDirection);
    } else {
        control.executeAimRelease(ctrl.playerId);
    }

    // Shooting
    if (keyStates[@intFromEnum(bindings.shoot)] == 1) {
        control.executeAction(ctrl.playerId, .shoot);
    }

    if (keyStates[@intFromEnum(bindings.rope)] == 1) {
        control.executeAction(ctrl.playerId, .rope);
    }
}
