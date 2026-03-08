const std = @import("std");
const sdl = @import("sdl.zig");

const allocator = @import("allocator.zig").allocator;
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

pub const MultiKey = struct {
    modifier: sdl.Scancode,
    key: sdl.Scancode,
};

pub const LevelEditorKeyBindings = struct {
    cursorLeft: sdl.Scancode,
    cursorRight: sdl.Scancode,
    cursorUp: sdl.Scancode,
    cursorDown: sdl.Scancode,
    copy: MultiKey,
    paste: MultiKey,
    openMenu: sdl.Scancode,
    openSpritePicker: sdl.Scancode,
    placeSprite: sdl.Scancode,
    deactivateSprite: sdl.Scancode,
};

pub const defaultEditorBindings = LevelEditorKeyBindings{
    .cursorLeft = .a,
    .cursorRight = .d,
    .cursorUp = .w,
    .cursorDown = .s,
    .copy = .{ .modifier = .lctrl, .key = .c_ },
    .paste = .{ .modifier = .lctrl, .key = .v },
    .openMenu = .escape,
    .openSpritePicker = .e,
    .placeSprite = .return_,
    .deactivateSprite = .q,
};

pub var keyboardBindings: std.ArrayList(KeyboardBindings) = .{};

pub fn init() !void {
    try keyboardBindings.append(allocator, player2Bindings);
    try keyboardBindings.append(allocator, player1Bindings);
}

pub fn cleanup() void {
    keyboardBindings.deinit(allocator);
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

pub fn handleLevelEditor(_: *const controller.Controller) void {
    const bindings = defaultEditorBindings;
    const keyStates = sdl.getKeyboardState();

    if (key(keyStates, bindings.cursorLeft)) control.executeLevelEditorAction(.cursor_left);
    if (key(keyStates, bindings.cursorRight)) control.executeLevelEditorAction(.cursor_right);
    if (key(keyStates, bindings.cursorUp)) control.executeLevelEditorAction(.cursor_up);
    if (key(keyStates, bindings.cursorDown)) control.executeLevelEditorAction(.cursor_down);

    if (key(keyStates, bindings.copy.modifier) and key(keyStates, bindings.copy.key)) {
        control.executeLevelEditorAction(.copy);
    }
    if (key(keyStates, bindings.paste.modifier) and key(keyStates, bindings.paste.key)) {
        control.executeLevelEditorAction(.paste);
    }
    if (key(keyStates, bindings.openMenu)) {
        control.executeLevelEditorAction(.open_menu);
    }
    if (key(keyStates, bindings.openSpritePicker)) {
        control.executeLevelEditorAction(.open_sprite_picker);
    }
    if (key(keyStates, bindings.placeSprite)) {
        control.executeLevelEditorAction(.place_sprite);
    }
    if (key(keyStates, bindings.deactivateSprite)) {
        control.executeLevelEditorAction(.deactivate_sprite);
    }
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
