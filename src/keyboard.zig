const std = @import("std");
const sdl = @import("sdl.zig");

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
    sprayPaint: sdl.Scancode,
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
    .sprayPaint = .s,
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
    .sprayPaint = .k,
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

fn key(keyStates: []const bool, scancode: sdl.Scancode) bool {
    return keyStates[@as(usize, @intCast(@intFromEnum(scancode)))];
}

pub fn handle(ctrl: *const controller.Controller) void {
    const bindings = ctrl.keyBindings orelse return;

    const keyStates = sdl.getKeyboardState();
    var aimDirection = vec.zero;

    // Movement
    const movingLeft = key(keyStates, bindings.moveLeft);
    const movingRight = key(keyStates, bindings.moveRight);

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
    if (key(keyStates, bindings.jump)) {
        control.executeAction(ctrl.playerId, .jump);
    }

    // Aiming - accumulate directions
    if (key(keyStates, bindings.aimLeft)) {
        aimDirection = vec.add(aimDirection, vec.west);
    }
    if (key(keyStates, bindings.aimRight)) {
        aimDirection = vec.add(aimDirection, vec.east);
    }
    if (key(keyStates, bindings.aimUp)) {
        aimDirection = vec.add(aimDirection, vec.north);
    }
    if (key(keyStates, bindings.aimDown)) {
        aimDirection = vec.add(aimDirection, vec.south);
    }

    if (aimDirection.x != 0 or aimDirection.y != 0) {
        control.executeAim(ctrl.playerId, aimDirection);
    } else {
        control.executeAimRelease(ctrl.playerId);
    }

    // Shooting
    if (key(keyStates, bindings.shoot)) {
        control.executeAction(ctrl.playerId, .shoot);
    }

    if (key(keyStates, bindings.rope)) {
        control.executeAction(ctrl.playerId, .rope);
    }

    if (key(keyStates, bindings.sprayPaint)) {
        control.executeAction(ctrl.playerId, .spray_paint);
    }
}
