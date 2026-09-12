const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const data = @import("data.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const player = @import("player.zig");
const movement = @import("movement.zig");
const player_input = @import("player_input.zig");
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
const collision = @import("collision.zig");

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
pub const Playback = enum { locomotion, neutral, run };
pub const Action = enum { grounded, jump, fall, land, crouch };
pub const ReviewAction = enum { view, pose, diagnostics, reload, slow_motion, zoom };
pub const Interpolation = enum { step, linear, bezier };
const jointCount = std.meta.fields(Joint).len;
const limbCount = std.meta.fields(Limb).len;
const controlCount = std.meta.fields(Control).len;
const target_x = [limbCount]Control{ .left_foot_x, .right_foot_x, .left_hand_x, .right_hand_x };
const target_y = [limbCount]Control{ .left_foot_y, .right_foot_y, .left_hand_y, .right_hand_y };
const foot_angles = [2]Control{ .left_foot_angle, .right_foot_angle };
const toes = [2]Joint{ .left_toe, .right_toe };
const foot_joints = [4]Joint{ .left_toe, .left_heel, .right_toe, .right_heel };

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
pub const Actions = struct { settings: data.CharacterActionsData, jump: Motion, fall: Motion, crouch: Motion };
pub const Assets = struct { arena: std.heap.ArenaAllocator, rig: Rig, motion: Motion, locomotion: data.CharacterLocomotionData, actions: Actions };
pub const Diagnostic = data.CharacterAssetDiagnostic;
pub const FootState = struct {
    locked: bool = false,
    blocked: bool = false,
    anchor: vec.Vec2 = vec.zero,
    correction: vec.Vec2 = vec.zero,
};
pub const LocomotionInput = struct {
    body: vec.Vec2,
    supported: bool,
    // Only an upward-facing static contact provides a flat planting plane.
    ground_y: ?f32,
    facing_right: bool,
    // Box2D convention: positive is downward; relative to support when present.
    vertical_speed_mps: f32,
    // Positive along the support normal means moving away from the surface.
    separation_speed_mps: f32,
    crouch_requested: bool = false,
};
pub const PlayerState = struct {
    previous_phase: f64 = 0,
    phase: f64 = 0,
    facing_right: bool = false,
    initialized: bool = false,
    body: vec.Vec2 = vec.zero,
    previous_body: vec.Vec2 = vec.zero,
    speed_mps: f32 = 0,
    vertical_speed_mps: f32 = 0,
    action: Action = .grounded,
    action_seconds: f32 = 0,
    landing_strength: f32 = 0,
    contact_intent: [2]bool = .{ false, false },
    run_weight: f32 = 0,
    intensity: f32 = 0,
    stride_scale: f32 = 1,
    feet: [2]FootState = .{ .{}, .{} },
    previous_feet: [2]FootState = .{ .{}, .{} },
    foot_heading: f32 = 0,
    previous_foot_heading: f32 = 0,
    sole_floors: [4]?f32 = @splat(null),
    previous_sole_floors: [4]?f32 = @splat(null),
    previous_controls: [controlCount]f32 = @splat(0),
    controls: [controlCount]f32 = @splat(0),
    previous_facing_right: bool = false,
    transition_offsets: [controlCount]f32 = @splat(0),
    transition_seconds: f32 = 0.14,
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
pub var playback: Playback = .locomotion;
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

fn validateLocomotion(file: data.CharacterLocomotionData, rig: Rig, motion: Motion, detail: *Diagnostic) !void {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (!std.mem.eql(u8, file.rig_id, rig.id)) return invalid(detail, "rig_id: does not match loaded rig", .{});
    if (!std.mem.eql(u8, file.motion_id, motion.id)) return invalid(detail, "motion_id: does not match loaded motion", .{});
    if (!motion.loop or motion.reference_speed_mps <= 0) return invalid(detail, "motion_id: locomotion requires a looping clip with positive reference speed", .{});
    if (file.stop_speed_mps < 0.001 or file.full_run_speed_mps <= file.stop_speed_mps or file.full_run_speed_mps > 100) return invalid(detail, "full_run_speed_mps: expected stop_speed_mps >= 0.001 < full_run_speed_mps <= 100", .{});
    if (file.stride_min < 0.1 or file.stride_max < file.stride_min or file.stride_max > 2) return invalid(detail, "stride_min/stride_max: expected 0.1 <= min <= max <= 2", .{});
    inline for (.{ "start_seconds", "stop_seconds", "turn_seconds", "release_seconds" }) |field| {
        if (@field(file, field) < 0.01 or @field(file, field) > 2) return invalid(detail, "{s}: expected 0.01..2 seconds", .{field});
    }
    inline for (.{ "plant_distance_m", "max_anchor_error_m", "flat_height_tolerance_m" }) |field| {
        if (@field(file, field) < 0.001 or @field(file, field) > 0.5) return invalid(detail, "{s}: expected 0.001..0.5 meters", .{field});
    }
}

fn validateActions(file: data.CharacterActionsData, rig: Rig, detail: *Diagnostic) !Actions {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (file.blend_seconds < 0.01 or file.blend_seconds > 0.5) return invalid(detail, "blend_seconds: expected 0.01..0.5 seconds", .{});
    if (file.takeoff_speed_mps < 0.01 or file.takeoff_speed_mps > 2) return invalid(detail, "takeoff_speed_mps: expected 0.01..2", .{});
    if (file.min_landing_speed_mps < 0 or file.full_landing_speed_mps <= file.min_landing_speed_mps or file.full_landing_speed_mps > 100) return invalid(detail, "full_landing_speed_mps: expected 0 <= min_landing_speed_mps < full_landing_speed_mps <= 100", .{});
    if (file.crouch_hold_phase <= 0 or file.crouch_hold_phase >= 1) return invalid(detail, "crouch_hold_phase: expected a phase strictly between 0 and 1", .{});
    var actions: Actions = .{ .settings = file, .jump = undefined, .fall = undefined, .crouch = undefined };
    inline for (.{ "jump", "fall", "crouch" }) |name| {
        const clip = @field(file, name);
        @field(actions, name) = validateMotion(clip, rig, detail) catch {
            const message = detail.message;
            return invalid(detail, "{s}.{s}", .{ name, message[0..detail.length] });
        };
        if (clip.loop or clip.reference_speed_mps != 0) return invalid(detail, "{s}: action clips must be non-looping with reference_speed_mps = 0", .{name});
        if (!std.mem.eql(u8, name, "crouch") and clip.contacts.len != 0) return invalid(detail, "{s}.contacts: airborne clips cannot plant feet", .{name});
    }
    if (std.mem.eql(u8, file.jump.id, file.fall.id) or std.mem.eql(u8, file.jump.id, file.crouch.id) or std.mem.eql(u8, file.fall.id, file.crouch.id)) return invalid(detail, "jump/fall/crouch.id: expected distinct clip IDs", .{});
    return actions;
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
    detail.file = data.characterLocomotionPath;
    try validateLocomotion(files.locomotion, rig, motion, detail);
    detail.file = data.characterActionsPath;
    const actions = try validateActions(files.actions, rig, detail);
    return .{ .arena = arena, .rig = rig, .motion = motion, .locomotion = files.locomotion, .actions = actions };
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
    var offsets: [4]vec.Vec2 = undefined;
    for (foot_joints, &offsets, 0..) |joint, *offset, index| {
        offset.* = rotate(rig.joints[@intFromEnum(joint)].rest_offset, controls[@intFromEnum(foot_angles[index / 2])]);
    }
    return solvePoseWithFeet(rig, controls, offsets);
}

fn solvePoseWithFeet(rig: Rig, controls: [controlCount]f32, offsets: [4]vec.Vec2) Pose {
    var pose: Pose = .{ .joints = @splat(vec.zero), .desired_targets = undefined, .clamped = undefined, .contact_intent = .{ false, false } };
    pose.joints[@intFromEnum(Joint.pelvis)] = .{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    const torso_rotation = -controls[@intFromEnum(Control.torso_angle)];
    for ([_]Joint{ .chest, .neck, .head, .left_shoulder, .right_shoulder }) |joint_id| {
        const joint = rig.joints[@intFromEnum(joint_id)];
        pose.joints[@intFromEnum(joint_id)] = vec.add(pose.joints[@intFromEnum(joint.parent.?)], rotate(joint.rest_offset, torso_rotation));
    }
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
    for (foot_joints, offsets) |joint_id, offset| {
        const joint = rig.joints[@intFromEnum(joint_id)];
        pose.joints[@intFromEnum(joint_id)] = vec.add(pose.joints[@intFromEnum(joint.parent.?)], offset);
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
        state.* = .{ .facing_right = state.facing_right };
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
        if (std.mem.eql(u8, arg, "--character-animation-reference")) playback = .run;
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
    state.* = .{ .facing_right = state.facing_right };
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

fn mirrorControls(rig: Rig, controls: [controlCount]f32) [controlCount]f32 {
    var result = controls;
    for (target_x ++ .{Control.pelvis_x}) |binding| result[@intFromEnum(binding)] = -result[@intFromEnum(binding)] - 2 * rig.root_from_body.x;
    for (foot_angles ++ .{Control.torso_angle}) |binding| result[@intFromEnum(binding)] *= -1;
    return result;
}

fn locomotionControls(set: *const Assets, state: *const PlayerState) [controlCount]f32 {
    const phase = clipPhase(set.motion, state.phase);
    const strength = state.run_weight * state.intensity;
    var controls: [controlCount]f32 = undefined;
    for (set.motion.tracks, set.rig.neutral, 0..) |track, neutral, index| {
        controls[index] = std.math.lerp(neutral, evaluateTrack(track, phase), strength);
    }
    // Horizontal travel follows stride length even at low speed. Bob, lift, lean
    // and arm swing have a separate intensity so a slow step still covers ground.
    for (toes, 0..) |toe, index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const angle = @intFromEnum(foot_angles[index]);
        const rest = set.rig.joints[@intFromEnum(toe)].rest_offset;
        const authored_offset = rotate(rest, evaluateTrack(set.motion.tracks[angle], phase));
        const neutral_offset = rotate(rest, set.rig.neutral[angle]);
        const offset = rotate(rest, controls[angle]);
        const toe_x = evaluateTrack(set.motion.tracks[x], phase) + authored_offset.x;
        const toe_y = evaluateTrack(set.motion.tracks[y], phase) + authored_offset.y;
        controls[x] = std.math.lerp(set.rig.neutral[x] + neutral_offset.x, toe_x * state.stride_scale, state.run_weight) - offset.x;
        controls[y] = std.math.lerp(set.rig.neutral[y] + neutral_offset.y, toe_y, strength) - offset.y;
    }
    return controls;
}

fn flatGroundAt(x: f32, floor_y: f32, profile: data.CharacterLocomotionData) ?f32 {
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_SENSOR;
    filter.maskBits = collision.MASK_SENSOR_FOOT;
    const tolerance = profile.flat_height_tolerance_m;
    const result = box2d.castRayClosest(.{ .x = x, .y = floor_y - tolerance * 2 }, .{ .x = 0, .y = tolerance * 4 }, filter);
    if (!result.hit or result.normal.y > -0.999 or @abs(result.point.y - floor_y) > tolerance) return null;
    if (box2d.c.b2Body_GetType(box2d.c.b2Shape_GetBody(result.shapeId)) != box2d.c.b2_staticBody) return null;
    return result.point.y;
}

fn turnedFootOffsets(rig: Rig, controls: [controlCount]f32, heading: f32, facing_right: bool) [4]vec.Vec2 {
    const sign: f32 = if (facing_right) 1 else -1;
    var offsets: [4]vec.Vec2 = undefined;
    for (foot_joints, &offsets, 0..) |joint, *offset, index| {
        const rest = rig.joints[@intFromEnum(joint)].rest_offset;
        var start = std.math.atan2(-rest.y, rest.x);
        if (start < 0) start += std.math.tau;
        var end = std.math.pi - start;
        if (end < start) end += std.math.tau;
        // Foot links turn continuously in world space. The heel takes the upper
        // arc around the toe; fixed lengths are retained throughout the turn.
        const angle = std.math.lerp(start, end, heading) - controls[@intFromEnum(foot_angles[index / 2])] * sign;
        const length = rig.lengths[@intFromEnum(joint)];
        offset.* = .{ .x = @cos(angle) * length * sign, .y = -@sin(angle) * length };
    }
    return offsets;
}

fn clearSoles(rig: Rig, controls: *[controlCount]f32, offsets: [4]vec.Vec2, floors: [4]?f32, body: vec.Vec2, facing_right: bool) void {
    for (0..2) |index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const toe_offset = offsets[index * 2];
        const heel_offset = vec.add(toe_offset, offsets[index * 2 + 1]);
        for ([_]vec.Vec2{ toe_offset, heel_offset }, floors[index * 2 ..][0..2]) |offset, floor| {
            if (floor == null) continue;
            const point = toWorld(rig, .{ .x = controls[x] + offset.x, .y = controls[y] + offset.y }, body, facing_right);
            controls[y] += @max(0, point.y - floor.?);
        }
    }
}

fn reachableFoot(rig: Rig, controls: [controlCount]f32, index: usize, ankle: vec.Vec2) bool {
    const limb = rig.limbs[index];
    const limits = reachLimits(rig.lengths[@intFromEnum(limb.middle)], rig.lengths[@intFromEnum(limb.end)], limb.min_bend_radians, limb.max_bend_radians);
    const pelvis = vec.Vec2{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    const distance = vec.magnitude(vec.subtract(ankle, pelvis));
    return distance >= limits[0] and distance <= limits[1] - 0.002;
}

fn updateAction(set: *const Assets, state: *PlayerState, input: LocomotionInput, dt: f32) bool {
    const settings = set.actions.settings;
    const previous = state.action;
    const airborne = previous == .jump or previous == .fall;
    const supported = input.supported and input.separation_speed_mps <= settings.takeoff_speed_mps;
    const impact_speed = @max(state.vertical_speed_mps, input.vertical_speed_mps);
    state.vertical_speed_mps = input.vertical_speed_mps;
    state.action_seconds += dt;
    if (!supported) {
        state.action = if (input.vertical_speed_mps < 0) .jump else .fall;
        state.landing_strength = 0;
    } else if (input.crouch_requested) {
        state.action = .crouch;
        state.landing_strength = 0;
    } else if (airborne) {
        state.landing_strength = std.math.clamp((impact_speed - settings.min_landing_speed_mps) / (settings.full_landing_speed_mps - settings.min_landing_speed_mps), 0, 1);
        state.action = if (state.landing_strength > 0) .land else .grounded;
    } else if (previous == .crouch or (previous == .land and state.action_seconds >= set.actions.crouch.cycle_seconds)) {
        state.action = .grounded;
        state.landing_strength = 0;
    }
    if (state.action == previous) return false;
    state.action_seconds = 0;
    // Airborne transitions discard stance state. Finishing a grounded landing
    // preserves the running/standing contacts that are already in progress.
    if (airborne or state.action == .jump or state.action == .fall) state.feet = .{ .{}, .{} };
    return true;
}

fn actionControls(set: *const Assets, state: *PlayerState) void {
    const moving = @abs(state.speed_mps) > set.locomotion.stop_speed_mps;
    const run_phase = clipPhase(set.motion, state.phase);
    for (&state.contact_intent, 0..) |*intent, index| intent.* = if (moving) contactIntent(set.motion, @enumFromInt(index), run_phase) else state.run_weight < 0.02;
    if (state.action == .grounded) return;
    const clip = switch (state.action) {
        .jump => set.actions.jump,
        .fall => set.actions.fall,
        .land, .crouch => set.actions.crouch,
        .grounded => unreachable,
    };
    const phase = if (state.action == .crouch) set.actions.settings.crouch_hold_phase else clipPhase(clip, state.action_seconds / clip.cycle_seconds);
    const compression = state.action == .land or state.action == .crouch;
    const strength = if (state.action == .land) state.landing_strength else 1;
    // Landing adds compression relative to the rig's neutral pose. Locomotion
    // continues underneath it, including foot trajectories and stance timing.
    for (&state.controls, clip.tracks, set.rig.neutral) |*control, track, neutral| {
        const value = evaluateTrack(track, phase);
        control.* = if (compression) control.* + (value - neutral) * strength else value;
    }
    if (compression and moving) return;
    state.contact_intent = .{ contactIntent(clip, .left_leg, phase), contactIntent(clip, .right_leg, phase) };
}

fn plantFeet(set: *const Assets, state: *PlayerState, input: LocomotionInput, dt: f32) void {
    const profile = set.locomotion;
    const sign: f32 = if (state.facing_right) 1 else -1;
    const moving = @abs(state.speed_mps) > profile.stop_speed_mps;
    const offsets = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
    state.sole_floors = @splat(null);
    for (&state.feet, 0..) |*foot, index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const toe_offset = offsets[index * 2];
        const toe_can_support = offsets[index * 2 + 1].y >= -0.000001;
        const desired = vec.Vec2{ .x = state.controls[x], .y = state.controls[y] };
        const desired_toe = toWorld(set.rig, vec.add(desired, toe_offset), input.body, state.facing_right);
        const intent = state.contact_intent[index];
        if (!intent or !moving) foot.blocked = false;
        const supported = input.ground_y != null and input.supported and state.action != .jump and state.action != .fall;
        if (foot.locked) {
            const correction = vec.subtract(foot.anchor, desired_toe);
            const ankle = vec.add(desired, .{ .x = correction.x * sign, .y = -correction.y });
            const anchor_floor = if (supported) flatGroundAt(foot.anchor.x, foot.anchor.y, profile) else null;
            const valid = supported and intent and toe_can_support and anchor_floor != null and
                @abs(anchor_floor.? - foot.anchor.y) <= 0.00001 and
                @abs(foot.anchor.y - input.ground_y.?) <= profile.flat_height_tolerance_m and
                vec.magnitude(correction) <= profile.max_anchor_error_m and
                reachableFoot(set.rig, state.controls, index, ankle);
            if (!valid) {
                foot.locked = false;
                foot.blocked = intent;
            } else {
                foot.correction = correction;
            }
        }
        const candidate_floor = if (!foot.locked and !foot.blocked and supported and intent and toe_can_support) flatGroundAt(desired_toe.x, input.ground_y.?, profile) else null;
        acquire: {
            if (candidate_floor == null) break :acquire;
            const anchor = vec.Vec2{ .x = desired_toe.x, .y = candidate_floor.? };
            const correction = vec.subtract(anchor, desired_toe);
            const ankle = vec.add(desired, .{ .x = correction.x * sign, .y = -correction.y });
            foot.locked = @abs(correction.y) <= profile.plant_distance_m and reachableFoot(set.rig, state.controls, index, ankle);
            if (!foot.locked) break :acquire;
            foot.anchor = anchor;
            foot.correction = correction;
        }
        if (!foot.locked) foot.correction = vec.mul(foot.correction, @exp(-dt / profile.release_seconds));
        state.controls[x] += foot.correction.x * sign;
        state.controls[y] -= foot.correction.y;
        // Blending an airborne foot toward rest must not drag its sole below a
        // real flat surface. Both ends are queried; ledges are not infinite planes.
        if (!supported) continue;
        const heel_offset = vec.add(toe_offset, offsets[index * 2 + 1]);
        for ([_]vec.Vec2{ toe_offset, heel_offset }, 0..) |offset, end| {
            const point = toWorld(set.rig, .{ .x = state.controls[x] + offset.x, .y = state.controls[y] + offset.y }, input.body, state.facing_right);
            state.sole_floors[index * 2 + end] = flatGroundAt(point.x, input.ground_y.?, profile);
        }
    }
    const before_clearance = state.controls;
    clearSoles(set.rig, &state.controls, offsets, state.sole_floors, input.body, state.facing_right);
    for (&state.feet, 0..) |*foot, index| {
        if (!foot.locked) continue;
        const y = @intFromEnum(target_y[index]);
        if (state.controls[y] - before_clearance[y] <= 0.00001) continue;
        foot.locked = false;
        foot.blocked = moving;
    }
}

// The fixed-step caller provides physical position and fresh grounding. Tests
// use this same entry point with a Box2D floor and repeatable movement samples.
pub fn updatePlayer(player_id: usize, input: LocomotionInput, dt: f64) void {
    if (assets == null) return; // Sprite fallback after an initial loading failure.
    const state = states.getPtr(player_id) orelse {
        std.log.warn("character_animation.updatePlayer: state missing for player {d}", .{player_id});
        return;
    };
    const set = &assets.?;
    const profile = set.locomotion;
    const step: f32 = @floatCast(dt);
    // Respawn/reload initializes from the current position. A discontinuous
    // relocation cannot carry a planted foot or count as a running stride.
    const initialize = !state.initialized or vec.magnitude(vec.subtract(input.body, state.body)) > 2;
    if (initialize) {
        state.* = .{ .facing_right = input.facing_right, .previous_facing_right = input.facing_right, .body = input.body, .initialized = true, .controls = set.rig.neutral, .previous_controls = set.rig.neutral };
        state.foot_heading = if (input.facing_right) 0 else 1;
    }
    state.previous_phase = state.phase;
    state.previous_controls = state.controls;
    state.previous_facing_right = state.facing_right;
    state.previous_feet = state.feet;
    state.previous_body = state.body;
    state.previous_foot_heading = state.foot_heading;
    state.previous_sole_floors = state.sole_floors;
    state.speed_mps = (input.body.x - state.body.x) / step;
    state.body = input.body;
    if (playback != .locomotion) {
        state.facing_right = input.facing_right;
        if (playback == .run) state.phase += dt / set.motion.cycle_seconds;
        return;
    }
    const speed = @abs(state.speed_mps);
    if (speed > profile.stop_speed_mps) state.facing_right = state.speed_mps > 0;
    const turning = state.facing_right != state.previous_facing_right;
    const action_changed = updateAction(set, state, input, step);
    const supported = state.action != .jump and state.action != .fall;
    state.foot_heading = std.math.lerp(state.foot_heading, if (state.facing_right) @as(f32, 0) else 1, 1 - @exp(-step / profile.turn_seconds));
    const target_weight: f32 = if (supported and speed > profile.stop_speed_mps) 1 else 0;
    const response = if (target_weight > state.run_weight) profile.start_seconds else profile.stop_seconds;
    state.run_weight = std.math.lerp(state.run_weight, target_weight, 1 - @exp(-step / response));
    const target_intensity = std.math.clamp(speed / profile.full_run_speed_mps, 0, 1);
    state.intensity = std.math.lerp(state.intensity, target_intensity, 1 - @exp(-step / response));
    const stride = if (target_weight == 0) 1 else std.math.clamp(@sqrt(speed / set.motion.reference_speed_mps), profile.stride_min, profile.stride_max);
    state.stride_scale = std.math.lerp(state.stride_scale, stride, 1 - @exp(-step / response));
    if (supported and speed > profile.stop_speed_mps) {
        state.phase += speed * dt / (set.motion.reference_speed_mps * set.motion.cycle_seconds * state.stride_scale);
    }
    state.controls = locomotionControls(set, state);
    actionControls(set, state);
    if (!initialize and (turning or action_changed)) {
        const previous = if (turning) mirrorControls(set.rig, state.previous_controls) else state.previous_controls;
        for (&state.transition_offsets, previous, state.controls) |*offset, before, after| offset.* = before - after;
        state.transition_seconds = if (turning) profile.turn_seconds else set.actions.settings.blend_seconds;
        // Existing valid contacts survive a turn. Their corrections are already
        // included in the mirrored controls; plantFeet recomputes them once.
        for (&state.feet) |*foot| foot.correction = vec.zero;
    }
    for (&state.controls, &state.transition_offsets) |*control, *offset| {
        control.* += offset.*;
        offset.* *= @exp(-step / state.transition_seconds);
    }
    plantFeet(set, state, input, step);
    if (initialize) {
        state.previous_controls = state.controls;
        state.previous_feet = state.feet;
        state.previous_sole_floors = state.sole_floors;
    }
}

pub fn interpolatedPose(set: *const Assets, state: PlayerState, alpha: f64) Pose {
    if (!state.initialized) return solvePose(set.rig, set.rig.neutral);
    const previous = if (state.previous_facing_right == state.facing_right) state.previous_controls else mirrorControls(set.rig, state.previous_controls);
    var controls: [controlCount]f32 = undefined;
    for (&controls, previous, state.controls) |*control, a, b| control.* = std.math.lerp(a, b, @as(f32, @floatCast(alpha)));
    const fraction: f32 = @floatCast(alpha);
    const body = vec.add(state.previous_body, vec.mul(vec.subtract(state.body, state.previous_body), fraction));
    const sign: f32 = if (state.facing_right) 1 else -1;
    const offsets = turnedFootOffsets(set.rig, controls, std.math.lerp(state.previous_foot_heading, state.foot_heading, fraction), state.facing_right);
    for (state.previous_feet, state.feet, 0..) |before, foot, index| {
        if (!before.locked or !foot.locked or !std.meta.eql(before.anchor, foot.anchor)) continue;
        const offset = offsets[index * 2];
        controls[@intFromEnum(target_x[index])] = (foot.anchor.x - body.x) * sign - set.rig.root_from_body.x - offset.x;
        controls[@intFromEnum(target_y[index])] = body.y - set.rig.root_from_body.y - foot.anchor.y - offset.y;
    }
    var floors: [4]?f32 = @splat(null);
    for (&floors, state.previous_sole_floors, state.sole_floors) |*floor, before, after| {
        if (before == null or after == null) continue;
        if (@abs(before.? - after.?) > set.locomotion.flat_height_tolerance_m) continue;
        floor.* = std.math.lerp(before.?, after.?, fraction);
    }
    clearSoles(set.rig, &controls, offsets, floors, body, state.facing_right);
    var pose = solvePoseWithFeet(set.rig, controls, offsets);
    pose.contact_intent = state.contact_intent;
    return pose;
}

pub fn fixedUpdate(dt: f64) void {
    if (assets == null) return; // Initial asset failure leaves sprite gameplay available.
    for (states.keys()) |player_id| {
        const p = player.players.get(player_id) orelse {
            std.log.warn("character_animation.fixedUpdate: player {d} is missing", .{player_id});
            continue;
        };
        if (p.isDead) continue;
        const movement_state = movement.states.get(player_id) orelse {
            std.log.warn("character_animation.fixedUpdate: movement state missing for player {d}", .{player_id});
            continue;
        };
        const input_state = player_input.playerInputs.get(player_id) orelse {
            std.log.warn("character_animation.fixedUpdate: input state missing for player {d}", .{player_id});
            continue;
        };
        var ground_y: ?f32 = null;
        const contact = movement_state.groundState.groundContact;
        if (contact != null and contact.?.normal.y < -0.999 and box2d.c.b2Body_GetType(contact.?.bodyId) == box2d.c.b2_staticBody) ground_y = contact.?.worldPoint.y;
        const velocity = box2d.c.b2Body_GetLinearVelocity(p.bodyId);
        // A rising platform should not look like a jump away from its support.
        const support_velocity = if (contact == null or !movement_state.groundState.supported) vec.zero else vec.fromBox2d(box2d.c.b2Body_GetWorldPointVelocity(contact.?.bodyId, vec.toBox2d(contact.?.worldPoint)));
        const relative_velocity = vec.subtract(vec.fromBox2d(velocity), support_velocity);
        updatePlayer(player_id, .{
            .body = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId)),
            .supported = movement_state.groundState.supported,
            .ground_y = ground_y,
            .facing_right = movement_state.facingRight,
            .vertical_speed_mps = relative_velocity.y,
            .separation_speed_mps = if (contact == null) 0 else vec.dot(relative_velocity, contact.?.normal),
            .crouch_requested = input_state.movementDirection.y < 0,
        }, dt);
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
            playback = switch (playback) {
                .locomotion => .neutral,
                .neutral => .run,
                .run => .locomotion,
            };
            for (states.values()) |*state| {
                state.* = .{ .facing_right = state.facing_right };
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
        const pose = if (playback == .locomotion) interpolatedPose(set, state, time.alpha) else evaluatePose(set, phase, playback);
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
        if (playback != .locomotion) continue;
        try gpu.setRenderDrawColor(.{ .r = 70, .g = 255, .b = 120, .a = 255 });
        for (state.feet) |foot| {
            if (!foot.locked) continue;
            try drawRing(toScreen(foot.anchor), width * 3, width * 0.6);
        }
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
    if (show_diagnostics and playback == .locomotion) {
        const cam = camera.cameras.get(camera.activeCameraId) orelse {
            std.log.warn("character_animation.drawStatus: active camera {d} is missing", .{camera.activeCameraId});
            return;
        };
        const state = states.get(cam.playerId) orelse return; // The startup camera can precede player creation.
        const motion_status = try std.fmt.bufPrintZ(&buffer, "{s}  x {d:.1} y {d:.1} m/s  run {d:.2}  stride {d:.2}  feet {s}/{s}", .{ @tagName(state.action), state.speed_mps, state.vertical_speed_mps, state.run_weight, state.stride_scale, if (state.feet[0].locked) "planted" else "free", if (state.feet[1].locked) "planted" else "free" });
        try text.write(.small, motion_status, .{ .x = 12, .y = height - 122 });
    }
    if (!reload_failed) return;
    try text.write(.small, "RIG RELOAD FAILED - see log", .{ .x = 12, .y = height - 92 });
}
