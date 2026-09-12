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

const rig_json = @embedFile("character_rigs/humanoid.json");
const motion_json = @embedFile("character_motions/run_reference.json");
const dense_motion_json = @embedFile("character_motions/run_reference_dense.json");
const reference_json = @embedFile("tests/fixtures/character_run_poses.json");

fn load() !animation.Assets {
    var detail: animation.Diagnostic = .{};
    return animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, motion_json, &detail), &detail);
}

fn replaceFromJson(rig_bytes: []const u8, motion_bytes: []const u8, detail: *data.CharacterAssetDiagnostic) !void {
    try animation.replaceAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, detail), detail);
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
        break :parsed try data.parseCharacterAnimationData(std.testing.allocator, rig_bytes, motion_bytes, &detail);
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
    var dense = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, rig_json, dense_motion_json, &detail), &detail);
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
    var reordered = try animation.prepareAssets(try data.parseCharacterAnimationData(std.testing.allocator, reordered_rig, reordered_motion, &detail), &detail);
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
