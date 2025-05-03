const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl");

const delay = @import("delay.zig");
const camera = @import("camera.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const levelEditor = @import("levelEditor.zig");

const leftButtonMask: u32 = 1;
const middleButtonMask: u32 = 1 << 1;
const rightButtonMask: u32 = 1 << 2;

pub fn handleGameMouseInput() !void {
    var x: i32 = 0;
    var y: i32 = 0;
    const currentMouseState: u5 = @intCast(sdl.getMouseState(&x, &y));

    if (currentMouseState & leftButtonMask == 1) {
        if (!delay.check("boxcreate")) {
            const resources = try shared.getResources();
            var shapeDef = box2d.b2DefaultShapeDef();
            shapeDef.friction = 0.5;
            try entity.createFromImg(camera.relativePositionForCreating(.{ .x = x, .y = y }), resources.boxSurface, shapeDef);

            try delay.action("boxcreate", 200);
        }
    }
}

pub fn handleGameKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();
    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 1) {
        player.moveLeft();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 1) {
        player.moveRight();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.space)] == 1) {
        player.jump();
        player.allowJump = false;
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.escape)] == 1) {
        shared.quitGame = true;
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.l)] == 1) {
        shared.editingLevel = true;
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 0 and currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 0) {
        player.brake();
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.space)] == 0) {
        player.allowJump = true;
    }
}

pub fn handleLevelEditorMouseInput() void {
    var x: i32 = 0;
    var y: i32 = 0;
    const currentMouseStates = sdl.getMouseState(&x, &y);

    //discard for now
    _ = currentMouseStates;
}

pub fn handleLevelEditorKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();
    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 1) {
        levelEditor.moveLeft();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.l)] == 1) {
        shared.editingLevel = false;
    }
}
