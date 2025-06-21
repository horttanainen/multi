const std = @import("std");
const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl");

const box = @import("box.zig");
const config = @import("config.zig");
const delay = @import("delay.zig");
const camera = @import("camera.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const levelEditor = @import("levelEditor.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");

const leftButtonMask: u32 = 1;
const middleButtonMask: u32 = 1 << 1;
const rightButtonMask: u32 = 1 << 2;

pub fn handleGameMouseInput() !void {
    var x: i32 = 0;
    var y: i32 = 0;
    const currentMouseState: u5 = @intCast(sdl.getMouseState(&x, &y));

    if (currentMouseState & leftButtonMask == 1) {
        if (!delay.check("boxcreate")) {
            var shapeDef = box2d.b2DefaultShapeDef();
            shapeDef.friction = 0.5;
            const bodyDef = box.createDynamicBodyDef(camera.relativePositionForCreating(.{ .x = x, .y = y }));
            _ = try entity.createFromImg(shared.boxImgSrc, shapeDef, bodyDef, "dynamic");

            delay.action("boxcreate", config.boxCreateDelayMs);
        }
    }
}

pub fn handleGameKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();
    if (currentKeyStates[@intFromEnum(sdl.Scancode.lctrl)] == 1 and currentKeyStates[@intFromEnum(sdl.Scancode.r)] == 1) {
        if (!delay.check("reloadLevel")) {
            level.reload() catch |err| {
                std.debug.print("Error reloading level: {!}\n", .{err});
            };
            delay.action("reloadLevel", config.reloadLevelDelayMs);
        }
    }

    var aimDirection = vec.zero;
    if (currentKeyStates[@intFromEnum(sdl.Scancode.left)] == 1) {
        aimDirection = vec.add(aimDirection, vec.west);
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.right)] == 1) {
        aimDirection = vec.add(aimDirection, vec.east);
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.up)] == 1) {
        aimDirection = vec.add(aimDirection, vec.north);
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.down)] == 1) {
        aimDirection = vec.add(aimDirection, vec.south);
    }

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
        if (!delay.check("quitGame")) {
            shared.quitGame = true;
            delay.action("quitGame", config.quitGameDelayMs);
        }
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.l)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.enter() catch |err| {
                std.debug.print("Error entering level editor: {!}\n", .{err});
            };
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 0 and currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 0) {
        player.brake();
    }

    player.aim(aimDirection);
}

pub fn handleLevelEditorMouseInput() void {
    var x: i32 = 0;
    var y: i32 = 0;
    const currentMouseState: u5 = @intCast(sdl.getMouseState(&x, &y));

    if (currentMouseState & leftButtonMask == 1) {
        if (!delay.check("levelEditorClick")) {
            levelEditor.selectEntityAt(camera.relativePositionForCreating(.{ .x = x, .y = y })) catch {
                std.debug.print("Error selecting entity\n", .{});
            };
            delay.action("levelEditorClick", config.levelEditorClickDelayMs);
        }
    }
}

pub fn handleLevelEditorKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();
    if (currentKeyStates[@intFromEnum(sdl.Scancode.a)] == 1) {
        camera.moveLeft();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.d)] == 1) {
        camera.moveRight();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.w)] == 1) {
        camera.moveUp();
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.s)] == 1) {
        camera.moveDown();
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.lctrl)] == 1 and currentKeyStates[@intFromEnum(sdl.Scancode.c)] == 1) {
        if (!delay.check("levelEditorClick")) {
            levelEditor.copySelection();
            delay.action("levelEditorClick", config.levelEditorClickDelayMs);
        }
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.lctrl)] == 1 and currentKeyStates[@intFromEnum(sdl.Scancode.v)] == 1) {
        if (!delay.check("levelEditorClick")) {
            var x: i32 = 0;
            var y: i32 = 0;
            _ = sdl.getMouseState(&x, &y);
            levelEditor.pasteSelection(camera.relativePositionForCreating(.{ .x = x, .y = y })) catch |err| {
                std.debug.print("Error pasteing selection: {!}\n", .{err});
            };
            delay.action("levelEditorClick", config.levelEditorClickDelayMs);
        }
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.escape)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.exit();
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
            delay.action("quitGame", config.quitGameDelayMs);
        }
    }
    if (currentKeyStates[@intFromEnum(sdl.Scancode.l)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.exit();
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }
}
