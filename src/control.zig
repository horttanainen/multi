const std = @import("std");
const box2d = @import("box2d.zig");
const sdl = @import("zsdl");

const config = @import("config.zig");
const delay = @import("delay.zig");
const camera = @import("camera.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const levelEditor = @import("leveleditor.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");
const conv = @import("conversion.zig");
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");

const leftButtonMask: u32 = 1;
const middleButtonMask: u32 = 1 << 1;
const rightButtonMask: u32 = 1 << 2;

pub fn handleGameMouseInput() !void {
    var x: i32 = 0;
    var y: i32 = 0;
    const currentMouseState: u5 = @intCast(sdl.getMouseState(&x, &y));

    if (currentMouseState & leftButtonMask == 1) {
        if (!delay.check("boxcreate")) {
            var shapeDef = box2d.c.b2DefaultShapeDef();
            shapeDef.friction = 0.5;
            shapeDef.filter.categoryBits = config.CATEGORY_DYNAMIC;
            shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_PLAYER | config.CATEGORY_PROJECTILE | config.CATEGORY_DYNAMIC | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;
            const position = camera.relativePositionForCreating(.{
                .x = x,
                .y = y,
            });
            const s = try sprite.createFromImg(
                shared.boxImgSrc,
                .{
                    .x = 1,
                    .y = 1,
                },
                vec.izero,
            );
            const pos = conv.pixel2MPos(
                position.x,
                position.y,
                s.sizeM.x,
                s.sizeM.y,
            );
            const bodyDef = box2d.createDynamicBodyDef(pos);
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "dynamic");

            delay.action("boxcreate", config.boxCreateDelayMs);
        }
    }
}

pub fn handleGameKeyboardInput() void {
    const currentKeyStates = sdl.getKeyboardState();

    // Global controls
    if (currentKeyStates[@intFromEnum(sdl.Scancode.lctrl)] == 1 and
        currentKeyStates[@intFromEnum(sdl.Scancode.r)] == 1)
    {
        if (!delay.check("reloadLevel")) {
            level.reload() catch |err| {
                std.debug.print("Error reloading level: {}\n", .{err});
            };
            delay.action("reloadLevel", config.reloadLevelDelayMs);
        }
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.escape)] == 1) {
        if (!delay.check("quitGame")) {
            shared.quitGame = true;
            delay.action("quitGame", config.quitGameDelayMs);
        }
    }

    // NOTE: Level editor toggle moved from 'L' to 'E' to avoid conflict with Player 1 controls
    if (currentKeyStates[@intFromEnum(sdl.Scancode.e)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.enter() catch |err| {
                std.debug.print("Error entering level editor: {}\n", .{err});
            };
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }

    // Per-player controls using controller abstraction
    for (controller.controllers.items) |*ctrl| {
        const maybePlayer = player.players.getPtr(ctrl.playerId);

        if (maybePlayer) |p| {
            handlePlayerInput(p, ctrl, currentKeyStates);
        }
    }
}

fn handlePlayerInput(p: *player.Player, ctrl: *const controller.Controller, keyStates: []const u8) void {
    // Movement
    const movingLeft = controller.isActionActive(ctrl, keyStates, .move_left);
    const movingRight = controller.isActionActive(ctrl, keyStates, .move_right);

    if (movingLeft) {
        player.moveLeft(p);
    }
    if (movingRight) {
        player.moveRight(p);
    }
    if (!movingLeft and !movingRight) {
        player.brake(p);
    }

    // Jump
    if (controller.isActionActive(ctrl, keyStates, .jump)) {
        player.jump(p);
    }

    // Aiming
    var aimDirection = vec.zero;
    if (controller.isActionActive(ctrl, keyStates, .aim_left)) {
        aimDirection = vec.add(aimDirection, vec.west);
    }
    if (controller.isActionActive(ctrl, keyStates, .aim_right)) {
        aimDirection = vec.add(aimDirection, vec.east);
    }
    if (controller.isActionActive(ctrl, keyStates, .aim_up)) {
        aimDirection = vec.add(aimDirection, vec.north);
    }
    if (controller.isActionActive(ctrl, keyStates, .aim_down)) {
        aimDirection = vec.add(aimDirection, vec.south);
    }
    player.aim(p, aimDirection);

    // Shoot
    if (controller.isActionActive(ctrl, keyStates, .shoot)) {
        player.shoot(p) catch |err| {
            std.debug.print("Error shooting: {}\n", .{err});
        };
    }
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
                std.debug.print("Error pasteing selection: {}\n", .{err});
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
    // NOTE: Changed from 'L' to 'E' to avoid conflict with Player 1 controls
    if (currentKeyStates[@intFromEnum(sdl.Scancode.e)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.exit();
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }
}
