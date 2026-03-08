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

pub const LevelEditorGamepadBindings = struct {
    cursorXAxis: sdl.GamepadAxis,
    cursorYAxis: sdl.GamepadAxis,
    moveThreshold: f32,
    configMenuButton: sdl.GamepadButton,
};

pub const defaultEditorBindings = LevelEditorGamepadBindings{
    .cursorXAxis = .leftx,
    .cursorYAxis = .lefty,
    .moveThreshold = MOVEMENT_THRESHOLD,
    .configMenuButton = .y,
};

pub const defaultBindings = GamepadBindings{
    .moveLeftAxis = .leftx,
    .moveRightAxis = .leftx,
    .moveThreshold = MOVEMENT_THRESHOLD,

    .jumpButton = .a,

    .aimXAxis = .rightx,
    .aimYAxis = .righty,
    .aimThreshold = 0.0,

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
    const normalized = std.math.clamp(@as(f32, @floatFromInt(rawValue)) / axisMax, -1.0, 1.0);
    if (@abs(normalized) < stickDeadzone) {
        return 0.0;
    }
    return normalized;
}

fn applyRadialDeadzone(rawX: i16, rawY: i16, deadzone: f32) vec.Vec2 {
    var x = std.math.clamp(@as(f32, @floatFromInt(rawX)) / axisMax, -1.0, 1.0);
    var y = std.math.clamp(@as(f32, @floatFromInt(rawY)) / axisMax, -1.0, 1.0);

    const mag = @sqrt(x * x + y * y);
    if (mag <= deadzone) {
        return .{ .x = 0, .y = 0 };
    }

    // Rescale from [deadzone..1] -> [0..1] to keep fine control near center.
    const legalRange = 1.0 - deadzone;
    const scaledMag = std.math.clamp((mag - deadzone) / legalRange, 0.0, 1.0);
    const invMag = 1.0 / mag;

    x = x * invMag * scaledMag;
    y = y * invMag * scaledMag;

    return .{ .x = x, .y = y };
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

pub fn handleLevelEditor(ctrl: *const controller.Controller) void {
    const bindings = defaultEditorBindings;
    const gp = assignedGamepads.get(ctrl.playerId) orelse return;
    const sdlGp = gp.gamepad orelse return;
    const axisX = normalizeAxis(sdl.getGamepadAxis(sdlGp, bindings.cursorXAxis));
    const axisY = normalizeAxis(sdl.getGamepadAxis(sdlGp, bindings.cursorYAxis));
    if (axisX > bindings.moveThreshold) control.executeLevelEditorAction(.cursor_right);
    if (axisX < -bindings.moveThreshold) control.executeLevelEditorAction(.cursor_left);
    if (axisY > bindings.moveThreshold) control.executeLevelEditorAction(.cursor_down);
    if (axisY < -bindings.moveThreshold) control.executeLevelEditorAction(.cursor_up);

    if (sdl.getGamepadButton(sdlGp, bindings.configMenuButton)) {
        control.executeLevelEditorAction(.open_config_menu);
    }
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

    const rawAimX = sdl.getGamepadAxis(sdlGamepad, bindings.aimXAxis);
    const rawAimY = sdl.getGamepadAxis(sdlGamepad, bindings.aimYAxis);
    const aim = applyRadialDeadzone(rawAimX, rawAimY, stickDeadzone);

    if (@abs(aim.x) > bindings.aimThreshold or @abs(aim.y) > bindings.aimThreshold) {
        const aimDirection = vec.Vec2{ .x = aim.x, .y = -aim.y };
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
