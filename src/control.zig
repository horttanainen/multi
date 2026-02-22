const std = @import("std");
const box2d = @import("box2d.zig");
const sdl = @import("zsdl");

const config = @import("config.zig");
const collision = @import("collision.zig");
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
            shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
            shapeDef.filter.maskBits = collision.MASK_DYNAMIC;
            const position = camera.relativePositionForCreating(.{
                .x = x,
                .y = y,
            });
            const spriteUuid = try sprite.createFromImg(
                shared.boxImgSrc,
                .{
                    .x = 1,
                    .y = 1,
                },
                vec.izero,
            );
            const pos = conv.pixel2M(position);
            const bodyDef = box2d.createDynamicBodyDef(pos);
            _ = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");

            delay.action("boxcreate", config.boxCreateDelayMs);
        }
    }
}

pub fn handleGlobalHotkeys() void {
    const currentKeyStates = sdl.getKeyboardState();

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

    if (currentKeyStates[@intFromEnum(sdl.Scancode.e)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.enter() catch |err| {
                std.debug.print("Error entering level editor: {}\n", .{err});
            };
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }
}

pub fn executeAction(playerId: usize, action: controller.GameAction) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        // Ignore input for dead players
        if (p.isDead) return;

        switch (action) {
            .move_left => player.moveLeft(p),
            .move_right => player.moveRight(p),
            .brake => player.brake(p),
            .jump => player.jump(p),
            .shoot => player.shoot(p) catch |err| {
                std.debug.print("Error shooting: {}\n", .{err});
            },
            .rope => player.toggleRope(p) catch |err| {
                std.debug.print("Error toggling rope: {}\n", .{err});
            },
            .aim_left, .aim_right, .aim_up, .aim_down => {},
        }
    }
}

pub fn executeAim(playerId: usize, direction: vec.Vec2) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        // Ignore input for dead players
        if (p.isDead) return;

        player.aim(p, direction);
    }
}

pub fn executeAimRelease(playerId: usize) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        if (p.isDead) return;

        player.aimRelease(p);
    }
}

pub fn executeZoom(playerId: usize) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        if (p.isDead) return;
        player.zoom(p);
    }
}

pub fn executeZoomRelease(playerId: usize) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        if (p.isDead) return;
        player.zoomRelease(p);
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
    if (currentKeyStates[@intFromEnum(sdl.Scancode.e)] == 1) {
        if (!delay.check("leveleditortoggle")) {
            levelEditor.exit();
            delay.action("leveleditortoggle", config.levelEditorToggleDelayMs);
        }
    }
}
