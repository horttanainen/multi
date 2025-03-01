const sdl = @import("zsdl2");

const createCube = @import("object.zig").createCube;

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

pub fn mouseButtonDown(event: sdl.MouseButtonEvent) void {
    createCube(.{ .x = event.x, .y = event.y });
}
