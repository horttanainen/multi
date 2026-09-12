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
const sprite = @import("src/sprite.zig");
const weapon = @import("src/weapon.zig");

const rig_json = @embedFile("character_rigs/humanoid.json");
const locomotion_json = @embedFile("character_locomotion/run.json");
const actions_json = @embedFile("character_actions/airborne.json");
const motion_json = @embedFile("character_motions/run_reference.json");
const dense_motion_json = @embedFile("character_motions/run_reference_dense.json");
const reference_json = @embedFile("tests/fixtures/character_run_poses.json");

fn load() !animation.Assets {
    var detail: animation.Diagnostic = .{};
    return animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, actions_json, &detail), &detail);
}

fn replaceFromJson(rig_bytes: []const u8, motion_bytes: []const u8, detail: *data.CharacterAssetDiagnostic) !void {
    try animation.replaceAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, locomotion_json, actions_json, detail), detail);
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
        break :parsed try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, locomotion_json, actions_bytes, &detail);
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
    try std.testing.expectEqualStrings("airborne_v1", files.actions.id);
    try std.testing.expectEqualStrings("jump_reference_v1", files.actions.jump.id);
    try std.testing.expectEqual(@as(f32, 1), files.actions.crouch.tracks[0].keys[2].phase);
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
    try std.testing.expectEqual(@as(usize, 6), menu.focusedIndex()); // Only atlas export is visible.
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

test "character run reproduces the twelve accepted poses after explicit frame conversion" {
    var set = try load();
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

test "compact Bezier run preserves dense controls, solved poses, and contact intent throughout the cycle" {
    var compact = try load();
    defer compact.arena.deinit();
    var detail: animation.Diagnostic = .{};
    var dense = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, dense_motion_json, locomotion_json, actions_json, &detail), &detail);
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
        .{ "\"value\": 0.30000000000000004", "\"value\": 1e999", "tracks[0].keys[0].value: number must be finite" },
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
    var reordered = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, reordered_rig, reordered_motion, locomotion_json, actions_json, &detail), &detail);
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

test "flat foot queries release removed support even with stale grounded input and ignore moving floors" {
    const floor = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    box2d.c.b2Body_SetType(floor, box2d.c.b2_kinematicBody);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(!foot.locked);
    box2d.c.b2Body_SetType(floor, box2d.c.b2_staticBody);
    animation.resetPlayer(7);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    box2d.c.b2DestroyBody(floor);
    advanceRun(0, true);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(!foot.locked);
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
        .{ "\"schema_version\": 1", "\"schema_version\": 2" },
        .{ "\"run_reference_v1\"", "\"missing_clip\"" },
        .{ "\"stride_max\": 1.15", "\"stride_max\": 0.1" },
        .{ "\"start_seconds\": 0.08", "\"start_seconds\": 0" },
        .{ "\"release_seconds\": 0.055", "\"release_seconds\": 1e999" },
        .{ "\"full_run_speed_mps\": 1.8", "\"full_run_speed_mps\": 0.01" },
        .{ "\"plant_distance_m\": 0.035,", "" },
    };
    for (cases) |case| {
        const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, locomotion_json, case[0], case[1]);
        defer std.testing.allocator.free(malformed);
        const result = replacement: {
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, malformed, actions_json, &detail) catch |err| break :replacement err;
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
    for ([_]animation.Motion{ set.actions.jump, set.actions.fall, set.actions.crouch }) |clip| {
        for (0..241) |tick| {
            var controls = set.rig.neutral;
            for (&controls, clip.tracks) |*control, track| control.* = animation.evaluateTrack(track, @as(f32, @floatFromInt(tick)) / 240);
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
    for (seen[0..@intFromEnum(animation.Action.crouch)]) |visited| try std.testing.expect(visited);
    try std.testing.expect(landing_contacts > 0);
    try std.testing.expect(early_landing_contacts > 0);
    for (animation.states.get(7).?.feet) |foot| try std.testing.expect(foot.locked);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/airborne_samples.json", bytes);
    // Existing moving support remains grounded. Foot anchoring to that support
    // is a later phase, but its upward velocity must not select the jump clip.
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
    try std.testing.expectEqual(animation.Action.crouch, animation.states.get(7).?.action);
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
        .{ "\"schema_version\": 1", "\"schema_version\": 2" },
        .{ "\"humanoid_v1\"", "\"missing_rig\"" },
        .{ "\"blend_seconds\": 0.045", "\"blend_seconds\": 0" },
        .{ "\"takeoff_speed_mps\": 0.2", "\"takeoff_speed_mps\": -1" },
        .{ "\"full_landing_speed_mps\": 12.0", "\"full_landing_speed_mps\": 0.5" },
        .{ "\"crouch_hold_phase\": 0.22", "\"crouch_hold_phase\": 1" },
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
            const files = data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, locomotion_json, malformed, &detail) catch |err| break :replacement err;
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

test "hard landings crouch and settle on both feet in either facing, including an airborne turn" {
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
        // Their feet should follow the same paths even at full impact strength.
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
            for ([_]animation.Control{ .left_foot_x, .left_foot_y, .left_foot_angle, .right_foot_x, .right_foot_y, .right_foot_angle }) |control| try std.testing.expectApproxEqAbs(baseline.controls[@intFromEnum(control)], sample.controls[@intFromEnum(control)], 0.000002);
            const phase = animation.clipPhase(animation.assets.?.motion, sample.phase);
            for (sample.contact_intent, 0..) |intent, index| try std.testing.expectEqual(animation.contactIntent(animation.assets.?.motion, @enumFromInt(index), phase), intent);
            try checkAirPose(sample);
            if (sample.action != .land) continue;
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

test "held crouch keeps the hips low while standing and moving, and releases into standing or jumping" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    runtime.init(std.testing.io);
    var samples: std.ArrayList(AirSample) = .empty;
    defer samples.deinit(std.testing.allocator);
    for ([_]f32{ 0, 0.5, 3.2, 9, -3.2 }) |speed| {
        animation.resetPlayer(7);
        advanceRun(0, true);
        var x: f32 = 0;
        var sample: animation.PlayerState = undefined;
        var contact_frames: usize = 0;
        for (0..120) |tick| {
            x += speed / 60;
            animation.updatePlayer(7, .{ .body = .{ .x = x, .y = 0 }, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true, .crouch_requested = true }, 1.0 / 60.0);
            sample = animation.states.get(7).?;
            try std.testing.expectEqual(animation.Action.crouch, sample.action);
            try checkAirPose(sample);
            if (tick < 30) continue;
            try std.testing.expect(sample.controls[@intFromEnum(animation.Control.pelvis_y)] < -0.26);
            if (sample.feet[0].locked or sample.feet[1].locked) contact_frames += 1;
            const set = &animation.assets.?;
            var joints = animation.interpolatedPose(set, sample, 1).joints;
            for (&joints) |*point| point.* = animation.toWorld(set.rig, point.*, sample.body, sample.facing_right);
            try samples.append(std.testing.allocator, .{ .action = sample.action, .seconds = sample.action_seconds, .strength = 1, .pose = .{ .speed = sample.speed_mps, .phase = animation.clipPhase(set.motion, sample.phase), .weight = sample.run_weight, .facing_right = sample.facing_right, .body = sample.body, .planted = .{ sample.feet[0].locked, sample.feet[1].locked }, .joints = joints } });
        }
        try std.testing.expect(contact_frames > 10);
        try std.testing.expectEqual(speed == 0, sample.phase == 0);
        for (0..60) |_| sample = advanceAir(.{ .x = x, .y = 0 }, 0, true);
        try std.testing.expectEqual(animation.Action.grounded, sample.action);
        try std.testing.expectApproxEqAbs(@as(f32, 0), sample.controls[@intFromEnum(animation.Control.pelvis_y)], 0.0001);
        animation.updatePlayer(7, .{ .body = .{ .x = x, .y = -0.1 }, .supported = true, .ground_y = 0.3, .vertical_speed_mps = -6, .separation_speed_mps = 6, .facing_right = true, .crouch_requested = true }, 1.0 / 60.0);
        sample = animation.states.get(7).?;
        try std.testing.expectEqual(animation.Action.jump, sample.action);
        try checkAirPose(sample);
        _ = advanceAir(.{ .x = x, .y = -0.2 }, 12, false);
        animation.updatePlayer(7, .{ .body = .{ .x = x, .y = 0 }, .supported = true, .ground_y = 0.3, .vertical_speed_mps = 0, .separation_speed_mps = 0, .facing_right = true, .crouch_requested = true }, 1.0 / 60.0);
        try std.testing.expectEqual(animation.Action.crouch, animation.states.get(7).?.action);
        try checkAirPose(animation.states.get(7).?);
    }
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, samples.items, .{});
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "artifacts/character_animation");
    try fs.writeFile("artifacts/character_animation/crouch_samples.json", bytes);
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

test "carried attachment uses solved wrist rotation through running crouching and airborne interpolation" {
    _ = try beginLocomotion();
    defer box2d.destroyWorld();
    defer animation.cleanup();
    const set = &animation.assets.?;
    const attachment = set.rig.attachments.getPtr("weapon_hand").?;
    attachment.angle_offset_radians = 0.3;
    attachment.local_offset = .{ .x = 0.025, .y = -0.01 };
    var x: f32 = 0;
    for (0..240) |tick| {
        const speed: f32 = if (tick < 120) 3.2 else -3.2;
        x += speed / 60;
        const in_air = tick >= 60 and tick < 110;
        const vertical: f32 = if (tick < 85) -6 else 8;
        animation.updatePlayer(7, .{ .body = .{ .x = x, .y = if (in_air) -0.2 else 0 }, .supported = !in_air, .ground_y = if (in_air) null else 0.3, .vertical_speed_mps = if (in_air) vertical else 0, .separation_speed_mps = if (in_air) -vertical else 0, .facing_right = speed > 0, .crouch_requested = tick >= 150 and tick < 200 }, 1.0 / 60.0);
        const sample = animation.states.get(7).?;
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
    weapons[0].carriedSpriteUuid = 123;
    var p = std.mem.zeroes(player.Player);
    p.weapons = &weapons;
    for ([_]animation.View{ .stick, .overlay }) |mode| {
        animation.view = mode;
        p.isAiming = false;
        try std.testing.expect(player.usesCarriedWeapon(p));
        p.isAiming = true;
        try std.testing.expect(!player.usesCarriedWeapon(p));
    }
    animation.view = .sprites;
    p.isAiming = false;
    try std.testing.expect(!player.usesCarriedWeapon(p));
    animation.view = .stick;
    weapons[0].carriedSpriteUuid = 0;
    try std.testing.expect(!player.usesCarriedWeapon(p));
}
