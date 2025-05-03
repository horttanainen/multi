const sdl = @import("zsdl");

const shared = @import("shared.zig");
const control = @import("control.zig");

pub fn handle() !void {
    // Event handling
    var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
    while (sdl.pollEvent(&event)) {
        switch (event.type) {
            sdl.EventType.quit => {
                shared.quitGame = true;
            },
            else => {},
        }
    }

    if (shared.editingLevel) {
        control.handleLevelEditorKeyboardInput();
        control.handleLevelEditorMouseInput();
    } else {
        control.handleGameKeyboardInput();
        try control.handleGameMouseInput();
    }
}
