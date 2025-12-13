const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");

/// Game actions that can be performed
pub const GameAction = enum {
    move_left,
    move_right,
    jump,
    aim_left,
    aim_right,
    aim_up,
    aim_down,
    shoot,
};

/// Controller maps keys to game actions for a specific player (data only)
pub const Controller = struct {
    playerId: usize,
    keyBindings: std.AutoHashMap(sdl.Scancode, GameAction),
};

/// Global controller registry
pub var controllers: [2]Controller = undefined;

/// Create a new controller for a player
pub fn createController(playerId: usize) !Controller {
    return Controller{
        .playerId = playerId,
        .keyBindings = std.AutoHashMap(sdl.Scancode, GameAction).init(shared.allocator),
    };
}

/// Clean up a controller's resources
pub fn destroyController(ctrl: *Controller) void {
    ctrl.keyBindings.deinit();
}

/// Check if an action is currently active on a controller
pub fn isActionActive(ctrl: *const Controller, keyStates: []const u8, action: GameAction) bool {
    var iter = ctrl.keyBindings.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == action) {
            if (keyStates[@intFromEnum(entry.key_ptr.*)] == 1) {
                return true;
            }
        }
    }
    return false;
}

/// Initialize default controller bindings
pub fn init() !void {
    // Player 0 (WASD + Arrow keys for aim + LShift for shoot)
    controllers[0] = try createController(0);
    try controllers[0].keyBindings.put(.a, .move_left);
    try controllers[0].keyBindings.put(.d, .move_right);
    try controllers[0].keyBindings.put(.space, .jump);
    try controllers[0].keyBindings.put(.left, .aim_left);
    try controllers[0].keyBindings.put(.right, .aim_right);
    try controllers[0].keyBindings.put(.up, .aim_up);
    try controllers[0].keyBindings.put(.down, .aim_down);
    try controllers[0].keyBindings.put(.lshift, .shoot);

    // Player 1 (IJKL for move + TFGH for aim + RShift for shoot)
    controllers[1] = try createController(1);
    try controllers[1].keyBindings.put(.j, .move_left);
    try controllers[1].keyBindings.put(.l, .move_right);
    try controllers[1].keyBindings.put(.i, .jump);
    try controllers[1].keyBindings.put(.f, .aim_left);
    try controllers[1].keyBindings.put(.h, .aim_right);
    try controllers[1].keyBindings.put(.t, .aim_up);
    try controllers[1].keyBindings.put(.g, .aim_down);
    try controllers[1].keyBindings.put(.rshift, .shoot);
}

pub fn cleanup() void {
    for (&controllers) |*ctrl| {
        destroyController(ctrl);
    }
}
