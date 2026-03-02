const std = @import("std");
const sdl = @import("sdl.zig");

const allocator = @import("allocator.zig").allocator;
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const control = @import("control.zig");
const vec = @import("vector.zig");

pub const stickDeadzone: f32 = 0.15;
pub const TRIGGER_THRESHOLD: f32 = 0.1;
pub const MOVEMENT_THRESHOLD: f32 = 0.2;
pub const axisMax: f32 = 32767.0;

pub const GamepadState = struct {
    gamepad: ?*sdl.Gamepad,
    instanceId: sdl.c.SDL_JoystickID,
};

pub const GamepadBindings = struct {
    // Movement
    moveLeftAxis: sdl.GamepadAxis,
    moveRightAxis: sdl.GamepadAxis,
    moveThreshold: f32,

    // Jump
    jumpButton: sdl.GamepadButton,

    // Aiming
    aimXAxis: sdl.GamepadAxis,
    aimYAxis: sdl.GamepadAxis,
    aimThreshold: f32,

    // Shooting
    shootAxis: sdl.GamepadAxis,
    shootThreshold: f32,

    // Rope
    ropeButton: sdl.GamepadButton,

    // Spray paint
    sprayPaintButton: sdl.GamepadButton,

    // Weapon switching
    weaponNextButton: sdl.GamepadButton,
    weaponPrevButton: sdl.GamepadButton,
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

    .sprayPaintButton = .y,

    .weaponNextButton = .dpad_right,
    .weaponPrevButton = .dpad_left,
};

pub var availableGamepads: std.ArrayList(GamepadState) = .{};

pub var assignedGamepads: std.AutoHashMapUnmanaged(usize, GamepadState) = .{};

fn openGamepad(instanceId: sdl.c.SDL_JoystickID) !void {
    const gp = try sdl.openGamepad(instanceId);

    const gamepadState = GamepadState{
        .gamepad = gp,
        .instanceId = instanceId,
    };

    try availableGamepads.append(allocator, gamepadState);
    std.debug.print("Gamepad {d} detected and added to available list\n", .{instanceId});
}

pub fn handleDeviceAdded(instanceId: sdl.c.SDL_JoystickID) !void {
    openGamepad(instanceId) catch |err| {
        std.debug.print("Failed to open gamepad {d}: {}\n", .{ instanceId, err });
        return;
    };

    controller.recalculateControllers() catch |err| {
        std.debug.print("Failed to recalculate controllers: {}\n", .{err});
    };
}

pub fn handleDeviceRemoved(instanceId: sdl.c.SDL_JoystickID) void {
    var iter = assignedGamepads.iterator();
    var playerIdToRemove: ?usize = null;
    while (iter.next()) |entry| {
        if (entry.value_ptr.instanceId == instanceId) {
            if (entry.value_ptr.gamepad) |gp| {
                sdl.closeGamepad(gp);
            }
            playerIdToRemove = entry.key_ptr.*;
            std.debug.print("Gamepad {d} disconnected from player {d}\n", .{ instanceId, entry.key_ptr.* });
            break;
        }
    }
    if (playerIdToRemove) |playerId| {
        _ = assignedGamepads.remove(playerId);
    }

    for (availableGamepads.items, 0..) |gp, i| {
        if (gp.instanceId == instanceId) {
            if (gp.gamepad) |ctrl| {
                sdl.closeGamepad(ctrl);
            }
            _ = availableGamepads.swapRemove(i);
            std.debug.print("Gamepad {d} removed from available list\n", .{instanceId});
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

    assignedGamepads.put(allocator, playerId, gamepadState) catch {
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
    const sdlGamepad = gp.gamepad orelse return;

    const moveAxis = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.moveLeftAxis));
    if (moveAxis < -bindings.moveThreshold) {
        control.executeAction(ctrl.playerId, .move_left);
    } else if (moveAxis > bindings.moveThreshold) {
        control.executeAction(ctrl.playerId, .move_right);
    } else {
        control.executeAction(ctrl.playerId, .brake);
    }

    if (sdl.getGamepadButton(sdlGamepad, bindings.jumpButton)) {
        control.executeAction(ctrl.playerId, .jump);
    }

    const aimX = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.aimXAxis));
    const aimY = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.aimYAxis));

    if (@abs(aimX) > bindings.aimThreshold or @abs(aimY) > bindings.aimThreshold) {
        const aimDirection = vec.Vec2{ .x = aimX, .y = -aimY };
        control.executeAim(ctrl.playerId, aimDirection);
    } else {
        control.executeAimRelease(ctrl.playerId);
    }

    const shootValue = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.shootAxis));
    if (shootValue > bindings.shootThreshold) {
        control.executeAction(ctrl.playerId, .shoot);
    }

    const zoomValue = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, .triggerleft));
    if (zoomValue > TRIGGER_THRESHOLD) {
        control.executeZoom(ctrl.playerId);
    } else {
        control.executeZoomRelease(ctrl.playerId);
    }

    if (sdl.getGamepadButton(sdlGamepad, bindings.ropeButton)) {
        control.executeAction(ctrl.playerId, .rope);
    }

    if (sdl.getGamepadButton(sdlGamepad, bindings.sprayPaintButton)) {
        control.executeAction(ctrl.playerId, .spray_paint);
    }

    if (sdl.getGamepadButton(sdlGamepad, bindings.weaponNextButton)) {
        control.executeAction(ctrl.playerId, .weapon_next);
    }
    if (sdl.getGamepadButton(sdlGamepad, bindings.weaponPrevButton)) {
        control.executeAction(ctrl.playerId, .weapon_prev);
    }
}

pub fn cleanup() void {
    var iter = assignedGamepads.valueIterator();
    while (iter.next()) |gp| {
        if (gp.gamepad) |ctrl| {
            sdl.closeGamepad(ctrl);
        }
    }
    assignedGamepads.deinit(allocator);

    for (availableGamepads.items) |gp| {
        if (gp.gamepad) |ctrl| {
            sdl.closeGamepad(ctrl);
        }
    }
    availableGamepads.deinit(allocator);
}
