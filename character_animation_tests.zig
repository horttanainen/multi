const std = @import("std");
const animation = @import("src/character_animation.zig");
const vec = @import("src/vector.zig");
const debug_menu = @import("src/debug_menu.zig");
const sdl = @import("src/sdl.zig");
const menu = @import("src/menu.zig");
const state = @import("src/state.zig");
const delay = @import("src/delay.zig");
const allocator = @import("src/allocator.zig");
const data = @import("src/data.zig");
const fs = @import("src/fs.zig");
const runtime = @import("src/runtime.zig");
const box2d = @import("src/box2d.zig");
const collision = @import("src/collision.zig");
const player = @import("src/player.zig");
const movement = @import("src/movement.zig");
const player_input = @import("src/player_input.zig");
const gamepad = @import("src/gamepad.zig");
const sprite = @import("src/sprite.zig");
const weapon = @import("src/weapon.zig");
const control = @import("src/control.zig");
const entity = @import("src/entity.zig");
const camera = @import("src/camera.zig");
const time = @import("src/time.zig");
const audio = @import("src/audio.zig");
const conv = @import("src/conversion.zig");
const pool = @import("src/pool.zig");
const character_art = @import("src/character_art.zig");

const rig_json = @embedFile("character_rigs/humanoid.json");
const locomotion_json = @embedFile("character_locomotion/run.json");
const walls_json = @embedFile("character_actions/walls.json");
const aiming_json = @embedFile("character_actions/aiming.json");
const actions_json = @embedFile("character_actions/airborne.json");
const motion_json = @embedFile("character_motions/run_reference.json");
const original_motion_json = @embedFile("tests/fixtures/character_run_reference_v1.json");
const dense_motion_json = @embedFile("character_motions/run_reference_dense.json");
const reference_json = @embedFile("tests/fixtures/character_run_poses.json");
const art_json = @embedFile("character_art/curb_rat_v1/manifest.json");

fn loadArt(rig: animation.Rig) !character_art.Pack {
    var detail: data.CharacterAssetDiagnostic = .{};
    return character_art.prepare(try data.parseCharacterArtData(std.testing.allocator, art_json, &detail), rig, &detail);
}

test "art files use shared strict decoding and own their data after input is freed" {
    runtime.init(std.testing.io);
    var set = try load();
    defer set.arena.deinit();
    var detail: data.CharacterAssetDiagnostic = .{};
    const files = parsed: {
        const bytes = try std.testing.allocator.dupe(u8, art_json);
        defer std.testing.allocator.free(bytes);
        break :parsed try data.parseCharacterArtData(std.testing.allocator, bytes, &detail);
    };
    var pack = try character_art.prepare(files, set.rig, &detail);
    defer character_art.destroy(&pack);
    try std.testing.expectEqualStrings("curb_rat_v1", pack.id);
    try std.testing.expectEqual(@as(usize, 10), pack.parts.len);
    try std.testing.expectEqual(@as(usize, 15), pack.bindings.len);
    try std.testing.expectEqualStrings("character_art/curb_rat_v1/export/head_skin.svg", pack.parts[0].paths[0]);
    var disk = try data.loadCharacterArtData(std.testing.allocator, &detail);
    defer disk.arena.deinit();
    try std.testing.expectEqualStrings(pack.id, disk.manifest.id);
}

test "invalid art candidates preserve the installed pack and report named fields" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var set = try load();
    defer set.arena.deinit();
    character_art.install(try loadArt(set.rig));
    defer character_art.cleanup();
    const original = character_art.assets.?.parts.ptr;
    const cases = [_][3][]const u8{
        .{ "\"schema_version\": 1", "\"schema_version\": 2", "schema" },
        .{ "\"rig\": \"humanoid_v1\"", "\"rig\": \"unknown\"", "rig" },
        .{ "\"attachment\": \"weapon_hand\"", "\"attachment\": \"grapple_hand\"", "weapon_hand.attachment" },
        .{ "\"meters_per_pixel\": 0.003225", "\"meters_per_pixel\": -1", "parts.head" },
        .{ "\"meters_per_pixel\": 0.003225", "\"meters_per_pixel\": \"0.003225\"", "parts.head.meters_per_pixel" },
        .{ "\"meters_per_pixel\": 0.003225", "\"meters_per_pixel\": 1e999", "finite" },
        .{ "\"meters_per_pixel\": 0.003225", "\"misspelled_scale\": 0.003225", "meters_per_pixel" },
        .{ "\"far_skin_multiplier\": 0.65", "\"far_skin_multiplier\": 2", "far_skin_multiplier" },
        .{ "\"export/head_skin.svg\"", "\"../head.svg\"", "relative layer path" },
        .{ "\"part\": \"forearm\"", "\"part\": \"missing\"", "unknown part" },
        .{ "\"role\": \"skin\"", "\"role\": \"fixed\"", "skin then fixed" },
        .{ "\"holstered_weapon\"", "\"missing_binding\"", "unknown binding" },
        .{ "\"near_foot\"", "\"near_shin\"", "duplicate binding" },
        .{ "\"length_mode\": \"rig_bone\"", "\"length_mode\": \"typo\"", "length_mode" },
        .{ "\"meters_per_pixel\": 0.005", "\"meters_per_pixel\": 0.007", "length differs" },
    };
    for (cases) |case| {
        var detail: data.CharacterAssetDiagnostic = .{};
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, art_json, case[0], case[1]);
        defer std.testing.allocator.free(bytes);
        const files = data.parseCharacterArtData(std.testing.allocator, bytes, &detail) catch |err| {
            try std.testing.expectEqual(error.InvalidCharacterAsset, err);
            try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], case[2]) != null);
            try std.testing.expect(original == character_art.assets.?.parts.ptr);
            continue;
        };
        try std.testing.expectError(error.InvalidCharacterAsset, character_art.prepare(files, set.rig, &detail));
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], case[2]) != null);
        try std.testing.expect(original == character_art.assets.?.parts.ptr);
    }
}

test "art SVGs decode in SDL with matching canvases neutral skin and visible fixed details" {
    var set = try load();
    defer set.arena.deinit();
    var pack = try loadArt(set.rig);
    defer character_art.destroy(&pack);
    for (pack.parts) |part| {
        var canvas: [2]c_int = undefined;
        for (part.paths, 0..) |path, layer| {
            const terminated = try std.testing.allocator.dupeZ(u8, path);
            defer std.testing.allocator.free(terminated);
            const surface = try sdl.image.load(terminated);
            defer sdl.destroySurface(surface);
            if (layer == 0) canvas = .{ surface.w, surface.h };
            try std.testing.expectEqual(canvas, [2]c_int{ surface.w, surface.h });
            var visible: usize = 0;
            var transparent: usize = 0;
            var y: c_int = 0;
            while (y < surface.h) : (y += 1) {
                var x: c_int = 0;
                while (x < surface.w) : (x += 1) {
                    var color: sdl.Color = undefined;
                    try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(surface, x, y, &color.r, &color.g, &color.b, &color.a));
                    if (color.a == 0) {
                        transparent += 1;
                        continue;
                    }
                    visible += 1;
                    if (layer != 0) continue;
                    try std.testing.expectEqual(color.r, color.g);
                    try std.testing.expectEqual(color.g, color.b);
                }
            }
            try std.testing.expect(transparent > 0);
            if (layer == 1) try std.testing.expect(visible > 0);
        }
    }
}

test "art follows the canonical weapon attachment when the rig assigns it to the left hand" {
    var set = try load();
    defer set.arena.deinit();
    set.rig.attachments.getPtr("weapon_hand").?.joint = .left_hand;
    var pack = try loadArt(set.rig);
    defer character_art.destroy(&pack);
    try std.testing.expectEqual(animation.Joint.left_hand, pack.weapon_joint);
    for ([_]bool{ false, true }) |facing| {
        const frame = animation.solveAimedPose(&set, animation.evaluatePose(&set, 0, .neutral), vec.zero, facing, vec.east, 0, null);
        const joints = character_art.worldJoints(set.rig, frame);
        for (pack.bindings, 0..) |binding, index| {
            const placed = character_art.placePart(&pack, index, joints, frame, true);
            if (binding.anchor != .left_hand) {
                try std.testing.expect(placed.part != pack.grip_part);
                continue;
            }
            try std.testing.expectEqual(pack.grip_part, placed.part);
            try nearPoint(frame.weapon.position, placed.position, 0.000001);
            try std.testing.expectEqual(character_art.isFar(.left, facing), placed.far);
        }
    }
}

test "interpolated holster and unholster artwork keeps the hand on its solved wrist" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const old_alpha = time.alpha;
    defer time.alpha = old_alpha;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    var pack = try loadArt(animation.assets.?.rig);
    defer character_art.destroy(&pack);
    const anim_state = animation.states.getPtr(7).?;
    anim_state.aim_weight = 0;
    anim_state.previous_aim_weight = 0;
    for ([_]bool{ false, true }) |facing| {
        anim_state.facing_right = facing;
        for ([_][2]f32{ .{ 0, 1 }, .{ 1, 0 } }) |transition| {
            anim_state.previous_stow_weight = transition[0];
            anim_state.stow_weight = transition[1];
            for ([_]f64{ 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 }) |alpha| {
                time.alpha = alpha;
                const frame = animation.playerFrame(7, .render, null).?;
                const expected = std.math.lerp(transition[0], transition[1], @as(f32, @floatCast(alpha)));
                try std.testing.expectApproxEqAbs(expected, frame.weapon_stow_weight, 0.000001);
                const joints = character_art.worldJoints(animation.assets.?.rig, frame);
                for (pack.bindings, 0..) |binding, index| {
                    if (binding.anchor != pack.weapon_joint) continue;
                    const placed = character_art.placePart(&pack, index, joints, frame, true);
                    if (expected == 0) {
                        try std.testing.expectEqual(pack.grip_part, placed.part);
                        try nearPoint(frame.weapon.position, placed.position, 0.000001);
                        continue;
                    }
                    try std.testing.expectEqual(binding.part, placed.part);
                    try nearPoint(joints[@intFromEnum(binding.anchor)], placed.position, 0.000001);
                    try std.testing.expect(vec.magnitude(vec.subtract(frame.weapon.position, placed.position)) > 0.001);
                }
            }
        }
    }
}

// Exercise the shared integer sprite placement. World-anchor truncation (<1px),
// the rotated difference of two rounded source points (<=sqrt(2)px) and the
// integer placedPoint result (<1px) together permit less than 3.5px per axis.
fn placedArtPoint(part: data.CharacterArtPart, placed: character_art.PlacedPart, source: [2]f32) vec.Vec2 {
    var visual: sprite.Sprite = undefined;
    visual.sizeP = .{ .x = 240, .y = 240 }; // Canvas width cancels around the mirrored pivot.
    const scale = part.meters_per_pixel * conv.met2pix;
    const pivot: vec.IVec2 = .{ .x = @intFromFloat(@round(part.pivot[0] * scale)), .y = @intFromFloat(@round(part.pivot[1] * scale)) };
    const pixel: vec.IVec2 = .{ .x = @intFromFloat(@round(source[0] * scale)), .y = @intFromFloat(@round(source[1] * scale)) };
    const placement = sprite.placeAtAnchor(visual, pivot, conv.m2Pixel(vec.toBox2d(placed.position)), placed.angle, !placed.facing_right);
    return conv.pixel2M(sprite.placedPoint(visual, placement, pixel));
}

test "art feet follow solved heel and toe contacts throughout running on both facings and scales" {
    var set = try load();
    defer set.arena.deinit();
    var pack = try loadArt(set.rig);
    defer character_art.destroy(&pack);
    const previous_scale = conv.met2pix;
    defer conv.met2pix = previous_scale;
    for ([_]f32{ 40, 80, 160 }) |scale| {
        conv.met2pix = scale;
        for ([_]bool{ false, true }) |facing| {
            for (0..120) |sample| {
                const frame: animation.FramePose = .{ .pose = animation.evaluatePose(&set, @as(f64, @floatFromInt(sample)) / 120, .run), .body = .{ .x = 2.1, .y = -1.7 }, .facing_right = facing, .weapon = .{ .position = vec.zero, .angle = 0 }, .weapon_facing_right = facing };
                const joints = character_art.worldJoints(set.rig, frame);
                for (pack.bindings, 0..) |binding, index| {
                    const definition = pack.parts[binding.part].definition;
                    if (definition.contacts == null) continue;
                    const contacts = definition.contacts.?;
                    const placed = character_art.placePart(&pack, index, joints, frame, false);
                    try nearPoint(joints[@intFromEnum(binding.axis[0])], placedArtPoint(definition, placed, contacts.heel), 3.5 / scale);
                    try nearPoint(joints[@intFromEnum(binding.axis[1])], placedArtPoint(definition, placed, contacts.toe), 3.5 / scale);
                }
            }
        }
    }
}

test "art grip follows the actual weapon attachment and anatomical depth through turning and holstering" {
    var set = try load();
    defer set.arena.deinit();
    var pack = try loadArt(set.rig);
    defer character_art.destroy(&pack);
    for ([_]animation.Joint{ .right_hand, .left_hand }) |weapon_joint| {
        pack.weapon_joint = weapon_joint;
        for ([_]bool{ false, true }) |facing| {
            for ([_]bool{ false, true }) |weapon_facing| {
                for ([_]f32{ -2.8, -1.5, 0, 1.4, 3.1 }) |angle| {
                    var frame: animation.FramePose = .{ .pose = animation.evaluatePose(&set, 0, .neutral), .body = .{ .x = 2, .y = 3 }, .facing_right = facing, .weapon = .{ .position = .{ .x = 2.8, .y = 1.9 }, .angle = angle }, .weapon_facing_right = weapon_facing };
                    const joints = character_art.worldJoints(set.rig, frame);
                    var grips: usize = 0;
                    for (pack.bindings, 0..) |binding, index| {
                        const placed = character_art.placePart(&pack, index, joints, frame, true);
                        try std.testing.expectEqual(character_art.isFar(binding.depth, facing), placed.far);
                        if (binding.anchor != weapon_joint) {
                            try std.testing.expect(placed.part != pack.grip_part);
                            continue;
                        }
                        grips += 1;
                        try std.testing.expectEqual(pack.grip_part, placed.part);
                        try nearPoint(frame.weapon.position, placed.position, 0.000001);
                        try std.testing.expectApproxEqAbs(@as(f32, 0), @sin(placed.angle - angle), 0.000001);
                        try std.testing.expectApproxEqAbs(@as(f32, 1), @cos(placed.angle - angle), 0.000001);
                        try std.testing.expectEqual(weapon_facing, placed.facing_right);
                        frame.weapon_stowed = true;
                        const stowed = character_art.placePart(&pack, index, joints, frame, true);
                        try std.testing.expectEqual(binding.part, stowed.part);
                        try nearPoint(joints[@intFromEnum(weapon_joint)], stowed.position, 0.000001);
                        frame.weapon_stowed = false;
                    }
                    try std.testing.expectEqual(@as(usize, 1), grips);
                }
            }
        }
    }
    try std.testing.expectEqual(sprite.Color{ .r = 33, .g = 65, .b = 130 }, character_art.skinColor(.{ .r = 50, .g = 100, .b = 200 }, 0.65));
}

test "shared debug menu cycles artwork overlay sprites and stick without changing locomotion" {
    resetMenuInput();
    defer resetMenuInput();
    const previous = animation.view;
    defer animation.view = previous;
    const playback = animation.playback;
    animation.view = .artwork;
    for ([_]animation.View{ .overlay, .sprites, .stick, .artwork }) |expected| {
        debug_menu.open();
        try menu.handleKey(sdl.c.SDL_SCANCODE_V, false);
        try std.testing.expectEqual(expected, animation.view);
        try std.testing.expectEqual(playback, animation.playback);
        try std.testing.expect(!menu.isOpen());
        menu.beginFrame();
    }
}

test "directional profiles preserve defaults and allow aiming independent of movement mechanism" {
    runtime.init(std.testing.io);
    const previous = player_input.directionSettings;
    defer player_input.directionSettings = previous;
    for ([_][]const u8{ "movements/towerfall_keep.json", "movements/liero_default.json", "movements/liero_theater.json" }) |path| {
        var profile = try data.loadMovementData(path);
        const expected_aim: data.AimMode = if (profile.mechanism == .towerfall) .eight_directions else .free;
        player_input.configure(profile);
        try std.testing.expectEqual(data.MovementInputMode.axis_thresholds, player_input.directionSettings.movementMode);
        try std.testing.expectEqual(expected_aim, player_input.directionSettings.aimMode);
        // Files without the new block still load with the mechanism defaults.
        profile.input = null;
        player_input.configure(profile);
        try std.testing.expectEqual(expected_aim, player_input.directionSettings.aimMode);
        profile.input = .{ .movementMode = .eight_directions, .aimMode = if (expected_aim == .free) .eight_directions else .free };
        player_input.configure(profile);
        try std.testing.expectEqual(profile.input.?, player_input.directionSettings);
        player_input.directionSettings = .{ .aimMode = expected_aim };
        player_input.resetDirectionSettings();
        try std.testing.expectEqual(profile.input.?, player_input.directionSettings);
        // Loading a different profile discards debug overrides.
        player_input.configure(try data.loadMovementData(path));
        try std.testing.expectEqual(expected_aim, player_input.directionSettings.aimMode);
        try std.testing.expectEqual(data.MovementInputMode.axis_thresholds, player_input.directionSettings.movementMode);
    }
    const parsed = try std.json.parseFromSlice(data.DirectionalInputData, std.testing.allocator,
        \\{"movementMode":"eight_directions","aimMode":"free"}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(data.AimMode.free, parsed.value.aimMode);
    try std.testing.expectEqual(data.MovementInputMode.eight_directions, parsed.value.movementMode);
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(data.DirectionalInputData, std.testing.allocator,
        \\{"aimMode":"typo"}
    , .{}));
}

test "eight sectors keep exact cardinals full diagonal movement and equal boundaries at all strengths" {
    const expected = [_]vec.Vec2{ vec.east, .{ .x = 1, .y = 1 }, vec.north, .{ .x = -1, .y = 1 }, vec.west, .{ .x = -1, .y = -1 }, vec.south, .{ .x = 1, .y = -1 } };
    try std.testing.expectEqual(vec.zero, player_input.eightDirection(vec.zero));
    for (expected, 0..) |direction, index| {
        const center = @as(f32, @floatFromInt(index)) * std.math.pi / 4.0;
        for ([_]f32{ 0.01, 0.3, 1 }) |strength| {
            for ([_]f32{ -22.49, 0, 22.49 }) |offset| {
                const angle = center + offset * std.math.pi / 180.0;
                try std.testing.expectEqual(direction, player_input.eightDirection(.{ .x = @cos(angle) * strength, .y = @sin(angle) * strength }));
            }
            const outside = center + 22.51 * std.math.pi / 180.0;
            try std.testing.expectEqual(expected[(index + 1) % 8], player_input.eightDirection(.{ .x = @cos(outside) * strength, .y = @sin(outside) * strength }));
        }
    }
}

test "stick sectors provide a down region while free aim retains the original angle and Liero uses its own stick" {
    const previous = player_input.directionSettings;
    defer player_input.directionSettings = previous;
    runtime.init(std.testing.io);
    try movement.configure(try data.loadMovementData("movements/towerfall_keep.json"));
    try player_input.register(77);
    defer _ = player_input.playerInputs.swapRemove(77);
    const move: gamepad.StickAxes = .{ .x = 8000, .y = 30000 };
    const other: gamepad.StickAxes = .{ .x = -30000, .y = -10000 };
    player_input.directionSettings = .{ .movementMode = .axis_thresholds, .aimMode = .free };
    var sample = gamepad.sampleSticks(gamepad.defaultBindings, move, other);
    try std.testing.expectEqual(vec.Vec2{ .x = 1, .y = -1 }, sample.movementDirection);
    player_input.directionSettings.movementMode = .eight_directions;
    sample = gamepad.sampleSticks(gamepad.defaultBindings, move, other);
    try std.testing.expectEqual(vec.south, sample.movementDirection);
    player_input.submit(77, sample);
    const free = player_input.playerInputs.get(77).?.aimDirection;
    try nearPoint(vec.normalize(.{ .x = 8000, .y = -30000 }), vec.normalize(free), 0.000001);
    player_input.directionSettings.aimMode = .eight_directions;
    player_input.submit(77, sample);
    const snapped = player_input.playerInputs.get(77).?.aimDirection;
    try nearPoint(vec.south, vec.normalize(snapped), 0.000001);
    try std.testing.expectApproxEqAbs(vec.magnitude(free), vec.magnitude(snapped), 0.000001);
    for ([_]gamepad.StickAxes{ .{ .x = 0, .y = 0 }, .{ .x = 6000, .y = 0 } }) |neutral| {
        sample = gamepad.sampleSticks(gamepad.defaultBindings, neutral, other);
        player_input.submit(77, sample);
        try std.testing.expectEqual(vec.zero, sample.movementDirection);
        try std.testing.expectEqual(vec.zero, player_input.playerInputs.get(77).?.aimDirection);
    }
    // A diagonal just outside the radial deadzone still gives full run intent.
    sample = gamepad.sampleSticks(gamepad.defaultBindings, .{ .x = 5000, .y = -5000 }, other);
    try std.testing.expectEqual(vec.Vec2{ .x = 1, .y = 1 }, sample.movementDirection);
    try movement.configure(try data.loadMovementData("movements/liero_default.json"));
    sample = gamepad.sampleSticks(gamepad.defaultBindings, move, other);
    player_input.submit(77, sample);
    try std.testing.expectEqual(vec.Vec2{ .x = 1, .y = -1 }, sample.movementDirection);
    try nearPoint(vec.normalize(.{ .x = -30000, .y = 10000 }), vec.normalize(player_input.playerInputs.get(77).?.aimDirection), 0.000001);
    player_input.directionSettings.aimMode = .eight_directions;
    player_input.submit(77, sample);
    try nearPoint(vec.west, vec.normalize(player_input.playerInputs.get(77).?.aimDirection), 0.000001);
}

test "debug input choices use shared menu shortcuts and restore the loaded profile" {
    resetMenuInput();
    defer resetMenuInput();
    const previous = player_input.directionSettings;
    defer player_input.directionSettings = previous;
    runtime.init(std.testing.io);
    const profile = try data.loadMovementData("movements/towerfall_keep.json");
    player_input.configure(profile);
    var keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    debug_menu.open();
    try menu.handleKey(sdl.c.SDL_SCANCODE_F, false);
    try std.testing.expectEqual(data.AimMode.free, player_input.directionSettings.aimMode);
    try std.testing.expect(!menu.isOpen());
    keys[sdl.c.SDL_SCANCODE_F] = true;
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    menu.beginFrame();
    keys[sdl.c.SDL_SCANCODE_F] = false;
    try std.testing.expect(!menu.blocksGameplayInput(&keys));
    debug_menu.open();
    try menu.handleKey(sdl.c.SDL_SCANCODE_M, false);
    try std.testing.expectEqual(data.MovementInputMode.eight_directions, player_input.directionSettings.movementMode);
    debug_menu.open();
    try menu.handleKey(sdl.c.SDL_SCANCODE_C, false);
    try std.testing.expectEqual(profile.input.?, player_input.directionSettings);
    const previous_editing = state.editingLevel;
    defer state.editingLevel = previous_editing;
    state.editingLevel = true;
    debug_menu.open();
    try menu.handleKey(sdl.c.SDL_SCANCODE_F, false);
    try menu.handleKey(sdl.c.SDL_SCANCODE_M, false);
    try std.testing.expectEqual(profile.input.?, player_input.directionSettings);
}

fn load() !animation.Assets {
    var detail: animation.Diagnostic = .{};
    return animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, actions_json, aiming_json, walls_json, &detail), &detail);
}

fn replaceFromJson(rig_bytes: []const u8, motion_bytes: []const u8, detail: *data.CharacterAssetDiagnostic) !void {
    try animation.replaceAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, locomotion_json, actions_json, aiming_json, walls_json, detail), detail);
}

test "bounded file reading loads the complete motion and rejects oversized or missing files" {
    runtime.init(std.testing.io);
    const path = "character_motions/run_reference_dense.json";
    const bytes = try fs.readFileAlloc(path, std.testing.allocator, dense_motion_json.len + 1);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 16384);
    try std.testing.expectEqualSlices(u8, dense_motion_json, bytes);
    try std.testing.expectError(error.StreamTooLong, fs.readFileAlloc(path, std.testing.allocator, dense_motion_json.len - 1));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [256]u8 = undefined;
    const missing = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/missing.json", .{temp.sub_path});
    try std.testing.expectError(error.FileNotFound, fs.readFileAlloc(missing, std.testing.allocator, 1024));
}

test "decoded character data owns its strings and curves after the source buffers are freed" {
    var detail: data.CharacterAssetDiagnostic = .{};
    var files = parsed: {
        const rig_bytes = try std.testing.allocator.dupe(u8, rig_json);
        defer std.testing.allocator.free(rig_bytes);
        const motion_bytes = try std.testing.allocator.dupe(u8, motion_json);
        defer std.testing.allocator.free(motion_bytes);
        const actions_bytes = try std.testing.allocator.dupe(u8, actions_json);
        defer std.testing.allocator.free(actions_bytes);
        break :parsed try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, locomotion_json, actions_bytes, aiming_json, walls_json, &detail);
    };
    defer files.arena.deinit();
    try std.testing.expectEqualStrings("humanoid_v1", files.rig.id);
    try std.testing.expectEqualStrings(files.rig.id, files.motion.rig_id);
    try std.testing.expectEqualStrings("run_reference_v1", files.motion.id);
    try std.testing.expectEqualStrings("weapon_hand", files.rig.attachments[0].id);
    for (files.motion.tracks) |track| {
        try std.testing.expect(track.keys.len >= 2);
        try std.testing.expectEqual(@as(f32, 1), track.keys[track.keys.len - 1].phase);
    }
    try std.testing.expectEqualStrings("airborne_v2", files.actions.id);
    try std.testing.expectEqualStrings("jump_reference_v1", files.actions.jump.id);
    try std.testing.expectEqual(@as(f32, 1), files.actions.landing.tracks[0].keys[2].phase);
}

test "data file loading transfers ownership to runtime assets and reproduces the reference poses" {
    runtime.init(std.testing.io);
    var detail: data.CharacterAssetDiagnostic = .{};
    var loaded = try animation.prepareAssets(try data.loadCharacterAnimationData(std.testing.allocator, &detail), &detail);
    defer loaded.arena.deinit();
    var reference = try load();
    defer reference.arena.deinit();
    try std.testing.expectEqualStrings(reference.rig.id, loaded.rig.id);
    for (0..12) |index| {
        const phase = @as(f64, @floatFromInt(index)) / 12;
        const expected = animation.evaluatePose(&reference, phase, .run);
        const actual = animation.evaluatePose(&loaded, phase, .run);
        for (expected.joints, actual.joints) |a, b| try nearPoint(a, b, 0.000001);
    }
}

fn nearPoint(expected: vec.Vec2, actual: vec.Vec2, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}

fn resetMenuInput() void {
    menu.close();
    menu.beginFrame();
    const released: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    _ = menu.blocksGameplayInput(&released);
    delay.cleanup();
    delay.delayedActions = .init(allocator.allocator);
}

var menu_action_count: usize = 0;

fn countMenuAction() !void {
    menu_action_count += 1;
}

var ordinary_menu_items = [_]menu.Item{
    .{ .label = "First", .kind = .{ .button = countMenuAction } },
    .{ .label = "Second", .kind = .{ .button = countMenuAction } },
};

fn openOrdinaryMenu() !void {
    menu.open(&ordinary_menu_items, .{});
}

test "debug prefix uses shared menu activation and consumes the chosen key until release" {
    resetMenuInput();
    defer resetMenuInput();
    const previous_zoom = animation.close_view;
    defer animation.close_view = previous_zoom;
    var keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    try std.testing.expect(!debug_menu.handleKey(sdl.c.SDL_SCANCODE_Z, 'z', false));
    try menu.handleKey(sdl.c.SDL_SCANCODE_Z, false);
    try std.testing.expectEqual(previous_zoom, animation.close_view);
    // A logical section character also works with an unrelated scancode.
    try std.testing.expect(debug_menu.handleKey(sdl.c.SDL_SCANCODE_UNKNOWN, 0x00a7, false));
    try std.testing.expect(menu.isOpen());
    try std.testing.expect(!menu.hidesScene());
    menu.beginFrame();
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    try menu.handleKey(sdl.c.SDL_SCANCODE_Z, false);
    try std.testing.expectEqual(!previous_zoom, animation.close_view);
    try std.testing.expect(!menu.isOpen());
    keys[sdl.c.SDL_SCANCODE_Z] = true;
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    menu.beginFrame();
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    keys[sdl.c.SDL_SCANCODE_Z] = false;
    try std.testing.expect(!menu.blocksGameplayInput(&keys));
}

test "held debug prefix chords activate once and suppress held gameplay letters" {
    resetMenuInput();
    defer resetMenuInput();
    const previous_diagnostics = animation.show_diagnostics;
    defer animation.show_diagnostics = previous_diagnostics;
    var keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_NONUSBACKSLASH, 0, false);
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_NONUSBACKSLASH, 0, true);
    try std.testing.expect(menu.isOpen());
    keys[sdl.c.SDL_SCANCODE_NONUSBACKSLASH] = true;
    keys[sdl.c.SDL_SCANCODE_D] = true;
    try menu.handleKey(sdl.c.SDL_SCANCODE_D, false);
    try std.testing.expectEqual(!previous_diagnostics, animation.show_diagnostics);
    try std.testing.expect(!menu.isOpen());
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    menu.beginFrame();
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_NONUSBACKSLASH, 0, true);
    try menu.handleKey(sdl.c.SDL_SCANCODE_D, true);
    try std.testing.expect(!menu.isOpen());
    try std.testing.expectEqual(!previous_diagnostics, animation.show_diagnostics);
    keys[sdl.c.SDL_SCANCODE_NONUSBACKSLASH] = false;
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    keys[sdl.c.SDL_SCANCODE_D] = false;
    try std.testing.expect(!menu.blocksGameplayInput(&keys));
}

test "debug cancellation consumes the event batch and respects existing menus and editor restrictions" {
    resetMenuInput();
    defer resetMenuInput();
    const previous_editing = state.editingLevel;
    defer state.editingLevel = previous_editing;
    const keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_GRAVE, '`', false);
    try menu.handleKey(sdl.c.SDL_SCANCODE_ESCAPE, false);
    try std.testing.expect(!menu.isOpen());
    try std.testing.expect(menu.blocksGameplayInput(&keys));
    menu.beginFrame();
    try std.testing.expect(!menu.blocksGameplayInput(&keys));
    menu.open(&ordinary_menu_items, .{});
    menu.setFocusedIndex(1);
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_GRAVE, '`', false);
    try std.testing.expect(menu.hidesScene());
    try std.testing.expectEqual(@as(usize, 1), menu.focusedIndex());
    menu.close();
    state.editingLevel = true;
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_GRAVE, '`', false);
    try std.testing.expectEqual(@as(usize, 9), menu.focusedIndex()); // Only atlas export is visible.
    const previous_zoom = animation.close_view;
    try menu.handleKey(sdl.c.SDL_SCANCODE_Z, false);
    try std.testing.expectEqual(previous_zoom, animation.close_view);
    try std.testing.expect(menu.isOpen());
    _ = debug_menu.handleKey(sdl.c.SDL_SCANCODE_GRAVE, '`', false);
    try std.testing.expect(!menu.isOpen());
}

test "ordinary menus retain arrow navigation, Enter activation, and modal presentation" {
    resetMenuInput();
    defer resetMenuInput();
    menu_action_count = 0;
    var keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    menu.open(&ordinary_menu_items, .{});
    try std.testing.expect(menu.hidesScene());
    menu.beginFrame();
    keys[sdl.c.SDL_SCANCODE_DOWN] = true;
    try menu.handleInput(&keys);
    try std.testing.expectEqual(@as(usize, 1), menu.focusedIndex());
    keys[sdl.c.SDL_SCANCODE_DOWN] = false;
    keys[sdl.c.SDL_SCANCODE_RETURN] = true;
    menu.beginFrame();
    try menu.handleInput(&keys);
    try std.testing.expectEqual(@as(usize, 1), menu_action_count);
    try std.testing.expect(menu.isOpen()); // Normal buttons do not automatically close.
    menu.beginFrame();
    try menu.handleKey(sdl.c.SDL_SCANCODE_ESCAPE, false);
    try std.testing.expect(!menu.isOpen());
    try std.testing.expect(menu.blocksGameplayInput(&keys));
}

test "shared shortcuts respect disabled and hidden items and do not become WASD navigation" {
    resetMenuInput();
    defer resetMenuInput();
    menu_action_count = 0;
    var items = [_]menu.Item{
        .{ .label = "Disabled", .shortcut = sdl.c.SDL_SCANCODE_D, .disabled = true, .kind = .{ .button = countMenuAction } },
        .{ .label = "Hidden", .shortcut = sdl.c.SDL_SCANCODE_H, .hidden = true, .kind = .{ .button = countMenuAction } },
        .{ .label = "Select", .shortcut = sdl.c.SDL_SCANCODE_S, .kind = .{ .button = countMenuAction } },
    };
    menu.open(&items, .{});
    try menu.handleKey(sdl.c.SDL_SCANCODE_D, false);
    try menu.handleKey(sdl.c.SDL_SCANCODE_H, false);
    try std.testing.expectEqual(@as(usize, 0), menu_action_count);
    try menu.handleKey(sdl.c.SDL_SCANCODE_S, false);
    try std.testing.expectEqual(@as(usize, 1), menu_action_count);
    try std.testing.expectEqual(@as(usize, 2), menu.focusedIndex());
    menu.beginFrame();
    try menu.handleKey(sdl.c.SDL_SCANCODE_S, true);
    var keys: [sdl.c.SDL_SCANCODE_COUNT]bool = @splat(false);
    keys[sdl.c.SDL_SCANCODE_S] = true;
    try menu.handleInput(&keys);
    try std.testing.expectEqual(@as(usize, 1), menu_action_count);
    try std.testing.expectEqual(@as(usize, 2), menu.focusedIndex());
}

test "navigation restores overlay options and automatic close preserves a callback's new menu" {
    resetMenuInput();
    defer resetMenuInput();
    var overlay_items = [_]menu.Item{
        .{ .label = "Open ordinary menu", .shortcut = sdl.c.SDL_SCANCODE_O, .kind = .{ .button = openOrdinaryMenu } },
    };
    menu.open(&ordinary_menu_items, .{});
    menu.setFocusedIndex(1);
    menu.push(&overlay_items, .{ .overlay = true, .close_on_activate = true, .item_height = 40 });
    try std.testing.expect(!menu.hidesScene());
    menu.push(&ordinary_menu_items, .{});
    try std.testing.expect(menu.hidesScene());
    try menu.back();
    try std.testing.expect(!menu.hidesScene());
    try menu.handleKey(sdl.c.SDL_SCANCODE_O, false);
    try std.testing.expect(menu.isOpen());
    try std.testing.expect(menu.hidesScene());
    try std.testing.expectEqual(@as(usize, 0), menu.focusedIndex());
    // Replacing from the callback starts a fresh navigation stack.
    try menu.back();
    try std.testing.expect(!menu.isOpen());
}

test "character IK retains segment lengths at reachable, coincident, and unreachable targets" {
    for ([_][2]f32{ .{ 0.46, 0.46 }, .{ 0.29, 0.26 }, .{ 0.1, 0.8 }, .{ 5, 0.001 }, .{ 0.001, 5 }, .{ 0.001, 0.001 }, .{ 5, 5 } }) |lengths| {
        for ([_][2]f32{ .{ 0.001, std.math.pi - 0.001 }, .{ 0.2, 2.4 } }) |bends| {
            const limits = animation.reachLimits(lengths[0], lengths[1], bends[0], bends[1]);
            for ([_]vec.Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = -0.2, .y = -0.7 }, .{ .x = 0, .y = -0.001 } }) |target| {
                for ([_]i8{ -1, 1 }) |sign| {
                    const solution = animation.solveLimb(vec.zero, target, lengths[0], lengths[1], sign, limits);
                    const lower = vec.subtract(solution.end, solution.middle);
                    try std.testing.expectApproxEqAbs(lengths[0], vec.magnitude(solution.middle), 0.00002);
                    try std.testing.expectApproxEqAbs(lengths[1], vec.magnitude(lower), 0.00002);
                    try std.testing.expect(std.math.isFinite(solution.end.x) and std.math.isFinite(solution.end.y));
                    const distance: f64 = vec.magnitude(solution.end);
                    try std.testing.expect(distance >= limits[0] - 0.00002 and distance <= limits[1] + 0.00002);
                    const cross = solution.end.x * solution.middle.y - solution.end.y * solution.middle.x;
                    try std.testing.expect(cross * @as(f32, @floatFromInt(sign)) >= -0.00001);
                    const bend = std.math.atan2(@abs(solution.middle.x * lower.y - solution.middle.y * lower.x), vec.dot(solution.middle, lower));
                    try std.testing.expect(bend >= bends[0] - 0.001 and bend <= bends[1] + 0.001);
                }
            }
        }
    }
}

test "character playback reset preserves facing and leaves other players unchanged" {
    defer animation.clearPlayers();
    try animation.register(7);
    try animation.register(19);
    animation.states.getPtr(7).?.* = .{ .previous_phase = 0.6, .phase = 0.7, .facing_right = true };
    animation.states.getPtr(19).?.* = .{ .previous_phase = 0.2, .phase = 0.3, .facing_right = false };
    const other = animation.states.get(19).?;
    animation.resetPlayer(7);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.phase);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.previous_phase);
    try std.testing.expect(animation.states.get(7).?.facing_right);
    try std.testing.expectEqualDeep(other, animation.states.get(19).?);
    animation.resetPlayer(19);
    try std.testing.expect(!animation.states.get(19).?.facing_right);
}

test "character curves respect outgoing interpolation and solve nonlinear Bezier time" {
    const keys = [_]animation.Key{
        .{ .phase = 0, .value = 0, .interpolation = .bezier, .out_handle = .{ 0.05, 1.0 / 3.0 } },
        .{ .phase = 1, .value = 1, .interpolation = .linear, .in_handle = .{ 0.25, 2.0 / 3.0 } },
    };
    const track: animation.Track = .{ .binding = .pelvis_y, .keys = &keys };
    var detail: animation.Diagnostic = .{};
    try animation.validateTrack(track, false, &detail);
    // Bezier t=.5 has x=.2375 and y=.5; treating phase as t would fail.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), animation.evaluateTrack(track, 0.2375), 0.00001);
    try std.testing.expectEqual(@as(f32, 0), animation.evaluateTrack(track, -1));
    try std.testing.expectEqual(@as(f32, 1), animation.evaluateTrack(track, 2));
    const discrete = [_]animation.Key{
        .{ .phase = 0, .value = 2, .interpolation = .step },
        .{ .phase = 0.5, .value = 4, .interpolation = .linear },
        .{ .phase = 1, .value = 8, .interpolation = .linear },
    };
    const stepped: animation.Track = .{ .binding = .pelvis_x, .keys = &discrete };
    try std.testing.expectEqual(@as(f32, 2), animation.evaluateTrack(stepped, 0.499));
    try std.testing.expectEqual(@as(f32, 4), animation.evaluateTrack(stepped, 0.5));
    try std.testing.expectEqual(@as(f32, 6), animation.evaluateTrack(stepped, 0.75));
}

test "original character run reproduces the twelve accepted poses after explicit frame conversion" {
    var detail: animation.Diagnostic = .{};
    var set = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, original_motion_json, locomotion_json, actions_json, aiming_json, walls_json, &detail), &detail);
    defer set.arena.deinit();
    const reference = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reference_json, .{});
    defer reference.deinit();
    const frames = reference.value.object.get("frames").?.array.items;
    for (frames, 0..) |frame, index| {
        const pose = animation.evaluatePose(&set, @as(f64, @floatFromInt(index)) / 12, .run);
        const joints = frame.object.get("joints").?.object;
        inline for (std.meta.fields(animation.Joint)) |field| {
            const expected = joints.get(field.name).?.array.items;
            const point = vec.Vec2{ .x = @floatCast(expected[0].float), .y = @as(f32, @floatCast(expected[1].float)) - 0.84 };
            // The runtime shoulders rotate their rest offset with the torso;
            // that documented hierarchy correction shifts each arm by <6 mm.
            const is_arm = std.mem.endsWith(u8, field.name, "shoulder") or std.mem.endsWith(u8, field.name, "elbow") or std.mem.endsWith(u8, field.name, "hand");
            try nearPoint(point, pose.joints[field.value], if (is_arm) 0.006 else 0.00015);
        }
    }
}

test "original compact Bezier run preserves dense controls, solved poses, and contact intent throughout the cycle" {
    var detail: animation.Diagnostic = .{};
    var compact = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, original_motion_json, locomotion_json, actions_json, aiming_json, walls_json, &detail), &detail);
    defer compact.arena.deinit();
    var dense = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, dense_motion_json, locomotion_json, actions_json, aiming_json, walls_json, &detail), &detail);
    defer dense.arena.deinit();
    try std.testing.expectEqual(dense.motion.cycle_seconds, compact.motion.cycle_seconds);
    try std.testing.expectEqual(dense.motion.reference_speed_mps, compact.motion.reference_speed_mps);
    try std.testing.expectEqual(dense.motion.loop, compact.motion.loop);
    try std.testing.expectEqualDeep(dense.motion.contacts, compact.motion.contacts);
    var compact_keys: usize = 0;
    var dense_keys: usize = 0;
    for (compact.motion.tracks, dense.motion.tracks) |a, b| {
        compact_keys += a.keys.len;
        dense_keys += b.keys.len;
    }
    try std.testing.expect(compact_keys < dense_keys / 4);
    var phases: std.ArrayList(f64) = .empty;
    defer phases.deinit(std.testing.allocator);
    for (0..4097) |index| try phases.append(std.testing.allocator, @as(f64, @floatFromInt(index)) / 4096);
    // Include exact keys/contact boundaries and both sides of each transition,
    // independently of the exporter's per-segment fitting samples.
    for ([_]*const animation.Assets{ &compact, &dense }) |set| {
        for (set.motion.tracks) |track| {
            for (track.keys) |key| {
                for ([_]f64{ -0.0000001, 0, 0.0000001 }) |offset| {
                    try phases.append(std.testing.allocator, std.math.clamp(@as(f64, key.phase) + offset, 0, 1));
                }
            }
        }
        for (set.motion.contacts) |contact| {
            for ([_]f64{ contact.start, contact.end }) |boundary| {
                for ([_]f64{ -0.0000001, 0, 0.0000001 }) |offset| {
                    try phases.append(std.testing.allocator, std.math.clamp(boundary + offset, 0, 1));
                }
            }
        }
    }
    var maximum_control_error: f32 = 0;
    var maximum_joint_error: f32 = 0;
    for (phases.items) |phase| {
        for (compact.motion.tracks, dense.motion.tracks) |a, b| {
            const difference = @abs(animation.evaluateTrack(a, @floatCast(phase)) - animation.evaluateTrack(b, @floatCast(phase)));
            maximum_control_error = @max(maximum_control_error, difference);
        }
        const a = animation.evaluatePose(&compact, phase, .run);
        const b = animation.evaluatePose(&dense, phase, .run);
        try std.testing.expectEqual(a.contact_intent, b.contact_intent);
        try std.testing.expectEqual(a.clamped, b.clamped);
        for (a.joints, b.joints) |actual, expected| {
            const difference = vec.magnitude(vec.subtract(actual, expected));
            maximum_joint_error = @max(maximum_joint_error, difference);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), maximum_control_error, 0.00021);
    try std.testing.expectApproxEqAbs(@as(f32, 0), maximum_joint_error, 0.0005);
}

test "character continuous run and neutral preserve every bone and loop without foot penetration" {
    var set = try load();
    defer set.arena.deinit();
    for (0..721) |index| {
        const phase = @as(f64, @floatFromInt(index)) / 720;
        const pose = animation.evaluatePose(&set, phase, if (index == 720) .neutral else .run);
        for (set.rig.joints, 0..) |joint, joint_index| {
            if (joint.parent == null) continue;
            const length = vec.magnitude(vec.subtract(pose.joints[joint_index], pose.joints[@intFromEnum(joint.parent.?)]));
            try std.testing.expectApproxEqAbs(set.rig.lengths[joint_index], length, 0.00002);
        }
        for (pose.clamped) |clamped| try std.testing.expect(!clamped);
        for ([_]animation.Joint{ .left_toe, .right_toe, .left_heel, .right_heel }) |joint| {
            try std.testing.expect(pose.joints[@intFromEnum(joint)].y >= -0.8402);
        }
    }
    const first = animation.evaluatePose(&set, 0, .run);
    const end = animation.evaluatePose(&set, 1, .run);
    const before_wrap = animation.evaluatePose(&set, 1 - 0.000001, .run);
    for (first.joints, end.joints, before_wrap.joints) |a, b, c| {
        try nearPoint(a, b, 0.000001);
        try nearPoint(a, c, 0.0001);
    }
}

test "polished run lands beneath the hips, extends at toe-off, and folds the heel beside the advancing knee" {
    var set = try load();
    defer set.arena.deinit();
    const pelvis = @intFromEnum(animation.Joint.pelvis);
    const ankle = @intFromEnum(animation.Joint.left_ankle);
    const knee = @intFromEnum(animation.Joint.left_knee);
    const heel = @intFromEnum(animation.Joint.left_heel);
    const toe = @intFromEnum(animation.Joint.left_toe);
    const touchdown = animation.evaluatePose(&set, 0, .run);
    try std.testing.expect(@abs(touchdown.joints[ankle].x - touchdown.joints[pelvis].x) < 0.1);
    const toe_off = animation.evaluatePose(&set, 0.3599, .run);
    const leg_length = set.rig.lengths[knee] + set.rig.lengths[ankle];
    try std.testing.expect(vec.magnitude(vec.subtract(toe_off.joints[ankle], toe_off.joints[pelvis])) > leg_length * 0.9);
    try std.testing.expect(toe_off.joints[heel].y > toe_off.joints[toe].y + 0.15);
    // During contact, the authored toe travels backwards exactly as far as the
    // root travels forwards. Planting should only correct terrain/transitions.
    for (0..36) |index| {
        const phase = @as(f32, @floatFromInt(index)) / 100;
        const pose = animation.evaluatePose(&set, phase, .run);
        try std.testing.expectApproxEqAbs(touchdown.joints[toe].x, pose.joints[toe].x + phase * set.motion.cycle_seconds * set.motion.reference_speed_mps, 0.0002);
    }
    const recovery = animation.evaluatePose(&set, 0.66, .run);
    try std.testing.expect(vec.magnitude(vec.subtract(recovery.joints[heel], recovery.joints[pelvis])) < 0.22);
    try std.testing.expect(recovery.joints[knee].x > recovery.joints[pelvis].x + 0.25);
    try std.testing.expect(recovery.joints[ankle].x < recovery.joints[knee].x - 0.25);
    const unfolding = animation.evaluatePose(&set, 0.84, .run);
    try std.testing.expect(unfolding.joints[ankle].x > recovery.joints[ankle].x + 0.3);
    try std.testing.expect(unfolding.joints[ankle].y < recovery.joints[ankle].y - 0.3);
    const returning = animation.evaluatePose(&set, 0.96, .run);
    try std.testing.expect(returning.joints[ankle].x < unfolding.joints[ankle].x);

    // Exact native IK output for the review sheet and continuous foot-path plot.
    const Sample = struct { phase: f32, joints: @TypeOf(recovery.joints) };
    var samples: [360]Sample = undefined;
    for (&samples, 0..) |*sample, index| {
        const phase = @as(f32, @floatFromInt(index)) / samples.len;
        sample.* = .{ .phase = phase, .joints = animation.evaluatePose(&set, phase, .run).joints };
    }
    runtime.init(std.testing.io);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/run_polish_poses.json", bytes);
}

test "character contacts are half-open and facing conversion preserves the root and attachments" {
    var set = try load();
    defer set.arena.deinit();
    try std.testing.expect(animation.contactIntent(set.motion, .left_leg, 0));
    try std.testing.expect(!animation.contactIntent(set.motion, .left_leg, 0.36));
    try std.testing.expect(animation.contactIntent(set.motion, .right_leg, 0.5));
    try std.testing.expect(!animation.contactIntent(set.motion, .right_leg, 0.86));
    try std.testing.expect(!animation.contactIntent(set.motion, .left_leg, 0.45));
    try std.testing.expect(!animation.contactIntent(set.motion, .right_leg, 0.45));
    try std.testing.expectEqual(@as(f32, 0), animation.clipPhase(set.motion, 1));
    var one_shot = set.motion;
    one_shot.loop = false;
    try std.testing.expectEqual(@as(f32, 1), animation.clipPhase(one_shot, 2));
    const pose = animation.evaluatePose(&set, 0, .neutral);
    const body: vec.Vec2 = .{ .x = 2, .y = 3 };
    const foot = pose.joints[@intFromEnum(animation.Joint.left_toe)];
    const right = animation.toWorld(set.rig, foot, body, true);
    const left = animation.toWorld(set.rig, foot, body, false);
    try std.testing.expectApproxEqAbs(@as(f32, 3.3), right.y, 0.00001);
    try std.testing.expectEqual(right.y, left.y);
    try std.testing.expectApproxEqAbs(@as(f32, 4), right.x + left.x, 0.00001);
    const hand = animation.attachmentPosition(set.rig, pose, "weapon_hand").?;
    try nearPoint(pose.joints[@intFromEnum(animation.Joint.right_hand)], hand, 0.000001);
}

test "character invalid assets report field paths and failed replacement preserves assets and phase" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err; // These failures are intentional; their diagnostics are asserted below.
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    try replaceFromJson(rig_json, motion_json, &detail);
    defer animation.cleanup();
    try animation.register(7);
    try animation.register(19);
    animation.states.getPtr(7).?.phase = 0.7;
    animation.states.getPtr(19).?.phase = 0.3;
    const old_id = animation.assets.?.rig.id.ptr;
    const cases = [_][3][]const u8{
        .{ "\"schema_version\": 1", "\"schema_version\": 2", "schema_version" },
        .{ "\"head_radius\": 0.105", "\"head_radius\": -1", "head_radius" },
        .{ "\"head_radius\": 0.105,", "", "head_radius" },
        .{ "\"parent\": null", "\"parent\": \"head\"", "parent" },
        .{ "\"id\": \"right_elbow\"", "\"id\": \"left_elbow\"", "duplicate" },
        .{ "\"id\": \"grapple_hand\"", "\"id\": \"weapon_hand\"", "attachments.weapon_hand: duplicate id" },
        .{ "\"head_radius\": 0.105", "\"head_radius\": 1e999", "finite" },
        .{ "\"angle_offset_radians\": 0", "\"angle_offset_radians\": 4", "attachments.weapon_hand.angle_offset_radians" },
        .{ "\"angle_offset_radians\": 0", "\"angle_offset_radians\": 1e999", "finite" },
        .{ "\"id\": \"weapon_hand\"", "\"id\": \"unused_hand\"", "attachments.weapon_hand" },
        .{ "\"joint\": \"right_hand\"", "\"joint\": \"head\"", "attachments.weapon_hand.joint" },
        .{ "\"y\": 0.43", "\"y\": 0", "bone length" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, rig_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidCharacterAsset, replaceFromJson(malformed, motion_json, &detail));
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], case[2]) != null);
        try std.testing.expect(old_id == animation.assets.?.rig.id.ptr);
        try std.testing.expectEqual(@as(f64, 0.7), animation.states.get(7).?.phase);
    }
    // Decoding failures in either file must preserve the installed runtime state too.
    const invalid_json = [_][3][]const u8{
        .{ "{", motion_json, data.characterRigPath },
        .{ rig_json, "{", data.characterMotionPath },
        .{ rig_json, "{}", data.characterMotionPath },
    };
    for (invalid_json) |case| {
        try std.testing.expectError(error.InvalidCharacterAsset, replaceFromJson(case[0], case[1], &detail));
        try std.testing.expectEqualStrings(case[2], detail.file);
        try std.testing.expect(detail.length > 0);
        try std.testing.expect(old_id == animation.assets.?.rig.id.ptr);
        try std.testing.expectEqual(@as(f64, 0.7), animation.states.get(7).?.phase);
        try std.testing.expectEqual(@as(f64, 0.3), animation.states.get(19).?.phase);
    }
    const motion_cases = [_][3][]const u8{
        .{ "\"end\": 0.36", "\"end\": 1.1", "contacts" },
        .{ "\"phase\": 0.0,", "\"phase\": 1e999,", "tracks[0].keys[0].phase: number must be finite" },
    };
    for (motion_cases) |case| {
        const malformed_motion = try std.mem.replaceOwned(u8, std.testing.allocator, motion_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed_motion);
        try std.testing.expectError(error.InvalidCharacterAsset, replaceFromJson(rig_json, malformed_motion, &detail));
        try std.testing.expectEqualStrings(data.characterMotionPath, detail.file);
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], case[2]) != null);
        try std.testing.expect(old_id == animation.assets.?.rig.id.ptr);
        try std.testing.expectEqual(@as(f64, 0.7), animation.states.get(7).?.phase);
        try std.testing.expectEqual(@as(f64, 0.3), animation.states.get(19).?.phase);
    }
    // Mutate the first control structurally so tuning its value cannot silently
    // stop exercising non-finite value rejection.
    {
        var motion = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, motion_json, .{});
        defer motion.deinit();
        const keys = motion.value.object.get("tracks").?.array.items[0].object.get("keys").?.array.items;
        try keys[0].object.put(motion.arena.allocator(), "value", .{ .number_string = "1e999" });
        const malformed_motion = try std.json.Stringify.valueAlloc(std.testing.allocator, motion.value, .{});
        defer std.testing.allocator.free(malformed_motion);
        try std.testing.expectError(error.InvalidCharacterAsset, replaceFromJson(rig_json, malformed_motion, &detail));
        try std.testing.expectEqualStrings(data.characterMotionPath, detail.file);
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], "tracks[0].keys[0].value: number must be finite") != null);
        try std.testing.expect(old_id == animation.assets.?.rig.id.ptr);
        try std.testing.expectEqual(@as(f64, 0.7), animation.states.get(7).?.phase);
        try std.testing.expectEqual(@as(f64, 0.3), animation.states.get(19).?.phase);
    }
    // Mutate handle values structurally: exported keys may already own handles.
    for ([_][]const u8{ "in_handle", "out_handle" }, 0..) |field, coordinate| {
        var motion = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, motion_json, .{});
        defer motion.deinit();
        var handle = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[0,0]", .{});
        defer handle.deinit();
        handle.value.array.items[coordinate] = .{ .number_string = "1e999" };
        const keys = motion.value.object.get("tracks").?.array.items[0].object.get("keys").?.array.items;
        try keys[0].object.put(motion.arena.allocator(), field, handle.value);
        const malformed_motion = try std.json.Stringify.valueAlloc(std.testing.allocator, motion.value, .{});
        defer std.testing.allocator.free(malformed_motion);
        try std.testing.expectError(error.InvalidCharacterAsset, replaceFromJson(rig_json, malformed_motion, &detail));
        try std.testing.expectEqualStrings(data.characterMotionPath, detail.file);
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], field) != null);
        try std.testing.expect(std.mem.indexOf(u8, detail.message[0..detail.length], "finite") != null);
        try std.testing.expect(old_id == animation.assets.?.rig.id.ptr);
        try std.testing.expectEqual(@as(f64, 0.7), animation.states.get(7).?.phase);
        try std.testing.expectEqual(@as(f64, 0.3), animation.states.get(19).?.phase);
    }
    try replaceFromJson(rig_json, motion_json, &detail);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.phase);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(19).?.phase);
    animation.states.getPtr(19).?.phase = 0.9;
    animation.states.getPtr(7).?.phase = 0.4;
    animation.resetPlayer(7);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.previous_phase);
    try std.testing.expectEqual(@as(f64, 0.9), animation.states.get(19).?.phase);
    animation.clearPlayers();
    try std.testing.expectEqual(@as(usize, 0), animation.states.count());
}

test "character curve validation rejects reversed handles, duplicate phases, and broken loops" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    var keys = [_]animation.Key{
        .{ .phase = 0, .value = 0, .interpolation = .bezier, .out_handle = .{ 0.8, 0 } },
        .{ .phase = 1, .value = 0, .interpolation = .linear, .in_handle = .{ 0.2, 0 } },
    };
    const track: animation.Track = .{ .binding = .left_foot_x, .keys = &keys };
    try std.testing.expectError(error.InvalidCharacterAsset, animation.validateTrack(track, true, &detail));
    keys[0].out_handle = .{ 0.2, 0 };
    keys[1].in_handle = .{ 0.8, 0 };
    keys[1].value = 1;
    try std.testing.expectError(error.InvalidCharacterAsset, animation.validateTrack(track, true, &detail));
    keys[1].value = 0;
    keys[0].out_handle = null;
    try std.testing.expectError(error.InvalidCharacterAsset, animation.validateTrack(track, true, &detail));
    keys[0].phase = 1;
    try std.testing.expectError(error.InvalidCharacterAsset, animation.validateTrack(track, true, &detail));
    const duplicate = [_]animation.Key{
        .{ .phase = 0, .value = 0, .interpolation = .linear },
        .{ .phase = 0.5, .value = 1, .interpolation = .linear },
        .{ .phase = 0.5, .value = 1, .interpolation = .linear },
        .{ .phase = 1, .value = 0, .interpolation = .linear },
    };
    try std.testing.expectError(error.InvalidCharacterAsset, animation.validateTrack(.{ .binding = .pelvis_x, .keys = &duplicate }, true, &detail));
}

test "character asset array order does not define joint, limb, control, contact, or attachment identity" {
    var original = try load();
    defer original.arena.deinit();
    var rig = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rig_json, .{});
    defer rig.deinit();
    var motion = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, motion_json, .{});
    defer motion.deinit();
    for ([_][]const u8{ "joints", "limbs", "neutral_controls", "attachments" }) |field| {
        std.mem.reverse(std.json.Value, rig.value.object.get(field).?.array.items);
    }
    for ([_][]const u8{ "tracks", "contacts" }) |field| {
        std.mem.reverse(std.json.Value, motion.value.object.get(field).?.array.items);
    }
    const reordered_rig = try std.json.Stringify.valueAlloc(std.testing.allocator, rig.value, .{});
    defer std.testing.allocator.free(reordered_rig);
    const reordered_motion = try std.json.Stringify.valueAlloc(std.testing.allocator, motion.value, .{});
    defer std.testing.allocator.free(reordered_motion);
    var detail: animation.Diagnostic = .{};
    var reordered = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, reordered_rig, reordered_motion, locomotion_json, actions_json, aiming_json, walls_json, &detail), &detail);
    defer reordered.arena.deinit();
    for (0..12) |index| {
        const phase = @as(f64, @floatFromInt(index)) / 12;
        const a = animation.evaluatePose(&original, phase, .run);
        const b = animation.evaluatePose(&reordered, phase, .run);
        for (a.joints, b.joints) |expected, actual| try nearPoint(expected, actual, 0.000001);
        try std.testing.expectEqual(a.contact_intent, b.contact_intent);
        for ([_][]const u8{ "weapon_hand", "grapple_hand" }) |name| {
            try nearPoint(animation.attachmentPosition(original.rig, a, name).?, animation.attachmentPosition(reordered.rig, b, name).?, 0.000001);
        }
    }
}

fn beginLocomotion() !box2d.c.b2BodyId {
    box2d.initWorld();
    errdefer box2d.destroyWorld();
    animation.installAssets(try load());
    errdefer animation.cleanup();
    animation.playback = .locomotion;
    try animation.register(7);
    const floor = try box2d.createBody(box2d.createStaticBodyDef(.{ .x = 0, .y = 0.8 }));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_TERRAIN;
    shape.filter.maskBits = collision.MASK_TERRAIN;
    const polygon = box2d.c.b2MakeBox(100, 0.5);
    _ = box2d.c.b2CreatePolygonShape(floor, &shape, &polygon);
    return floor;
}

fn advanceRun(x: f32, supported: bool) void {
    animation.updatePlayer(7, .{ .body = .{ .x = x, .y = 0 }, .supported = supported, .vertical_speed_mps = 0, .separation_speed_mps = 0, .ground_y = if (supported) 0.3 else null, .facing_right = true }, 1.0 / 60.0);
}

fn checkBones(rig: animation.Rig, pose: animation.Pose) !void {
    for (rig.joints, 0..) |joint, index| {
        if (joint.parent == null) continue;
        try std.testing.expectApproxEqAbs(rig.lengths[index], vec.magnitude(vec.subtract(pose.joints[index], pose.joints[@intFromEnum(joint.parent.?)])), 0.00002);
    }
}

test "locomotion stands still against a wall and adapts cadence with planted toes at slow, reference, and game run speeds" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    var samples: std.ArrayList(LocomotionSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for (0..120) |_| advanceRun(0, true);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.phase);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.run_weight);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    var previous_cadence: f64 = 0;
    for ([_]f32{ 0.5, 3.2, 9 }) |speed| {
        animation.resetPlayer(7);
        advanceRun(0, true);
        var x: f32 = 0;
        var locked_samples: usize = 0;
        for (0..240) |tick| {
            x += speed / 60;
            advanceRun(x, true);
            const sample = animation.states.get(7).?;
            if (tick >= 120) {
                var joints = animation.interpolatedPose(&animation.assets.?, sample, 1).joints;
                for (&joints) |*point| point.* = animation.toWorld(animation.assets.?.rig, point.*, sample.body, sample.facing_right);
                try samples.append(std.testing.allocator, .{ .speed = speed, .phase = animation.clipPhase(animation.assets.?.motion, sample.phase), .weight = sample.run_weight, .facing_right = sample.facing_right, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints });
            }
            for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
                try checkBones(animation.assets.?.rig, pose);
                const body: vec.Vec2 = .{ .x = std.math.lerp(sample.previous_body.x, sample.body.x, @as(f32, @floatCast(alpha))), .y = 0 };
                for ([_]animation.Joint{ .left_toe, .right_toe }, 0..) |toe, index| {
                    if (!sample.feet[index].locked or !sample.previous_feet[index].locked or !std.meta.eql(sample.feet[index].anchor, sample.previous_feet[index].anchor)) continue;
                    if (tick > 60) locked_samples += 1;
                    try nearPoint(sample.feet[index].anchor, animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(toe)], body, sample.facing_right), 0.00003);
                }
                for ([_]animation.Joint{ .left_toe, .right_toe, .left_heel, .right_heel }) |joint| {
                    const point = animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(joint)], body, sample.facing_right);
                    try std.testing.expect(point.y <= 0.3002);
                }
            }
        }
        try std.testing.expect(locked_samples > 50);
        const sample = animation.states.get(7).?;
        const cadence = (sample.phase - sample.previous_phase) * 60;
        try std.testing.expect(cadence > previous_cadence);
        const expected = speed / (animation.assets.?.motion.reference_speed_mps * animation.assets.?.motion.cycle_seconds * sample.stride_scale);
        try std.testing.expectApproxEqAbs(@as(f64, expected), cadence, 0.0001);
        previous_cadence = cadence;
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/run_speed_samples.json", bytes);
}

test "run lift and horizontal stride respond independently to locomotion profile tuning" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const base = animation.assets.?.locomotion;
    var widths: [3]f32 = undefined;
    var heights: [3]f32 = undefined;
    var cadences: [3]f64 = undefined;
    for (0..3) |variant| {
        animation.assets.?.locomotion = base;
        if (variant == 1) animation.assets.?.locomotion.full_run_speed_mps = 6.4;
        if (variant == 2) animation.assets.?.locomotion.stride_max = 0.75;
        animation.resetPlayer(7);
        advanceRun(0, true);
        var x: f32 = 0;
        var minimum_x: f32 = 20;
        var maximum_x: f32 = -20;
        var maximum_y: f32 = -20;
        for (0..360) |tick| {
            x += 3.2 / 60.0;
            advanceRun(x, true);
            if (tick < 120) continue;
            const sample = animation.states.get(7).?;
            const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
            try checkBones(animation.assets.?.rig, pose);
            for ([_]animation.Joint{ .left_toe, .right_toe }) |joint| {
                const point = pose.joints[@intFromEnum(joint)];
                minimum_x = @min(minimum_x, point.x);
                maximum_x = @max(maximum_x, point.x);
                maximum_y = @max(maximum_y, point.y);
            }
        }
        widths[variant] = maximum_x - minimum_x;
        heights[variant] = maximum_y + 0.84;
        const sample = animation.states.get(7).?;
        cadences[variant] = (sample.phase - sample.previous_phase) * 60;
    }
    try std.testing.expect(heights[1] < heights[0] * 0.6);
    try std.testing.expectApproxEqAbs(widths[0], widths[1], 0.025);
    try std.testing.expectApproxEqAbs(cadences[0], cadences[1], 0.00001);
    try std.testing.expect(widths[2] < widths[0] * 0.85);
    try std.testing.expectApproxEqAbs(heights[0], heights[2], 0.025);
    try std.testing.expect(cadences[2] > cadences[0]);
}

test "locomotion settles a stopped swing, turns using actual displacement, and releases on support loss or teleport" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    var x: f32 = 0;
    for (0..49) |_| {
        x += 3.2 / 60.0;
        advanceRun(x, true);
    }
    const stopped_phase = animation.states.get(7).?.phase;
    for (0..90) |_| advanceRun(x, true);
    const stopped = animation.states.get(7).?;
    try std.testing.expectEqual(stopped_phase, stopped.phase);
    try std.testing.expect(stopped.run_weight < 0.00001);
    const rest = animation.solvePose(animation.assets.?.rig, animation.assets.?.rig.neutral);
    const settled = animation.interpolatedPose(&animation.assets.?, stopped, 1);
    // Idle retains the final settled footholds instead of sliding them the last
    // few millimeters to the exact neutral targets after planting.
    for (rest.joints, settled.joints) |a, b| try nearPoint(a, b, 0.015);
    for (stopped.feet) |foot| try std.testing.expect(foot.locked);
    for (0..60) |_| advanceRun(x, true);
    const later = animation.interpolatedPose(&animation.assets.?, animation.states.get(7).?, 1);
    for (settled.joints, later.joints) |a, b| try nearPoint(a, b, 0.00002);
    // The supplied facing intent points right throughout; displacement goes left.
    for (0..120) |_| {
        x -= 3.2 / 60.0;
        advanceRun(x, true);
        const sample = animation.states.get(7).?;
        try std.testing.expect(!sample.facing_right);
        try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, 0.5));
    }
    advanceRun(x, false);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(!foot.locked);
    advanceRun(x + 10, true);
    try std.testing.expectEqual(@as(f64, 0), animation.states.get(7).?.phase);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.speed_mps);
}

test "foot queries follow moving support and release removed support despite stale grounded input" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    box2d.c.b2Body_SetType(floor, box2d.c.b2_staticBody);
    animation.resetPlayer(7);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    box2d.c.b2DestroyBody(floor);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(!foot.locked);
}

fn checkTerrainPose(sample: animation.PlayerState, slope: f32) !void {
    const set = &animation.assets.?;
    for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
        const pose = animation.interpolatedPose(set, sample, alpha);
        try checkBones(set.rig, pose);
        const body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
        for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel, .left_knee, .right_knee }) |joint| {
            const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], body, sample.facing_right);
            const floor = 0.3 + slope * point.x;
            errdefer std.log.err("terrain pose: slope {d}, speed {d}, action {s}, alpha {d}, {s} depth {d}, point {any}, clamped {any}", .{ slope, sample.speed_mps, @tagName(sample.action), alpha, @tagName(joint), point.y - floor, point, pose.clamped });
            try std.testing.expect(point.y <= floor + 0.0003);
        }
        for (sample.previous_feet, sample.feet, [_]animation.Joint{ .left_toe, .right_toe }) |before, foot, toe| {
            if (!before.locked or !foot.locked or !std.meta.eql(before.anchor, foot.anchor)) continue;
            try nearPoint(foot.anchor, animation.toWorld(set.rig, pose.joints[@intFromEnum(toe)], body, sample.facing_right), 0.00003);
        }
    }
}

test "static slopes adapt running soles and preserve planted toes in both directions" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    var samples: std.ArrayList(LocomotionSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]f32{ -0.55, -0.25, 0.25, 0.55 }) |angle| {
        const rotation = box2d.c.b2MakeRot(angle);
        box2d.c.b2Body_SetTransform(floor, .{ .x = 0, .y = 0.3 + 0.5 / rotation.c }, rotation);
        const slope = rotation.s / rotation.c;
        for ([_]f32{ 0, 0.5, 3.2, 9, -3.2 }) |speed| {
            animation.resetPlayer(7);
            var locked_samples: usize = 0;
            for (0..180) |tick| {
                const x = speed * @as(f32, @floatFromInt(tick)) / 60;
                animation.updatePlayer(7, .{ .body = .{ .x = x, .y = slope * x }, .supported = true, .ground_y = 0.3 + slope * x, .ground_normal = .{ .x = rotation.s, .y = -rotation.c }, .vertical_speed_mps = speed * slope, .separation_speed_mps = 0, .horizontal_speed_mps = speed, .movement_direction = std.math.sign(speed), .facing_right = speed >= 0 }, 1.0 / 60.0);
                const sample = animation.states.get(7).?;
                try checkTerrainPose(sample, slope);
                if (angle == -0.25 and speed == 3.2 and tick >= 120 and tick < 144 and tick % 2 == 0) {
                    const set = &animation.assets.?;
                    var joints = animation.interpolatedPose(set, sample, 1).joints;
                    for (&joints) |*point| point.* = animation.toWorld(set.rig, point.*, sample.body, sample.facing_right);
                    try samples.append(std.testing.allocator, .{ .speed = sample.speed_mps, .phase = animation.clipPhase(set.motion, sample.phase), .weight = sample.run_weight, .facing_right = sample.facing_right, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints });
                }
                for (sample.feet) |foot| {
                    if (foot.locked and tick > 30) locked_samples += 1;
                }
            }
            errdefer std.log.err("slope contacts: angle {d}, speed {d}, count {d}", .{ angle, speed, locked_samples });
            try std.testing.expect(locked_samples > 15);
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/terrain_run_samples.json", bytes);
}

test "kneeling aiming and landing retain clearance on static slopes" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    for ([_]f32{ -0.55, -0.25, 0.25, 0.55 }) |angle| {
        const rotation = box2d.c.b2MakeRot(angle);
        box2d.c.b2Body_SetTransform(floor, .{ .x = 0, .y = 0.3 + 0.5 / rotation.c }, rotation);
        for ([_]bool{ true, false }) |facing| {
            animation.resetPlayer(7);
            var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .ground_normal = .{ .x = rotation.s, .y = -rotation.c }, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = facing, .kneel_requested = true };
            for (0..90) |_| {
                animation.updatePlayer(7, input, 1.0 / 60.0);
                try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
            }
            try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
            input.aiming = true;
            input.aim_direction = if (facing) vec.west else vec.east;
            for (0..90) |_| {
                animation.updatePlayer(7, input, 1.0 / 60.0);
                try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
            }
            input.kneel_requested = false;
            for (0..60) |_| {
                animation.updatePlayer(7, input, 1.0 / 60.0);
                try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
            }
            input.supported = false;
            input.ground_y = null;
            input.body.y = -0.5;
            input.vertical_speed_mps = 12;
            for (0..20) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
            input.supported = true;
            input.ground_y = 0.3;
            input.body.y = 0;
            input.vertical_speed_mps = 0;
            for (0..60) |tick| {
                animation.updatePlayer(7, input, 1.0 / 60.0);
                if (tick == 0) try std.testing.expectEqual(animation.Action.land, animation.states.get(7).?.action);
                try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
            }
        }
    }
}

fn addTerrainBox(position: vec.Vec2, half_size: vec.Vec2) !box2d.c.b2BodyId {
    const body = try box2d.createBody(box2d.createStaticBodyDef(position));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_TERRAIN;
    shape.filter.maskBits = collision.MASK_TERRAIN;
    const polygon = box2d.c.b2MakeBox(half_size.x, half_size.y);
    _ = box2d.c.b2CreatePolygonShape(body, &shape, &polygon);
    return body;
}

test "running over static step edges clears both soles without interpolating a false ramp" {
    const original_floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    box2d.c.b2DestroyBody(original_floor);
    _ = try addTerrainBox(.{ .x = -50, .y = 0.8 }, .{ .x = 50, .y = 0.5 });
    const upper = try addTerrainBox(.{ .x = 50, .y = 0.65 }, .{ .x = 50, .y = 0.5 });
    const set = &animation.assets.?;
    for ([_]f32{ 0.12, 0.24 }) |height| {
        box2d.c.b2Body_SetTransform(upper, .{ .x = 50, .y = 0.8 - height }, box2d.c.b2MakeRot(0));
        for ([_]f32{ 0.5, 3.2, 9, -0.5, -3.2, -9 }) |speed| {
            animation.resetPlayer(7);
            const frames: usize = @intFromFloat(@ceil(4 / @abs(speed) * 60));
            for (0..frames) |tick| {
                const x = -2.0 * @as(f32, @floatFromInt(std.math.sign(speed))) + speed * @as(f32, @floatFromInt(tick)) / 60;
                const floor_y: f32 = if (x < 0) 0.3 else 0.3 - height;
                animation.updatePlayer(7, .{ .body = .{ .x = x, .y = floor_y - 0.3 }, .supported = true, .ground_y = floor_y, .vertical_speed_mps = 0, .separation_speed_mps = 0, .horizontal_speed_mps = speed, .movement_direction = std.math.sign(speed), .facing_right = speed >= 0 }, 1.0 / 60.0);
                const sample = animation.states.get(7).?;
                for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                    const pose = animation.interpolatedPose(set, sample, alpha);
                    try checkBones(set.rig, pose);
                    const body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
                    for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                        const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], body, sample.facing_right);
                        const ground: f32 = if (point.x < 0) 0.3 else 0.3 - height;
                        errdefer std.log.err("step: height {d}, speed {d}, tick {d}, alpha {d}, {s} depth {d}, point {any}", .{ height, speed, tick, alpha, @tagName(joint), point.y - ground, point });
                        try std.testing.expect(point.y <= ground + 0.0003);
                    }
                    for (sample.previous_feet, sample.feet, [_]animation.Joint{ .left_toe, .right_toe }) |before, foot, toe| {
                        if (!before.locked or !foot.locked or !std.meta.eql(before.anchor, foot.anchor)) continue;
                        try nearPoint(foot.anchor, animation.toWorld(set.rig, pose.joints[@intFromEnum(toe)], body, sample.facing_right), 0.00003);
                    }
                }
            }
        }
    }
}

test "kneeling and aiming across static step edges retain knee and sole clearance" {
    const original_floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    box2d.c.b2DestroyBody(original_floor);
    _ = try addTerrainBox(.{ .x = -50, .y = 0.8 }, .{ .x = 50, .y = 0.5 });
    _ = try addTerrainBox(.{ .x = 50, .y = 0.68 }, .{ .x = 50, .y = 0.5 });
    const set = &animation.assets.?;
    for ([_]f32{ -0.2, -0.08, 0.08, 0.2 }) |x| {
        for ([_]bool{ true, false }) |facing| {
            animation.resetPlayer(7);
            const floor_y: f32 = if (x < 0) 0.3 else 0.18;
            var input: animation.LocomotionInput = .{ .body = .{ .x = x, .y = floor_y - 0.3 }, .supported = true, .ground_y = floor_y, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = facing, .kneel_requested = true };
            for (0..180) |tick| {
                input.aiming = tick >= 90;
                input.aim_direction = if (facing) vec.west else vec.east;
                animation.updatePlayer(7, input, 1.0 / 60.0);
                const sample = animation.states.get(7).?;
                for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                    const pose = animation.interpolatedPose(set, sample, alpha);
                    try checkBones(set.rig, pose);
                    for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel, .left_knee, .right_knee }) |joint| {
                        const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], sample.body, sample.facing_right);
                        const ground: f32 = if (point.x < 0) 0.3 else 0.18;
                        errdefer std.log.err("kneeling step: x {d}, facing {}, tick {d}, alpha {d}, {s} depth {d}", .{ x, facing, tick, alpha, @tagName(joint), point.y - ground });
                        try std.testing.expect(point.y <= ground + 0.0003);
                    }
                }
            }
        }
    }
}

test "invalid locomotion JSON preserves the complete installed pose and contacts; valid reload clears transient state" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    const before = animation.states.get(7).?;
    const old_id = animation.assets.?.locomotion.id.ptr;
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    const cases = [_][2][]const u8{
        .{ "\"schema_version\": 2", "\"schema_version\": 3" },
        .{ "\"run_reference_v1\"", "\"missing_clip\"" },
        .{ "\"stride_max\": 1.15", "\"stride_max\": 0.1" },
        .{ "\"start_seconds\": 0.08", "\"start_seconds\": 0" },
        .{ "\"release_seconds\": 0.055", "\"release_seconds\": 1e999" },
        .{ "\"full_run_speed_mps\": 1.8", "\"full_run_speed_mps\": 0.01" },
        .{ "\"plant_distance_m\": 0.035,", "" },
        .{ "\"probe_up_m\": 0.65", "\"probe_up_m\": 0" },
        .{ "\"probe_down_m\": 0.65", "\"probe_down_m\": 1.1" },
        .{ "\"max_slope_radians\": 0.7853982", "\"max_slope_radians\": 1.5" },
        .{ "\"pelvis_limit_m\": 0.18", "\"pelvis_limit_m\": -1" },
        .{ "\"blend_seconds\": 0.06", "\"blend_seconds\": 1e999" },
        .{ "\"swing_clearance_m\": 0.04", "\"swing_clearance_m\": -0.01" },
        .{ "\"lookahead_m\": 0.12", "\"lookahead_m\": 0.9" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, locomotion_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        const result = replacement: {
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, malformed, actions_json, aiming_json, walls_json, &detail) catch |err| break :replacement err;
            break :replacement animation.replaceAssets(files, &detail);
        };
        try std.testing.expectError(error.InvalidCharacterAsset, result);
        try std.testing.expectEqualStrings(data.characterLocomotionPath, detail.file);
        try std.testing.expect(detail.length > 0);
        try std.testing.expectEqualDeep(before, animation.states.get(7).?);
        try std.testing.expect(old_id == animation.assets.?.locomotion.id.ptr);
    }
    try replaceFromJson(rig_json, motion_json, &detail);
    const cleared = animation.states.get(7).?;
    try std.testing.expect(!cleared.initialized);
    for (cleared.feet) |foot| try std.testing.expect(!foot.locked);
    try std.testing.expectEqual(before.facing_right, cleared.facing_right);
}

const LocomotionSample = struct {
    speed: f32,
    phase: f32,
    weight: f32,
    facing_right: bool,
    body: vec.Vec2,
    planted: [2]bool,
    joints: [std.meta.fields(animation.Joint).len]vec.Vec2,
};

test "running reversals preserve control positions and export exact solved poses for visual review" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    var samples: std.ArrayList(LocomotionSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    var x: f32 = 0;
    var speed: f32 = 0;
    advanceRun(x, true);
    var turns: usize = 0;
    var slow_restart_contacts: usize = 0;
    // Stand, accelerate, brake, reverse at running speed, stop, slow run.
    for (0..600) |tick| {
        errdefer std.log.err("locomotion reversal regression failed at tick {d}", .{tick});
        const target: f32 = if (tick < 30) 0 else if (tick < 150) 3.2 else if (tick < 270) 9 else if (tick < 390) -9 else if (tick < 480) 0 else 0.5;
        speed += std.math.clamp(target - speed, -1.5, 1.5);
        const before = animation.states.get(7).?;
        x += speed / 60;
        advanceRun(x, true);
        const sample = animation.states.get(7).?;
        if (tick >= 510 and tick < 540 and (sample.feet[0].locked or sample.feet[1].locked)) slow_restart_contacts += 1;
        const set = &animation.assets.?;
        const pose = animation.interpolatedPose(set, sample, 1);
        try checkBones(set.rig, pose);
        for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
            errdefer std.log.err("locomotion reversal clearance failed at alpha {d}", .{alpha});
            const between = animation.interpolatedPose(set, sample, alpha);
            try checkBones(set.rig, between);
            const body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
            for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                const point = animation.toWorld(set.rig, between.joints[@intFromEnum(joint)], body, sample.facing_right);
                try std.testing.expectApproxEqAbs(@as(f32, 0), @max(0, point.y - 0.3), 0.0002);
            }
        }
        if (sample.facing_right != before.facing_right) {
            turns += 1;
            const earlier = animation.interpolatedPose(set, before, 1);
            for (pose.desired_targets, earlier.desired_targets) |a, b| {
                const current_world = animation.toWorld(set.rig, a, sample.body, sample.facing_right);
                const previous_world = animation.toWorld(set.rig, b, before.body, before.facing_right);
                errdefer std.log.err("turn target displacement {d}", .{vec.magnitude(vec.subtract(current_world, previous_world))});
                try std.testing.expect(vec.magnitude(vec.subtract(current_world, previous_world)) < 0.06);
            }
            for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }, 0..) |joint, index| {
                const current_world = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], sample.body, sample.facing_right);
                const previous_world = animation.toWorld(set.rig, earlier.joints[@intFromEnum(joint)], before.body, before.facing_right);
                errdefer std.log.err("turn {s} displacement {d}", .{ @tagName(joint), vec.magnitude(vec.subtract(current_world, previous_world)) });
                // At 60 Hz the eased turn can move a free toe up to 8 cm, but
                // cannot introduce the former 30+ cm instantaneous mirror jump.
                try std.testing.expect(vec.magnitude(vec.subtract(current_world, previous_world)) < @as(f32, if (index % 2 == 0) 0.08 else 0.13));
                if (index % 2 != 0 or !sample.feet[index / 2].locked or !before.feet[index / 2].locked) continue;
                try nearPoint(before.feet[index / 2].anchor, current_world, 0.00003);
            }
        }
        var joints = pose.joints;
        for (&joints) |*point| point.* = animation.toWorld(set.rig, point.*, sample.body, sample.facing_right);
        try samples.append(std.testing.allocator, .{ .speed = sample.speed_mps, .phase = animation.clipPhase(set.motion, sample.phase), .weight = sample.run_weight, .facing_right = sample.facing_right, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints });
    }
    try std.testing.expectEqual(@as(usize, 2), turns);
    try std.testing.expect(slow_restart_contacts > 5);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/locomotion_samples.json", bytes);
}

test "toe planting uses the actual heel geometry and preserves interpolated floor clearance for a tilted heel" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const tilted_rig = try std.mem.replaceOwned(u8, std.testing.allocator, rig_json, "\"x\": -0.22,\n        \"y\": 0", "\"x\": -0.22,\n        \"y\": -0.01");
    defer std.testing.allocator.free(tilted_rig);
    var detail: animation.Diagnostic = .{};
    try replaceFromJson(tilted_rig, motion_json, &detail);
    try std.testing.expectEqual(@as(f32, -0.01), animation.assets.?.rig.joints[@intFromEnum(animation.Joint.left_heel)].rest_offset.y);
    var x: f32 = 0;
    for (0..150) |tick| {
        errdefer std.log.err("tilted heel regression failed at tick {d}", .{tick});
        if (tick >= 60) x -= 3.2 / 60.0;
        advanceRun(x, true);
        const sample = animation.states.get(7).?;
        if (tick < 60) for (sample.feet) |foot| {
            try std.testing.expect(!foot.locked);
        };
        for ([_]f64{ 0.25, 0.5, 0.75, 1 }) |alpha| {
            const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
            try checkBones(animation.assets.?.rig, pose);
            const body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
            for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                const point = animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(joint)], body, sample.facing_right);
                try std.testing.expect(point.y <= 0.3002);
            }
        }
    }
}

fn advanceAir(body: vec.Vec2, vertical_speed: f32, supported: bool) animation.PlayerState {
    animation.updatePlayer(7, .{ .body = body, .vertical_speed_mps = vertical_speed, .separation_speed_mps = -vertical_speed, .supported = supported, .ground_y = if (supported) 0.3 else null, .facing_right = true }, 1.0 / 60.0);
    return animation.states.get(7).?;
}

fn checkAirPose(sample: animation.PlayerState) !void {
    const set = &animation.assets.?;
    for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
        errdefer std.log.err("air pose failed in {s} at alpha {d}, body ({d}, {d})", .{ @tagName(sample.action), alpha, sample.body.x, sample.body.y });
        const pose = animation.interpolatedPose(set, sample, alpha);
        try checkBones(set.rig, pose);
        const body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
        for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
            const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], body, sample.facing_right);
            errdefer std.log.err("{s} floor depth {d}", .{ @tagName(joint), point.y - 0.3 });
            try std.testing.expect(point.y <= 0.3002);
        }
        for (sample.previous_feet, sample.feet, [_]animation.Joint{ .left_toe, .right_toe }) |before, foot, toe| {
            if (!before.locked or !foot.locked or !std.meta.eql(before.anchor, foot.anchor)) continue;
            try nearPoint(foot.anchor, animation.toWorld(set.rig, pose.joints[@intFromEnum(toe)], body, sample.facing_right), 0.00003);
        }
    }
    if (sample.action != .jump and sample.action != .fall) return;
    try std.testing.expectEqual([2]bool{ false, false }, sample.contact_intent);
    for (sample.feet) |foot| try std.testing.expect(!foot.locked);
}

test "airborne clips retain bone lengths and reach their authored controls without clamping" {
    var set = try load();
    defer set.arena.deinit();
    for ([_]animation.Motion{ set.actions.jump, set.actions.fall, set.actions.landing, set.actions.kneel }) |clip| {
        for (0..241) |tick| {
            var controls = set.rig.neutral;
            for (&controls, clip.tracks) |*value, track| value.* = animation.evaluateTrack(track, @as(f32, @floatFromInt(tick)) / 240);
            const pose = animation.solvePose(set.rig, controls);
            try checkBones(set.rig, pose);
            for (pose.clamped) |clamped| try std.testing.expect(!clamped);
        }
    }
}

test "takeoff ignores lingering support and falling, air jumps, landing interruptions and resets recover" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    const planted = animation.states.get(7).?;
    var sample = advanceAir(.{ .x = 0, .y = -0.08 }, -5, true);
    try std.testing.expectEqual(animation.Action.jump, sample.action);
    try std.testing.expectEqual(planted.phase, sample.phase);
    try checkAirPose(sample);
    // The first action frame retains the previous controls, releasing anchors
    // without snapping the feet to the authored takeoff pose.
    for (planted.controls, sample.controls) |before, after| try std.testing.expectApproxEqAbs(before, after, 0.000001);
    for (0..15) |_| sample = advanceAir(.{ .x = 0, .y = -1 }, -2, false);
    sample = advanceAir(.{ .x = 0, .y = -1 }, 0, false);
    try std.testing.expectEqual(animation.Action.fall, sample.action);
    try checkAirPose(sample);
    sample = advanceAir(.{ .x = 0, .y = -1.1 }, -6, false);
    try std.testing.expectEqual(animation.Action.jump, sample.action);
    try std.testing.expectEqual(@as(f32, 0), sample.action_seconds);
    sample = advanceAir(.{ .x = 0, .y = -0.2 }, 12, false);
    sample = advanceAir(vec.zero, 0, true);
    try std.testing.expectEqual(animation.Action.land, sample.action);
    try std.testing.expect(sample.landing_strength > 0.7);
    try checkAirPose(sample);
    sample = advanceAir(.{ .x = 0, .y = -0.1 }, -8, true);
    try std.testing.expectEqual(animation.Action.jump, sample.action);
    try std.testing.expectEqual(@as(f32, 0), sample.landing_strength);
    try checkAirPose(sample);
    // Spawning/teleporting directly into support must not invent an impact.
    sample = advanceAir(.{ .x = 10, .y = 0 }, 0, true);
    try std.testing.expectEqual(animation.Action.grounded, sample.action);
    try std.testing.expectEqual(@as(f32, 0), sample.landing_strength);
    animation.resetPlayer(7);
    sample = advanceAir(.{ .x = 0, .y = -1 }, 12, false);
    try std.testing.expectEqual(animation.Action.fall, sample.action);
    try std.testing.expectEqual(@as(f32, 0), sample.landing_strength);
    try checkAirPose(sample);
    // A small step down gets an airborne pose but no hard landing recoil.
    animation.resetPlayer(7);
    advanceRun(0, true);
    sample = advanceAir(.{ .x = 0, .y = -0.01 }, 0.5, false);
    try std.testing.expectEqual(animation.Action.fall, sample.action);
    sample = advanceAir(vec.zero, 0, true);
    try std.testing.expectEqual(animation.Action.grounded, sample.action);
    for (0..90) |_| sample = advanceAir(vec.zero, 0, true);
    for (sample.feet) |foot| try std.testing.expect(foot.locked);
    try checkAirPose(sample);
}

const AirSample = struct {
    action: animation.Action,
    seconds: f32,
    strength: f32,
    pose: LocomotionSample,
};

test "real physics and movement grounding drive jump fall and landing through fixedUpdate" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    box2d.setGravity(80);
    const body = try box2d.createBody(box2d.createNonRotatingDynamicBodyDef(vec.zero));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_PLAYER;
    shape.filter.maskBits = collision.MASK_PLAYER;
    shape.material.friction = 0;
    const circle = box2d.c.b2Circle{ .center = .{ .x = 0, .y = 0 }, .radius = player.lowerBodyColliderRadius };
    const body_shape = box2d.c.b2CreateCircleShape(body, &shape, &circle);
    var p = std.mem.zeroes(player.Player);
    p.id = 7;
    p.bodyId = body;
    try player.players.put(allocator.allocator, 7, p);
    defer _ = player.players.swapRemove(7);
    try player_input.register(7);
    defer _ = player_input.playerInputs.swapRemove(7);
    try movement.states.put(allocator.allocator, 7, .{ .bodyId = body, .footSensorShapeId = body_shape, .leftWallSensorId = body_shape, .rightWallSensorId = body_shape, .facingRight = true });
    defer _ = movement.states.swapRemove(7);
    try movement.configure(try data.loadMovementData("movements/towerfall_keep.json"));
    var samples: std.ArrayList(AirSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    var seen: [std.meta.fields(animation.Action).len]bool = @splat(false);
    var landing_contacts: usize = 0;
    var early_landing_contacts: usize = 0;
    for (0..150) |tick| {
        errdefer std.log.err("physics jump regression failed at tick {d}", .{tick});
        if (tick == 30) box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 3.2, .y = -12 });
        if (tick == 95) box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
        box2d.worldStep(1.0 / 60.0, 4);
        try movement.processSensorEvents();
        animation.fixedUpdate(1.0 / 60.0);
        const sample = animation.states.get(7).?;
        seen[@intFromEnum(sample.action)] = true;
        if (sample.action == .land and (sample.feet[0].locked or sample.feet[1].locked)) {
            landing_contacts += 1;
            if (sample.action_seconds <= 0.1) early_landing_contacts += 1;
        }
        try checkAirPose(sample);
        const set = &animation.assets.?;
        var joints = animation.interpolatedPose(set, sample, 1).joints;
        for (&joints) |*point| point.* = animation.toWorld(set.rig, point.*, sample.body, sample.facing_right);
        try samples.append(std.testing.allocator, .{ .action = sample.action, .seconds = sample.action_seconds, .strength = sample.landing_strength, .pose = .{ .speed = sample.speed_mps, .phase = animation.clipPhase(set.motion, sample.phase), .weight = sample.run_weight, .facing_right = sample.facing_right, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints } });
    }
    for (seen[0..@intFromEnum(animation.Action.kneel)]) |visited| try std.testing.expect(visited);
    try std.testing.expect(landing_contacts > 0);
    try std.testing.expect(early_landing_contacts > 0);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/airborne_samples.json", bytes);
    // A rising support must remain grounded rather than select the jump clip.
    box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
    box2d.c.b2Body_SetLinearVelocity(floor, .{ .x = 0, .y = -3 });
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = -3 });
    for (0..12) |_| {
        box2d.worldStep(1.0 / 60.0, 4);
        try movement.processSensorEvents();
        animation.fixedUpdate(1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
    }
    player_input.submit(7, .{ .movementDirection = .{ .x = 0, .y = -1 } });
    animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
    player_input.neutralize(7);
    animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
}

test "invalid action assets preserve live airborne state and successful reload resets it" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const before = advanceAir(.{ .x = 0, .y = -1 }, 8, false);
    const old_id = animation.assets.?.actions.jump.id.ptr;
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    const cases = [_][2][]const u8{
        .{ "\"schema_version\": 2", "\"schema_version\": 1" },
        .{ "\"schema_version\": 2", "\"schema_version\": 3" },
        .{ "\"schema_version\": 1", "\"schema_version\": 2" },
        .{ "\"kneel\":", "\"crouch\":" },
        .{ "\"humanoid_v1\"", "\"missing_rig\"" },
        .{ "\"blend_seconds\": 0.045", "\"blend_seconds\": 0" },
        .{ "\"takeoff_speed_mps\": 0.2", "\"takeoff_speed_mps\": -1" },
        .{ "\"full_landing_speed_mps\": 12.0", "\"full_landing_speed_mps\": 0.5" },
        .{ "\"kneel_reference_v1\"", "\"landing_reference_v1\"" },
        .{ "\"loop\": false", "\"loop\": true" },
        .{ "\"cycle_seconds\": 0.18", "\"cycle_seconds\": 0" },
        .{ "\"jump_reference_v1\"", "\"fall_reference_v1\"" },
        .{ "\"contacts\": []", "\"contacts\": [{\"limb\": \"left_leg\", \"start\": 0, \"end\": 1}]" },
        .{ "\"binding\": \"pelvis_x\"", "\"binding\": \"pelvis_y\"" },
        .{ "\"value\": 0.04", "\"value\": 1e999" },
        .{ "\"phase\": 1", "\"phase\": 0.9" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, actions_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        try std.testing.expect(!std.mem.eql(u8, malformed, actions_json));
        const result = replacement: {
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, malformed, aiming_json, walls_json, &detail) catch |err| break :replacement err;
            break :replacement animation.replaceAssets(files, &detail);
        };
        try std.testing.expectError(error.InvalidCharacterAsset, result);
        try std.testing.expectEqualStrings(data.characterActionsPath, detail.file);
        try std.testing.expect(detail.length > 0);
        try std.testing.expectEqualDeep(before, animation.states.get(7).?);
        try std.testing.expect(old_id == animation.assets.?.actions.jump.id.ptr);
    }
    try replaceFromJson(rig_json, motion_json, &detail);
    const cleared = animation.states.get(7).?;
    try std.testing.expect(!cleared.initialized);
    try std.testing.expectEqual(animation.Action.grounded, cleared.action);
    try std.testing.expectEqual(@as(f32, 0), cleared.action_seconds);
    try std.testing.expectEqual(@as(f32, 0), cleared.landing_strength);
    try std.testing.expectEqual(before.facing_right, cleared.facing_right);
}

test "hard landings squat and settle on both feet in either facing, including an airborne turn" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    for ([_]f32{ 0, -0.03 }) |horizontal_step| {
        animation.resetPlayer(7);
        var x: f32 = 0;
        var sample = advanceAir(.{ .x = x, .y = -1 }, 16, false);
        for (0..24) |_| {
            x += horizontal_step;
            sample = advanceAir(.{ .x = x, .y = -1 }, 16, false);
            try checkAirPose(sample);
        }
        try std.testing.expectEqual(horizontal_step == 0, sample.facing_right);
        sample = advanceAir(.{ .x = x, .y = 0 }, 0, true);
        try std.testing.expectEqual(animation.Action.land, sample.action);
        try std.testing.expectEqual(@as(f32, 1), sample.landing_strength);
        var lowest_pelvis: f32 = 0;
        var contact_frames: usize = 0;
        for (0..90) |_| {
            sample = advanceAir(.{ .x = x, .y = 0 }, 0, true);
            lowest_pelvis = @min(lowest_pelvis, sample.controls[@intFromEnum(animation.Control.pelvis_y)]);
            if (sample.action == .land and (sample.feet[0].locked or sample.feet[1].locked)) contact_frames += 1;
            try checkAirPose(sample);
        }
        // In the canonical frame lower pelvis_y increases world Y, putting the
        // hips closer to the actual floor rather than only leaning the torso.
        const rig = animation.assets.?.rig;
        const neutral_hip_height = 0.3 - animation.toWorld(rig, .{ .x = 0, .y = 0 }, .{ .x = x, .y = 0 }, sample.facing_right).y;
        const compressed_hip_height = 0.3 - animation.toWorld(rig, .{ .x = 0, .y = lowest_pelvis }, .{ .x = x, .y = 0 }, sample.facing_right).y;
        try std.testing.expect(compressed_hip_height < neutral_hip_height - 0.28);
        try std.testing.expect(contact_frames > 5);
        try std.testing.expectEqual(animation.Action.grounded, sample.action);
        try std.testing.expectEqual(@as(f32, 0), sample.landing_strength);
        for (sample.feet) |foot| try std.testing.expect(foot.locked);
        const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
        const neutral = animation.solvePose(animation.assets.?.rig, animation.assets.?.rig.neutral);
        // Keep the acquired landing stance; only the upper body returns to the
        // neutral coordinates. Both foot anchors must remain stable afterward.
        for ([_]animation.Joint{ .pelvis, .chest, .neck, .head, .left_hand, .right_hand }) |joint| try nearPoint(pose.joints[@intFromEnum(joint)], neutral.joints[@intFromEnum(joint)], 0.001);
        for (0..60) |_| sample = advanceAir(.{ .x = x, .y = 0 }, 0, true);
        const settled = animation.interpolatedPose(&animation.assets.?, sample, 1);
        for (pose.joints, settled.joints) |a, b| try nearPoint(a, b, 0.00002);
    }
}

test "uphill travel stays grounded until velocity separates from the support normal" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    var input: animation.LocomotionInput = .{ .body = .{ .x = 0.05, .y = -0.05 }, .vertical_speed_mps = -3, .separation_speed_mps = 0, .supported = true, .ground_y = null, .facing_right = true };
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
    input.body = .{ .x = 0.1, .y = -0.15 };
    input.vertical_speed_mps = -6;
    input.separation_speed_mps = 3;
    animation.updatePlayer(7, input, 1.0 / 60.0);
    const sample = animation.states.get(7).?;
    try std.testing.expectEqual(animation.Action.jump, sample.action);
    try checkAirPose(sample);
}

test "landing compression lowers the hips while preserving walking and running foot paths and contacts" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    try animation.register(8);
    for ([_]f32{ 0.5, 9 }) |speed| {
        animation.resetPlayer(7);
        _ = advanceAir(.{ .x = 0, .y = -1 }, 16, false);
        for (0..24) |_| _ = advanceAir(.{ .x = 0, .y = -1 }, 16, false);
        var sample = advanceAir(vec.zero, 0, true);
        try std.testing.expectEqual(@as(f32, 1), sample.landing_strength);
        // A matching player with zero compression provides the locomotion pose.
        // Their authored paths should match even at full impact strength.
        // Lower hips can retain a contact that an extended leg must release.
        animation.states.getPtr(8).?.* = sample;
        animation.states.getPtr(8).?.landing_strength = 0;
        var x: f32 = 0;
        var saw_compression = false;
        var minimum_ankle_x: f32 = 20;
        var maximum_ankle_x: f32 = -20;
        for (0..24) |_| {
            x += speed / 60;
            const input: animation.LocomotionInput = .{ .body = .{ .x = x, .y = 0 }, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true };
            animation.updatePlayer(7, input, 1.0 / 60.0);
            animation.updatePlayer(8, input, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            const baseline = animation.states.get(8).?;
            const pelvis_y = @intFromEnum(animation.Control.pelvis_y);
            if (sample.controls[pelvis_y] < baseline.controls[pelvis_y] - 0.07) saw_compression = true;
            const phase = animation.clipPhase(animation.assets.?.motion, sample.phase);
            for (sample.contact_intent, 0..) |intent, index| try std.testing.expectEqual(animation.contactIntent(animation.assets.?.motion, @enumFromInt(index), phase), intent);
            try checkAirPose(sample);
            if (sample.action != .land) continue;
            for ([_][3]animation.Control{
                .{ .left_foot_x, .left_foot_y, .left_foot_angle },
                .{ .right_foot_x, .right_foot_y, .right_foot_angle },
            }, sample.feet, baseline.feet) |bindings, foot, baseline_foot| {
                const ix = @intFromEnum(bindings[0]);
                const iy = @intFromEnum(bindings[1]);
                const ia = @intFromEnum(bindings[2]);
                try std.testing.expectApproxEqAbs(baseline.controls[ix] - baseline_foot.correction.x, sample.controls[ix] - foot.correction.x, 0.000002);
                try std.testing.expectApproxEqAbs(baseline.controls[iy] + baseline_foot.correction.y, sample.controls[iy] + foot.correction.y, 0.000002);
                try std.testing.expectApproxEqAbs(baseline.controls[ia], sample.controls[ia], 0.000002);
            }
            minimum_ankle_x = @min(minimum_ankle_x, sample.controls[@intFromEnum(animation.Control.left_foot_x)]);
            maximum_ankle_x = @max(maximum_ankle_x, sample.controls[@intFromEnum(animation.Control.left_foot_x)]);
        }
        try std.testing.expect(saw_compression);
        try std.testing.expect(maximum_ankle_x - minimum_ankle_x > 0.03);
    }
}

test "ascent keeps both hands above the head and descent lowers them" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    var sample: animation.PlayerState = undefined;
    for (0..30) |tick| {
        sample = advanceAir(.{ .x = 0, .y = -1 }, -4, false);
        try checkAirPose(sample);
        if (tick < 8) continue;
        const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
        for ([_]animation.Joint{ .left_hand, .right_hand }) |hand| try std.testing.expect(pose.joints[@intFromEnum(hand)].y > pose.joints[@intFromEnum(animation.Joint.head)].y + 0.08);
    }
    const rising = animation.interpolatedPose(&animation.assets.?, sample, 1);
    for (0..24) |_| sample = advanceAir(.{ .x = 0, .y = -1 }, 4, false);
    const falling = animation.interpolatedPose(&animation.assets.?, sample, 1);
    for ([_]animation.Joint{ .left_hand, .right_hand }, [_]animation.Joint{ .left_shoulder, .right_shoulder }) |hand, shoulder| {
        try std.testing.expect(falling.joints[@intFromEnum(hand)].y < rising.joints[@intFromEnum(hand)].y - 0.15);
        try std.testing.expect(falling.joints[@intFromEnum(hand)].y > falling.joints[@intFromEnum(shoulder)].y + 0.05);
    }
    try checkAirPose(sample);
}

test "kneeling plants the rear knee and front foot with a low head on both facings" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    const set = &animation.assets.?;
    var samples: std.ArrayList(AirSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]bool{ true, false }) |facing| {
        animation.resetPlayer(7);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = facing };
        for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        input.kneel_requested = true;
        var sample: animation.PlayerState = undefined;
        for (0..90) |tick| {
            animation.updatePlayer(7, input, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            try std.testing.expectEqual(animation.Action.kneel, sample.action);
            try checkAirPose(sample);
            for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                const pose = animation.interpolatedPose(set, sample, alpha);
                for ([_]animation.Joint{ .left_knee, .right_knee }) |knee| {
                    const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(knee)], sample.body, facing);
                    try std.testing.expect(point.y <= 0.3002);
                }
            }
            var joints = animation.interpolatedPose(set, sample, 1).joints;
            for (&joints) |*point| point.* = animation.toWorld(set.rig, point.*, sample.body, facing);
            if (tick >= 30) {
                try std.testing.expectApproxEqAbs(@as(f32, 0.284), joints[@intFromEnum(animation.Joint.right_knee)].y, 0.008);
                try std.testing.expect(joints[@intFromEnum(animation.Joint.left_knee)].y < 0.1);
                try std.testing.expectApproxEqAbs(@as(f32, 0.3), joints[@intFromEnum(animation.Joint.left_toe)].y, 0.00003);
                try std.testing.expect(joints[@intFromEnum(animation.Joint.head)].y > -0.5);
                const sign: f32 = if (facing) 1 else -1;
                try std.testing.expect((joints[@intFromEnum(animation.Joint.head)].x - joints[@intFromEnum(animation.Joint.pelvis)].x) * sign > 0.45);
                for (sample.feet) |foot| try std.testing.expect(foot.locked);
            }
            if (tick % 3 == 0) try samples.append(std.testing.allocator, .{ .action = sample.action, .seconds = sample.action_seconds, .strength = 1, .pose = .{ .speed = sample.speed_mps, .phase = 0, .weight = sample.run_weight, .facing_right = facing, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints } });
        }
        const settled = animation.interpolatedPose(set, sample, 1);
        input.kneel_requested = false;
        for (0..90) |tick| {
            animation.updatePlayer(7, input, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            try std.testing.expectEqual(animation.Action.grounded, sample.action);
            try checkAirPose(sample);
            if (tick == 0) {
                const boundary = animation.interpolatedPose(set, sample, 0);
                for (settled.joints, boundary.joints) |a, b| try nearPoint(a, b, 0.00003);
            }
        }
        try std.testing.expectApproxEqAbs(@as(f32, 0), sample.controls[@intFromEnum(animation.Control.pelvis_y)], 0.0001);
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/kneel_samples.json", bytes);
}

test "Down never crouch walks and horizontal intent exits kneeling before the body moves" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    for ([_]f32{ 0.5, 3.2, 9, -3.2 }) |speed| {
        animation.resetPlayer(7);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true, .kneel_requested = true };
        for (0..60) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
        input.movement_direction = if (speed > 0) 1 else -1;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
        for (0..120) |tick| {
            input.body.x += speed / 60;
            input.horizontal_speed_mps = speed;
            animation.updatePlayer(7, input, 1.0 / 60.0);
            const sample = animation.states.get(7).?;
            try std.testing.expectEqual(animation.Action.grounded, sample.action);
            try checkAirPose(sample);
            if (tick > 30) try std.testing.expect(sample.controls[@intFromEnum(animation.Control.pelvis_y)] > -0.15);
        }
        // Releasing sideways input during residual motion cannot start a kneel.
        input.movement_direction = 0;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
        input.horizontal_speed_mps = 0;
        for (0..60) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
        input.body.y = -0.1;
        input.vertical_speed_mps = -6;
        input.separation_speed_mps = 6;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
        try checkAirPose(animation.states.get(7).?);
    }
}

test "kneeling turns while aiming and losing support releases the stance" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true, .kneel_requested = true };
    for ([_]vec.Vec2{ vec.east, vec.west, vec.east }) |direction| {
        input.aiming = true;
        input.aim_direction = direction;
        for (0..90) |tick| {
            animation.updatePlayer(7, input, 1.0 / 60.0);
            const sample = animation.states.get(7).?;
            try std.testing.expectEqual(animation.Action.kneel, sample.action);
            try checkAirPose(sample);
            for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
                for ([_]animation.Joint{ .left_knee, .right_knee }) |knee| {
                    const point = animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(knee)], sample.body, sample.facing_right);
                    errdefer std.log.err("kneel turn: tick {d}, alpha {d}, knee {s}, point {any}", .{ tick, alpha, @tagName(knee), point });
                    try std.testing.expect(point.y <= 0.3002);
                }
            }
        }
    }
    input.supported = false;
    input.ground_y = null;
    input.vertical_speed_mps = 2;
    animation.updatePlayer(7, input, 1.0 / 60.0);
    const falling = animation.states.get(7).?;
    try std.testing.expectEqual(animation.Action.fall, falling.action);
    for (falling.feet) |foot| try std.testing.expect(!foot.locked);
}

test "landing has priority over Down and only settles into kneeling after impact recovery" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    for ([_]f32{ 0, 3.2 }) |speed| {
        animation.resetPlayer(7);
        _ = advanceAir(.{ .x = 0, .y = -0.1 }, 16, false);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true, .kneel_requested = true, .horizontal_speed_mps = speed };
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.land, animation.states.get(7).?.action);
        for (0..90) |tick| {
            input.body.x += speed / 60;
            animation.updatePlayer(7, input, 1.0 / 60.0);
            const sample = animation.states.get(7).?;
            if (sample.action_seconds > 0.07 and sample.action == .land) {
                const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
                for ([_]animation.Joint{ .left_knee, .right_knee }) |knee| {
                    const point = animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(knee)], sample.body, sample.facing_right);
                    errdefer std.log.err("landing knee: speed {d}, tick {d}, {s}, y {d}", .{ speed, tick, @tagName(knee), point.y });
                    // Running keeps its leg cycle; only a stationary landing
                    // has the symmetric squat's larger knee clearance.
                    try std.testing.expect(point.y < (if (speed == 0) @as(f32, 0.2) else 0.3002));
                }
            }
            if (tick < 15) try std.testing.expectEqual(animation.Action.land, sample.action);
            try checkAirPose(sample);
        }
        try std.testing.expectEqual(if (speed == 0) animation.Action.kneel else animation.Action.grounded, animation.states.get(7).?.action);
    }
}

test "SVG L sprites preserve their colors and transparency when stained with red blood" {
    runtime.init(std.testing.io);
    const fixtures = .{
        .{ "level_assets/animation_tests/low_l.svg", sdl.Color{ .r = 135, .g = 152, .b = 170, .a = 255 } },
        .{ "level_assets/animation_tests/tall_l.svg", sdl.Color{ .r = 166, .g = 148, .b = 124, .a = 255 } },
    };
    inline for (fixtures) |fixture| {
        const surface = try sdl.image.load(fixture[0]);
        defer sdl.destroySurface(surface);
        var before: sdl.Color = undefined;
        try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(surface, 288, @divTrunc(surface.h, 2), &before.r, &before.g, &before.b, &before.a));
        try std.testing.expectEqualDeep(fixture[1], before);

        // The CPU stain entry point only consumes the surface and rendered scale.
        var visual: sprite.Sprite = undefined;
        visual.surface = surface;
        visual.scale = .{ .x = 1, .y = 1 };
        const sprite_id = 998877;
        try sprite.sprites.putLocking(sprite_id, visual);
        defer _ = sprite.sprites.fetchSwapRemoveLocking(sprite_id);
        const dirty = try sprite.stainSplatOnSurface(sprite_id, .{ .x = 128 / conv.met2pix, .y = 0 }, 12 / conv.met2pix, vec.zero, 0, .{ .r = 220, .g = 0, .b = 0 }, vec.zero, 42);
        try std.testing.expect(dirty != null);
        var after: sdl.Color = undefined;
        try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(surface, 288, @divTrunc(surface.h, 2), &after.r, &after.g, &after.b, &after.a));
        try std.testing.expect(after.r > after.b and after.r > after.g);
        try std.testing.expectEqual(before.a, after.a);
        try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(surface, 16, surface.h - 6, &after.r, &after.g, &after.b, &after.a));
        try std.testing.expectEqualDeep(before, after);

        // A stain centered in the empty part of the L must not fill its alpha.
        _ = try sprite.stainSplatOnSurface(sprite_id, .{ .x = -60 / conv.met2pix, .y = (6 - @as(f32, @floatFromInt(surface.h)) / 2) / conv.met2pix }, 4 / conv.met2pix, vec.zero, 0, .{ .r = 220, .g = 0, .b = 0 }, vec.zero, 42);
        try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(surface, 100, 6, null, null, null, &after.a));
        try std.testing.expectEqual(@as(u8, 0), after.a);
    }
}

test "image loading preserves decoded colors and alpha in the shared BGRA surface format" {
    for ([_][*:0]const u8{
        "level_assets/animation_tests/low_l.svg",
        "level_assets/animation_tests/tall_l.svg",
        "weapons/alien_blaster/weapon.svg",
        "weapons/rocket_launcher/weapon_with_arm.png",
        "level_assets/medieval_keep/terrain/stone_block_runtime.png",
    }) |path| {
        const decoded: *sdl.Surface = sdl.c.IMG_Load(path) orelse {
            std.log.err("image format test: could not decode {s}: {s}", .{ path, sdl.c.SDL_GetError() });
            return error.IMGLoadFailed;
        };
        defer sdl.destroySurface(decoded);
        const loaded = try sdl.image.load(path);
        defer sdl.destroySurface(loaded);
        try std.testing.expectEqual(@as(c_uint, sdl.c.SDL_PIXELFORMAT_BGRA32), loaded.format);
        try std.testing.expectEqual(decoded.w, loaded.w);
        try std.testing.expectEqual(decoded.h, loaded.h);
        var y: c_int = 0;
        while (y < decoded.h) : (y += 1) {
            var x: c_int = 0;
            while (x < decoded.w) : (x += 1) {
                var expected: sdl.Color = undefined;
                var actual: sdl.Color = undefined;
                try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(decoded, x, y, &expected.r, &expected.g, &expected.b, &expected.a));
                try std.testing.expect(sdl.c.SDL_ReadSurfacePixel(loaded, x, y, &actual.r, &actual.g, &actual.b, &actual.a));
                try std.testing.expectEqualDeep(expected, actual);
            }
        }
    }
}

test "blaster source loads through SDL and its grip and muzzle markers are extracted" {
    const surface = try sdl.image.load("weapons/alien_blaster/weapon.svg");
    defer sdl.destroySurface(surface);
    try std.testing.expectEqual(@as(c_int, 160), surface.w);
    try std.testing.expectEqual(@as(c_int, 96), surface.h);
    const points = sprite.extractMarkerPoints(surface, .{ .x = 1, .y = 1 }, .{ .anchorLeft = true, .muzzle = true });
    try std.testing.expect(points.anchorPointLeft != null);
    try std.testing.expect(points.muzzlePoint != null);
    try nearPoint(.{ .x = 49, .y = 64 }, points.anchorPointLeft.?, 0.00001);
    try nearPoint(.{ .x = 151, .y = 35 }, points.muzzlePoint.?, 0.00001);
    // Extraction replaces the grip marker and removes the transparent muzzle marker.
    const second = sprite.extractMarkerPoints(surface, .{ .x = 1, .y = 1 }, .{ .anchorLeft = true, .muzzle = true });
    try std.testing.expect(second.anchorPointLeft == null and second.muzzlePoint == null);
    const original = try sdl.image.load("weapons/rocket_launcher/weapon_with_arm.png");
    defer sdl.destroySurface(original);
    const original_points = sprite.extractMarkerPoints(original, .{ .x = 1, .y = 1 }, .{ .anchorLeft = true, .muzzle = true });
    try std.testing.expect(original_points.anchorPointLeft != null and original_points.muzzlePoint != null);
}

test "anchored sprite keeps its grip fixed and mirrors the muzzle across both facings" {
    var image: sprite.Sprite = undefined; // Pure placement only consumes rendered dimensions.
    image.sizeP = .{ .x = 161, .y = 97 };
    const grip: vec.IVec2 = .{ .x = 49, .y = 64 };
    const muzzle: vec.IVec2 = .{ .x = 151, .y = 35 };
    const position: vec.IVec2 = .{ .x = -131, .y = 277 };
    try std.testing.expectEqual(vec.IVec2{ .x = -29, .y = 248 }, sprite.placedPoint(image, sprite.placeAtAnchor(image, grip, position, 0, false), muzzle));
    try std.testing.expectEqual(vec.IVec2{ .x = -233, .y = 248 }, sprite.placedPoint(image, sprite.placeAtAnchor(image, grip, position, 0, true), muzzle));
    for (0..73) |frame| {
        const angle = @as(f32, @floatFromInt(frame)) * std.math.tau / 72;
        const right = sprite.placeAtAnchor(image, grip, position, angle, false);
        const left = sprite.placeAtAnchor(image, grip, position, -angle, true);
        for ([_]sprite.AnchoredPlacement{ right, left }) |placement| {
            try std.testing.expectEqual(position, sprite.placedPoint(image, placement, grip));
            try std.testing.expectEqual(position.x, placement.centerPosition.x - @divTrunc(image.sizeP.x, 2) + placement.pivot.x);
            try std.testing.expectEqual(position.y, placement.centerPosition.y - @divTrunc(image.sizeP.y, 2) + placement.pivot.y);
        }
        const a = sprite.placedPoint(image, right, muzzle);
        const b = sprite.placedPoint(image, left, muzzle);
        try std.testing.expectEqual(2 * position.x, a.x + b.x);
        try std.testing.expectEqual(a.y, b.y);
    }
}

test "carried attachment uses solved wrist rotation through running kneeling and airborne interpolation" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const set = &animation.assets.?;
    const attachment = set.rig.attachments.getPtr("weapon_hand").?;
    attachment.angle_offset_radians = 0.3;
    attachment.local_offset = .{ .x = 0.025, .y = -0.01 };
    var x: f32 = 0;
    for (0..240) |tick| {
        const kneeling = tick >= 150 and tick < 200;
        const speed: f32 = if (kneeling) 0 else if (tick < 120) 3.2 else -3.2;
        x += speed / 60;
        const in_air = tick >= 60 and tick < 110;
        const vertical: f32 = if (tick < 85) -6 else 8;
        animation.updatePlayer(7, .{ .body = .{ .x = x, .y = if (in_air) -0.2 else 0 }, .supported = !in_air, .ground_y = if (in_air) null else 0.3, .vertical_speed_mps = if (in_air) vertical else 0, .separation_speed_mps = if (in_air) -vertical else 0, .facing_right = speed > 0, .kneel_requested = kneeling }, 1.0 / 60.0);
        const sample = animation.states.get(7).?;
        if (kneeling) try std.testing.expectEqual(animation.Action.kneel, sample.action);
        for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
            const pose = animation.interpolatedPose(set, sample, alpha);
            const local = animation.attachmentTransform(set.rig, pose, "weapon_hand").?;
            const hand = pose.joints[@intFromEnum(animation.Joint.right_hand)];
            const elbow = pose.joints[@intFromEnum(animation.Joint.right_elbow)];
            const direction = vec.normalize(vec.subtract(hand, elbow));
            const offset = vec.subtract(local.position, hand);
            try std.testing.expectApproxEqAbs(@as(f32, 0.025), offset.x * direction.x + offset.y * direction.y, 0.00001);
            try std.testing.expectApproxEqAbs(@as(f32, -0.01), -offset.x * direction.y + offset.y * direction.x, 0.00001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.3), local.angle - std.math.atan2(direction.y, direction.x), 0.00001);
            const right = animation.attachmentToWorld(set.rig, local, sample.body, true);
            const left = animation.attachmentToWorld(set.rig, local, sample.body, false);
            try std.testing.expectApproxEqAbs(sample.body.x * 2, right.position.x + left.position.x, 0.00001);
            try std.testing.expectEqual(right.position.y, left.position.y);
            try std.testing.expectEqual(-right.angle, left.angle);
        }
    }
}

test "carried weapon selection respects view aiming and optional weapon visuals" {
    animation.installAssets(try load());
    defer animation.cleanup();
    const old_view = animation.view;
    defer animation.view = old_view;
    var weapons = [_]weapon.Weapon{std.mem.zeroes(weapon.Weapon)};
    weapons[0].standaloneSpriteUuid = 123;
    var p = std.mem.zeroes(player.Player);
    p.weapons = &weapons;
    for ([_]animation.View{ .stick, .overlay }) |mode| {
        animation.view = mode;
        p.isAiming = false;
        try std.testing.expect(player.usesProceduralWeapon(p));
        p.isAiming = true;
        try std.testing.expect(player.usesProceduralWeapon(p));
    }
    animation.view = .sprites;
    p.isAiming = false;
    try std.testing.expect(!player.usesProceduralWeapon(p));
    animation.view = .stick;
    weapons[0].standaloneSpriteUuid = 0;
    try std.testing.expect(!player.usesProceduralWeapon(p));
}

const AimSample = struct { action: []const u8, direction: vec.Vec2, frame: animation.FramePose };

test "aim IK preserves legs and grip while the barrel points in every direction on either facing" {
    runtime.init(std.testing.io);
    var set = try load();
    defer set.arena.deinit();
    var samples: std.ArrayListUnmanaged(AimSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    const body: vec.Vec2 = .{ .x = 2, .y = 3 };
    for ([_][]const u8{ "neutral", "run", "kneel", "jump", "fall" }) |action| {
        var base = animation.evaluatePose(&set, 0.25, .neutral);
        if (std.mem.eql(u8, action, "run")) base = animation.evaluatePose(&set, 0.25, .run);
        if (!std.mem.eql(u8, action, "run") and !std.mem.eql(u8, action, "neutral")) {
            const clip = if (std.mem.eql(u8, action, "jump")) set.actions.jump else if (std.mem.eql(u8, action, "fall")) set.actions.fall else set.actions.kneel;
            var controls = set.rig.neutral;
            const phase: f32 = 1;
            for (&controls, clip.tracks) |*value, track| value.* = animation.evaluateTrack(track, phase);
            base = animation.solvePose(set.rig, controls);
        }
        for ([_]bool{ true, false }) |facing| {
            for ([_]vec.Vec2{ vec.east, .{ .x = 1, .y = 1 }, vec.north, .{ .x = -1, .y = 1 }, vec.west, .{ .x = -1, .y = -1 }, vec.south, .{ .x = 1, .y = -1 } }) |raw| {
                const direction = vec.normalize(raw);
                for ([_]f32{ 0, 0.25, 0.5, 0.75, 1 }) |weight| {
                    const frame = animation.solveAimedPose(&set, base, body, facing, direction, weight, null);
                    try checkBones(set.rig, frame.pose);
                    try std.testing.expectEqual(base.contact_intent, frame.pose.contact_intent);
                    for (base.joints, frame.pose.joints, 0..) |before, after, joint| {
                        if (joint == @intFromEnum(animation.Joint.right_elbow) or joint == @intFromEnum(animation.Joint.right_hand)) continue;
                        try nearPoint(before, after, 0.000001);
                    }
                    const grip = animation.attachmentPosition(set.rig, frame.pose, "weapon_hand").?;
                    try nearPoint(animation.toWorld(set.rig, grip, body, facing), frame.weapon.position, 0.000001);
                    if (weight != 1) continue;
                    const sign: f32 = if (frame.weapon_facing_right) 1 else -1;
                    try nearPoint(direction, .{ .x = @cos(frame.weapon.angle) * sign, .y = -@sin(frame.weapon.angle) * sign }, 0.000002);
                    try std.testing.expect(!frame.pose.clamped[@intFromEnum(animation.Limb.right_arm)]);
                    const shoulder = frame.pose.joints[@intFromEnum(animation.Joint.right_shoulder)];
                    const elbow = frame.pose.joints[@intFromEnum(animation.Joint.right_elbow)];
                    const wrist = frame.pose.joints[@intFromEnum(animation.Joint.right_hand)];
                    const upper_direction = vec.normalize(vec.subtract(elbow, shoulder));
                    const lower_direction = vec.normalize(vec.subtract(wrist, elbow));
                    const alignment = upper_direction.x * lower_direction.x + upper_direction.y * lower_direction.y;
                    // Nearly straight, with a small visible bend instead of a
                    // locked elbow: between 5 and 25 degrees from full extension.
                    try std.testing.expect(alignment > @cos(@as(f32, 25 * std.math.pi / 180.0)));
                    try std.testing.expect(alignment < @cos(@as(f32, 5 * std.math.pi / 180.0)));
                    var world = frame;
                    for (&world.pose.joints) |*joint| joint.* = animation.toWorld(set.rig, joint.*, body, facing);
                    try samples.append(std.testing.allocator, .{ .action = action, .direction = direction, .frame = world });
                }
            }
        }
    }
    // Nonzero authored grip offsets and the other hand use the same solver path.
    const attachment = set.rig.attachments.getPtr("weapon_hand").?;
    attachment.joint = .left_hand;
    attachment.local_offset = .{ .x = 0.02, .y = 0.01 };
    attachment.angle_offset_radians = 0.4;
    const base = animation.evaluatePose(&set, 0.25, .run);
    const other = animation.solveAimedPose(&set, base, body, false, vec.east, 1, null);
    try checkBones(set.rig, other.pose);
    try nearPoint(base.joints[@intFromEnum(animation.Joint.right_hand)], other.pose.joints[@intFromEnum(animation.Joint.right_hand)], 0.000001);
    try nearPoint(animation.toWorld(set.rig, animation.attachmentPosition(set.rig, other.pose, "weapon_hand").?, body, false), other.weapon.position, 0.000001);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try fs.writeFile("artifacts/character_animation/aim_samples.json", bytes);
}

const aiming_sprite_id: u64 = 900017;

// A real movement body/input/player with CPU-only sprite metadata. No GPU is
// needed to exercise the production world-space placement and shooting paths.
fn beginAimingPlayer() !box2d.c.b2BodyId {
    runtime.init(std.testing.io);
    _ = try beginLocomotion();
    errdefer box2d.destroyWorld();
    errdefer animation.cleanup();
    const body = try box2d.createBody(box2d.createNonRotatingDynamicBodyDef(vec.zero));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_PLAYER;
    shape.filter.maskBits = collision.MASK_PLAYER;
    shape.material.friction = 0;
    const circle = box2d.c.b2Circle{ .center = .{ .x = 0, .y = 0 }, .radius = player.lowerBodyColliderRadius };
    const body_shape = box2d.c.b2CreateCircleShape(body, &shape, &circle);
    var p = std.mem.zeroes(player.Player);
    p.id = 7;
    p.bodyId = body;
    p.aimDirection = vec.east;
    p.weapons = try std.testing.allocator.alloc(weapon.Weapon, 2);
    errdefer std.testing.allocator.free(p.weapons);
    for (p.weapons, 0..) |*w, index| {
        w.* = .{ .name = "aim_test", .delay = 0, .sound = .{ .file = "sounds/cannon_fire.wav", .durationMs = 10000, .volume = 0 }, .impulse = 0, .spriteUuid = aiming_sprite_id, .standaloneSpriteUuid = aiming_sprite_id, .range = if (index == 0) 3 else 5, .trailDurationMs = 1000 };
    }
    try player.players.put(allocator.allocator, 7, p);
    errdefer _ = player.players.swapRemove(7);
    try player_input.register(7);
    errdefer _ = player_input.playerInputs.swapRemove(7);
    try movement.states.put(allocator.allocator, 7, .{ .bodyId = body, .footSensorShapeId = body_shape, .leftWallSensorId = body_shape, .rightWallSensorId = body_shape, .facingRight = true });
    errdefer _ = movement.states.swapRemove(7);
    try movement.configure(try data.loadMovementData("movements/towerfall_keep.json"));
    var ent = std.mem.zeroes(entity.Entity);
    ent.spriteUuids = try std.testing.allocator.alloc(u64, 1);
    errdefer std.testing.allocator.free(ent.spriteUuids);
    ent.spriteUuids[0] = aiming_sprite_id;
    ent.bodyId = body;
    ent.state = box2d.getState(body);
    ent.flipEntityHorizontally = true;
    try entity.entities.putLocking(body, ent);
    errdefer _ = entity.entities.fetchSwapRemoveLocking(body);
    var visual: sprite.Sprite = undefined;
    visual.sizeP = .{ .x = 48, .y = 29 };
    visual.offset = vec.izero;
    visual.anchorPointLeft = .{ .x = 15, .y = 19 };
    visual.anchorPointRight = .{ .x = 33, .y = 19 };
    visual.muzzlePoint = .{ .x = 45, .y = 11 };
    visual.imgPath = "aim fixture";
    try sprite.sprites.putLocking(aiming_sprite_id, visual);
    errdefer _ = sprite.sprites.fetchSwapRemoveLocking(aiming_sprite_id);
    animation.view = .stick;
    for (0..5) |_| {
        movement.applyAll(1.0 / 60.0);
        box2d.worldStep(1.0 / 60.0, 4);
        try movement.processSensorEvents();
        animation.fixedUpdate(1.0 / 60.0);
    }
    return body;
}

fn endAimingPlayer(body: box2d.c.b2BodyId) void {
    const ent = entity.entities.fetchSwapRemoveLocking(body).?.value;
    std.testing.allocator.free(ent.spriteUuids);
    _ = sprite.sprites.fetchSwapRemoveLocking(aiming_sprite_id);
    const p = player.players.fetchSwapRemove(7).?.value;
    std.testing.allocator.free(p.weapons);
    _ = movement.states.swapRemove(7);
    _ = player_input.playerInputs.swapRemove(7);
    animation.cleanup();
    box2d.destroyWorld();
}

fn submitAim(direction: vec.Vec2, held: bool) void {
    var sample: player_input.Sample = .{ .movementDirection = direction, .aimDirection = direction };
    sample.buttons.set(.shoot, held);
    player_input.submit(7, sample);
    control.applyPlayerInput(7);
}

fn stepAimingMovement() !void {
    player_input.beginPhysicsStep();
    defer player_input.endPhysicsStep();
    movement.applyAll(1.0 / 60.0);
    box2d.worldStep(1.0 / 60.0, 4);
    try movement.resolveGroundMovement();
    try movement.processSensorEvents();
    animation.fixedUpdate(1.0 / 60.0);
}

fn addTraversalTorso(body: box2d.c.b2BodyId) void {
    box2d.c.b2Body_SetGravityScale(body, movement.bodyMotion.gravityScale);
    box2d.c.b2Body_SetLinearDamping(body, movement.bodyMotion.linearDamping);
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_PLAYER;
    shape.filter.maskBits = collision.MASK_PLAYER;
    shape.material.friction = 0;
    const polygon = box2d.c.b2MakeOffsetBox(player.bodyColliderHalfWidth, player.bodyColliderHalfHeight, vec.toBox2d(player.bodyColliderOffset), box2d.c.b2MakeRot(0));
    _ = box2d.c.b2CreatePolygonShape(body, &shape, &polygon);
}

test "real controller contacts drive static slope adaptation through kneeling aiming jumping and landing" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_SENSOR;
    filter.maskBits = collision.CATEGORY_TERRAIN;
    const hit = box2d.castRayClosest(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, filter);
    try std.testing.expect(hit.hit);
    const floor = box2d.c.b2Shape_GetBody(hit.shapeId);
    for ([_]f32{ -0.55, -0.25, 0.25, 0.55 }) |angle| {
        const rotation = box2d.c.b2MakeRot(angle);
        box2d.c.b2Body_SetTransform(floor, .{ .x = 0, .y = 0.3 + 0.5 / rotation.c }, rotation);
        box2d.c.b2Body_SetTransform(body, .{ .x = 0, .y = -0.15 }, box2d.c.b2MakeRot(0));
        box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
        movement.reset(7);
        animation.resetPlayer(7);
        submitAim(vec.south, false);
        for (0..120) |_| try stepAimingMovement();
        errdefer std.log.err("real slope: angle {d}, velocity {any}, action {s}", .{ angle, box2d.c.b2Body_GetLinearVelocity(body), @tagName(animation.states.get(7).?.action) });
        try std.testing.expect(movement.states.get(7).?.groundState.supported);
        try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
        try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
        submitAim(vec.west, true);
        for (0..45) |_| {
            try stepAimingMovement();
            try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
            try checkTerrainPose(animation.states.get(7).?, rotation.s / rotation.c);
        }
        var input: player_input.Sample = .{ .aimDirection = vec.west };
        input.buttons.set(.shoot, true);
        input.buttons.set(.jump, true);
        player_input.submit(7, input);
        control.applyPlayerInput(7);
        try stepAimingMovement();
        try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
        input.buttons.set(.jump, false);
        player_input.submit(7, input);
        control.applyPlayerInput(7);
        var landed = false;
        for (0..180) |_| {
            try stepAimingMovement();
            const sample = animation.states.get(7).?;
            if (sample.action == .land) landed = true;
            if (sample.action == .jump or sample.action == .fall) continue;
            try checkTerrainPose(sample, rotation.s / rotation.c);
        }
        try std.testing.expect(landed);
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
        for ([_]vec.Vec2{ vec.east, vec.west }) |direction| {
            submitAim(vec.zero, false);
            for (0..120) |_| try stepAimingMovement();
            const start_x = box2d.c.b2Body_GetPosition(body).x;
            submitAim(direction, false);
            var supported_steps: usize = 0;
            var controller_supported_steps: usize = 0;
            for (0..120) |_| {
                try stepAimingMovement();
                if (movement.states.get(7).?.groundState.supported) controller_supported_steps += 1;
                const sample = animation.states.get(7).?;
                if (sample.action == .jump or sample.action == .fall) {
                    for (sample.feet) |foot| try std.testing.expect(!foot.locked);
                    for ([_]f64{ 0, 0.5, 1 }) |alpha| try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, alpha));
                    continue;
                }
                supported_steps += 1;
                try checkTerrainPose(sample, rotation.s / rotation.c);
            }
            const distance = (box2d.c.b2Body_GetPosition(body).x - start_x) * direction.x;
            errdefer std.log.err("real slope run: direction {any}, supported {d}, controller supported {d}, distance {d}, input {any}, mechanism {s}", .{ direction, supported_steps, controller_supported_steps, distance, movement.locomotionDirection(7), @tagName(movement.mechanism) });
            try std.testing.expectEqual(@as(usize, 120), supported_steps);
            try std.testing.expectEqual(@as(usize, 120), controller_supported_steps);
            try std.testing.expect(distance > 15);
            try std.testing.expectApproxEqAbs(direction.x * movement.towerfallSettings.control.maxRunSpeed, box2d.c.b2Body_GetLinearVelocity(body).x, 0.03);
        }
    }
}

test "real controller climbs and descends 0.2 through 0.5 meter stairs without jumping" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    for ([_]f32{ 0.2, 0.3, 0.4, 0.5 }) |height| {
        for ([_]f32{ -1, 1 }) |direction| {
            var stairs: [3]box2d.c.b2BodyId = undefined;
            for (&stairs, 0..) |*stair, index| {
                const step: f32 = @floatFromInt(index);
                const half_width: f32 = if (index == 2) 50 else 0.6;
                stair.* = try addTerrainBox(.{ .x = direction * (step * 1.2 + half_width), .y = 0.8 - height * (step + 1) }, .{ .x = half_width, .y = 0.5 });
            }
            defer for (stairs) |stair| box2d.c.b2DestroyBody(stair);
            box2d.c.b2Body_SetTransform(body, .{ .x = -2 * direction, .y = -0.02 }, box2d.c.b2MakeRot(0));
            box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
            movement.reset(7);
            animation.resetPlayer(7);
            submitAim(vec.zero, false);
            for (0..30) |_| try stepAimingMovement();
            for ([_]f32{ direction, -direction }) |travel| {
                submitAim(.{ .x = travel, .y = 0 }, false);
                for (0..65) |tick| {
                    try stepAimingMovement();
                    const sample = animation.states.get(7).?;
                    errdefer std.log.err("stairs: height {d}, direction {d}, travel {d}, tick {d}, body {any}, action {s}, support {}", .{ height, direction, travel, tick, sample.body, @tagName(sample.action), movement.states.get(7).?.groundState.supported });
                    try std.testing.expectEqual(animation.Action.grounded, sample.action);
                    const set = &animation.assets.?;
                    for ([_]f64{ 0, 0.5, 1 }) |alpha| {
                        const pose = animation.interpolatedPose(set, sample, alpha);
                        try checkBones(set.rig, pose);
                        const position = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
                        for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                            const point = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], position, sample.facing_right);
                            const step = std.math.clamp(@floor(point.x * direction / 1.2) + 1, 0, 3);
                            errdefer std.log.err("stairs sole: {s}, alpha {d}, point {any}, floor {d}", .{ @tagName(joint), alpha, point, 0.3 - step * height });
                            try std.testing.expect(point.y <= 0.3 - step * height + 0.002);
                        }
                    }
                }
                const position = box2d.c.b2Body_GetPosition(body);
                if (travel == direction) {
                    try std.testing.expect(position.x * direction > 4);
                    try std.testing.expect(position.y < -height * 3 + 0.03);
                } else {
                    try std.testing.expect(position.x * direction < -0.4);
                    try std.testing.expectApproxEqAbs(@as(f32, 0), position.y, 0.03);
                }
            }
        }
    }
}

test "step climbing works from rest against a riser and at low speed" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    for ([_]f32{ 0.3, 0.5 }) |height| {
        for ([_]f32{ -1, 1 }) |direction| {
            const stair = try addTerrainBox(.{ .x = direction * 50, .y = 0.8 - height }, .{ .x = 50, .y = 0.5 });
            defer box2d.c.b2DestroyBody(stair);
            for ([_]f32{ 0.1, 1 }) |speed| {
                box2d.c.b2Body_SetTransform(body, .{ .x = -0.31 * direction, .y = -0.02 }, box2d.c.b2MakeRot(0));
                box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
                movement.reset(7);
                animation.resetPlayer(7);
                submitAim(vec.zero, false);
                for (0..30) |_| try stepAimingMovement();
                submitAim(.{ .x = direction * speed, .y = 0 }, false);
                for (0..90) |tick| {
                    try stepAimingMovement();
                    const sample = animation.states.get(7).?;
                    try std.testing.expectEqual(animation.Action.grounded, sample.action);
                    try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, 0.5));
                    if (tick != 5) continue;
                    submitAim(vec.zero, false);
                    for (0..15) |_| {
                        try stepAimingMovement();
                        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
                    }
                    submitAim(.{ .x = direction * speed, .y = 0 }, false);
                }
                const position = box2d.c.b2Body_GetPosition(body);
                errdefer std.log.err("step from rest: height {d}, direction {d}, speed {d}, position {any}", .{ height, direction, speed, position });
                try std.testing.expect(position.x * direction > 0.5);
                try std.testing.expectApproxEqAbs(-height, position.y, 0.03);
            }
        }
    }
}

test "ground following preserves upward motion generated during the physics step" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    submitAim(vec.zero, false);
    for (0..30) |_| try stepAimingMovement();
    try std.testing.expect(movement.states.get(7).?.groundState.supported);
    player_input.beginPhysicsStep();
    defer player_input.endPhysicsStep();
    movement.applyAll(1.0 / 60.0);
    try std.testing.expect(movement.states.get(7).?.followGround);
    const mass = box2d.c.b2Body_GetMass(body);
    box2d.c.b2Body_ApplyForceToCenter(body, .{ .x = 0, .y = -mass * 600 }, true);
    box2d.worldStep(1.0 / 60.0, 4);
    const position = vec.fromBox2d(box2d.c.b2Body_GetPosition(body));
    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body));
    try std.testing.expect(velocity.y < -5);
    try movement.resolveGroundMovement();
    try nearPoint(position, vec.fromBox2d(box2d.c.b2Body_GetPosition(body)), 0.000001);
    try nearPoint(velocity, vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body)), 0.000001);
    try std.testing.expect(!movement.states.get(7).?.followGround);
    try movement.processSensorEvents();
    animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
}

fn addRubbleBox(position: vec.Vec2, half_size: vec.Vec2) !box2d.c.b2BodyId {
    const body = try box2d.createBody(box2d.createDynamicBodyDef(position));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_RUBBLE;
    shape.filter.maskBits = collision.MASK_RUBBLE;
    shape.material.friction = 0.7;
    shape.material.restitution = 0.08;
    shape.density = 1.2;
    // Runtime rubble is triangulated with a 1 cm collision radius.
    const extent = vec.subtract(half_size, .{ .x = 0.01, .y = 0.01 });
    const corners = [_]box2d.c.b2Vec2{
        .{ .x = -extent.x, .y = -extent.y },
        .{ .x = extent.x, .y = -extent.y },
        .{ .x = extent.x, .y = extent.y },
        .{ .x = -extent.x, .y = extent.y },
    };
    for ([_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |indices| {
        const vertices = [_]box2d.c.b2Vec2{ corners[indices[0]], corners[indices[1]], corners[indices[2]] };
        const hull = box2d.c.b2ComputeHull(&vertices, 3);
        const polygon = box2d.c.b2MakePolygon(&hull, 0.01);
        _ = box2d.c.b2CreatePolygonShape(body, &shape, &polygon);
    }
    return body;
}

test "controller steps onto sleeping and awake dynamic rubble up to half a meter" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    for ([_]f32{ 0.3, 0.5 }) |height| {
        for ([_]f32{ -1, 1 }) |direction| {
            const piece = try addRubbleBox(.{ .x = direction * 1.5, .y = 0.3 - height / 2 }, .{ .x = 1.5, .y = height / 2 });
            defer box2d.c.b2DestroyBody(piece);
            for ([_]bool{ true, false }) |asleep| {
                box2d.c.b2Body_SetTransform(piece, .{ .x = direction * 1.5, .y = 0.3 - height / 2 }, box2d.c.b2MakeRot(0));
                box2d.c.b2Body_SetLinearVelocity(piece, .{ .x = 0, .y = 0 });
                box2d.c.b2Body_SetAngularVelocity(piece, 0);
                box2d.c.b2Body_SetTransform(body, .{ .x = -0.31 * direction, .y = -0.02 }, box2d.c.b2MakeRot(0));
                box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
                movement.reset(7);
                animation.resetPlayer(7);
                submitAim(vec.zero, false);
                for (0..30) |_| try stepAimingMovement();
                box2d.c.b2Body_SetAwake(piece, !asleep);
                submitAim(.{ .x = direction, .y = 0 }, false);
                var stood = false;
                var planted = false;
                var highest: f32 = 0;
                for (0..90) |_| {
                    try stepAimingMovement();
                    const sample = animation.states.get(7).?;
                    highest = @min(highest, sample.body.y);
                    const contact = movement.states.get(7).?.groundState.groundContact;
                    if (contact != null and box2d.c.B2_ID_EQUALS(contact.?.bodyId, piece)) stood = true;
                    for (sample.feet) |foot| {
                        if (foot.locked and foot.support != null and box2d.c.B2_ID_EQUALS(foot.support.?.bodyId, piece)) planted = true;
                    }
                    try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, 0.5));
                }
                errdefer std.log.err("rubble step: height {d}, direction {d}, asleep {}, stood {}, planted {}, highest {d}, body {any}", .{ height, direction, asleep, stood, planted, highest, box2d.c.b2Body_GetPosition(body) });
                try std.testing.expect(stood and planted);
                try std.testing.expect(highest < -height + 0.04);
                try std.testing.expect(box2d.c.b2Body_GetPosition(body).x * direction > 4);
            }
        }
    }
}

test "controller steps onto pooled giblets and plants feet on their colliders" {
    const old_view = animation.view;
    defer animation.view = old_view;
    for ([_]f32{ -1, 1 }) |direction| {
        const body = try beginAimingPlayer();
        defer endAimingPlayer(body);
        addTraversalTorso(body);
        const giblet = try box2d.createBody(box2d.createDynamicBodyDef(.{ .x = direction * 1.5, .y = 0.15 }));
        var shape = box2d.c.b2DefaultShapeDef();
        shape.filter.categoryBits = collision.CATEGORY_GIBLET;
        shape.filter.maskBits = collision.MASK_GIBLET;
        shape.material.friction = 0.5;
        const polygon = box2d.c.b2MakeBox(1.5, 0.15);
        _ = box2d.c.b2CreatePolygonShape(giblet, &shape, &polygon);
        const pool_id = try pool.create(&.{giblet});
        defer allocator.allocator.free(pool.takeBodyIds(pool_id) catch unreachable);
        _ = (try pool.acquire(pool_id, .return_null)).?;
        box2d.c.b2Body_SetTransform(body, .{ .x = -0.31 * direction, .y = -0.02 }, box2d.c.b2MakeRot(0));
        movement.reset(7);
        animation.resetPlayer(7);
        submitAim(vec.zero, false);
        for (0..30) |_| try stepAimingMovement();
        submitAim(.{ .x = direction, .y = 0 }, false);
        var planted = false;
        for (0..90) |_| {
            try stepAimingMovement();
            for (animation.states.get(7).?.feet) |foot| {
                if (foot.locked and foot.support != null and box2d.c.B2_ID_EQUALS(foot.support.?.bodyId, giblet)) planted = true;
            }
        }
        try std.testing.expect(planted);
        try std.testing.expect(box2d.c.b2Body_GetPosition(body).x * direction > 4);
    }
}

fn addDynamicL(height: f32, direction: f32) !box2d.c.b2BodyId {
    const body = try box2d.createBody(box2d.createDynamicBodyDef(.{ .x = 0, .y = 0.1 }));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_DYNAMIC;
    shape.filter.maskBits = collision.MASK_DYNAMIC;
    shape.material.friction = 0;
    const base = box2d.c.b2MakeBox(3, 0.2);
    _ = box2d.c.b2CreatePolygonShape(body, &shape, &base);
    const upright = box2d.c.b2MakeOffsetBox(0.5, height / 2, .{ .x = direction * 1.5, .y = -0.2 - height / 2 }, box2d.c.b2MakeRot(0));
    _ = box2d.c.b2CreatePolygonShape(body, &shape, &upright);
    return body;
}

test "grounding and foot probes use solid collision pairs including custom categories and group overrides" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const custom_category: u64 = 1 << 30;
    const cases = [_]struct { player_group: i32, support_group: i32, mask: u64, supported: bool }{
        .{ .player_group = 0, .support_group = 0, .mask = collision.CATEGORY_PLAYER, .supported = true },
        .{ .player_group = 2, .support_group = 2, .mask = collision.CATEGORY_PLAYER, .supported = true },
        .{ .player_group = -2, .support_group = -2, .mask = collision.CATEGORY_PLAYER, .supported = false },
        // Runtime players use group zero: a positive-group shape with no mask
        // neither collides with them nor supplies a false probe-only foothold.
        .{ .player_group = 0, .support_group = 2, .mask = 0, .supported = false },
    };
    for (cases) |case| {
        const body = try beginAimingPlayer();
        defer endAimingPlayer(body);
        var player_shapes: [1]box2d.c.b2ShapeId = undefined;
        _ = box2d.c.b2Body_GetShapes(body, &player_shapes, 1);
        var player_filter = box2d.c.b2Shape_GetFilter(player_shapes[0]);
        player_filter.groupIndex = case.player_group;
        if (case.player_group <= 0) player_filter.maskBits |= custom_category;
        box2d.c.b2Shape_SetFilter(player_shapes[0], player_filter);
        const platform = try box2d.createBody(box2d.createStaticBodyDef(.{ .x = 0, .y = 0.1 }));
        var shape = box2d.c.b2DefaultShapeDef();
        // No sensor category in its mask: the character's solid filter decides.
        shape.filter.categoryBits = custom_category;
        shape.filter.maskBits = case.mask;
        shape.filter.groupIndex = case.support_group;
        const polygon = box2d.c.b2MakeBox(3, 0.2);
        const surface = box2d.c.b2CreatePolygonShape(platform, &shape, &polygon);
        // A sensor and a non-colliding solid above it must not hide the support.
        const decoy = try box2d.createBody(box2d.createStaticBodyDef(.{ .x = 0, .y = -0.12 }));
        const thin = box2d.c.b2MakeBox(3, 0.01);
        shape.filter.groupIndex = 0;
        shape.isSensor = true;
        _ = box2d.c.b2CreatePolygonShape(decoy, &shape, &thin);
        shape.isSensor = false;
        shape.filter.maskBits = collision.CATEGORY_SENSOR;
        _ = box2d.c.b2CreatePolygonShape(decoy, &shape, &thin);
        box2d.c.b2Body_SetTransform(body, .{ .x = 0, .y = -0.42 }, box2d.c.b2MakeRot(0));
        movement.reset(7);
        animation.resetPlayer(7);
        submitAim(vec.zero, false);
        for (0..60) |_| try stepAimingMovement();
        const sample = animation.states.get(7).?;
        const contact = movement.states.get(7).?.groundState.groundContact.?;
        try std.testing.expectEqual(case.supported, box2d.c.B2_ID_EQUALS(surface, contact.shapeId));
        for (sample.feet) |foot| {
            try std.testing.expect(foot.locked);
            try std.testing.expectEqual(case.supported, box2d.c.B2_ID_EQUALS(platform, foot.support.?.bodyId));
        }
    }
}

test "walking up a low dynamic L steps before shoving its upright" {
    const old_view = animation.view;
    defer animation.view = old_view;
    for ([_]f32{ -1, 1 }) |direction| {
        for ([_]f32{ 0, 0.68, 0.7 }) |start_x| {
            const body = try beginAimingPlayer();
            defer endAimingPlayer(body);
            addTraversalTorso(body);
            const support = try addDynamicL(0.3, direction);
            box2d.c.b2Body_SetTransform(body, .{ .x = direction * start_x, .y = -0.42 }, box2d.c.b2MakeRot(0));
            movement.reset(7);
            animation.resetPlayer(7);
            submitAim(vec.zero, false);
            for (0..45) |_| try stepAimingMovement();
            const origin = box2d.c.b2Body_GetPosition(support);
            submitAim(.{ .x = direction, .y = 0 }, false);
            var climbed = false;
            for (0..18) |_| {
                try stepAimingMovement();
                const position = box2d.c.b2Body_GetPosition(body);
                if (position.y < -0.65 and position.x * direction > 1.2) climbed = true;
            }
            errdefer std.log.err("low L: climbed {}, support {any}, velocity {any}, player {any}", .{ climbed, box2d.c.b2Body_GetPosition(support), box2d.c.b2Body_GetLinearVelocity(support), box2d.c.b2Body_GetPosition(body) });
            try std.testing.expect(climbed);
            try std.testing.expectApproxEqAbs(origin.x, box2d.c.b2Body_GetPosition(support).x, 0.02);
        }
    }
}

test "holding against the same dynamic support cannot continuously propel its tall upright" {
    const old_view = animation.view;
    defer animation.view = old_view;
    for ([_]f32{ -1, 1 }) |direction| {
        for ([_]f32{ 0, 0.68, 0.7 }) |start_x| {
            const body = try beginAimingPlayer();
            defer endAimingPlayer(body);
            addTraversalTorso(body);
            const support = try addDynamicL(1.4, direction);
            box2d.c.b2Body_SetTransform(body, .{ .x = direction * start_x, .y = -0.42 }, box2d.c.b2MakeRot(0));
            movement.reset(7);
            animation.resetPlayer(7);
            submitAim(vec.zero, false);
            for (0..45) |_| try stepAimingMovement();
            const origin = box2d.c.b2Body_GetPosition(support);
            submitAim(.{ .x = direction, .y = 0 }, false);
            for (0..180) |_| try stepAimingMovement();
            errdefer std.log.err("tall L: support {any}, velocity {any}, player {any}", .{ box2d.c.b2Body_GetPosition(support), box2d.c.b2Body_GetLinearVelocity(support), box2d.c.b2Body_GetPosition(body) });
            try std.testing.expectApproxEqAbs(origin.x, box2d.c.b2Body_GetPosition(support).x, 0.02);
            try std.testing.expect(@abs(box2d.c.b2Body_GetLinearVelocity(support).x) < 0.02);
            const local = box2d.c.b2Body_GetLocalPoint(support, box2d.c.b2Body_GetPosition(body));
            try std.testing.expect(local.x * direction < 0.71);
            // Real impulses still move the support, carrying the blocked player.
            const impulse = box2d.c.b2Body_GetMass(support) * 1.2 * direction;
            box2d.c.b2Body_ApplyLinearImpulseToCenter(support, .{ .x = impulse, .y = 0 }, true);
            for (0..30) |_| try stepAimingMovement();
            try std.testing.expect((box2d.c.b2Body_GetPosition(support).x - origin.x) * direction > 0.25);
            try std.testing.expect(box2d.c.b2Body_GetLinearVelocity(support).x * direction > 0.5);
        }
    }
}

test "walking into a separate tall object still pushes it from terrain or a dynamic support" {
    const old_view = animation.view;
    defer animation.view = old_view;
    for ([_]bool{ false, true }) |on_platform| {
        const body = try beginAimingPlayer();
        defer endAimingPlayer(body);
        addTraversalTorso(body);
        const floor_y: f32 = if (on_platform) -0.1 else 0.3;
        if (on_platform) _ = try addRubbleBox(.{ .x = 0, .y = 0.1 }, .{ .x = 8, .y = 0.2 });
        const box = try addRubbleBox(.{ .x = 1.5, .y = floor_y - 0.7 }, .{ .x = 0.5, .y = 0.7 });
        box2d.c.b2Body_SetTransform(body, .{ .x = 0.68, .y = floor_y - 0.32 }, box2d.c.b2MakeRot(0));
        movement.reset(7);
        animation.resetPlayer(7);
        submitAim(vec.zero, false);
        for (0..45) |_| try stepAimingMovement();
        const origin = box2d.c.b2Body_GetPosition(box);
        submitAim(vec.east, false);
        for (0..90) |_| try stepAimingMovement();
        try std.testing.expect(box2d.c.b2Body_GetPosition(box).x > origin.x + 0.3);
    }
}

test "moving and rotating support preserves local foot anchors and idle cadence through rendering" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
    for (0..30) |_| advanceRun(0, true);
    const start = animation.states.get(7).?;
    for (start.feet) |foot| try std.testing.expect(foot.locked);
    var previous_body = vec.zero;
    for (1..61) |tick| {
        const elapsed: f32 = @as(f32, @floatFromInt(tick)) / 60;
        const angle = elapsed * 0.08;
        box2d.c.b2Body_SetTransform(floor, .{ .x = elapsed * 0.5, .y = 0.8 - elapsed * 0.1 }, box2d.c.b2MakeRot(angle));
        const body = vec.fromBox2d(box2d.c.b2Body_GetWorldPoint(floor, .{ .x = 0, .y = -0.8 }));
        const origin = box2d.c.b2Body_GetPosition(floor);
        const slope = @tan(angle);
        const floor_y = origin.y + (body.x - origin.x) * slope - 0.5 / @cos(angle);
        animation.updatePlayer(7, .{ .body = body, .supported = true, .ground_y = floor_y, .ground_normal = .{ .x = @sin(angle), .y = -@cos(angle) }, .vertical_speed_mps = 0, .separation_speed_mps = 0, .support_velocity_x = (body.x - previous_body.x) * 60, .facing_right = true }, 1.0 / 60.0);
        previous_body = body;
        const sample = animation.states.get(7).?;
        errdefer std.log.err("moving anchors tick {d}: {any}", .{ tick, sample.feet });
        try std.testing.expectEqual(animation.Action.grounded, sample.action);
        try std.testing.expect(@abs(sample.speed_mps) < 0.0001);
        try std.testing.expect(sample.run_weight < 0.001);
        try std.testing.expectEqual(start.phase, sample.phase);
        for (sample.feet, start.feet) |foot, initial| {
            try std.testing.expect(foot.locked);
            try nearPoint(initial.local_anchor, foot.local_anchor, 0.00001);
            try nearPoint(vec.fromBox2d(box2d.c.b2Body_GetWorldPoint(floor, vec.toBox2d(foot.local_anchor))), foot.anchor, 0.00001);
        }
        for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
            const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
            try checkBones(animation.assets.?.rig, pose);
            const fraction: f32 = @floatCast(alpha);
            const rendered_body = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), fraction));
            for ([_]animation.Joint{ .left_toe, .right_toe }, sample.previous_feet, sample.feet) |joint, before, foot| {
                const rendered_origin = vec.add(before.support_origin, vec.mul(vec.subtract(foot.support_origin, before.support_origin), fraction));
                const rendered_angle = std.math.lerp(before.support_angle, foot.support_angle, fraction);
                const local = foot.local_anchor;
                const expected = vec.add(rendered_origin, .{ .x = local.x * @cos(rendered_angle) - local.y * @sin(rendered_angle), .y = local.x * @sin(rendered_angle) + local.y * @cos(rendered_angle) });
                try nearPoint(expected, animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(joint)], rendered_body, sample.facing_right), 0.001);
            }
        }
    }
}

test "controller follows moving support with idle feet and releases it when disabled" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    const platform = try addRubbleBox(.{ .x = 0, .y = -0.2 }, .{ .x = 3, .y = 0.3 });
    box2d.c.b2Body_SetType(platform, box2d.c.b2_kinematicBody);
    box2d.c.b2Body_SetTransform(body, .{ .x = 0, .y = -0.82 }, box2d.c.b2MakeRot(0));
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
    movement.reset(7);
    animation.resetPlayer(7);
    submitAim(vec.zero, false);
    for (0..45) |_| try stepAimingMovement();
    box2d.c.b2Body_SetLinearVelocity(platform, .{ .x = 1, .y = -0.1 });
    for (0..90) |tick| {
        try stepAimingMovement();
        if (tick < 30) continue;
        const sample = animation.states.get(7).?;
        errdefer std.log.err("carried idle tick {d}: speed {d}, action {s}, body {any}", .{ tick, sample.speed_mps, @tagName(sample.action), sample.body });
        try std.testing.expectEqual(animation.Action.grounded, sample.action);
        try std.testing.expect(@abs(sample.speed_mps) < 0.01);
        try std.testing.expect(sample.run_weight < 0.01);
        for (sample.feet) |foot| try std.testing.expect(foot.locked);
    }
    try std.testing.expect(box2d.c.b2Body_GetPosition(body).x > 1.4);
    box2d.c.b2Body_Disable(platform);
    try stepAimingMovement();
    const released = animation.states.get(7).?;
    try std.testing.expectEqual(animation.Action.fall, released.action);
    for (released.feet) |foot| try std.testing.expect(!foot.locked);
    try std.testing.expect(!movement.states.get(7).?.groundState.supported);
    for (0..90) |_| try stepAimingMovement();
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
}

test "feet use separate moving pieces and release a support that tips beyond the slope limit" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    const neutral = animation.states.get(7).?;
    const seam = (neutral.feet[0].anchor.x + neutral.feet[1].anchor.x) / 2;
    box2d.c.b2DestroyBody(floor);
    _ = try addRubbleBox(.{ .x = seam - 1, .y = 0.5 }, .{ .x = 1, .y = 0.2 });
    _ = try addRubbleBox(.{ .x = seam + 1, .y = 0.5 }, .{ .x = 1, .y = 0.2 });
    animation.resetPlayer(7);
    for (0..30) |_| advanceRun(0, true);
    const initial = animation.states.get(7).?;
    try std.testing.expect(initial.feet[0].locked and initial.feet[1].locked);
    try std.testing.expect(!box2d.c.B2_ID_EQUALS(initial.feet[0].support.?.bodyId, initial.feet[1].support.?.bodyId));
    const raised = initial.feet[0].support.?.bodyId;
    const other = initial.feet[1].support.?.bodyId;
    for (1..16) |tick| {
        var position = box2d.c.b2Body_GetPosition(raised);
        position.y -= 0.001;
        box2d.c.b2Body_SetTransform(raised, position, box2d.c.b2MakeRot(0));
        advanceRun(0, true);
        const sample = animation.states.get(7).?;
        errdefer std.log.err("separate pieces tick {d}: {any}", .{ tick, sample.feet });
        try std.testing.expect(sample.feet[0].locked and sample.feet[1].locked);
        try nearPoint(initial.feet[0].local_anchor, sample.feet[0].local_anchor, 0.00001);
        try nearPoint(initial.feet[1].anchor, sample.feet[1].anchor, 0.00001);
    }
    box2d.c.b2Body_SetTransform(raised, box2d.c.b2Body_GetPosition(raised), box2d.c.b2MakeRot(1.1));
    advanceRun(0, true);
    try std.testing.expect(!animation.states.get(7).?.feet[0].locked);
    // A disappearing piece must also release while its neighbor remains alive.
    box2d.c.b2Body_Disable(other);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(!foot.locked);
}

test "render endpoint discards a destroyed or recycled moving surface above its replacement" {
    for ([_]bool{ false, true }) |recycle| {
        const floor = try beginLocomotion();
        defer box2d.destroyWorld();
        defer animation.cleanup();
        runtime.init(std.testing.io);
        box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
        const pool_id = try pool.create(&.{floor});
        defer {
            const bodies = pool.takeBodyIds(pool_id) catch unreachable;
            allocator.allocator.free(bodies);
        }
        _ = (try pool.acquire(pool_id, .return_null)).?;
        for (0..30) |_| advanceRun(0, true);
        if (recycle) {
            try pool.release(pool_id, floor);
            _ = (try pool.acquire(pool_id, .return_null)).?;
            box2d.c.b2Body_SetTransform(floor, .{ .x = 0, .y = 0.95 }, box2d.c.b2MakeRot(0));
        } else {
            box2d.c.b2DestroyBody(floor);
            _ = try addTerrainBox(.{ .x = 0, .y = 0.95 }, .{ .x = 100, .y = 0.5 });
        }
        animation.updatePlayer(7, .{ .body = .{ .x = 0, .y = 0.15 }, .supported = true, .ground_y = 0.45, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true }, 1.0 / 60.0);
        const sample = animation.states.get(7).?;
        var without_stale_surfaces = sample;
        without_stale_surfaces.previous_sole_surfaces = sample.sole_surfaces;
        without_stale_surfaces.previous_knee_surfaces = sample.knee_surfaces;
        const expected = animation.interpolatedPose(&animation.assets.?, without_stale_surfaces, 1);
        const actual = animation.interpolatedPose(&animation.assets.?, sample, 1);
        for (expected.joints, actual.joints) |a, b| try nearPoint(a, b, 0.00001);
        for (sample.feet) |foot| try std.testing.expect(!foot.locked);
    }
}

test "asymmetric support and planted feet share rendering through the signed angle boundary" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const old_alpha = time.alpha;
    defer time.alpha = old_alpha;
    var shapes: [1]box2d.c.b2ShapeId = undefined;
    _ = box2d.c.b2Body_GetShapes(floor, &shapes, 1);
    box2d.c.b2DestroyShape(shapes[0], true);
    box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
    const vertices = [_]box2d.c.b2Vec2{ .{ .x = -2, .y = 0.5 }, .{ .x = 2, .y = 0.5 }, .{ .x = -1, .y = -0.6 } };
    const hull = box2d.c.b2ComputeHull(&vertices, 3);
    const polygon = box2d.c.b2MakePolygon(&hull, 0.01);
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_RUBBLE;
    shape.filter.maskBits = collision.MASK_RUBBLE;
    _ = box2d.c.b2CreatePolygonShape(floor, &shape, &polygon);
    const before_angle: f32 = std.math.pi - 0.02;
    box2d.c.b2Body_SetTransform(floor, .{ .x = 0, .y = 0.8 }, box2d.c.b2MakeRot(before_angle));
    const before = box2d.getState(floor);
    const floor_y: f32 = 0.8 + 0.51 / @cos(before_angle);
    const input: animation.LocomotionInput = .{ .body = .{ .x = 0, .y = floor_y - 0.3 }, .supported = true, .ground_y = floor_y, .ground_normal = .{ .x = -@sin(before_angle), .y = @cos(before_angle) }, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true };
    for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
    box2d.c.b2Body_SetTransform(floor, before.pos, box2d.c.b2MakeRot(std.math.pi + 0.02));
    var next_input = input;
    next_input.ground_normal.x *= -1;
    animation.updatePlayer(7, next_input, 1.0 / 60.0);
    const sample = animation.states.get(7).?;
    const after = box2d.getState(floor);
    for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
        time.alpha = alpha;
        const drawn = box2d.getInterpolatedState(before, after);
        try std.testing.expect(before.rotAngle > 3 and after.rotAngle < -3);
        const expected_angle = std.math.lerp(before.rotAngle, after.rotAngle + std.math.tau, @as(f32, @floatCast(alpha)));
        // The off-center marker distinguishes an asymmetric piece's orientation.
        const marker = vec.Vec2{ .x = 0.7, .y = -0.3 };
        const actual_marker = vec.Vec2{ .x = marker.x * @cos(drawn.rotAngle) - marker.y * @sin(drawn.rotAngle), .y = marker.x * @sin(drawn.rotAngle) + marker.y * @cos(drawn.rotAngle) };
        const expected_marker = vec.Vec2{ .x = marker.x * @cos(expected_angle) - marker.y * @sin(expected_angle), .y = marker.x * @sin(expected_angle) + marker.y * @cos(expected_angle) };
        try nearPoint(expected_marker, actual_marker, 0.000001);
        const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
        try checkBones(animation.assets.?.rig, pose);
        for (sample.feet, [_]animation.Joint{ .left_toe, .right_toe }) |foot, toe| {
            try std.testing.expect(foot.locked);
            const local = foot.local_anchor;
            const expected = vec.add(vec.fromBox2d(drawn.pos), .{ .x = local.x * @cos(drawn.rotAngle) - local.y * @sin(drawn.rotAngle), .y = local.x * @sin(drawn.rotAngle) + local.y * @cos(drawn.rotAngle) });
            try nearPoint(expected, animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(toe)], sample.body, sample.facing_right), 0.001);
        }
    }
}

test "rotated rounded triangle keeps a planted toe inside its actual face endpoint" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    box2d.c.b2DestroyBody(floor);
    const angle: f32 = 0.4;
    const piece = try box2d.createBody(box2d.createDynamicBodyDef(.{ .x = 0, .y = 0.5 }));
    box2d.c.b2Body_SetTransform(piece, .{ .x = 0, .y = 0.5 }, box2d.c.b2MakeRot(angle));
    const vertices = [_]box2d.c.b2Vec2{ .{ .x = -1, .y = -0.2 }, .{ .x = 1, .y = -0.2 }, .{ .x = -1, .y = 0.7 } };
    const hull = box2d.c.b2ComputeHull(&vertices, 3);
    const polygon = box2d.c.b2MakePolygon(&hull, 0.01);
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_RUBBLE;
    shape.filter.maskBits = collision.MASK_RUBBLE;
    _ = box2d.c.b2CreatePolygonShape(piece, &shape, &polygon);
    const endpoint = box2d.c.b2Body_GetWorldPoint(piece, .{ .x = 1, .y = -0.21 });
    // Establish the stance on this slope before positioning its forward toe
    // beside the endpoint; rotating the sole changes its neutral X offset.
    const rotation = box2d.c.b2Body_GetRotation(piece);
    const neutral_floor = 0.5 - 0.21 / rotation.c;
    for (0..90) |_| animation.updatePlayer(7, .{ .body = .{ .x = 0, .y = neutral_floor - 0.3 }, .supported = true, .ground_y = neutral_floor, .ground_normal = .{ .x = rotation.s, .y = -rotation.c }, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true }, 1.0 / 60.0);
    const neutral = animation.states.get(7).?;
    try std.testing.expect(neutral.feet[0].locked and neutral.feet[1].locked);
    const leg: usize = if (neutral.feet[0].anchor.x > neutral.feet[1].anchor.x) 0 else 1;
    const body_x = endpoint.x - 0.003 - neutral.feet[leg].anchor.x;
    const floor_y = neutral_floor + body_x * rotation.s / rotation.c;
    animation.resetPlayer(7);
    for (0..90) |_| animation.updatePlayer(7, .{ .body = .{ .x = body_x, .y = floor_y - 0.3 }, .supported = true, .ground_y = floor_y, .ground_normal = .{ .x = rotation.s, .y = -rotation.c }, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true }, 1.0 / 60.0);
    const sample = animation.states.get(7).?;
    errdefer std.log.err("rounded endpoint {any}, body {any}, feet {any}, surfaces {any}", .{ endpoint, sample.body, sample.feet, sample.sole_surfaces });
    try std.testing.expect(sample.sole_surfaces[leg * 2] != null);
    const surface = sample.sole_surfaces[leg * 2].?;
    try std.testing.expectApproxEqAbs(endpoint.x, surface.maximum_x, 0.00001);
    try std.testing.expect(sample.feet[leg].locked);
    const unrounded_endpoint = box2d.c.b2Body_GetWorldPoint(piece, .{ .x = 1, .y = -0.2 });
    try std.testing.expect(sample.feet[leg].anchor.x > unrounded_endpoint.x);
    try std.testing.expect(sample.feet[leg].anchor.x <= endpoint.x);
    for ([_]f64{ 0, 0.5, 1 }) |alpha| {
        const pose = animation.interpolatedPose(&animation.assets.?, sample, alpha);
        const toe: animation.Joint = if (leg == 0) .left_toe else .right_toe;
        try nearPoint(sample.feet[leg].anchor, animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(toe)], sample.body, sample.facing_right), 0.001);
    }
}

test "pooled support identity rejects released recycled disabled and destroyed rubble" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    const pool_id = try pool.create(&.{floor});
    defer {
        const bodies = pool.takeBodyIds(pool_id) catch unreachable;
        allocator.allocator.free(bodies);
    }
    _ = (try pool.acquire(pool_id, .return_null)).?;
    for (0..30) |_| advanceRun(0, true);
    const foot = animation.states.get(7).?.feet[0];
    try std.testing.expect(foot.locked);
    const original = foot.support.?;
    try pool.release(pool_id, floor);
    try std.testing.expect(!movement.validSupport(original));
    _ = (try pool.acquire(pool_id, .return_null)).?;
    try std.testing.expect(!movement.validSupport(original));
    advanceRun(0, true);
    const new_foot = animation.states.get(7).?.feet[0];
    try std.testing.expect(!new_foot.locked or new_foot.support.?.poolActivation != original.poolActivation);
    const second = movement.supportForShape(original.shapeId).?;
    _ = (try pool.acquire(pool_id, .recycle_oldest)).?;
    try std.testing.expect(!movement.validSupport(second));
    const third = movement.supportForShape(original.shapeId).?;
    box2d.c.b2Body_Disable(floor);
    try std.testing.expect(!movement.validSupport(third));
    advanceRun(0, false);
    for (animation.states.get(7).?.feet) |released| try std.testing.expect(!released.locked);
    box2d.c.b2Body_Enable(floor);
    box2d.c.b2DestroyShape(original.shapeId, true);
    try std.testing.expect(!movement.validSupport(third));
}

test "running follows flat to ramp transitions without selecting an airborne pose" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    // Keep the original floor beneath a ramp that rises from x=0 to x=3.
    const rotation = box2d.c.b2MakeRot(-0.4);
    const slope = rotation.s / rotation.c;
    const ramp = try addTerrainBox(.{ .x = 1.5 - 0.2 * rotation.s, .y = 0.3 + 1.5 * slope + 0.2 * rotation.c }, .{ .x = 1.5 / rotation.c, .y = 0.2 });
    box2d.c.b2Body_SetTransform(ramp, box2d.c.b2Body_GetPosition(ramp), rotation);
    _ = try addTerrainBox(.{ .x = 53, .y = 0.8 + 3 * slope }, .{ .x = 50, .y = 0.5 });
    box2d.c.b2Body_SetTransform(body, .{ .x = -2, .y = -0.02 }, box2d.c.b2MakeRot(0));
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
    movement.reset(7);
    animation.resetPlayer(7);
    submitAim(vec.zero, false);
    for (0..30) |_| try stepAimingMovement();
    for ([_]vec.Vec2{ vec.east, vec.west }) |direction| {
        submitAim(direction, false);
        for (0..80) |tick| {
            try stepAimingMovement();
            const sample = animation.states.get(7).?;
            errdefer std.log.err("ramp seam: direction {any}, tick {d}, body {any}, action {s}", .{ direction, tick, sample.body, @tagName(sample.action) });
            try std.testing.expectEqual(animation.Action.grounded, sample.action);
            try std.testing.expect(movement.states.get(7).?.groundState.supported);
            try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, 0.5));
        }
    }
    try std.testing.expect(box2d.c.b2Body_GetPosition(body).x < -0.5);
}

test "step climbing respects the height limit disabled setting and full body ceiling clearance" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    const step = try addTerrainBox(.{ .x = 50, .y = 0.2 }, .{ .x = 50, .y = 0.5 });
    const ceiling = try addTerrainBox(.{ .x = 0, .y = -10 }, .{ .x = 5, .y = 0.1 });
    for (0..3) |scenario| {
        const height: f32 = if (scenario == 0) 0.6 else if (scenario == 1) 0.3 else 0.5;
        movement.towerfallSettings.maxStepHeight = if (scenario == 2) 0 else 0.5;
        box2d.c.b2Body_SetTransform(step, .{ .x = 50, .y = 0.8 - height }, box2d.c.b2MakeRot(0));
        box2d.c.b2Body_SetTransform(ceiling, .{ .x = 0, .y = if (scenario == 1) -1.3 else -10 }, box2d.c.b2MakeRot(0));
        box2d.c.b2Body_SetTransform(body, .{ .x = -2, .y = -0.02 }, box2d.c.b2MakeRot(0));
        box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
        movement.reset(7);
        animation.resetPlayer(7);
        submitAim(vec.zero, false);
        for (0..30) |_| try stepAimingMovement();
        submitAim(vec.east, false);
        for (0..100) |_| {
            try stepAimingMovement();
            const position = box2d.c.b2Body_GetPosition(body);
            errdefer std.log.err("blocked step: scenario {d}, position {any}", .{ scenario, position });
            try std.testing.expect(position.x < -0.1);
            if (scenario == 1) try std.testing.expect(position.y > -0.11);
        }
    }
}

test "ground following releases for jumps and drops beyond the step limit" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    addTraversalTorso(body);
    _ = try addTerrainBox(.{ .x = -25, .y = 0.1 }, .{ .x = 25, .y = 0.5 });
    box2d.c.b2Body_SetTransform(body, .{ .x = -1, .y = -0.72 }, box2d.c.b2MakeRot(0));
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
    movement.reset(7);
    animation.resetPlayer(7);
    submitAim(vec.zero, false);
    for (0..30) |_| try stepAimingMovement();
    var jumping: player_input.Sample = .{};
    jumping.buttons.set(.jump, true);
    player_input.submit(7, jumping);
    control.applyPlayerInput(7);
    try stepAimingMovement();
    try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
    try std.testing.expect(!movement.states.get(7).?.followGround);
    try std.testing.expect(box2d.c.b2Body_GetPosition(body).y < -0.95);
    submitAim(vec.zero, false);
    for (0..120) |_| try stepAimingMovement();
    try std.testing.expect(movement.states.get(7).?.groundState.supported);
    submitAim(vec.east, false);
    var fell = false;
    errdefer std.log.err("large drop: fell {}, body {any}, action {s}", .{ fell, box2d.c.b2Body_GetPosition(body), @tagName(animation.states.get(7).?.action) });
    for (0..70) |_| {
        try stepAimingMovement();
        const sample = animation.states.get(7).?;
        if (sample.body.x > 0 and sample.action == .fall) {
            fell = true;
            for (sample.feet) |foot| try std.testing.expect(!foot.locked);
        }
    }
    try std.testing.expect(fell);
    try std.testing.expectApproxEqAbs(@as(f32, 0), box2d.c.b2Body_GetPosition(body).y, 0.03);
}

test "Towerfall input keeps an existing kneel while aiming and restores live stance on release" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    for ([_]data.AimMode{ .free, .eight_directions }) |aim_mode| {
        player_input.directionSettings.aimMode = aim_mode;
        submitAim(vec.south, false);
        for (0..30) |_| try stepAimingMovement();
        try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
        for ([_]vec.Vec2{ vec.east, vec.west, vec.north, vec.south, .{ .x = 0.8, .y = 0.3 }, vec.zero }) |direction| {
            submitAim(direction, true);
            for (0..20) |_| {
                try stepAimingMovement();
                const sample = animation.states.get(7).?;
                try std.testing.expectEqual(animation.Action.kneel, sample.action);
                try checkAirPose(sample);
                try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
                try std.testing.expectApproxEqAbs(@as(f32, 0), box2d.c.b2Body_GetLinearVelocity(body).x, 0.00001);
            }
            const frame = player.weaponFrame(7, .physics, null).?;
            try nearPoint(player.players.get(7).?.aimDirection, player.weaponDirection(frame), 0.00001);
            const pose = animation.playerFrame(7, .physics, null).?;
            try checkBones(animation.assets.?.rig, pose.pose);
            try std.testing.expect(pose.pose.joints[@intFromEnum(animation.Joint.pelvis)].y < -0.35);
        }
        // Down can keep the stance after firing; neutral ends it immediately.
        submitAim(vec.south, false);
        try stepAimingMovement();
        try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
        submitAim(vec.zero, true);
        try stepAimingMovement();
        submitAim(vec.zero, false);
        try stepAimingMovement();
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
        // Aiming down from standing cannot create a kneel from aim input.
        submitAim(vec.south, true);
        for (0..15) |_| try stepAimingMovement();
        try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
    }
    submitAim(vec.south, false);
    for (0..30) |_| try stepAimingMovement();
    submitAim(vec.east, true);
    try stepAimingMovement();
    player_input.neutralize(7);
    control.applyPlayerInput(7);
    try stepAimingMovement();
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
    submitAim(vec.south, false);
    for (0..30) |_| try stepAimingMovement();
    submitAim(vec.east, true);
    try stepAimingMovement();
    var jump: player_input.Sample = .{ .movementDirection = vec.east, .aimDirection = vec.east };
    jump.buttons.set(.shoot, true);
    jump.buttons.set(.jump, true);
    player_input.submit(7, jump);
    control.applyPlayerInput(7);
    try stepAimingMovement();
    try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
    // Once interrupted by a jump, the aim hold cannot restore the old kneel.
    jump.buttons.set(.jump, false);
    player_input.submit(7, jump);
    control.applyPlayerInput(7);
    for (0..180) |_| {
        try stepAimingMovement();
        try std.testing.expect(animation.states.get(7).?.action != .kneel);
    }
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
}

test "Liero aiming uses live movement input to enter and leave kneeling" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    movement.mechanism = .liero;
    defer movement.mechanism = .towerfall;
    var input: player_input.Sample = .{ .movementDirection = vec.south, .aimDirection = vec.east };
    player_input.submit(7, input);
    control.applyPlayerInput(7);
    for (0..30) |_| try stepAimingMovement();
    try std.testing.expect(player.players.get(7).?.isAiming);
    try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
    input.aimDirection = vec.west;
    player_input.submit(7, input);
    control.applyPlayerInput(7);
    for (0..30) |_| try stepAimingMovement();
    try std.testing.expectEqual(animation.Action.kneel, animation.states.get(7).?.action);
    try nearPoint(vec.west, player.weaponDirection(player.weaponFrame(7, .physics, null).?), 0.00001);
    input.movementDirection = vec.zero;
    player_input.submit(7, input);
    control.applyPlayerInput(7);
    try stepAimingMovement();
    try std.testing.expect(player.players.get(7).?.isAiming);
    try std.testing.expectEqual(animation.Action.grounded, animation.states.get(7).?.action);
}

test "aiming removes directional locomotion while momentum gravity and independent jumping continue" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    try std.testing.expect(movement.states.get(7).?.groundState.supported);
    submitAim(vec.east, true);
    try std.testing.expectEqual(@as(i8, 0), movement.states.get(7).?.lateralMovementIntent);
    movement.applyAll(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0), box2d.c.b2Body_GetLinearVelocity(body).x);
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 6, .y = 0 });
    submitAim(.{ .x = -1, .y = -1 }, true);
    movement.applyAll(1.0 / 60.0);
    try std.testing.expectApproxEqAbs(6 - movement.towerfallSettings.control.groundDeceleration / 60, box2d.c.b2Body_GetLinearVelocity(body).x, 0.00001);
    animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expect(animation.states.get(7).?.action != .kneel);
    const moving = movement.states.getPtr(7).?;
    moving.groundState = .{};
    moving.leftWallContactCount = 1;
    box2d.c.b2Body_SetTransform(body, .{ .x = 0, .y = -2 }, box2d.c.b2MakeRot(0));
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 6, .y = 1 });
    movement.applyAll(1.0 / 60.0);
    var velocity = box2d.c.b2Body_GetLinearVelocity(body);
    try std.testing.expectApproxEqAbs(6 - movement.towerfallSettings.control.airDeceleration / 60, velocity.x, 0.00001);
    try std.testing.expectApproxEqAbs(1 + movement.towerfallSettings.control.gravity / 60, velocity.y, 0.00001);
    try std.testing.expect(!moving.wallSliding);
    moving.leftWallContactCount = 0;
    submitAim(.{ .x = -1, .y = -1 }, false);
    movement.applyAll(1.0 / 60.0);
    const after_release = box2d.c.b2Body_GetLinearVelocity(body);
    try std.testing.expect(after_release.x < velocity.x);
    try std.testing.expectApproxEqAbs(velocity.y + movement.towerfallSettings.control.fastFallAcceleration / 60, after_release.y, 0.00001);
    moving.groundState = .{ .supported = true, .jumpAvailable = true };
    box2d.c.b2Body_SetLinearVelocity(body, .{ .x = 0, .y = 0 });
    var sample: player_input.Sample = .{ .movementDirection = vec.east, .aimDirection = vec.east };
    sample.buttons.set(.shoot, true);
    sample.buttons.set(.jump, true);
    player_input.submit(7, sample);
    control.applyPlayerInput(7);
    player_input.beginPhysicsStep();
    defer player_input.endPhysicsStep();
    movement.applyAll(1.0 / 60.0);
    velocity = box2d.c.b2Body_GetLinearVelocity(body);
    try std.testing.expect(velocity.y < 0);
    try std.testing.expectEqual(@as(f32, 0), velocity.x);
    // The policy is specific to Towerfall; Liero retains independent direction.
    movement.mechanism = .liero;
    defer movement.mechanism = .towerfall;
    try nearPoint(vec.east, movement.locomotionDirection(7), 0.00001);
}

test "airborne aim preserves the same trajectory as continuing the previous horizontal input" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    const moving = movement.states.getPtr(7).?;
    box2d.c.b2Body_SetGravityScale(body, movement.bodyMotion.gravityScale);
    box2d.c.b2Body_SetLinearDamping(body, movement.bodyMotion.linearDamping);
    var expected_positions: [90]vec.Vec2 = undefined;
    var expected_velocities: [90]vec.Vec2 = undefined;
    for ([_]data.AimMode{ .free, .eight_directions }) |aim_mode| {
        player_input.directionSettings.aimMode = aim_mode;
        for ([_]f32{ -1, -0.35, 0, 0.4, 1 }) |horizontal| {
            var landing_tick: usize = 90;
            for ([_]bool{ false, true }) |aiming| {
                movement.reset(7);
                player_input.neutralize(7);
                box2d.c.b2Body_SetTransform(body, .{ .x = 0, .y = -2 }, box2d.c.b2MakeRot(0));
                box2d.c.b2Body_SetLinearVelocity(body, .{ .x = if (horizontal == 0) 6 else horizontal * 2, .y = -8 });
                moving.heldJumpGravityActive = true;
                var landed = false;
                for (0..90) |tick| {
                    const holding_aim = aiming and tick >= 5;
                    // Poll less often than physics after the press. Turning the
                    // aim immediately and later must not replace the earlier input.
                    if (tick <= 5 or tick % 3 == 0) {
                        const direction: vec.Vec2 = if (holding_aim) .{ .x = if (tick % 2 == 0) 1 else -1, .y = -0.7 } else .{ .x = horizontal, .y = 0 };
                        var input: player_input.Sample = .{ .movementDirection = direction, .aimDirection = direction };
                        input.buttons.set(.shoot, holding_aim);
                        input.buttons.set(.jump, tick < 12);
                        player_input.submit(7, input);
                        control.applyPlayerInput(7);
                    }
                    player_input.beginPhysicsStep();
                    movement.applyAll(1.0 / 60.0);
                    box2d.worldStep(1.0 / 60.0, 4);
                    try movement.processSensorEvents();
                    player_input.endPhysicsStep();
                    const position = vec.fromBox2d(box2d.c.b2Body_GetPosition(body));
                    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body));
                    if (aiming) {
                        try std.testing.expect(tick <= landing_tick);
                        try nearPoint(expected_positions[tick], position, 0.00002);
                        try nearPoint(expected_velocities[tick], velocity, 0.00002);
                    } else {
                        expected_positions[tick] = position;
                        expected_velocities[tick] = velocity;
                    }
                    if (!moving.groundState.supported) continue;
                    landed = true;
                    if (!aiming) {
                        landing_tick = tick;
                        break;
                    }
                    try std.testing.expectEqual(landing_tick, tick);
                    try std.testing.expectEqual(@as(f32, 0), player_input.playerInputs.get(7).?.aimMovementDirection);
                    try std.testing.expectEqual(@as(i8, 0), moving.lateralMovementIntent);
                    // Another jump while aim stays held must not resurrect the
                    // direction captured for the completed jump.
                    var jump: player_input.Sample = .{ .movementDirection = vec.west, .aimDirection = vec.west };
                    jump.buttons.set(.shoot, true);
                    jump.buttons.set(.jump, true);
                    player_input.submit(7, jump);
                    control.applyPlayerInput(7);
                    player_input.beginPhysicsStep();
                    movement.applyAll(1.0 / 60.0);
                    player_input.endPhysicsStep();
                    try std.testing.expect(box2d.c.b2Body_GetLinearVelocity(body).y < 0);
                    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
                    break;
                }
                try std.testing.expect(landed);
            }
        }
    }
}

test "airborne aim capture clears on release neutralization reset level cleanup and grounded aiming" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    const moving = movement.states.getPtr(7).?;
    moving.groundState = .{};
    submitAim(vec.east, false);
    submitAim(vec.west, true);
    try nearPoint(vec.east, movement.locomotionDirection(7), 0.00001);
    submitAim(vec.west, false);
    try nearPoint(vec.west, movement.locomotionDirection(7), 0.00001);
    try std.testing.expectEqual(@as(f32, 0), player_input.playerInputs.get(7).?.aimMovementDirection);
    submitAim(vec.east, true);
    try nearPoint(vec.west, movement.locomotionDirection(7), 0.00001);
    submitAim(vec.south, true);
    try nearPoint(vec.west, movement.locomotionDirection(7), 0.00001);
    player_input.neutralize(7);
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
    submitAim(vec.east, false);
    submitAim(vec.west, true);
    movement.reset(7);
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
    // Reset/respawn cannot reactivate a pre-reset hold on the next input poll.
    submitAim(vec.west, true);
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
    moving.groundState.supported = true;
    submitAim(vec.east, false);
    submitAim(vec.west, true);
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
    moving.groundState.supported = false;
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
    submitAim(vec.east, false);
    submitAim(vec.west, true);
    try nearPoint(vec.east, movement.locomotionDirection(7), 0.00001);
    // Level reloads recreate movement bodies/states while retaining controller
    // input registrations. Exercise that boundary with a fresh unsupported state.
    const replacement: movement.State = .{ .bodyId = body, .footSensorShapeId = moving.footSensorShapeId, .leftWallSensorId = moving.leftWallSensorId, .rightWallSensorId = moving.rightWallSensorId };
    movement.cleanup();
    try std.testing.expect(player_input.playerInputs.get(7).?.buttons.get(.shoot).held);
    try std.testing.expectEqual(@as(f32, 0), player_input.playerInputs.get(7).?.aimMovementDirection);
    try movement.states.put(allocator.allocator, 7, replacement);
    submitAim(vec.west, true);
    try nearPoint(vec.zero, movement.locomotionDirection(7), 0.00001);
}

test "shot geometry is independent of camera and render alpha and returns to carrying" {
    const old_view = animation.view;
    const old_alpha = time.alpha;
    defer animation.view = old_view;
    defer time.alpha = old_alpha;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    submitAim(vec.east, true);
    for (0..10) |_| animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 1), animation.states.get(7).?.aim_weight);
    const expected = player.weaponFrame(7, .physics, vec.west).?;
    const muzzle = player.weaponMuzzle(expected).?;
    const cameraId = try camera.spawnForPlayer(7, .{ .x = 900, .y = -500 });
    defer camera.destroyCamera(cameraId);
    const old_camera = camera.activeCameraId;
    defer camera.activeCameraId = old_camera;
    camera.activeCameraId = cameraId;
    for ([_]f64{ 0, 0.25, 0.75, 1 }) |alpha| {
        time.alpha = alpha;
        const actual = player.weaponFrame(7, .physics, vec.west).?;
        try std.testing.expectEqual(muzzle, player.weaponMuzzle(actual).?);
        try nearPoint(vec.west, player.weaponDirection(actual), 0.00001);
    }
    player_input.neutralize(7);
    control.applyPlayerInput(7);
    animation.holdShotPose(7, vec.west);
    for (0..2) |_| animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 1), animation.states.get(7).?.aim_weight);
    for (0..20) |_| animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.aim_weight);
    time.alpha = 1;
    const frame = animation.playerFrame(7, .render, null).?;
    const carry = animation.attachmentToWorld(animation.assets.?.rig, animation.attachmentTransform(animation.assets.?.rig, frame.pose, "weapon_hand").?, frame.body, frame.facing_right);
    try nearPoint(carry.position, frame.weapon.position, 0.00001);
    try std.testing.expectApproxEqAbs(carry.angle, frame.weapon.angle, 0.00001);
}

test "aim turns the character with stable foot targets and backpedals against residual travel" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    const set = &animation.assets.?;
    for ([_]bool{ true, false }) |facing| {
        animation.resetPlayer(7);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = facing };
        for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        const before = animation.states.get(7).?;
        const old_pose = animation.interpolatedPose(set, before, 1);
        input.aiming = true;
        input.aim_direction = if (facing) vec.west else vec.east;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        var sample = animation.states.get(7).?;
        try std.testing.expectEqual(!facing, sample.facing_right);
        const turn_start = animation.interpolatedPose(set, sample, 0);
        for (0..2) |leg| {
            const old_target = animation.toWorld(set.rig, old_pose.desired_targets[leg], before.body, before.facing_right);
            const new_target = animation.toWorld(set.rig, turn_start.desired_targets[leg], sample.body, sample.facing_right);
            try nearPoint(old_target, new_target, 0.0001);
        }
        for (0..30) |tick| {
            // Small horizontal noise around straight up/down must not undo
            // the requested turn, even with opposite movement-facing input.
            input.aim_direction = vec.normalize(.{ .x = if (tick % 2 == 0) -0.02 else 0.02, .y = if (tick < 15) 1 else -1 });
            animation.updatePlayer(7, input, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            try std.testing.expectEqual(!facing, sample.facing_right);
            const pose = animation.interpolatedPose(set, sample, 1);
            try checkBones(set.rig, pose);
        }
        input.aiming = false;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(!facing, animation.states.get(7).?.facing_right);
        player_input.neutralize(7);
        submitAim(vec.zero, true);
        try nearPoint(if (facing) vec.west else vec.east, player.players.get(7).?.aimDirection, 0.00001);

        // Ground momentum can carry the player opposite the new facing. The
        // same authored stride/contact intervals run in reverse until release.
        input.aiming = true;
        input.aim_direction = if (facing) vec.west else vec.east;
        const speed: f32 = if (facing) 3.2 else -3.2;
        var contacts: usize = 0;
        for (0..120) |_| {
            const phase = animation.states.get(7).?.phase;
            input.body.x += speed / 60;
            animation.updatePlayer(7, input, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            try std.testing.expectEqual(!facing, sample.facing_right);
            try std.testing.expect(sample.phase < phase);
            for (sample.previous_feet, sample.feet) |previous, foot| {
                if (previous.locked and foot.locked and std.meta.eql(previous.anchor, foot.anchor)) contacts += 1;
            }
            // Reuse the transition checks for bone lengths, sole clearance
            // and toe-to-anchor stability at interpolated render positions.
            try checkAirPose(sample);
        }
        try std.testing.expect(contacts > 10);
        input.aiming = false;
        const phase = sample.phase;
        input.body.x += speed / 60;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        sample = animation.states.get(7).?;
        try std.testing.expectEqual(facing, sample.facing_right);
        try std.testing.expect(sample.phase > phase);

        input.aiming = true;
        input.supported = false;
        input.ground_y = null;
        input.vertical_speed_mps = -3;
        input.separation_speed_mps = 3;
        input.body.y -= 0.05;
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(!facing, animation.states.get(7).?.facing_right);
        try std.testing.expectEqual(animation.Action.jump, animation.states.get(7).?.action);
    }
}

test "lowering from backwards aim stays continuous throughout the running cycle" {
    const old_view = animation.view;
    const old_alpha = time.alpha;
    defer animation.view = old_view;
    defer time.alpha = old_alpha;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    for ([_]f32{ 3.2, 9, -3.2, -9 }) |speed| {
        for (0..24) |release_phase| {
            animation.resetPlayer(7);
            var x: f32 = 0;
            const direction = if (speed > 0) vec.west else vec.east;
            const release_tick = 60 + release_phase;
            var before: ?f32 = null;
            for (0..release_tick + 20) |tick| {
                x += speed / 60;
                animation.updatePlayer(7, .{ .body = .{ .x = x, .y = 0 }, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = speed > 0, .aiming = tick < release_tick, .aim_direction = direction }, 1.0 / 60.0);
                if (tick < release_tick - 1) continue;
                for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                    time.alpha = alpha;
                    const frame = animation.playerFrame(7, .render, null).?;
                    const angle = frame.weapon.angle + (if (frame.weapon_facing_right) @as(f32, 0) else std.math.pi);
                    const delta = angle - (before orelse angle);
                    errdefer std.log.err("aim lowering: speed {d}, release phase {d}, tick {d}, alpha {d}, angle delta {d}", .{ speed, release_phase, tick, alpha, delta });
                    // A quarter of a physics step must not jump across the
                    // +/-pi seam when the moving wrist passes the aim's opposite.
                    try std.testing.expect(@abs(std.math.atan2(@sin(delta), @cos(delta))) < 0.5);
                    before = angle;
                }
            }
            try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.aim_weight);
        }
    }
}

test "release-to-fire captures direction once across quick taps re-presses switching and cancellation" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    defer {
        delay.cleanup();
        delay.delayedActions = .init(allocator.allocator);
    }
    defer weapon.activeTrails.clearAndFree(allocator.allocator);
    try std.testing.expect(sdl.c.SDL_SetHint(sdl.c.SDL_HINT_AUDIO_DRIVER, "dummy"));
    defer _ = sdl.c.SDL_ResetHint(sdl.c.SDL_HINT_AUDIO_DRIVER);
    try std.testing.expect(sdl.c.SDL_InitSubSystem(sdl.c.SDL_INIT_AUDIO));
    defer sdl.c.SDL_QuitSubSystem(sdl.c.SDL_INIT_AUDIO);
    try audio.init();
    defer audio.cleanup();
    // A tap before the first animation update must still fire from the aimed pose.
    animation.resetPlayer(7);
    submitAim(vec.east, true);
    submitAim(vec.east, false);
    const expected_east = player.weaponMuzzle(player.weaponFrame(7, .physics, vec.east).?).?;
    // A new hold changes live aim without redirecting the queued eastward shot.
    submitAim(vec.north, true);
    try nearPoint(vec.east, player_input.playerInputs.get(7).?.releasedAimDirection, 0.00001);
    player_input.beginPhysicsStep();
    control.applyFixedStepPlayerInputs();
    player_input.endPhysicsStep();
    try std.testing.expectEqual(@as(usize, 1), weapon.activeTrails.items.len);
    try nearPoint(conv.pixel2M(expected_east), weapon.activeTrails.items[0].startPos, 0.00001);
    try nearPoint(.{ .x = 3, .y = 0 }, vec.subtract(weapon.activeTrails.items[0].endPos, weapon.activeTrails.items[0].startPos), 0.00001);
    try std.testing.expect(player.players.get(7).?.isAiming);
    try nearPoint(vec.north, player.players.get(7).?.aimDirection, 0.00001);
    animation.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 1), animation.states.get(7).?.aim_weight);
    for (0..3) |_| {
        player_input.beginPhysicsStep();
        control.applyFixedStepPlayerInputs();
        player_input.endPhysicsStep();
    }
    try std.testing.expectEqual(@as(usize, 1), weapon.activeTrails.items.len);
    // Direction is retained even when controls return to neutral on release and
    // another movement sample arrives before the next fixed step.
    submitAim(vec.zero, false);
    submitAim(vec.west, false);
    try nearPoint(vec.north, player_input.playerInputs.get(7).?.releasedAimDirection, 0.00001);
    player.cycleWeapon(player.players.getPtr(7).?, 1);
    try std.testing.expectEqual(@as(usize, 1), player.players.get(7).?.selectedWeaponIndex);
    const expected_north = player.weaponMuzzle(player.weaponFrame(7, .physics, vec.north).?).?;
    player_input.beginPhysicsStep();
    control.applyFixedStepPlayerInputs();
    player_input.endPhysicsStep();
    try std.testing.expectEqual(@as(usize, 2), weapon.activeTrails.items.len);
    try nearPoint(conv.pixel2M(expected_north), weapon.activeTrails.items[1].startPos, 0.00001);
    try nearPoint(.{ .x = 0, .y = -5 }, vec.subtract(weapon.activeTrails.items[1].endPos, weapon.activeTrails.items[1].startPos), 0.00001);
    try std.testing.expectEqual(@as(f32, 1), animation.states.get(7).?.aim_weight);
    // Menu/focus neutralization cancels queued edges; death also prevents shots.
    submitAim(vec.east, true);
    submitAim(vec.east, false);
    player_input.neutralize(7);
    control.applyPlayerInput(7);
    player_input.beginPhysicsStep();
    control.applyFixedStepPlayerInputs();
    player_input.endPhysicsStep();
    try std.testing.expectEqual(@as(usize, 2), weapon.activeTrails.items.len);
    submitAim(vec.east, true);
    submitAim(vec.east, false);
    player.players.getPtr(7).?.isDead = true;
    player_input.beginPhysicsStep();
    control.applyFixedStepPlayerInputs();
    player_input.endPhysicsStep();
    try std.testing.expectEqual(@as(usize, 2), weapon.activeTrails.items.len);
}

test "free and snapped stick aim align the procedural barrel and release shot through neutral and re-press" {
    const old_view = animation.view;
    defer animation.view = old_view;
    const body = try beginAimingPlayer();
    defer endAimingPlayer(body);
    defer {
        delay.cleanup();
        delay.delayedActions = .init(allocator.allocator);
    }
    defer weapon.activeTrails.clearAndFree(allocator.allocator);
    try std.testing.expect(sdl.c.SDL_SetHint(sdl.c.SDL_HINT_AUDIO_DRIVER, "dummy"));
    defer _ = sdl.c.SDL_ResetHint(sdl.c.SDL_HINT_AUDIO_DRIVER);
    try std.testing.expect(sdl.c.SDL_InitSubSystem(sdl.c.SDL_INIT_AUDIO));
    defer sdl.c.SDL_QuitSubSystem(sdl.c.SDL_INIT_AUDIO);
    try audio.init();
    defer audio.cleanup();
    for ([_]data.AimMode{ .free, .eight_directions }) |aim_mode| {
        player_input.directionSettings.aimMode = aim_mode;
        player_input.neutralize(7);
        animation.resetPlayer(7);
        weapon.activeTrails.clearRetainingCapacity();
        var sample = gamepad.sampleSticks(gamepad.defaultBindings, .{ .x = 30000, .y = -20000 }, .{ .x = 0, .y = 0 });
        sample.buttons.set(.shoot, true);
        player_input.submit(7, sample);
        control.applyPlayerInput(7);
        const expected = if (aim_mode == .free) vec.normalize(.{ .x = 3, .y = 2 }) else vec.normalize(.{ .x = 1, .y = 1 });
        try nearPoint(expected, player.players.get(7).?.aimDirection, 0.00001);
        // Another render poll before physics: the stick returns to neutral while
        // the button is held and its press edge has not yet been consumed.
        sample = .{};
        sample.buttons.set(.shoot, true);
        player_input.submit(7, sample);
        control.applyPlayerInput(7);
        try nearPoint(expected, player.players.get(7).?.aimDirection, 0.00001);
        player_input.beginPhysicsStep();
        player_input.endPhysicsStep();
        for (0..10) |_| animation.fixedUpdate(1.0 / 60.0);
        const held_frame = player.weaponFrame(7, .physics, null).?;
        try nearPoint(expected, player.weaponDirection(held_frame), 0.00001);
        const muzzle = player.weaponMuzzle(held_frame).?;
        sample.buttons.set(.shoot, false);
        player_input.submit(7, sample);
        control.applyPlayerInput(7);
        // A new hold before physics may change live aim but not the queued shot.
        submitAim(vec.north, true);
        try nearPoint(expected, player_input.playerInputs.get(7).?.releasedAimDirection, 0.00001);
        player_input.beginPhysicsStep();
        control.applyFixedStepPlayerInputs();
        player_input.endPhysicsStep();
        try std.testing.expectEqual(@as(usize, 1), weapon.activeTrails.items.len);
        const trail = weapon.activeTrails.items[0];
        try nearPoint(conv.pixel2M(muzzle), trail.startPos, 0.00001);
        try nearPoint(.{ .x = expected.x * 3, .y = -expected.y * 3 }, vec.subtract(trail.endPos, trail.startPos), 0.00001);
        player_input.beginPhysicsStep();
        control.applyFixedStepPlayerInputs();
        player_input.endPhysicsStep();
        try std.testing.expectEqual(@as(usize, 1), weapon.activeTrails.items.len);
    }
}

test "invalid aiming settings preserve live pose and successful reload clears transient aiming" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    animation.holdShotPose(7, vec.west);
    const before = animation.states.get(7).?;
    const old_id = animation.assets.?.aiming.id.ptr;
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    const cases = [_][2][]const u8{
        .{ "\"schema_version\": 1", "\"schema_version\": 2" },
        .{ "\"humanoid_v1\"", "\"missing_rig\"" },
        .{ "\"hand_distance_m\": 0.545", "\"hand_distance_m\": 3" },
        .{ "\"hand_distance_m\": 0.545", "\"hand_distance_m\": 0" },
        .{ "\"raise_seconds\": 0.09", "\"raise_seconds\": 0" },
        .{ "\"lower_seconds\": 0.14", "\"lower_seconds\": 1e999" },
        .{ "\"shot_hold_seconds\": 0.06", "\"shot_hold_seconds\": -1" },
        .{ "\"time_unit\": \"seconds\",", "" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, aiming_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        const result: anyerror!void = replacement: {
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, actions_json, malformed, walls_json, &detail) catch |err| break :replacement err;
            break :replacement animation.replaceAssets(files, &detail);
        };
        try std.testing.expectError(error.InvalidCharacterAsset, result);
        try std.testing.expectEqualStrings(data.characterAimingPath, detail.file);
        try std.testing.expectEqual(old_id, animation.assets.?.aiming.id.ptr);
        try std.testing.expectEqualDeep(before, animation.states.get(7).?);
    }
    animation.installAssets(try load());
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.aim_weight);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.shot_hold_seconds);
}

fn createAnimationWall(side: f32, face: f32) !box2d.c.b2BodyId {
    const body = try box2d.createBody(box2d.createStaticBodyDef(.{ .x = side * (face + 0.5), .y = -2 }));
    var shape = box2d.c.b2DefaultShapeDef();
    shape.filter.categoryBits = collision.CATEGORY_TERRAIN;
    shape.filter.maskBits = collision.MASK_TERRAIN;
    shape.material.friction = 0;
    shape.enableSensorEvents = true;
    const polygon = box2d.c.b2MakeBox(0.5, 2.3);
    _ = box2d.c.b2CreatePolygonShape(body, &shape, &polygon);
    return body;
}

const WallPoseSample = struct { label: []const u8, side: f32, frame: animation.FramePose };

fn captureWallPose(samples: *std.ArrayListUnmanaged(WallPoseSample), label: []const u8, side: f32) !void {
    const frame = animation.playerFrame(7, .physics, null).?;
    try checkBones(animation.assets.?.rig, frame.pose);
    try samples.append(std.testing.allocator, .{ .label = label, .side = side, .frame = frame });
}

test "wall approach braces before contact and sustained input plants both hands and stows the blaster" {
    const old_view = animation.view;
    defer animation.view = old_view;
    var samples: std.ArrayListUnmanaged(WallPoseSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]f32{ 1, -1 }) |side| {
        const body = try beginAimingPlayer();
        defer endAimingPlayer(body);
        const wall = try createAnimationWall(side, 1);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .facing_right = side > 0, .vertical_speed_mps = 0, .separation_speed_mps = 0, .movement_direction = side, .horizontal_speed_mps = side * 6 };
        animation.resetPlayer(7);
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
        for (0..7) |tick| {
            input.body.x = side * (@as(f32, @floatFromInt(tick)) + 1) * 0.1;
            box2d.c.b2Body_SetTransform(body, vec.toBox2d(input.body), box2d.c.b2MakeRot(0));
            animation.updatePlayer(7, input, 1.0 / 60.0);
            if (tick == 4) {
                try std.testing.expectEqual(animation.WallAction.brace, animation.states.get(7).?.wall.action);
                try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.wall.contact_seconds);
                try captureWallPose(&samples, "approach", side);
            }
        }
        try captureWallPose(&samples, "contact", side);
        input.horizontal_speed_mps = 0;
        for (0..8) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        try captureWallPose(&samples, "absorb", side);
        for (0..60) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        const pushing = animation.states.get(7).?;
        try std.testing.expectEqual(animation.WallAction.push, pushing.wall.action);
        try std.testing.expect(pushing.feet[0].locked and pushing.feet[1].locked);
        for (0..120) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        const held_push = animation.states.get(7).?;
        for (pushing.feet, held_push.feet) |before_foot, after_foot| {
            try std.testing.expect(after_foot.locked);
            try nearPoint(before_foot.anchor, after_foot.anchor, 0.00001);
        }
        try std.testing.expectEqual(side > 0, pushing.facing_right);
        const stowed = animation.playerFrame(7, .physics, null).?;
        try std.testing.expect(stowed.weapon_stowed);
        const rig = animation.assets.?.rig;
        const hip = animation.attachmentToWorld(rig, animation.attachmentTransform(rig, stowed.pose, "weapon_holster").?, stowed.body, stowed.facing_right);
        try nearPoint(hip.position, stowed.weapon.position, 0.00001);
        const shot = animation.playerFrame(7, .physics, .{ .x = -side, .y = 0 }).?;
        try std.testing.expect(!shot.weapon_stowed);
        const grip = animation.attachmentToWorld(rig, animation.attachmentTransform(rig, shot.pose, "weapon_hand").?, shot.body, shot.facing_right);
        try nearPoint(grip.position, shot.weapon.position, 0.00001);
        try captureWallPose(&samples, "push", side);
        for ([_]f64{ 0, 0.25, 0.75, 1 }) |alpha| {
            const pose = animation.interpolatedPose(&animation.assets.?, pushing, alpha);
            try checkBones(animation.assets.?.rig, pose);
            for ([_]animation.Joint{ .left_hand, .right_hand }, pushing.wall.hands) |joint, anchor| {
                try std.testing.expect(anchor != null);
                const hand = animation.toWorld(animation.assets.?.rig, pose.joints[@intFromEnum(joint)], input.body, pushing.facing_right);
                try nearPoint(anchor.?, hand, 0.00003);
                try std.testing.expectApproxEqAbs(side, hand.x, 0.00003);
            }
        }
        try checkAirPose(pushing);
        // Aiming retains the free hand's contact and restores the weapon hand.
        input.aiming = true;
        input.movement_direction = 0;
        input.aim_direction = .{ .x = -side, .y = 0 };
        for (0..45) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        const aimed = animation.playerFrame(7, .physics, null).?;
        try std.testing.expect(!aimed.weapon_stowed);
        try std.testing.expectEqual(side < 0, aimed.facing_right);
        const free_hand = animation.toWorld(animation.assets.?.rig, aimed.pose.joints[@intFromEnum(animation.Joint.left_hand)], aimed.body, aimed.facing_right);
        try std.testing.expectApproxEqAbs(side, free_hand.x, 0.00003);
        try std.testing.expectApproxEqAbs(-side, player.weaponDirection(player.weaponFrame(7, .physics, null).?).x, 0.00003);
        try captureWallPose(&samples, "aim away", side);
        const before_release = animation.states.get(7).?;
        // Actual wall removal must release contacts even while aim stays held.
        box2d.c.b2DestroyBody(wall);
        animation.updatePlayer(7, input, 1.0 / 60.0);
        try checkWallPoseBoundary(before_release, animation.states.get(7).?);
        try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
        try std.testing.expectEqualDeep([2]?vec.Vec2{ null, null }, animation.states.get(7).?.wall.hands);
        input.aiming = false;
        for (0..60) |_| {
            const previous = animation.states.get(7).?;
            animation.updatePlayer(7, input, 1.0 / 60.0);
            try checkWallPoseBoundary(previous, animation.states.get(7).?);
        }
        try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.stow_weight);
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/wall_samples.json", bytes);
}

fn addAnimationWallSensors(body: box2d.c.b2BodyId) void {
    const moving = movement.states.getPtr(7).?;
    for ([_]f32{ -1, 1 }) |side| {
        var shape = box2d.c.b2DefaultShapeDef();
        shape.isSensor = true;
        shape.enableSensorEvents = true;
        shape.density = 0;
        shape.filter.categoryBits = collision.CATEGORY_SENSOR;
        shape.filter.maskBits = collision.MASK_SENSOR_WALL;
        const polygon = box2d.c.b2MakeOffsetBox(0.15, 0.4, .{ .x = side * 0.2, .y = -0.5 }, box2d.c.b2MakeRot(0));
        const id = box2d.c.b2CreatePolygonShape(body, &shape, &polygon);
        if (side < 0) moving.leftWallSensorId = id else moving.rightWallSensorId = id;
    }
}

test "real wall slide and wall jump drive poses without changing physics even with zero forced movement steps" {
    const old_view = animation.view;
    defer animation.view = old_view;
    var samples: std.ArrayListUnmanaged(WallPoseSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]f32{ -1, 1 }) |side| {
        for ([_]u32{ 0, 5 }) |forced_steps| {
            for ([_]usize{ 3, 8 }) |slide_before_jump| {
                const body = try beginAimingPlayer();
                defer endAimingPlayer(body);
                _ = try createAnimationWall(side, 1);
                addAnimationWallSensors(body);
                movement.towerfallSettings.wallJump.forcedMovementSteps = forced_steps;
                const moving = movement.states.getPtr(7).?;
                var saw_push = false;
                var slide_ticks: usize = 0;
                var jump_tick: ?usize = null;
                var extended_ticks: usize = 0;
                for (0..190) |tick| {
                    var input: player_input.Sample = .{ .movementDirection = .{ .x = side, .y = 0 }, .aimDirection = .{ .x = side, .y = 0 } };
                    const wall_jump = slide_ticks >= slide_before_jump and jump_tick == null;
                    input.buttons.set(.jump, tick == 60 or wall_jump);
                    player_input.submit(7, input);
                    control.applyPlayerInput(7);
                    player_input.beginPhysicsStep();
                    movement.applyAll(1.0 / 60.0);
                    const launch = moving.wallJumpedDirection;
                    box2d.worldStep(1.0 / 60.0, 4);
                    try movement.processSensorEvents();
                    const before_velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body));
                    const before_position = vec.fromBox2d(box2d.c.b2Body_GetPosition(body));
                    const before_animation = animation.states.get(7).?;
                    animation.fixedUpdate(1.0 / 60.0);
                    try nearPoint(before_velocity, vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body)), 0);
                    try nearPoint(before_position, vec.fromBox2d(box2d.c.b2Body_GetPosition(body)), 0);
                    player_input.endPhysicsStep();
                    const sample = animation.states.get(7).?;
                    if (before_animation.initialized and (before_animation.facing_right == sample.facing_right or before_animation.wall.action != .none or sample.wall.action != .none)) try checkWallPoseBoundary(before_animation, sample);
                    try checkBones(animation.assets.?.rig, animation.interpolatedPose(&animation.assets.?, sample, 0.5));
                    if (sample.wall.action == .push) saw_push = true;
                    if (sample.wall.action == .slide) {
                        slide_ticks += 1;
                        if (slide_ticks == 3) try captureWallPose(&samples, "slide", side);
                        try std.testing.expect(moving.wallSliding);
                        try std.testing.expectEqual(side < 0, sample.facing_right);
                        try std.testing.expect(sample.wall.hands[1] == null);
                        try std.testing.expect(!sample.feet[0].locked and !sample.feet[1].locked);
                        for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                            const set = &animation.assets.?;
                            const pose = animation.interpolatedPose(set, sample, alpha);
                            const position = vec.add(sample.previous_body, vec.mul(vec.subtract(sample.body, sample.previous_body), @floatCast(alpha)));
                            for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                                const sole = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], position, sample.facing_right);
                                if (sole.x * side > 1.00003) std.debug.print("slide sole {s} side={d} age={d} alpha={d}: {any} planes={any}\n", .{ @tagName(joint), side, sample.wall.seconds, alpha, sole, sample.wall.foot_surfaces });
                                try std.testing.expect(sole.x * side <= 1.00003);
                            }
                            for (sample.previous_wall.feet, sample.wall.feet, 0..) |before, after, index| {
                                if (!sample.previous_wall.feet_planted[index] or !sample.wall.feet_planted[index]) continue;
                                if (before == null or after == null) continue;
                                const expected = vec.add(before.?, vec.mul(vec.subtract(after.?, before.?), @floatCast(alpha)));
                                const joint: animation.Joint = if (index == 0) .left_toe else .right_toe;
                                const toe = animation.toWorld(set.rig, pose.joints[@intFromEnum(joint)], position, sample.facing_right);
                                try nearPoint(expected, toe, 0.00003);
                            }
                        }
                    }
                    if (launch != 0) {
                        try std.testing.expect(jump_tick == null);
                        jump_tick = tick;
                        try std.testing.expectEqual(@as(i8, @intFromFloat(-side)), launch);
                        try std.testing.expectEqual(animation.WallAction.jump, sample.wall.action);
                        try std.testing.expectEqualDeep([2]?vec.Vec2{ null, null }, sample.wall.hands);
                        try std.testing.expect(before_velocity.x * side < 0 and before_velocity.y < 0);
                        try captureWallPose(&samples, "push off", side);
                    }
                    if (jump_tick == null) continue;
                    if (sample.wall.action == .jump) {
                        try std.testing.expectEqual(side < 0, sample.facing_right);
                        try std.testing.expect(!animation.playerFrame(7, .physics, null).?.weapon_stowed);
                    }
                    const age = tick - jump_tick.?;
                    if (age < 12 and forced_steps == 5) {
                        const labels = [_][]const u8{ "jump 00", "jump 01", "jump 02", "jump 03", "jump 04", "jump 05", "jump 06", "jump 07", "jump 08", "jump 09", "jump 10", "jump 11" };
                        try captureWallPose(&samples, labels[age], side);
                    }
                    if (age >= 1 and age <= 5) {
                        const rig = animation.assets.?.rig;
                        const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
                        var extended = true;
                        for (rig.limbs[0..2]) |limb| {
                            const length = rig.lengths[@intFromEnum(limb.middle)] + rig.lengths[@intFromEnum(limb.end)];
                            const reach = vec.magnitude(vec.subtract(pose.joints[@intFromEnum(limb.end)], pose.joints[@intFromEnum(limb.root)]));
                            extended = extended and reach > length * 0.95;
                        }
                        if (extended) extended_ticks += 1;
                    }
                    if (tick == jump_tick.? + 5) try captureWallPose(&samples, "depart", side);
                    if (tick <= jump_tick.? + 20) continue;
                    try std.testing.expect(sample.wall.action != .jump);
                    break;
                }
                if (!saw_push or slide_ticks < 3 or jump_tick == null) std.debug.print("wall trial side={d} forced={d}: push={} slide_ticks={d} jump={?d}, pos={any}, contacts={d}/{d}\n", .{ side, forced_steps, saw_push, slide_ticks, jump_tick, box2d.c.b2Body_GetPosition(body), moving.leftWallContactCount, moving.rightWallContactCount });
                try std.testing.expect(saw_push);
                try std.testing.expect(slide_ticks >= 3);
                try std.testing.expect(jump_tick != null);
                // The push-off must be visible for several real gameplay frames.
                if (extended_ticks < 3) std.debug.print("extended ticks side={d}: {d}\n", .{ side, extended_ticks });
                try std.testing.expect(extended_ticks >= 3);
                movement.reset(7);
                animation.resetPlayer(7);
                try std.testing.expectEqual(@as(i8, 0), moving.wallJumpedDirection);
                try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
            }
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try fs.writeFile("artifacts/character_animation/wall_jump_samples.json", bytes);
}

test "wall jump keeps reachable toes planted then releases without stretching or reacquiring" {
    for ([_]f32{ -1, 1 }) |side| {
        for ([_]bool{ false, true }) |aim_away| {
            for ([_]bool{ false, true }) |remove_wall| {
                _ = try beginLocomotion();
                defer box2d.destroyWorld();
                defer animation.cleanup();
                const wall = try createAnimationWall(side, 0.3);
                var input: animation.LocomotionInput = .{ .body = .{ .x = 0, .y = -1.5 }, .supported = false, .ground_y = null, .facing_right = side > 0, .vertical_speed_mps = 2, .separation_speed_mps = 0, .wall_sliding = true, .movement_direction = side, .aiming = aim_away, .aim_direction = .{ .x = -side, .y = 0 } };
                for (0..90) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
                const rig = animation.assets.?.rig;
                const sliding = animation.states.get(7).?;
                const slide_pose = animation.interpolatedPose(&animation.assets.?, sliding, 1);
                for ([_]animation.Joint{ .left_toe, .left_heel, .right_toe, .right_heel }) |joint| {
                    const sole = animation.toWorld(rig, slide_pose.joints[@intFromEnum(joint)], sliding.body, sliding.facing_right);
                    try std.testing.expectApproxEqAbs(side * 0.3, sole.x, 0.00003);
                }
                var retained: usize = 0;
                var released = [_]bool{ false, false };
                for (0..12) |tick| {
                    const previous = animation.states.get(7).?;
                    input.body.x -= side * 0.1;
                    input.body.y -= 0.1;
                    input.vertical_speed_mps = -6;
                    input.wall_sliding = false;
                    input.wall_jump_direction = if (tick == 0) @intFromFloat(-side) else 0;
                    if (tick == 1 and remove_wall) box2d.c.b2DestroyBody(wall);
                    animation.updatePlayer(7, input, 1.0 / 60.0);
                    const current = animation.states.get(7).?;
                    try checkWallPoseBoundary(previous, current);
                    for (current.wall.feet, 0..) |anchor, index| {
                        if (anchor == null) {
                            released[index] = true;
                            continue;
                        }
                        try std.testing.expect(!released[index]);
                        try std.testing.expect(!remove_wall or tick == 0);
                        try nearPoint(sliding.wall.feet[index].?, anchor.?, 0.00001);
                        retained += 1;
                        for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |alpha| {
                            const pose = animation.interpolatedPose(&animation.assets.?, current, alpha);
                            const body = vec.add(previous.body, vec.mul(vec.subtract(current.body, previous.body), @floatCast(alpha)));
                            const joint: animation.Joint = if (index == 0) .left_toe else .right_toe;
                            const toe = animation.toWorld(rig, pose.joints[@intFromEnum(joint)], body, current.facing_right);
                            try nearPoint(anchor.?, toe, 0.00003);
                        }
                    }
                }
                // The nearly straight leg releases on launch; the bent leg
                // stays until extension or next-tick wall removal.
                try std.testing.expect(retained >= if (remove_wall) @as(usize, 1) else 2);
                try std.testing.expect(released[0] and released[1]);
            }
        }
    }
}

test "sliding wall contacts follow authored foot height curves" {
    const ramp_json = try std.mem.replaceOwned(u8, std.testing.allocator, walls_json, "{\"phase\": 1, \"value\": -0.52, \"interpolation\": \"linear\"}", "{\"phase\": 1, \"value\": -0.62, \"interpolation\": \"linear\"}");
    defer std.testing.allocator.free(ramp_json);
    for ([_]f32{ -1, 1 }) |side| {
        _ = try beginLocomotion();
        defer box2d.destroyWorld();
        defer animation.cleanup();
        _ = try createAnimationWall(side, 0.3);
        var detail: animation.Diagnostic = .{};
        const files = try data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, actions_json, aiming_json, ramp_json, &detail);
        try animation.replaceAssets(files, &detail);
        const input: animation.LocomotionInput = .{ .body = .{ .x = 0, .y = -1.5 }, .supported = false, .ground_y = null, .facing_right = side > 0, .vertical_speed_mps = 2, .separation_speed_mps = 0, .wall_sliding = true, .movement_direction = side };
        for (0..14) |_| {
            animation.updatePlayer(7, input, 1.0 / 60.0);
            const sample = animation.states.get(7).?;
            const rig = animation.assets.?.rig;
            const pose = animation.interpolatedPose(&animation.assets.?, sample, 1);
            const phase = @min(1, sample.wall.seconds / animation.assets.?.walls.slide.cycle_seconds);
            try std.testing.expectApproxEqAbs(-0.52 - phase * 0.1, pose.joints[@intFromEnum(animation.Joint.right_ankle)].y, 0.00003);
            const toe = animation.toWorld(rig, pose.joints[@intFromEnum(animation.Joint.right_toe)], sample.body, sample.facing_right);
            try std.testing.expectApproxEqAbs(side * 0.3, toe.x, 0.00003);
            try std.testing.expect(sample.wall.feet[1] != null);
            try checkBones(rig, pose);
        }
    }
}

test "one-handed wall slide faces outward and keeps the blaster ready through aiming and push-off" {
    const old_view = animation.view;
    defer animation.view = old_view;
    var samples: std.ArrayListUnmanaged(WallPoseSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]f32{ -1, 1 }) |side| {
        const body = try beginAimingPlayer();
        defer endAimingPlayer(body);
        _ = try createAnimationWall(side, 1);
        var input: animation.LocomotionInput = .{ .body = .{ .x = side * 0.7, .y = -1.5 }, .supported = false, .ground_y = null, .facing_right = side > 0, .vertical_speed_mps = 2, .separation_speed_mps = 0, .movement_direction = side, .wall_sliding = true };
        box2d.c.b2Body_SetTransform(body, vec.toBox2d(input.body), box2d.c.b2MakeRot(0));
        animation.resetPlayer(7);
        for (0..90) |tick| {
            animation.updatePlayer(7, input, 1.0 / 60.0);
            if (tick == 0) try captureWallPose(&samples, "enter", side);
        }
        const set = &animation.assets.?;
        const sliding = animation.states.get(7).?;
        const ready = animation.playerFrame(7, .physics, null).?;
        try std.testing.expectEqual(side < 0, ready.facing_right);
        try std.testing.expect(!ready.weapon_stowed);
        try std.testing.expect(sliding.wall.hands[0] != null and sliding.wall.hands[1] == null);
        try std.testing.expectEqual(@as(f32, 0), sliding.stow_weight);
        try checkWallSlideLegs(ready, side);
        const hand = animation.toWorld(set.rig, ready.pose.joints[@intFromEnum(animation.Joint.left_hand)], ready.body, ready.facing_right);
        const head = animation.toWorld(set.rig, ready.pose.joints[@intFromEnum(animation.Joint.head)], ready.body, ready.facing_right);
        try nearPoint(sliding.wall.hands[0].?, hand, 0.00003);
        try std.testing.expect(hand.y < head.y);
        const direction = player.weaponDirection(player.weaponFrame(7, .physics, null).?);
        try std.testing.expect(direction.x * side < -0.8 and direction.y < 0 and direction.y > -0.6);
        for ([_]animation.Joint{ .left_knee, .right_knee }) |joint| {
            const knee = animation.toWorld(set.rig, ready.pose.joints[@intFromEnum(joint)], ready.body, ready.facing_right);
            try std.testing.expect(knee.x * side < 1);
        }
        try captureWallPose(&samples, "slide", side);
        // The knife-style grip travels down the face, rather than hanging from
        // one stationary point. Neither animation nor aiming holds up the body.
        for (0..5) |_| {
            input.body.y += 0.02;
            box2d.c.b2Body_SetTransform(body, vec.toBox2d(input.body), box2d.c.b2MakeRot(0));
            animation.updatePlayer(7, input, 1.0 / 60.0);
        }
        try std.testing.expectApproxEqAbs(sliding.wall.hands[0].?.y + 0.1, animation.states.get(7).?.wall.hands[0].?.y, 0.00003);
        const directions = [_]vec.Vec2{ .{ .x = -side, .y = 0 }, vec.north, .{ .x = side, .y = 0 } };
        for (directions, [_][]const u8{ "aim out", "aim up", "aim wall" }) |aim, label| {
            input.aiming = true;
            input.aim_direction = aim;
            for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
            const frame = animation.playerFrame(7, .physics, null).?;
            try std.testing.expect(!frame.weapon_stowed);
            try std.testing.expect(animation.states.get(7).?.wall.hands[1] == null);
            try checkWallSlideLegs(frame, side);
            const support = animation.toWorld(set.rig, frame.pose.joints[@intFromEnum(animation.Joint.left_hand)], frame.body, frame.facing_right);
            try nearPoint(animation.states.get(7).?.wall.hands[0].?, support, 0.00003);
            try nearPoint(aim, player.weaponDirection(player.weaponFrame(7, .physics, null).?), 0.00003);
            const forced = animation.playerFrame(7, .physics, .{ .x = -side, .y = 0 }).?;
            try std.testing.expect(!forced.weapon_stowed);
            try captureWallPose(&samples, label, side);
        }
        input.aiming = false;
        for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
        try std.testing.expectEqual(side < 0, animation.states.get(7).?.facing_right);
        for (0..25) |tick| {
            const before = animation.states.get(7).?;
            input.body.x -= side * 0.15;
            input.body.y -= 0.15;
            input.vertical_speed_mps = -9;
            input.wall_sliding = false;
            input.wall_jump_direction = if (tick == 0) @intFromFloat(-side) else 0;
            box2d.c.b2Body_SetTransform(body, vec.toBox2d(input.body), box2d.c.b2MakeRot(0));
            animation.updatePlayer(7, input, 1.0 / 60.0);
            const after = animation.states.get(7).?;
            const frame = animation.playerFrame(7, .physics, null).?;
            try std.testing.expectEqual(side < 0, frame.facing_right);
            try std.testing.expect(!frame.weapon_stowed);
            try std.testing.expect(after.wall.hands[0] == null and after.wall.hands[1] == null);
            try checkWallPoseBoundary(before, after);
            try nearPoint(animation.toWorld(set.rig, animation.attachmentPosition(set.rig, frame.pose, "weapon_hand").?, frame.body, frame.facing_right), frame.weapon.position, 0.00003);
            if (tick == 0) try captureWallPose(&samples, "push off", side);
            if (tick == 5) try captureWallPose(&samples, "depart", side);
            if (tick == 20) try captureWallPose(&samples, "airborne", side);
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try fs.writeFile("artifacts/character_animation/one_hand_slide_samples.json", bytes);
}

test "wall settings validate atomically and reload clears contacts and holstering" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    _ = try createAnimationWall(1, 0.3);
    for (0..40) |_| animation.updatePlayer(7, .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .facing_right = true, .vertical_speed_mps = 0, .separation_speed_mps = 0, .movement_direction = 1 }, 1.0 / 60.0);
    const before = animation.states.get(7).?;
    try std.testing.expectEqual(animation.WallAction.push, before.wall.action);
    const old_id = animation.assets.?.walls.settings.id.ptr;
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var detail: animation.Diagnostic = .{};
    const cases = [_][2][]const u8{
        .{ "\"schema_version\": 1", "\"schema_version\": 2" },
        .{ "\"rig_id\": \"humanoid_v1\"", "\"rig_id\": \"missing\"" },
        .{ "\"blend_seconds\": 0.06", "\"blend_seconds\": 0" },
        .{ "\"probe_distance_m\": 0.75", "\"probe_distance_m\": 0.1" },
        .{ "\"impact_compression_m\": 0.09", "\"impact_compression_m\": 1e999" },
        .{ "\"start\": 0, \"end\": 0.2", "\"start\": 0.1, \"end\": 0.2" },
        .{ "\"wall_jump_v1\"", "\"wall_slide_v1\"" },
        .{ "\"loop\": false", "\"loop\": true" },
        .{ "\"time_unit\": \"seconds\",", "" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, walls_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        const result: anyerror!void = replacement: {
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, actions_json, aiming_json, malformed, &detail) catch |err| break :replacement err;
            break :replacement animation.replaceAssets(files, &detail);
        };
        try std.testing.expectError(error.InvalidCharacterAsset, result);
        try std.testing.expectEqualStrings(data.characterWallsPath, detail.file);
        try std.testing.expectEqual(old_id, animation.assets.?.walls.settings.id.ptr);
        try std.testing.expectEqualDeep(before, animation.states.get(7).?);
    }
    animation.installAssets(try load());
    try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.stow_weight);
}

test "wall bracing releases on neutral input edges and unsupported surfaces" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const wall = try createAnimationWall(1, 0.3);
    var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .facing_right = true, .vertical_speed_mps = 0, .separation_speed_mps = 0, .movement_direction = 1 };
    for (0..30) |_| animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.push, animation.states.get(7).?.wall.action);
    input.movement_direction = 0;
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
    try std.testing.expectEqualDeep([2]?vec.Vec2{ null, null }, animation.states.get(7).?.wall.hands);
    input.movement_direction = 1;
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.brace, animation.states.get(7).?.wall.action);
    // Dynamic/rotated surfaces do not inherit static wall anchors.
    box2d.c.b2Body_SetType(wall, box2d.c.b2_kinematicBody);
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
    box2d.c.b2Body_SetType(wall, box2d.c.b2_staticBody);
    box2d.c.b2Body_SetTransform(wall, .{ .x = 0.8, .y = -2 }, box2d.c.b2MakeRot(0.1));
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
    box2d.c.b2Body_SetTransform(wall, .{ .x = 0.8, .y = -2 }, box2d.c.b2MakeRot(0));
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(animation.WallAction.brace, animation.states.get(7).?.wall.action);
    input.supported = false;
    input.ground_y = null;
    input.wall_sliding = true;
    for (0..35) |tick| {
        input.body.y = -@as(f32, @floatFromInt(tick)) * 0.1;
        animation.updatePlayer(7, input, 1.0 / 60.0);
    }
    // Above the wall's top, stale movement contact input cannot keep bracing.
    try std.testing.expectEqual(animation.WallAction.none, animation.states.get(7).?.wall.action);
    try std.testing.expectEqualDeep([2]?vec.Vec2{ null, null }, animation.states.get(7).?.wall.hands);
    input.body = .{ .x = 10, .y = 0 };
    animation.updatePlayer(7, input, 1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0), animation.states.get(7).?.stow_weight);
}

fn checkWallSlideLegs(frame: animation.FramePose, side: f32) !void {
    const rig = animation.assets.?.rig;
    for (rig.limbs[0..2], 0..) |limb, index| {
        const length = rig.lengths[@intFromEnum(limb.middle)] + rig.lengths[@intFromEnum(limb.end)];
        const reach = vec.magnitude(vec.subtract(frame.pose.joints[@intFromEnum(limb.end)], frame.pose.joints[@intFromEnum(limb.root)]));
        try std.testing.expect(if (index == 0) reach > length * 0.97 else reach < length * 0.8);
        const toe_id: animation.Joint = if (index == 0) .left_toe else .right_toe;
        const heel_id: animation.Joint = if (index == 0) .left_heel else .right_heel;
        const ankle = animation.toWorld(rig, frame.pose.joints[@intFromEnum(limb.end)], frame.body, frame.facing_right);
        const toe = animation.toWorld(rig, frame.pose.joints[@intFromEnum(toe_id)], frame.body, frame.facing_right);
        const heel = animation.toWorld(rig, frame.pose.joints[@intFromEnum(heel_id)], frame.body, frame.facing_right);
        try std.testing.expect(ankle.x * side < 1);
        try std.testing.expectApproxEqAbs(side, toe.x, 0.00003);
        try std.testing.expectApproxEqAbs(side, heel.x, 0.00003);
        try std.testing.expect(toe.y > ankle.y and toe.y > heel.y + 0.2);
    }
}

fn checkWallPoseBoundary(before: animation.PlayerState, after: animation.PlayerState) !void {
    const set = &animation.assets.?;
    const end = animation.interpolatedPose(set, before, 1);
    const start = animation.interpolatedPose(set, after, 0);
    try checkBones(set.rig, end);
    try checkBones(set.rig, start);
    // Facing reflects the rig's small anatomical shoulder offsets (8 mm each).
    // Allow that shoulder shift on a turn, but catch a switched elbow/knee branch.
    const tolerance: f32 = if (before.facing_right == after.facing_right) 0.00003 else 0.02;
    for (end.joints, start.joints, 0..) |a, b, index| {
        nearPoint(animation.toWorld(set.rig, a, before.body, before.facing_right), animation.toWorld(set.rig, b, after.previous_body, after.facing_right), tolerance) catch |err| {
            std.debug.print("wall boundary {s}->{s}, joint {s}, age={d}\n", .{ @tagName(before.wall.action), @tagName(after.wall.action), @tagName(@as(animation.Joint, @enumFromInt(index))), after.wall.seconds });
            return err;
        };
    }
    for ([_]f64{ 0.25, 0.5, 0.75 }) |fraction| try checkBones(set.rig, animation.interpolatedPose(set, after, fraction));
}

test "partial wall brace entry and release preserve adjacent render endpoints" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    _ = try createAnimationWall(1, 0.3);
    _ = try createAnimationWall(-1, 0.3);
    for ([_]f32{ 1, -1 }) |side| {
        animation.resetPlayer(7);
        var input: animation.LocomotionInput = .{ .body = vec.zero, .supported = true, .ground_y = 0.3, .facing_right = side > 0, .vertical_speed_mps = 0, .separation_speed_mps = 0 };
        animation.updatePlayer(7, input, 1.0 / 60.0);
        for (0..18) |tick| {
            const before = animation.states.get(7).?;
            // Release while only partly raised, re-enter during release, then
            // hold and leave the wall again. Check each shared render endpoint.
            input.movement_direction = if (tick < 2 or (tick >= 4 and tick < 10)) side else 0;
            animation.updatePlayer(7, input, 1.0 / 60.0);
            try checkWallPoseBoundary(before, animation.states.get(7).?);
        }
    }
}
