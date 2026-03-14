const sdl = @import("sdl.zig");

const state = @import("state.zig");
const control = @import("control.zig");
const controller = @import("controller.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const window = @import("window.zig");
const menu = @import("menu.zig");
const gameMenu = @import("gameMenu.zig");
const backgroundConfigMenu = @import("backgroundConfigMenu.zig");
const delay = @import("delay.zig");

pub fn handle() !void {
    // Event handling
    var event: sdl.Event = undefined;
    while (sdl.pollEvent(&event)) {
        switch (event.type) {
            sdl.EventType.quit => {
                state.quitGame = true;
            },
            sdl.EventType.window_resized => {
                try window.handleResize(event.window.data1, event.window.data2);
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

    // Any open menu (game menu or config menu) takes priority
    if (menu.isOpen()) {
        try menu.handleInput();
        return;
    }

    // Gamepad Start button opens the game menu from any mode
    {
        var it = gamepad.assignedGamepads.valueIterator();
        while (it.next()) |gp| {
            const sdlGp = gp.gamepad orelse continue;
            if (sdl.getGamepadButton(sdlGp, .start) and !delay.check("menuToggle")) {
                gameMenu.openGameMenu();
                delay.action("menuToggle", 400);
                return;
            }
        }
    }

    if (state.editingBackground) {
        // Y/triangle button or T key opens background config menu
        {
            var it = gamepad.assignedGamepads.valueIterator();
            while (it.next()) |gp| {
                const sdlGp = gp.gamepad orelse continue;
                if (sdl.getGamepadButton(sdlGp, .y) and !delay.check("bgConfigToggle")) {
                    backgroundConfigMenu.open();
                    delay.action("bgConfigToggle", 400);
                    return;
                }
            }
        }
        const keys = sdl.getKeyboardState();
        if (keys[@intFromEnum(sdl.Scancode.t)] and !delay.check("bgConfigToggle")) {
            backgroundConfigMenu.open();
            delay.action("bgConfigToggle", 400);
        }
        return;
    }

    if (state.editingLevel) {
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

        try control.handleGameMouseInput();
    }
}
