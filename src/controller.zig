const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const sprite = @import("sprite.zig");
const gamepad = @import("gamepad.zig");
const keyboard = @import("keyboard.zig");

pub const InputType = enum {
    keyboard,
    gamepad,
};

pub const GameAction = enum {
    move_left,
    move_right,
    brake,
    jump,
    aim_left,
    aim_right,
    aim_up,
    aim_down,
    shoot,
};

pub var availableColors: std.ArrayList(sprite.Color) = .{};

pub const Controller = struct {
    playerId: usize,
    color: sprite.Color,
    inputType: InputType,
    keyBindings: ?keyboard.KeyboardBindings,
    gamepadBindings: ?gamepad.GamepadBindings,
};

pub var controllers: std.AutoArrayHashMapUnmanaged(usize, Controller) = .{};

pub fn recalculateControllers() !void {
    var iter = controllers.iterator();
    while (iter.next()) |entry| {
        const ctrl = entry.value_ptr;
        if (ctrl.inputType == .keyboard) {
            if (gamepad.createController(ctrl.playerId, ctrl.color)) |newCtrl| {

                if (ctrl.keyBindings) |keyBindings| {
                    try keyboard.keyboardBindings.append(shared.allocator, keyBindings);
                }
                try controllers.put(shared.allocator, ctrl.playerId, newCtrl);
            }
        }
        if (ctrl.inputType == .gamepad and !gamepad.assignedGamepads.contains(ctrl.playerId)) {
            if (keyboard.createController(ctrl.playerId, ctrl.color)) |newCtrl| {
                try controllers.put(shared.allocator, ctrl.playerId, newCtrl);
            }
        }
    }
}

pub fn createControllerForPlayer(playerId: usize) !sprite.Color {
    const maybeColor = availableColors.pop();
    const defaultColor: sprite.Color = .{ .r = 150, .g = 150, .b = 150 };
    const color = if (maybeColor) |c| c else defaultColor;

    if (gamepad.createController(playerId, color)) |ctrl| {
        try controllers.put(shared.allocator, playerId, ctrl);
        return color;
    }

    if (keyboard.createController(playerId, color)) |ctrl| {
        try controllers.put(shared.allocator, playerId, ctrl);
        return color;
    }

    return color;
}

pub fn init() !void {
    try availableColors.append(shared.allocator, .{ .r = 255, .g = 1, .b = 1 });
    try availableColors.append(shared.allocator, .{ .r = 1, .g = 1, .b = 255 });
    try availableColors.append(shared.allocator, .{ .r = 1, .g = 255, .b = 1 });
    try availableColors.append(shared.allocator, .{ .r = 255, .g = 1, .b = 255 });
}

pub fn cleanup() void {
    controllers.deinit(shared.allocator);
    availableColors.deinit(shared.allocator);
}
