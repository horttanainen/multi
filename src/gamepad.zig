const std = @import("std");
const sdl = @import("sdl.zig");
const config = @import("config.zig");
const delay = @import("delay.zig");

const allocator = @import("allocator.zig").allocator;
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const control = @import("control.zig");
const player_input = @import("player_input.zig");
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
    moveXAxis: sdl.GamepadAxis,
    moveYAxis: sdl.GamepadAxis,
    moveThreshold: f32,

    // Platforming
    jumpButton: sdl.GamepadButton,
    dodgeButton: sdl.GamepadButton,

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
    openPickerButton: sdl.GamepadButton,
    confirmButton: sdl.GamepadButton,
    deactivateButton: sdl.GamepadButton,
    snapToggleButton: sdl.GamepadButton,
    scaleLeftButton: sdl.GamepadButton,
    scaleRightButton: sdl.GamepadButton,
    scaleUpButton: sdl.GamepadButton,
    scaleDownButton: sdl.GamepadButton,
};

pub const defaultEditorBindings = LevelEditorGamepadBindings{
    .cursorXAxis = .leftx,
    .cursorYAxis = .lefty,
    .moveThreshold = MOVEMENT_THRESHOLD,
    .configMenuButton = .y,
    .openPickerButton = .x,
    .confirmButton = .a,
    .deactivateButton = .b,
    .snapToggleButton = .rightshoulder,
    .scaleLeftButton = .dpad_left,
    .scaleRightButton = .dpad_right,
    .scaleUpButton = .dpad_up,
    .scaleDownButton = .dpad_down,
};

pub const defaultBindings = GamepadBindings{
    .moveXAxis = .leftx,
    .moveYAxis = .lefty,
    .moveThreshold = MOVEMENT_THRESHOLD,

    .jumpButton = .a,
    .dodgeButton = .b,

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

pub var availableGamepads: std.ArrayList(GamepadState) = .empty;

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

fn digitalAxis(value: f32, threshold: f32) f32 {
    if (value < -threshold) return -1;
    if (value > threshold) return 1;
    return 0;
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
        control.executeLevelEditorAction(.open_context_menu);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.openPickerButton) and !delay.check("pickerOpen")) {
        control.executeLevelEditorAction(.open_sprite_picker);
        delay.action("pickerOpen", 300);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.confirmButton) and !delay.check("levelEditorClick")) {
        control.executeLevelEditorAction(.confirm);
        delay.action("levelEditorClick", config.levelEditorClickDelayMs);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.deactivateButton) and !delay.check("levelEditorClick")) {
        control.executeLevelEditorAction(.deactivate_sprite);
        delay.action("levelEditorClick", config.levelEditorClickDelayMs);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.snapToggleButton)) {
        control.executeLevelEditorAction(.toggle_snap);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.scaleLeftButton)) {
        control.executeLevelEditorAction(.scale_left);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.scaleRightButton)) {
        control.executeLevelEditorAction(.scale_right);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.scaleUpButton)) {
        control.executeLevelEditorAction(.scale_up);
    }
    if (sdl.getGamepadButton(sdlGp, bindings.scaleDownButton)) {
        control.executeLevelEditorAction(.scale_down);
    }
}

pub fn handle(ctrl: *const controller.Controller) void {
    const bindings = ctrl.gamepadBindings orelse {
        std.log.warn("gamepad.handle: gamepad bindings are missing for player {d}", .{ctrl.playerId});
        return;
    };

    const gp = assignedGamepads.get(ctrl.playerId) orelse {
        std.log.warn("gamepad.handle: assigned gamepad is missing for player {d}", .{ctrl.playerId});
        player_input.neutralize(ctrl.playerId);
        return;
    };
    const sdlGamepad = gp.gamepad orelse {
        std.log.warn("gamepad.handle: SDL gamepad is missing for player {d}", .{ctrl.playerId});
        player_input.neutralize(ctrl.playerId);
        return;
    };

    const moveX = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.moveXAxis));
    const moveY = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.moveYAxis));
    const movementDirection: vec.Vec2 = .{
        .x = digitalAxis(moveX, bindings.moveThreshold),
        .y = -digitalAxis(moveY, bindings.moveThreshold),
    };

    const rawAimX = sdl.getGamepadAxis(sdlGamepad, bindings.aimXAxis);
    const rawAimY = sdl.getGamepadAxis(sdlGamepad, bindings.aimYAxis);
    const aim = applyRadialDeadzone(rawAimX, rawAimY, stickDeadzone);

    const aimDirection: vec.Vec2 = if (@abs(aim.x) > bindings.aimThreshold or @abs(aim.y) > bindings.aimThreshold)
        .{ .x = aim.x, .y = -aim.y }
    else
        vec.zero;

    const shootValue = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, bindings.shootAxis));
    const zoomValue = normalizeAxis(sdl.getGamepadAxis(sdlGamepad, .triggerleft));

    var sample: player_input.Sample = .{
        .movementDirection = movementDirection,
        .aimDirection = aimDirection,
    };
    sample.buttons.set(.jump, sdl.getGamepadButton(sdlGamepad, bindings.jumpButton));
    sample.buttons.set(.dodge, sdl.getGamepadButton(sdlGamepad, bindings.dodgeButton));
    sample.buttons.set(.shoot, shootValue > bindings.shootThreshold);
    sample.buttons.set(.zoom, zoomValue > TRIGGER_THRESHOLD);
    sample.buttons.set(.rope, sdl.getGamepadButton(sdlGamepad, bindings.ropeButton));
    sample.buttons.set(.sprayPaint, sdl.getGamepadButton(sdlGamepad, bindings.sprayPaintButton));
    sample.buttons.set(.weaponNext, sdl.getGamepadButton(sdlGamepad, bindings.weaponNextButton));
    sample.buttons.set(.weaponPrev, sdl.getGamepadButton(sdlGamepad, bindings.weaponPrevButton));
    player_input.submit(ctrl.playerId, sample);
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
