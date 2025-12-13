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

pub var keyBindingSets: std.ArrayList(std.AutoHashMapUnmanaged(sdl.Scancode, GameAction)) = .{};

/// Controller maps keys to game actions for a specific player (data only)
pub const Controller = struct {
    playerId: usize,
    keyBindings: std.AutoHashMapUnmanaged(sdl.Scancode, GameAction),
};

/// Global controller registry
pub var controllers: std.ArrayList(Controller) = .{};

pub fn createControllerForPlayer(playerId: usize) !void {
    const maybeKeyBindingSet = keyBindingSets.pop();

    if (maybeKeyBindingSet) |keyBindingSet| {
        const controller: Controller = .{
            .playerId = playerId,
            .keyBindings = keyBindingSet,
        };

        try controllers.append(shared.allocator, controller);
    }
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

pub fn init() !void {
    var keyBindings1: std.AutoHashMapUnmanaged(sdl.Scancode, GameAction) = .{};
    try keyBindings1.put(shared.allocator, .a, .move_left);
    try keyBindings1.put(shared.allocator, .d, .move_right);
    try keyBindings1.put(shared.allocator, .space, .jump);
    try keyBindings1.put(shared.allocator, .left, .aim_left);
    try keyBindings1.put(shared.allocator, .right, .aim_right);
    try keyBindings1.put(shared.allocator, .up, .aim_up);
    try keyBindings1.put(shared.allocator, .down, .aim_down);
    try keyBindings1.put(shared.allocator, .lshift, .shoot);

    var keyBindings2: std.AutoHashMapUnmanaged(sdl.Scancode, GameAction) = .{};
    try keyBindings2.put(shared.allocator, .j, .move_left);
    try keyBindings2.put(shared.allocator, .l, .move_right);
    try keyBindings2.put(shared.allocator, .i, .jump);
    try keyBindings2.put(shared.allocator, .f, .aim_left);
    try keyBindings2.put(shared.allocator, .h, .aim_right);
    try keyBindings2.put(shared.allocator, .t, .aim_up);
    try keyBindings2.put(shared.allocator, .g, .aim_down);
    try keyBindings2.put(shared.allocator, .rshift, .shoot);

    try keyBindingSets.append(shared.allocator, keyBindings2);
    try keyBindingSets.append(shared.allocator, keyBindings1);
}

pub fn cleanupController(ctrl: *Controller) void {
    ctrl.keyBindings.deinit(shared.allocator);
}

pub fn cleanup() void {
    for (controllers.items) |*ctrl| {
        cleanupController(ctrl);
    }
    controllers.deinit(shared.allocator);
    keyBindingSets.deinit(shared.allocator);
}
