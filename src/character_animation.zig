const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const data = @import("data.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const player = @import("player.zig");
const movement = @import("movement.zig");
const entity = @import("entity.zig");
const time = @import("time.zig");
const gpu = @import("gpu.zig");
const sdl = @import("sdl.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const text = @import("text.zig");
const viewport = @import("viewport.zig");
const renderer = @import("renderer.zig");
const sprite = @import("sprite.zig");

pub const Joint = enum(u8) {
    pelvis,
    chest,
    neck,
    head,
    left_shoulder,
    left_elbow,
    left_hand,
    left_knee,
    left_ankle,
    left_toe,
    left_heel,
    right_shoulder,
    right_elbow,
    right_hand,
    right_knee,
    right_ankle,
    right_toe,
    right_heel,
};
pub const Limb = enum(u8) { left_leg, right_leg, left_arm, right_arm };
pub const Control = enum(u8) {
    pelvis_x,
    pelvis_y,
    torso_angle,
    left_foot_x,
    left_foot_y,
    left_foot_angle,
    right_foot_x,
    right_foot_y,
    right_foot_angle,
    left_hand_x,
    left_hand_y,
    right_hand_x,
    right_hand_y,
};
pub const View = enum { sprites, stick, overlay };
pub const Playback = enum { neutral, run };
pub const ReviewAction = enum { view, pose, diagnostics, reload, slow_motion, zoom };
pub const Interpolation = enum { step, linear, bezier };
const jointCount = std.meta.fields(Joint).len;
const limbCount = std.meta.fields(Limb).len;
const controlCount = std.meta.fields(Control).len;

pub const Key = struct {
    phase: f32,
    value: f32,
    interpolation: Interpolation,
    in_handle: ?[2]f32 = null,
    out_handle: ?[2]f32 = null,
};
pub const Track = struct { binding: Control, keys: []const Key };
pub const JointDef = struct { id: Joint, parent: ?Joint, rest_offset: vec.Vec2 };
pub const LimbDef = struct {
    id: Limb,
    root: Joint,
    middle: Joint,
    end: Joint,
    bend_sign: i8,
    min_bend_radians: f32,
    max_bend_radians: f32,
};
pub const Attachment = struct { id: []const u8, joint: Joint, local_offset: vec.Vec2 };
pub const Contact = struct { limb: Limb, start: f32, end: f32 };
pub const Rig = struct {
    id: []const u8,
    joints: [jointCount]JointDef,
    lengths: [jointCount]f32,
    limbs: [limbCount]LimbDef,
    attachments: std.StringHashMapUnmanaged(Attachment),
    neutral: [controlCount]f32,
    root_from_body: vec.Vec2,
    head_radius: f32,
    line_width: f32,
};
pub const Motion = struct {
    id: []const u8,
    tracks: [controlCount]Track,
    contacts: []const Contact,
    cycle_seconds: f32,
    reference_speed_mps: f32,
    loop: bool,
};
pub const Assets = struct { arena: std.heap.ArenaAllocator, rig: Rig, motion: Motion };
pub const Diagnostic = data.CharacterAssetDiagnostic;
pub const PlayerState = struct {
    previous_phase: f64 = 0,
    phase: f64 = 0,
    facing_right: bool = false,
};
pub const Pose = struct {
    joints: [jointCount]vec.Vec2,
    desired_targets: [limbCount]vec.Vec2,
    clamped: [limbCount]bool,
    contact_intent: [2]bool,
};
pub const LimbSolution = struct { middle: vec.Vec2, end: vec.Vec2, clamped: bool };

pub var assets: ?Assets = null;
pub var states: std.AutoArrayHashMapUnmanaged(usize, PlayerState) = .empty;
pub var view: View = .sprites;
pub var playback: Playback = .run;
pub var show_diagnostics = false;
pub var diagnostic: Diagnostic = .{};
var slow_motion = false;
var reload_failed = false;
var review_enabled = false;
pub var close_view = false;
pub var capture_path: ?[:0]const u8 = null;
var capture_path_buffer: [1024:0]u8 = undefined;
var capture_started_at: ?f64 = null;

const invalid = data.invalidCharacterAsset;

fn expectedParent(joint: Joint) ?Joint {
    return switch (joint) {
        .pelvis => null,
        .chest, .left_knee, .right_knee => .pelvis,
        .neck, .left_shoulder, .right_shoulder => .chest,
        .head => .neck,
        .left_elbow => .left_shoulder,
        .right_elbow => .right_shoulder,
        .left_hand => .left_elbow,
        .right_hand => .right_elbow,
        .left_ankle => .left_knee,
        .right_ankle => .right_knee,
        .left_toe => .left_ankle,
        .right_toe => .right_ankle,
        .left_heel => .left_toe,
        .right_heel => .right_toe,
    };
}

fn validateRig(file: data.CharacterRigData, memory: std.mem.Allocator, detail: *Diagnostic) !Rig {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (file.joints.len != jointCount) return invalid(detail, "joints: expected {d} unique named joints", .{jointCount});
    if (file.limbs.len != limbCount) return invalid(detail, "limbs: expected four named chains", .{});
    if (file.neutral_controls.len != controlCount) return invalid(detail, "neutral_controls: expected {d} controls", .{controlCount});
    if (file.head_radius < 0.01 or file.head_radius > 1) return invalid(detail, "head_radius: expected 0.01..1 meters", .{});
    if (file.line_width < 0.005 or file.line_width > 0.2) return invalid(detail, "line_width: expected 0.005..0.2 meters", .{});
    if (vec.magnitude(file.root_from_body) > 5) return invalid(detail, "root_from_body: exceeds 5 meters", .{});
    var rig: Rig = .{
        .id = file.id,
        .joints = undefined,
        .lengths = undefined,
        .limbs = undefined,
        .attachments = .empty,
        .neutral = undefined,
        .root_from_body = file.root_from_body,
        .head_radius = file.head_radius,
        .line_width = file.line_width,
    };
    var seen_joints: [jointCount]bool = @splat(false);
    for (file.joints) |joint| {
        const index = @intFromEnum(joint.id);
        if (seen_joints[index]) return invalid(detail, "joints.{s}: duplicate joint", .{@tagName(joint.id)});
        seen_joints[index] = true;
        // This first schema supports the documented humanoid tree. Checking every
        // parent also rejects cycles and ensures every solver chain is connected.
        if (joint.parent != expectedParent(joint.id)) return invalid(detail, "joints.{s}.parent: does not match humanoid hierarchy (cycles are forbidden)", .{@tagName(joint.id)});
        const length = vec.magnitude(joint.rest_offset);
        if (joint.id == .pelvis and length != 0) return invalid(detail, "joints.pelvis.rest_offset: must be zero", .{});
        if (joint.id != .pelvis and (length < 0.001 or length > 5)) return invalid(detail, "joints.{s}.rest_offset: bone length must be 0.001..5 meters", .{@tagName(joint.id)});
        rig.joints[index] = joint;
        rig.lengths[index] = length;
    }
    var seen_limbs: [limbCount]bool = @splat(false);
    const roots = [limbCount]Joint{ .pelvis, .pelvis, .left_shoulder, .right_shoulder };
    const middles = [limbCount]Joint{ .left_knee, .right_knee, .left_elbow, .right_elbow };
    const ends = [limbCount]Joint{ .left_ankle, .right_ankle, .left_hand, .right_hand };
    for (file.limbs) |limb| {
        const index = @intFromEnum(limb.id);
        if (seen_limbs[index]) return invalid(detail, "limbs.{s}: duplicate chain", .{@tagName(limb.id)});
        seen_limbs[index] = true;
        if (limb.root != roots[index] or limb.middle != middles[index] or limb.end != ends[index]) return invalid(detail, "limbs.{s}: incorrect root/middle/end bindings", .{@tagName(limb.id)});
        if (limb.bend_sign != -1 and limb.bend_sign != 1) return invalid(detail, "limbs.{s}.bend_sign: expected -1 or 1", .{@tagName(limb.id)});
        if (limb.min_bend_radians < 0.001 or limb.max_bend_radians > std.math.pi - 0.0005 or limb.max_bend_radians <= limb.min_bend_radians) return invalid(detail, "limbs.{s}: expected 0.001 <= min_bend < max_bend < pi", .{@tagName(limb.id)});
        rig.limbs[index] = limb;
    }
    var seen_controls: [controlCount]bool = @splat(false);
    for (file.neutral_controls) |control| {
        const index = @intFromEnum(control.binding);
        if (seen_controls[index]) return invalid(detail, "neutral_controls.{s}: duplicate control", .{@tagName(control.binding)});
        seen_controls[index] = true;
        if (@abs(control.value) > 20) return invalid(detail, "neutral_controls.{s}: exceeds supported range +/-20", .{@tagName(control.binding)});
        rig.neutral[index] = control.value;
    }
    if (file.attachments.len == 0 or file.attachments.len > 32) return invalid(detail, "attachments: expected 1..32 entries", .{});
    for (file.attachments, 0..) |attachment, index| {
        if (attachment.id.len == 0 or attachment.id.len > 64) return invalid(detail, "attachments[{d}].id: expected 1..64 bytes", .{index});
        if (vec.magnitude(attachment.local_offset) > 5) return invalid(detail, "attachments.{s}.local_offset: exceeds 5 meters", .{attachment.id});
        const entry = try rig.attachments.getOrPut(memory, attachment.id);
        if (entry.found_existing) return invalid(detail, "attachments.{s}: duplicate id", .{attachment.id});
        entry.value_ptr.* = attachment;
    }
    return rig;
}

pub fn validateTrack(track: Track, loop: bool, detail: *Diagnostic) !void {
    const keys = track.keys;
    const name = @tagName(track.binding);
    if (keys.len < 2) return invalid(detail, "tracks.{s}.keys: expected at least 2 keys", .{name});
    if (keys[0].phase != 0 or keys[keys.len - 1].phase != 1) return invalid(detail, "tracks.{s}: first/last phase must be 0/1", .{name});
    if (loop and @abs(keys[0].value - keys[keys.len - 1].value) > 0.00001) return invalid(detail, "tracks.{s}: loop endpoints do not match", .{name});
    for (keys, 0..) |key, index| {
        if (@abs(key.value) > 20) return invalid(detail, "tracks.{s}.keys[{d}]: value exceeds supported range +/-20", .{ name, index });
        for ([_]?[2]f32{ key.in_handle, key.out_handle }) |handle| {
            if (handle == null) continue;
            const point = handle.?;
            if (point[0] < 0 or point[0] > 1 or @abs(point[1]) > 20) return invalid(detail, "tracks.{s}.keys[{d}]: handle is outside phase/value limits", .{ name, index });
        }
        if (index + 1 == keys.len) continue;
        const next = keys[index + 1];
        if (next.phase - key.phase < 0.000001) return invalid(detail, "tracks.{s}.keys[{d}]: phases must strictly increase", .{ name, index });
        if (key.interpolation != .bezier) continue;
        if (key.out_handle == null or next.in_handle == null) return invalid(detail, "tracks.{s}.keys[{d}]: Bezier requires outgoing/incoming handles", .{ name, index });
        const outgoing = key.out_handle.?;
        const incoming = next.in_handle.?;
        if (outgoing[0] < key.phase or incoming[0] < outgoing[0] or incoming[0] > next.phase) return invalid(detail, "tracks.{s}.keys[{d}]: Bezier time handles must be monotonic within the segment", .{ name, index });
    }
}

fn validateMotion(file: data.CharacterMotionData, rig: Rig, detail: *Diagnostic) !Motion {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (!std.mem.eql(u8, file.rig_id, rig.id)) return invalid(detail, "rig_id: '{s}' does not match '{s}'", .{ file.rig_id, rig.id });
    if (file.cycle_seconds < 0.05 or file.cycle_seconds > 60) return invalid(detail, "cycle_seconds: expected 0.05..60 seconds", .{});
    if (file.reference_speed_mps < 0 or file.reference_speed_mps > 100) return invalid(detail, "reference_speed_mps: expected 0..100", .{});
    if (file.tracks.len != controlCount) return invalid(detail, "tracks: expected {d} unique named controls", .{controlCount});
    var motion: Motion = .{ .id = file.id, .tracks = undefined, .contacts = file.contacts, .cycle_seconds = file.cycle_seconds, .reference_speed_mps = file.reference_speed_mps, .loop = file.loop };
    var seen: [controlCount]bool = @splat(false);
    for (file.tracks) |track| {
        const index = @intFromEnum(track.binding);
        if (seen[index]) return invalid(detail, "tracks.{s}: duplicate binding", .{@tagName(track.binding)});
        seen[index] = true;
        try validateTrack(track, file.loop, detail);
        motion.tracks[index] = track;
    }
    if (file.contacts.len > 32) return invalid(detail, "contacts: exceeds 32 intervals", .{});
    for (file.contacts, 0..) |contact, index| {
        if (contact.limb != .left_leg and contact.limb != .right_leg) return invalid(detail, "contacts[{d}].limb: expected a leg", .{index});
        if (contact.start < 0 or contact.end > 1 or contact.end <= contact.start) return invalid(detail, "contacts[{d}]: expected 0 <= start < end <= 1", .{index});
        for (file.contacts[0..index]) |previous| {
            if (contact.limb == previous.limb and contact.start < previous.end and previous.start < contact.end) return invalid(detail, "contacts[{d}]: overlapping intervals for {s}", .{ index, @tagName(contact.limb) });
        }
    }
    return motion;
}

// Consumes the decoded data on both success and failure. Successful preparation
// transfers its arena to the runtime assets; failed validation releases it here.
pub fn prepareAssets(files: data.CharacterAnimationData, detail: *Diagnostic) !Assets {
    var arena = files.arena;
    errdefer arena.deinit();
    detail.* = .{ .file = data.characterRigPath };
    const rig = try validateRig(files.rig, arena.allocator(), detail);
    detail.file = data.characterMotionPath;
    const motion = try validateMotion(files.motion, rig, detail);
    return .{ .arena = arena, .rig = rig, .motion = motion };
}

fn cubic(a: f32, b: f32, c: f32, d: f32, t: f32) f32 {
    const q = 1 - t;
    return q * q * q * a + 3 * q * q * t * b + 3 * q * t * t * c + t * t * t * d;
}

pub fn evaluateTrack(track: Track, phase: f32) f32 {
    const keys = track.keys;
    if (phase <= 0) return keys[0].value;
    if (phase >= 1) return keys[keys.len - 1].value;
    var low: usize = 0;
    var high = keys.len - 1;
    while (high - low > 1) {
        const middle = (low + high) / 2;
        if (keys[middle].phase <= phase) low = middle else high = middle;
    }
    const a = keys[low];
    const b = keys[high];
    const progress = (phase - a.phase) / (b.phase - a.phase);
    switch (a.interpolation) {
        .step => return a.value,
        .linear => return a.value + (b.value - a.value) * progress,
        .bezier => {
            // Handles are guaranteed by validation. Solve their time coordinate;
            // normalized segment time is not generally the Bezier parameter.
            const outgoing = a.out_handle.?;
            const incoming = b.in_handle.?;
            var start: f32 = 0;
            var end: f32 = 1;
            for (0..24) |_| {
                const t = (start + end) * 0.5;
                if (cubic(a.phase, outgoing[0], incoming[0], b.phase, t) < phase) start = t else end = t;
            }
            return cubic(a.value, outgoing[1], incoming[1], b.value, (start + end) * 0.5);
        },
    }
}

pub fn clipPhase(motion: Motion, phase: f64) f32 {
    return @floatCast(if (motion.loop) @mod(phase, 1) else std.math.clamp(phase, 0, 1));
}

pub fn contactIntent(motion: Motion, limb: Limb, phase: f32) bool {
    for (motion.contacts) |interval| {
        if (interval.limb == limb and phase >= interval.start and phase < interval.end) return true;
    }
    return false;
}

fn rotate(point: vec.Vec2, angle: f32) vec.Vec2 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ .x = point.x * c - point.y * s, .y = point.x * s + point.y * c };
}

pub fn reachLimits(upper: f32, lower: f32, min_bend: f32, max_bend: f32) [2]f64 {
    // This form avoids cancellation near a fully folded equal-length chain.
    const u: f64 = upper;
    const l: f64 = lower;
    const difference = (u - l) * (u - l);
    return .{
        @sqrt(difference + 4 * u * l * std.math.pow(f64, @cos(@as(f64, max_bend) * 0.5), 2)),
        @sqrt(difference + 4 * u * l * std.math.pow(f64, @cos(@as(f64, min_bend) * 0.5), 2)),
    };
}

pub fn solveLimb(root: vec.Vec2, target: vec.Vec2, upper: f32, lower: f32, bend_sign: i8, limits: [2]f64) LimbSolution {
    // Keep the triangle calculations wide: valid rigs can pair a 5 m bone with
    // a 1 mm bone, which loses its length through cancellation in f32.
    const dx = @as(f64, target.x) - root.x;
    const dy = @as(f64, target.y) - root.y;
    const requested_distance = @sqrt(dx * dx + dy * dy);
    // Coincident and out-of-reach targets are supported IK inputs. Use a stable
    // downward direction for the coincident case and expose clamping in the pose.
    const direction: [2]f64 = if (requested_distance > 0.000001) .{ dx / requested_distance, dy / requested_distance } else .{ 0, -1 };
    const distance = std.math.clamp(requested_distance, limits[0], limits[1]);
    const u: f64 = upper;
    const l: f64 = lower;
    const projection = (u * u - l * l + distance * distance) / (2 * distance);
    const height = @sqrt(@max(0, u * u - projection * projection)) * @as(f64, @floatFromInt(bend_sign));
    return .{
        .middle = .{
            .x = @floatCast(root.x + direction[0] * projection - direction[1] * height),
            .y = @floatCast(root.y + direction[1] * projection + direction[0] * height),
        },
        .end = .{ .x = @floatCast(root.x + direction[0] * distance), .y = @floatCast(root.y + direction[1] * distance) },
        .clamped = @abs(requested_distance - distance) > 0.00001,
    };
}

pub fn solvePose(rig: Rig, controls: [controlCount]f32) Pose {
    var pose: Pose = .{ .joints = @splat(vec.zero), .desired_targets = undefined, .clamped = undefined, .contact_intent = .{ false, false } };
    pose.joints[@intFromEnum(Joint.pelvis)] = .{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    const torso_rotation = -controls[@intFromEnum(Control.torso_angle)];
    for ([_]Joint{ .chest, .neck, .head, .left_shoulder, .right_shoulder }) |joint_id| {
        const joint = rig.joints[@intFromEnum(joint_id)];
        pose.joints[@intFromEnum(joint_id)] = vec.add(pose.joints[@intFromEnum(joint.parent.?)], rotate(joint.rest_offset, torso_rotation));
    }
    const target_x = [limbCount]Control{ .left_foot_x, .right_foot_x, .left_hand_x, .right_hand_x };
    const target_y = [limbCount]Control{ .left_foot_y, .right_foot_y, .left_hand_y, .right_hand_y };
    for (rig.limbs, 0..) |limb, index| {
        const target = vec.Vec2{ .x = controls[@intFromEnum(target_x[index])], .y = controls[@intFromEnum(target_y[index])] };
        const upper = rig.lengths[@intFromEnum(limb.middle)];
        const lower = rig.lengths[@intFromEnum(limb.end)];
        const solution = solveLimb(pose.joints[@intFromEnum(limb.root)], target, upper, lower, limb.bend_sign, reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians));
        pose.joints[@intFromEnum(limb.middle)] = solution.middle;
        pose.joints[@intFromEnum(limb.end)] = solution.end;
        pose.desired_targets[index] = target;
        pose.clamped[index] = solution.clamped;
    }
    for ([_]Joint{ .left_toe, .left_heel, .right_toe, .right_heel }, 0..) |joint_id, index| {
        const joint = rig.joints[@intFromEnum(joint_id)];
        const angle = controls[@intFromEnum(if (index < 2) Control.left_foot_angle else Control.right_foot_angle)];
        pose.joints[@intFromEnum(joint_id)] = vec.add(pose.joints[@intFromEnum(joint.parent.?)], rotate(joint.rest_offset, angle));
    }
    return pose;
}

pub fn evaluatePose(set: *const Assets, phase: f64, mode: Playback) Pose {
    if (mode == .neutral) return solvePose(set.rig, set.rig.neutral);
    const p = clipPhase(set.motion, phase);
    var controls: [controlCount]f32 = undefined;
    for (set.motion.tracks, 0..) |track, index| controls[index] = evaluateTrack(track, p);
    var pose = solvePose(set.rig, controls);
    pose.contact_intent = .{ contactIntent(set.motion, .left_leg, p), contactIntent(set.motion, .right_leg, p) };
    return pose;
}

// Attachment offsets use +X along the incoming bone and +Y counterclockwise.
pub fn attachmentPosition(rig: Rig, pose: Pose, name: []const u8) ?vec.Vec2 {
    const attachment = rig.attachments.get(name) orelse {
        std.log.warn("character_animation.attachmentPosition: attachment '{s}' is missing", .{name});
        return null;
    };
    const index = @intFromEnum(attachment.joint);
    const parent = rig.joints[index].parent;
    if (parent == null) return vec.add(pose.joints[index], attachment.local_offset);
    const direction = vec.subtract(pose.joints[index], pose.joints[@intFromEnum(parent.?)]);
    return vec.add(pose.joints[index], rotate(attachment.local_offset, std.math.atan2(direction.y, direction.x)));
}

pub fn installAssets(replacement: Assets) void {
    if (assets != null) assets.?.arena.deinit();
    assets = replacement;
    for (states.values()) |*state| {
        state.phase = 0;
        state.previous_phase = 0;
    }
    reload_failed = false;
}

// Consumes the decoded candidate; the active assets change only after validation.
pub fn replaceAssets(files: data.CharacterAnimationData, detail: *Diagnostic) !void {
    const replacement = try prepareAssets(files, detail);
    installAssets(replacement);
}

fn loadAssets() !void {
    try replaceAssets(try data.loadCharacterAnimationData(allocator, &diagnostic), &diagnostic);
}

pub fn reload() void {
    loadAssets() catch |err| {
        reload_failed = true;
        std.log.warn("character_animation.reload: keeping previous assets ({s})", .{@errorName(err)});
        return;
    };
    std.log.info("character_animation: loaded {s} / {s}", .{ assets.?.rig.id, assets.?.motion.id });
}

pub fn configure(args: []const []const u8) !void {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--character-animation")) {
            view = .stick;
            review_enabled = true;
        }
        if (std.mem.eql(u8, arg, "--character-animation-overlay")) {
            view = .overlay;
            review_enabled = true;
        }
        if (std.mem.eql(u8, arg, "--character-animation-neutral")) playback = .neutral;
        if (std.mem.eql(u8, arg, "--character-animation-diagnostics")) show_diagnostics = true;
        if (std.mem.eql(u8, arg, "--character-animation-close")) close_view = true;
        if (!std.mem.eql(u8, arg, "--character-animation-capture")) continue;
        if (index + 1 >= args.len or args[index + 1].len == 0) {
            std.log.err("character_animation.configure: --character-animation-capture needs a PNG path", .{});
            return error.MissingCharacterCapturePath;
        }
        index += 1;
        capture_path = std.fmt.bufPrintZ(&capture_path_buffer, "{s}", .{args[index]}) catch {
            std.log.err("character_animation.configure: capture path exceeds 1024 bytes", .{});
            return error.CharacterCapturePathTooLong;
        };
    }
}

pub fn init() void {
    reload();
    if (review_enabled) std.log.info("character_animation controls: press § for debug options (Z zoom, V view, P pose, D targets, R reload, S slow motion)", .{});
}

pub fn register(player_id: usize) !void {
    try states.put(allocator, player_id, .{});
}

pub fn resetPlayer(player_id: usize) void {
    const state = states.getPtr(player_id) orelse {
        std.log.warn("character_animation.resetPlayer: state missing for player {d}", .{player_id});
        return;
    };
    state.phase = 0;
    state.previous_phase = 0;
}

pub fn clearPlayers() void {
    states.clearAndFree(allocator);
}

pub fn cleanup() void {
    clearPlayers();
    if (assets != null) assets.?.arena.deinit();
    assets = null;
    if (slow_motion) time.setSimulationScale(1);
}

pub fn fixedUpdate(dt: f64) void {
    if (assets == null) return; // Initial asset failure leaves sprite gameplay available.
    for (states.keys(), states.values()) |player_id, *state| {
        const p = player.players.get(player_id) orelse {
            std.log.warn("character_animation.fixedUpdate: player {d} is missing", .{player_id});
            continue;
        };
        if (p.isDead) continue;
        const movement_state = movement.states.get(player_id) orelse {
            std.log.warn("character_animation.fixedUpdate: movement state missing for player {d}", .{player_id});
            continue;
        };
        state.facing_right = movement_state.facingRight;
        state.previous_phase = state.phase;
        if (playback == .run) state.phase += dt / assets.?.motion.cycle_seconds;
    }
}

pub fn reviewAction(action: ReviewAction) void {
    review_enabled = true;
    switch (action) {
        .view => {
            view = switch (view) {
                .sprites => .stick,
                .stick => .overlay,
                .overlay => .sprites,
            };
        },
        .pose => {
            playback = if (playback == .neutral) .run else .neutral;
            for (states.values()) |*state| {
                state.phase = 0;
                state.previous_phase = 0;
            }
        },
        .diagnostics => show_diagnostics = !show_diagnostics,
        .reload => reload(),
        .slow_motion => {
            slow_motion = !slow_motion;
            time.setSimulationScale(if (slow_motion) 0.25 else 1);
        },
        .zoom => close_view = !close_view,
    }
    std.log.info("character_animation: view={s} pose={s} diagnostics={} slow={} close={}", .{ @tagName(view), @tagName(playback), show_diagnostics, slow_motion, close_view });
}

pub fn hideSprites() bool {
    return assets != null and view == .stick;
}

pub fn captureReady() bool {
    if (capture_path == null) return false;
    if (capture_started_at == null) {
        capture_started_at = time.realNow();
        return false;
    }
    return time.realNow() - capture_started_at.? >= 2;
}

pub fn focusCamera(camera_id: usize, zoom: f32) void {
    const cam = camera.cameras.get(camera_id) orelse {
        std.log.warn("character_animation.focusCamera: camera {d} is missing", .{camera_id});
        return;
    };
    const p = player.players.get(cam.playerId) orelse return; // Editor/shared cameras can have no player.
    const ent = entity.getEntity(p.bodyId) orelse {
        std.log.warn("character_animation.focusCamera: entity missing for player {d}", .{p.id});
        return;
    };
    const body = box2d.getInterpolatedState(ent.state, box2d.getState(p.bodyId));
    const center = vec.add(vec.fromBox2d(body.pos), player.centerOffset);
    camera.centerOn(conv.m2Pixel(vec.toBox2d(center)), zoom);
}

pub fn toWorld(rig: Rig, local: vec.Vec2, body: vec.Vec2, facing_right: bool) vec.Vec2 {
    const sign: f32 = if (facing_right) 1 else -1;
    return .{ .x = body.x + (rig.root_from_body.x + local.x) * sign, .y = body.y - rig.root_from_body.y - local.y };
}

fn toScreen(world: vec.Vec2) [2]f32 {
    // Convert the local offset separately to preserve subpixel joint positions.
    const origin = camera.relativePosition(.{ .x = 0, .y = 0 });
    return .{ @as(f32, @floatFromInt(origin.x)) + world.x * conv.met2pix, @as(f32, @floatFromInt(origin.y)) + world.y * conv.met2pix };
}

fn drawSegment(a: [2]f32, b: [2]f32, width: f32) !void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.0001) return; // Coincident overlay markers need no segment.
    const x = -dy / length * width * 0.5;
    const y = dx / length * width * 0.5;
    try gpu.renderFillQuad(.{ .{ a[0] + x, a[1] + y }, .{ b[0] + x, b[1] + y }, .{ b[0] - x, b[1] - y }, .{ a[0] - x, a[1] - y } });
}

fn drawRing(center: [2]f32, radius: f32, width: f32) !void {
    for (0..24) |index| {
        const a = @as(f32, @floatFromInt(index)) * std.math.tau / 24;
        const b = @as(f32, @floatFromInt(index + 1)) * std.math.tau / 24;
        try drawSegment(.{ center[0] + @cos(a) * radius, center[1] + @sin(a) * radius }, .{ center[0] + @cos(b) * radius, center[1] + @sin(b) * radius }, width);
    }
}

fn limbColor(color: sprite.Color, far: bool) sdl.Color {
    return .{ .r = if (far) color.r / 2 else color.r, .g = if (far) color.g / 2 else color.g, .b = if (far) color.b / 2 else color.b, .a = 255 };
}

pub fn drawAll() !void {
    if (assets == null or view == .sprites) return;
    const set = &assets.?;
    for (states.keys(), states.values()) |player_id, state| {
        const p = player.players.get(player_id) orelse {
            std.log.warn("character_animation.drawAll: player {d} is missing", .{player_id});
            continue;
        };
        if (p.isDead) continue;
        const ent = entity.getEntity(p.bodyId) orelse {
            std.log.warn("character_animation.drawAll: entity missing for player {d}", .{player_id});
            continue;
        };
        const body = box2d.getInterpolatedState(ent.state, box2d.getState(p.bodyId));
        const phase = state.previous_phase + (state.phase - state.previous_phase) * time.alpha;
        const pose = evaluatePose(set, phase, playback);
        var points: [jointCount][2]f32 = undefined;
        for (pose.joints, 0..) |point, index| points[index] = toScreen(toWorld(set.rig, point, vec.fromBox2d(body.pos), state.facing_right));
        const width = @max(1.25 / renderer.zoom, set.rig.line_width * conv.met2pix);
        // Fixed limb identity: right is the far limb even when movement faces left.
        for ([_]bool{ true, false }) |far| {
            try gpu.setRenderDrawColor(limbColor(p.color, far));
            for (set.rig.joints) |joint| {
                if (joint.id == .pelvis or joint.id == .head) continue;
                const right = @intFromEnum(joint.id) >= @intFromEnum(Joint.right_shoulder);
                if (right != far) continue;
                try drawSegment(points[@intFromEnum(joint.parent.?)], points[@intFromEnum(joint.id)], width);
            }
            const ankle: Joint = if (far) .right_ankle else .left_ankle;
            const heel: Joint = if (far) .right_heel else .left_heel;
            try drawSegment(points[@intFromEnum(ankle)], points[@intFromEnum(heel)], width * 0.6);
        }
        try gpu.setRenderDrawColor(limbColor(p.color, false));
        try drawRing(points[@intFromEnum(Joint.head)], set.rig.head_radius * conv.met2pix, width * 0.75);
        const head = pose.joints[@intFromEnum(Joint.head)];
        const eye = toScreen(toWorld(set.rig, vec.add(head, .{ .x = set.rig.head_radius * 0.43, .y = set.rig.head_radius * 0.15 }), vec.fromBox2d(body.pos), state.facing_right));
        try drawSegment(.{ eye[0] - width * 0.2, eye[1] }, .{ eye[0] + width * 0.2, eye[1] }, width * 0.6);
        if (!show_diagnostics) continue;
        try drawDiagnostics(set.rig, pose, points, vec.fromBox2d(body.pos), state.facing_right, width);
    }
}

fn drawDiagnostics(rig: Rig, pose: Pose, points: [jointCount][2]f32, body: vec.Vec2, facing: bool, width: f32) !void {
    try gpu.setRenderDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 210 });
    for (points) |point| try drawRing(point, width * 1.3, width * 0.4);
    for (rig.limbs, 0..) |limb, index| {
        const desired = toScreen(toWorld(rig, pose.desired_targets[index], body, facing));
        try gpu.setRenderDrawColor(.{ .r = 255, .g = if (pose.clamped[index]) 70 else 200, .b = 40, .a = 210 });
        try drawSegment(.{ desired[0] - width * 3, desired[1] }, .{ desired[0] + width * 3, desired[1] }, width * 0.5);
        try drawSegment(.{ desired[0], desired[1] - width * 3 }, .{ desired[0], desired[1] + width * 3 }, width * 0.5);
        try drawSegment(desired, points[@intFromEnum(limb.end)], width * 0.5);
        try gpu.setRenderDrawColor(.{ .r = 150, .g = 160, .b = 190, .a = 65 });
        const upper = rig.lengths[@intFromEnum(limb.middle)];
        const lower = rig.lengths[@intFromEnum(limb.end)];
        const limits = reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians);
        try drawRing(points[@intFromEnum(limb.root)], @floatCast(limits[1] * conv.met2pix), width * 0.35);
    }
    try gpu.setRenderDrawColor(.{ .r = 100, .g = 255, .b = 130, .a = 255 });
    for ([_]Joint{ .left_toe, .right_toe }, 0..) |toe, index| {
        if (!pose.contact_intent[index]) continue;
        const point = points[@intFromEnum(toe)];
        try drawSegment(.{ point[0] - width * 3, point[1] + width * 3 }, .{ point[0] + width * 3, point[1] + width * 3 }, width);
    }
}

pub fn drawStatus() !void {
    if (!review_enabled) return;
    gpu.setZoom(1);
    var buffer: [256]u8 = undefined;
    const status = try std.fmt.bufPrintZ(&buffer, "RIG: {s} / {s} / {s}", .{ @tagName(view), @tagName(playback), if (slow_motion) "0.25x" else "1x" });
    const height = viewport.activeViewport.height;
    try text.write(.small, status, .{ .x = 12, .y = height - 62 });
    try text.write(.small, "§ Debug options", .{ .x = 12, .y = height - 32 });
    if (!reload_failed) return;
    try text.write(.small, "RIG RELOAD FAILED - see log", .{ .x = 12, .y = height - 92 });
}
