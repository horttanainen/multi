const sdl = @import("sdl.zig");

const state = @import("state.zig");
const control = @import("control.zig");
const controller = @import("controller.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const window = @import("window.zig");

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

    if (state.editingLevel) {
        control.handleLevelEditorKeyboardInput();
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
