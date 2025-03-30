const sdl = @import("zsdl2");

const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

pub fn handleKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();
    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 1) {
        player.moveLeft();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 1) {
        player.moveRight();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.space)] == 1) {
        player.jump();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.escape)] == 1) {
        shared.quitGame = true;
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 0 and currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 0) {
        player.brake();
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.space)] == 0) {
        player.allowJump = true;
    }
}

pub fn mouseButtonDown(event: sdl.MouseButtonEvent) !void {
    try entity.createBox(.{ .x = event.x, .y = event.y });
}
