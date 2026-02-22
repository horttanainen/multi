const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const control = @import("control.zig");
const vec = @import("vector.zig");

pub const stickDeadzone: f32 = 0.15;
pub const TRIGGER_THRESHOLD: f32 = 0.1;
pub const MOVEMENT_THRESHOLD: f32 = 0.2;
pub const axisMax: f32 = 32767.0;

pub const GamepadState = struct {
    controller: ?*sdl.GameController,
    deviceIndex: i32,
};

pub const GamepadBindings = struct {
    // Movement
    moveLeftAxis: sdl.GameController.Axis,
    moveRightAxis: sdl.GameController.Axis,
    moveThreshold: f32,

    // Jump
    jumpButton: sdl.GameController.Button,

    // Aiming
    aimXAxis: sdl.GameController.Axis,
    aimYAxis: sdl.GameController.Axis,
    aimThreshold: f32,

    // Shooting
    shootAxis: sdl.GameController.Axis,
    shootThreshold: f32,

    // Rope
    ropeButton: sdl.GameController.Button,
};

pub const defaultBindings = GamepadBindings{
    .moveLeftAxis = .leftx,
    .moveRightAxis = .leftx,
    .moveThreshold = MOVEMENT_THRESHOLD,

    .jumpButton = .a,

    .aimXAxis = .rightx,
    .aimYAxis = .righty,
    .aimThreshold = 0.1,

    .shootAxis = .triggerright,
    .shootThreshold = TRIGGER_THRESHOLD,

    .ropeButton = .leftshoulder,
};

pub var availableGamepads: std.ArrayList(GamepadState) = .{};

pub var assignedGamepads: std.AutoHashMapUnmanaged(usize, GamepadState) = .{};

fn openGamepad(deviceIndex: i32) !void {
    const gc = try sdl.gameControllerOpen(deviceIndex);

    const gamepadState = GamepadState{
        .controller = gc,
        .deviceIndex = deviceIndex,
    };

    try availableGamepads.append(shared.allocator, gamepadState);
    std.debug.print("Gamepad {d} detected and added to available list\n", .{deviceIndex});
}

pub fn handleDeviceAdded(deviceIndex: i32) !void {
    openGamepad(deviceIndex) catch |err| {
        std.debug.print("Failed to open gamepad {d}: {}\n", .{ deviceIndex, err });
        return;
    };

    controller.recalculateControllers() catch |err| {
        std.debug.print("Failed to recalculate controllers: {}\n", .{err});
    };
}

pub fn handleDeviceRemoved(deviceIndex: i32) void {
    var iter = assignedGamepads.iterator();
    var playerIdToRemove: ?usize = null;
    while (iter.next()) |entry| {
        if (entry.value_ptr.deviceIndex == deviceIndex) {
            if (entry.value_ptr.controller) |ctrl| {
                sdl.gameControllerClose(ctrl);
            }
            playerIdToRemove = entry.key_ptr.*;
            std.debug.print("Gamepad {d} disconnected from player {d}\n", .{ deviceIndex, entry.key_ptr.* });
            break;
        }
    }
    if (playerIdToRemove) |playerId| {
        _ = assignedGamepads.remove(playerId);
    }

    for (availableGamepads.items, 0..) |gp, i| {
        if (gp.deviceIndex == deviceIndex) {
            if (gp.controller) |ctrl| {
                sdl.gameControllerClose(ctrl);
            }
            _ = availableGamepads.swapRemove(i);
            std.debug.print("Gamepad {d} removed from available list\n", .{deviceIndex});
            break;
        }
    }

    // Trigger controller recalculation
    controller.recalculateControllers() catch |err| {
        std.debug.print("Failed to recalculate controllers: {}\n", .{err});
    };
}

fn normalizeAxis(rawValue: i16) f32 {
    const normalized = @as(f32, @floatFromInt(rawValue)) / axisMax;
    if (@abs(normalized) < stickDeadzone) {
        return 0.0;
    }
    return normalized;
}

pub fn createController(playerId: usize, color: sprite.Color) ?controller.Controller {
    const maybeGamepad = availableGamepads.pop();
    if (maybeGamepad == null) {
        return null;
    }
    const gamepadState = maybeGamepad.?;

    assignedGamepads.put(shared.allocator, playerId, gamepadState) catch {
        std.debug.print("Failed to assign gamepad to player {d}\n", .{playerId});
        return null;
    };

    std.debug.print("Gamepad assigned to player {d}\n", .{playerId});

    return controller.Controller{
        .playerId = playerId,
        .color = color,
        .inputType = .gamepad,
        .keyBindings = null,
        .gamepadBindings = defaultBindings,
    };
}

pub fn handle(ctrl: *const controller.Controller) void {
    const bindings = ctrl.gamepadBindings orelse return;

    const gp = assignedGamepads.get(ctrl.playerId) orelse return;
    const sdlCtrl = gp.controller orelse return;

    const moveAxis = normalizeAxis(sdl.gameControllerGetAxis(sdlCtrl, bindings.moveLeftAxis));
    if (moveAxis < -bindings.moveThreshold) {
        control.executeAction(ctrl.playerId, .move_left);
    } else if (moveAxis > bindings.moveThreshold) {
        control.executeAction(ctrl.playerId, .move_right);
    } else {
        control.executeAction(ctrl.playerId, .brake);
    }

    if (sdl.gameControllerGetButton(sdlCtrl, bindings.jumpButton)) {
        control.executeAction(ctrl.playerId, .jump);
    }

    const aimX = normalizeAxis(sdl.gameControllerGetAxis(sdlCtrl, bindings.aimXAxis));
    const aimY = normalizeAxis(sdl.gameControllerGetAxis(sdlCtrl, bindings.aimYAxis));

    if (@abs(aimX) > bindings.aimThreshold or @abs(aimY) > bindings.aimThreshold) {
        const aimDirection = vec.Vec2{ .x = aimX, .y = -aimY };
        control.executeAim(ctrl.playerId, aimDirection);
    } else {
        control.executeAimRelease(ctrl.playerId);
    }

    const shootValue = normalizeAxis(sdl.gameControllerGetAxis(sdlCtrl, bindings.shootAxis));
    if (shootValue > bindings.shootThreshold) {
        control.executeAction(ctrl.playerId, .shoot);
    }

    const zoomValue = normalizeAxis(sdl.gameControllerGetAxis(sdlCtrl, .triggerleft));
    if (zoomValue > TRIGGER_THRESHOLD) {
        control.executeZoom(ctrl.playerId);
    } else {
        control.executeZoomRelease(ctrl.playerId);
    }

    if (sdl.gameControllerGetButton(sdlCtrl, bindings.ropeButton)) {
        control.executeAction(ctrl.playerId, .rope);
    }
}

pub fn cleanup() void {
    var iter = assignedGamepads.valueIterator();
    while (iter.next()) |gp| {
        if (gp.controller) |ctrl| {
            sdl.gameControllerClose(ctrl);
        }
    }
    assignedGamepads.deinit(shared.allocator);

    for (availableGamepads.items) |gp| {
        if (gp.controller) |ctrl| {
            sdl.gameControllerClose(ctrl);
        }
    }
    availableGamepads.deinit(shared.allocator);
}
