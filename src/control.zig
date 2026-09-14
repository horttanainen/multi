const std = @import("std");
const box2d = @import("box2d.zig");
const sdl = @import("sdl.zig");

const config = @import("config.zig");
const collision = @import("collision.zig");
const delay = @import("delay.zig");
const camera = @import("camera.zig");
const state = @import("state.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const levelEditor = @import("level_editor.zig");
const levelEditorGrid = @import("level_editor_grid.zig");
const level = @import("level.zig");
const movement = @import("movement.zig");
const vec = @import("vector.zig");
const conv = @import("conversion.zig");
const sprite = @import("sprite.zig");
const controller = @import("controller.zig");
const data = @import("data.zig");
const damage = @import("damage.zig");
const gameMenu = @import("gameMenu.zig");
const rubble = @import("rubble.zig");
const cursor = @import("cursor.zig");
const spritePicker = @import("spritePicker.zig");
const player_input = @import("player_input.zig");

const leftButtonMask: u32 = 1;
const middleButtonMask: u32 = 1 << 1;
const rightButtonMask: u32 = 1 << 2;
const spawnedBoxHealth: f32 = 100;
const spawnedBoxRubbleSeed: u64 = 0xB07B07;

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
            const spawnedBox = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");
            const rubbleTemplateId = rubble.prepare(spriteUuid, spawnedBoxRubbleSeed) catch |err| {
                _ = entity.remove(spawnedBox.bodyId);
                return err;
            };
            damage.register(spawnedBox.bodyId, .{
                .model = .{ .health = .{
                    .current = spawnedBoxHealth,
                    .maximum = spawnedBoxHealth,
                } },
                .onDestroyed = .{ .spawn_rubble = rubbleTemplateId },
            }) catch |err| {
                _ = entity.remove(spawnedBox.bodyId);
                return err;
            };

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
}

pub fn applyAllPlayerInputs() void {
    for (player_input.playerInputs.keys()) |playerId| {
        applyPlayerInput(playerId);
    }
}

pub fn applyFixedStepPlayerInputs() void {
    for (player_input.playerInputs.keys(), player_input.playerInputs.values()) |playerId, *inputState| {
        const shootButton = inputState.buttons.get(.shoot);
        const shouldShoot = switch (movement.mechanism) {
            .liero => shootButton.held,
            .towerfall => shootButton.released,
        };
        if (!shouldShoot) continue;

        const p = player.players.get(playerId) orelse {
            std.log.warn("control.applyFixedStepPlayerInputs: player {d} is missing", .{playerId});
            continue;
        };
        const direction = if (movement.mechanism == .towerfall) inputState.releasedAimDirection else p.aimDirection;
        player.shoot(playerId, direction) catch |err| {
            std.log.err("control.applyFixedStepPlayerInputs: player {d} could not shoot: {}", .{ playerId, err });
        };
    }
}

fn updateTowerfallAimState(playerId: usize, inputState: player_input.PlayerInput) void {
    const p = player.players.getPtr(playerId) orelse {
        std.log.warn("control.updateTowerfallAimState: player {d} is missing", .{playerId});
        return;
    };
    if (p.isDead) return;
    const shootButton = inputState.buttons.get(.shoot);
    const hasDirection = !vec.equals(inputState.aimDirection, vec.zero);
    // applyPlayerInput just looked up this input; no input collection changes
    // occur here. Remember the resolved default facing along with explicit aim.
    const liveInput = player_input.playerInputs.getPtr(playerId).?;
    if (shootButton.held) {
        // A press can stay pending across render polls before the fixed step.
        // Once aiming has begun, neutral stick input keeps the resolved direction.
        const needsDefaultAim = shootButton.pendingPressed and vec.equals(inputState.heldAimDirection, vec.zero);
        if (hasDirection or needsDefaultAim or !p.isAiming) player.aim(p, inputState.aimDirection);
        liveInput.heldAimDirection = p.aimDirection;
        return;
    }
    if (shootButton.pendingReleased) {
        const direction = if (vec.equals(inputState.releasedAimDirection, vec.zero)) p.aimDirection else inputState.releasedAimDirection;
        player.aim(p, direction);
        liveInput.releasedAimDirection = p.aimDirection;
        player.aimRelease(p);
        return;
    }
    if (hasDirection) player.aim(p, inputState.aimDirection);
    player.aimRelease(p);
}

pub fn applyPlayerInput(playerId: usize) void {
    const inputState = player_input.playerInputs.get(playerId) orelse {
        std.log.warn("control.applyPlayerInput: input state is missing for player {d}", .{playerId});
        return;
    };

    const direction = movement.locomotionDirection(playerId);
    if (direction.x < 0) {
        executeAction(playerId, .move_left);
    } else if (direction.x > 0) {
        executeAction(playerId, .move_right);
    } else {
        executeAction(playerId, .brake);
    }

    if (movement.mechanism == .liero and inputState.buttons.get(.jump).held) executeAction(playerId, .jump);

    if (movement.mechanism == .towerfall) {
        updateTowerfallAimState(playerId, inputState);
    } else if (inputState.aimDirection.x == 0 and inputState.aimDirection.y == 0) {
        executeAimRelease(playerId);
    } else {
        executeAim(playerId, inputState.aimDirection);
    }

    if (inputState.buttons.get(.zoom).held) {
        executeZoom(playerId);
    } else {
        executeZoomRelease(playerId);
    }
    if (inputState.buttons.get(.rope).held) executeAction(playerId, .rope);
    if (inputState.buttons.get(.sprayPaint).held) executeAction(playerId, .spray_paint);
    if (inputState.buttons.get(.weaponNext).held) executeAction(playerId, .weapon_next);
    if (inputState.buttons.get(.weaponPrev).held) executeAction(playerId, .weapon_prev);
}

pub fn executeAction(playerId: usize, action: controller.GameAction) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        // Ignore input for dead players
        if (p.isDead) return;

        switch (action) {
            .move_left => movement.moveLeft(playerId),
            .move_right => movement.moveRight(playerId),
            .brake => movement.brake(playerId),
            .jump => movement.jump(playerId),
            .shoot => player.shoot(playerId, p.aimDirection) catch |err| {
                std.log.err("control.executeAction: player {d} could not shoot: {}", .{ playerId, err });
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
        .undo => {
            if (!delay.check("levelEditorClick")) {
                levelEditor.undo() catch |err| {
                    std.debug.print("Error undoing level editor action: {}\n", .{err});
                };
                delay.action("levelEditorClick", config.levelEditorClickDelayMs);
            }
        },
        .redo => {
            if (!delay.check("levelEditorClick")) {
                levelEditor.redo() catch |err| {
                    std.debug.print("Error redoing level editor action: {}\n", .{err});
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
        .open_context_menu => {
            if (!delay.check("menuToggle")) {
                levelEditor.openContextMenu();
                delay.action("menuToggle", 300);
            }
        },
        .open_sprite_picker => {
            if (!delay.check("pickerOpen")) {
                levelEditor.prepareSpritePlacement();
                spritePicker.open() catch |err| {
                    std.debug.print("Error opening sprite picker: {}\n", .{err});
                };
                delay.action("pickerOpen", 300);
            }
        },
        .confirm => {
            if (!delay.check("levelEditorConfirm")) {
                confirmLevelEditorAction();
                delay.action("levelEditorConfirm", 300);
            }
        },
        .deactivate_sprite => {
            levelEditor.cancelCurrentAction();
        },
        .toggle_snap => {
            if (!delay.check("levelEditorSnapToggle")) {
                levelEditorGrid.toggleSnap();
                delay.action("levelEditorSnapToggle", config.levelEditorClickDelayMs);
            }
        },
        .scale_left => scaleSelectedEntity(.left),
        .scale_right => scaleSelectedEntity(.right),
        .scale_up => scaleSelectedEntity(.up),
        .scale_down => scaleSelectedEntity(.down),
    }
}

fn confirmLevelEditorAction() void {
    if (!cursor.hasPendingSprite()) {
        _ = levelEditor.selectEntityAtCursor();
        return;
    }

    const imgPath = cursor.getPendingImgPath() orelse {
        std.log.warn("confirmLevelEditorAction: pending sprite has no image path", .{});
        return;
    };

    const pos = cursor.getWorldPos();
    levelEditor.placeSprite(imgPath, cursor.getPendingScale(), pos) catch |err| {
        std.debug.print("Error placing sprite: {}\n", .{err});
    };
}

fn scaleSelectedEntity(direction: levelEditor.FreeformScaleDirection) void {
    if (cursor.hasPendingSprite()) return;
    if (delay.check("levelEditorScaleEdit")) return;

    levelEditor.scaleSelectedEntityFreeform(direction) catch |err| {
        std.log.warn("scaleSelectedEntity: failed to scale selected entity: {}", .{err});
    };
    delay.action("levelEditorScaleEdit", config.levelEditorScaleRepeatDelayMs);
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
