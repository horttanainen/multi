const std = @import("std");
const box2d = @import("box2d.zig");
const sdl = @import("sdl.zig");
const tex = @import("texture.zig");

const config = @import("config.zig");
const collision = @import("collision.zig");
const delay = @import("delay.zig");
const camera = @import("camera.zig");
const state = @import("state.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const levelEditor = @import("level_editor.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");
const conv = @import("conversion.zig");
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const data = @import("data.zig");
const gameMenu = @import("gameMenu.zig");
const cursor = @import("cursor.zig");
const levelConfigMenu = @import("levelConfigMenu.zig");

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
            shapeDef.material.friction = 0.5;
            shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
            shapeDef.filter.maskBits = collision.MASK_DYNAMIC;
            const position = camera.relativePositionForCreating(.{
                .x = x,
                .y = y,
            });
            const spriteUuid = data.createSpriteFrom("box") orelse return;
            const pos = conv.pixel2M(position);
            const bodyDef = box2d.createDynamicBodyDef(pos);
            _ = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");

            delay.action("boxcreate", config.boxCreateDelayMs);
        }
    }
}

pub fn handleGlobalHotkeys() void {
    const currentKeyStates = sdl.getKeyboardState();

    if (currentKeyStates[@intFromEnum(sdl.Scancode.lctrl)] and
        currentKeyStates[@intFromEnum(sdl.Scancode.r)])
    {
        if (!delay.check("reloadLevel")) {
            level.reload() catch |err| {
                std.debug.print("Error reloading level: {}\n", .{err});
            };
            delay.action("reloadLevel", config.reloadLevelDelayMs);
        }
    }

    if (currentKeyStates[@intFromEnum(sdl.Scancode.escape)]) {
        if (!delay.check("menuToggle")) {
            gameMenu.openGameMenu();
            delay.action("menuToggle", 400);
        }
    }

    // § key - dump atlas texture to disk (try both grave and nonusbackslash for Nordic keyboards)
    if (currentKeyStates[@intFromEnum(sdl.Scancode.grave)] or
        currentKeyStates[@intFromEnum(sdl.Scancode.nonusbackslash)])
    {
        if (!delay.check("atlasDump")) {
            tex.saveAtlasToDisk("atlas_dump.png");
            delay.action("atlasDump", 1000);
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
            .spray_paint => player.sprayPaint(p) catch |err| {
                std.debug.print("Error spray painting: {}\n", .{err});
            },
            .weapon_next => player.cycleWeapon(p, 1),
            .weapon_prev => player.cycleWeapon(p, -1),
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

pub fn executeLevelEditorAction(action: controller.LevelEditorAction) void {
    switch (action) {
        .cursor_left => cursor.moveLeft(),
        .cursor_right => cursor.moveRight(),
        .cursor_up => cursor.moveUp(),
        .cursor_down => cursor.moveDown(),
        .copy => {
            if (!delay.check("levelEditorClick")) {
                levelEditor.copySelection();
                delay.action("levelEditorClick", config.levelEditorClickDelayMs);
            }
        },
        .paste => {
            if (!delay.check("levelEditorClick")) {
                var x: i32 = 0;
                var y: i32 = 0;
                _ = sdl.getMouseState(&x, &y);
                levelEditor.pasteSelection(camera.relativePositionForCreating(.{ .x = x, .y = y })) catch |err| {
                    std.debug.print("Error pasting selection: {}\n", .{err});
                };
                delay.action("levelEditorClick", config.levelEditorClickDelayMs);
            }
        },
        .open_menu => {
            if (!delay.check("menuToggle")) {
                gameMenu.openGameMenu();
                delay.action("menuToggle", 400);
            }
        },
        .open_config_menu => {
            if (!delay.check("levelConfigToggle")) {
                const cfg = levelEditor.getConfig() catch levelEditor.Config{ .gravity = 10.0, .pixelsPerMeter = 80 };
                levelConfigMenu.open(cfg.gravity, cfg.pixelsPerMeter);
                delay.action("levelConfigToggle", 300);
            }
        },
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

