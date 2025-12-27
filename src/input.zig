const sdl = @import("zsdl");

const shared = @import("shared.zig");
const control = @import("control.zig");
const controller = @import("controller.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");

pub fn handle() !void {
    // Event handling
    var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
    while (sdl.pollEvent(&event)) {
        switch (event.type) {
            sdl.EventType.quit => {
                shared.quitGame = true;
            },
            sdl.EventType.controllerdeviceadded => {
                try gamepad.handleDeviceAdded(event.controllerdevice.which);
            },
            sdl.EventType.controllerdeviceremoved => {
                gamepad.handleDeviceRemoved(event.controllerdevice.which);
            },
            else => {},
        }
    }

    if (shared.editingLevel) {
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
