const sdl = @import("sdl.zig");

const state = @import("state.zig");
const control = @import("control.zig");
const controller = @import("controller.zig");
const movement = @import("movement.zig");
const player_input = @import("player_input.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const window = @import("window.zig");
const menu = @import("menu.zig");
const gameMenu = @import("gameMenu.zig");
const backgroundConfigMenu = @import("backgroundConfigMenu.zig");
const delay = @import("delay.zig");
const debug_menu = @import("debug_menu.zig");

pub fn handle() !void {
    menu.beginFrame();
    // Event handling
    var event: sdl.Event = undefined;
    while (sdl.pollEvent(&event)) {
        switch (event.type) {
            sdl.c.SDL_EVENT_KEY_DOWN => {
                if (debug_menu.handleKey(event.key.scancode, event.key.key, event.key.repeat)) continue;
                try menu.handleKey(event.key.scancode, event.key.repeat);
            },
            sdl.EventType.quit => {
                state.quitGame = true;
            },
            sdl.EventType.window_resized => {
                try window.handleResize(event.window.data1, event.window.data2);
                menu.ensureFocusedVisible();
            },
            sdl.EventType.gamepad_added => {
                try gamepad.handleDeviceAdded(event.gdevice.which);
            },
            sdl.EventType.gamepad_removed => {
                gamepad.handleDeviceRemoved(event.gdevice.which);
            },
            else => {},
        }
    }

    movement.clearAllMovementIntents();

    if (state.quitGame) {
        neutralizeGameplayInput();
        return;
    }

    const key_states = sdl.getKeyboardState();
    const menu_blocks_input = menu.blocksGameplayInput(key_states);

    // All menus, including overlays, use the shared input handling.
    if (menu.isOpen()) {
        neutralizeGameplayInput();
        try menu.handleInput(key_states);
        return;
    }

    if (menu_blocks_input) {
        neutralizeGameplayInput();
        return;
    }

    // Start button or Escape key opens the game menu from any mode
    {
        const keys = sdl.getKeyboardState();
        var start_pressed = keys[@intFromEnum(sdl.Scancode.escape)];
        if (!start_pressed) {
            var it = gamepad.assignedGamepads.valueIterator();
            while (it.next()) |gp| {
                const sdlGp = gp.gamepad orelse continue;
                if (sdl.getGamepadButton(sdlGp, .start)) {
                    start_pressed = true;
                    break;
                }
            }
        }
        if (start_pressed and !delay.check("menuToggle")) {
            gameMenu.openGameMenu();
            delay.action("menuToggle", 400);
            neutralizeGameplayInput();
            return;
        }
    }

    if (state.editingBackground) {
        neutralizeGameplayInput();

        // Y/triangle button or T key opens background config menu
        {
            var it = gamepad.assignedGamepads.valueIterator();
            while (it.next()) |gp| {
                const sdlGp = gp.gamepad orelse continue;
                if (sdl.getGamepadButton(sdlGp, .y) and !delay.check("menuToggle")) {
                    backgroundConfigMenu.open();
                    delay.action("menuToggle", 400);
                    return;
                }
            }
        }
        const keys = sdl.getKeyboardState();
        if (keys[@intFromEnum(sdl.Scancode.t)] and !delay.check("menuToggle")) {
            backgroundConfigMenu.open();
            delay.action("menuToggle", 400);
        }
        return;
    }

    if (state.editingLevel) {
        neutralizeGameplayInput();

        var it = controller.controllers.iterator();
        while (it.next()) |kv| {
            const ctrl = kv.value_ptr;
            switch (ctrl.inputType) {
                .keyboard => keyboard.handleLevelEditor(ctrl),
                .gamepad => gamepad.handleLevelEditor(ctrl),
            }
        }
        control.handleLevelEditorMouseInput();
    } else {
        control.handleGlobalHotkeys();

        var it = controller.controllers.iterator();
        while (it.next()) |kv| {
            const ctrl = kv.value_ptr;
            switch (ctrl.inputType) {
                .keyboard => keyboard.handle(ctrl),
                .gamepad => gamepad.handle(ctrl),
            }
        }

        control.applyAllPlayerInputs();
        try control.handleGameMouseInput();
    }
}

fn neutralizeGameplayInput() void {
    player_input.neutralizeAll();
    control.applyAllPlayerInputs();
}
