const sdl = @import("zsdl2");

const entity = @import("entity.zig");

pub fn keyDown(event: sdl.KeyboardEvent) bool {
    var running = true;
    switch (event.keysym.scancode) {
        sdl.Scancode.escape => {
            running = false;
        },
        else => {},
    }
    return running;
}

pub fn mouseButtonDown(event: sdl.MouseButtonEvent) !void {
    try entity.createBox(.{ .x = event.x, .y = event.y });
}
