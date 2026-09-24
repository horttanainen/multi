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
pub const Action = enum { grounded, jump, fall, land, kneel };
pub const WallAction = enum { none, brace, push, slide, jump };
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
pub const Attachment = struct { id: []const u8, joint: Joint, local_offset: vec.Vec2, angle_offset_radians: f32 = 0 };
pub const AttachmentTransform = struct { position: vec.Vec2, angle: f32 };
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
pub const Actions = struct { settings: data.CharacterActionsData, jump: Motion, fall: Motion, landing: Motion, kneel: Motion };
pub const WallActions = struct { settings: data.CharacterWallsData, brace: Motion, push: Motion, slide: Motion, jump: Motion };
pub const Assets = struct { arena: std.heap.ArenaAllocator, rig: Rig, motion: Motion, locomotion: data.CharacterLocomotionData, actions: Actions, aiming: data.CharacterAimingData, walls: WallActions };
pub const Diagnostic = data.CharacterAssetDiagnostic;
pub const FootState = struct {
    locked: bool = false,
    blocked: bool = false,
    anchor: vec.Vec2 = vec.zero,
    correction: vec.Vec2 = vec.zero,
    terrain_y: f32 = 0,
    terrain_angle: f32 = 0,
};
// A finite, static polygon face in world coordinates. Render interpolation can
// evaluate its slope without querying physics or extending it across a ledge.
pub const GroundSurface = struct {
    point: vec.Vec2,
    normal: vec.Vec2,
    minimum_x: f32,
    maximum_x: f32,
};
pub const WallState = struct {
    action: WallAction = .none,
    side: i8 = 0,
    seconds: f32 = 0,
    contact_seconds: f32 = 0,
    impact: f32 = 0,
    weight: f32 = 0,
    hands: [2]?vec.Vec2 = .{ null, null },
    // Toe targets slide with the body, then stay in world space for push-off.
    feet: [2]?vec.Vec2 = .{ null, null },
    feet_planted: [2]bool = .{ false, false },
    // Surface limits remain available while a transitioning foot is unplanted.
    foot_surfaces: [2]?f32 = .{ null, null },
};
pub const LocomotionInput = struct {
    body: vec.Vec2,
    supported: bool,
    // Static support height centers the bounded cosmetic terrain probes.
    ground_y: ?f32,
    ground_normal: vec.Vec2 = .{ .x = 0, .y = -1 },
    facing_right: bool,
    // Box2D convention: positive is downward; relative to support when present.
    vertical_speed_mps: f32,
    // Positive along the support normal means moving away from the surface.
    separation_speed_mps: f32,
    kneel_requested: bool = false,
    aiming: bool = false,
    aim_direction: vec.Vec2 = vec.east,
    horizontal_speed_mps: f32 = 0,
    movement_direction: f32 = 0,
    wall_sliding: bool = false,
    wall_jump_direction: i8 = 0,
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
    sole_surfaces: [4]?GroundSurface = @splat(null),
    previous_sole_surfaces: [4]?GroundSurface = @splat(null),
    knee_surfaces: [2]?GroundSurface = @splat(null),
    previous_knee_surfaces: [2]?GroundSurface = @splat(null),
    pelvis_reference_y: f32 = 0,
    previous_pelvis_reference_y: f32 = 0,
    previous_controls: [controlCount]f32 = @splat(0),
    controls: [controlCount]f32 = @splat(0),
    previous_facing_right: bool = false,
    transition_offsets: [controlCount]f32 = @splat(0),
    transition_seconds: f32 = 0.14,
    aim_weight: f32 = 0,
    previous_aim_weight: f32 = 0,
    aim_direction: vec.Vec2 = vec.east,
    shot_hold_seconds: f32 = 0,
    weapon_angle: ?f32 = null,
    previous_weapon_angle: ?f32 = null,
    wall: WallState = .{},
    previous_wall: WallState = .{},
    stow_weight: f32 = 0,
    previous_stow_weight: f32 = 0,
    limb_release_angles: [limbCount][2]f32 = @splat(.{ 0, 0 }),
    limb_release_active: [limbCount]bool = @splat(false),
    limb_release_seconds: f32 = 1,
    previous_limb_release_seconds: f32 = 1,
    limb_release_facing_right: bool = false,
};
pub const Sampling = enum { render, physics };
pub const FramePose = struct {
    pose: Pose,
    body: vec.Vec2,
    facing_right: bool,
    weapon: AttachmentTransform,
    weapon_facing_right: bool,
    weapon_stowed: bool = false,
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
        if (@abs(attachment.angle_offset_radians) > std.math.pi) return invalid(detail, "attachments.{s}.angle_offset_radians: expected -pi..pi", .{attachment.id});
        const entry = try rig.attachments.getOrPut(memory, attachment.id);
        if (entry.found_existing) return invalid(detail, "attachments.{s}: duplicate id", .{attachment.id});
        entry.value_ptr.* = attachment;
    }
    const weapon_attachment = rig.attachments.get("weapon_hand") orelse return invalid(detail, "attachments.weapon_hand: required hand attachment is missing", .{});
    if (weapon_attachment.joint != .left_hand and weapon_attachment.joint != .right_hand) return invalid(detail, "attachments.weapon_hand.joint: expected left_hand or right_hand", .{});
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
    if (file.schema_version != 2) return invalid(detail, "schema_version: expected 2", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (!std.mem.eql(u8, file.rig_id, rig.id)) return invalid(detail, "rig_id: does not match loaded rig", .{});
    if (!std.mem.eql(u8, file.motion_id, motion.id)) return invalid(detail, "motion_id: does not match loaded motion", .{});
    if (!motion.loop or motion.reference_speed_mps <= 0) return invalid(detail, "motion_id: locomotion requires a looping clip with positive reference speed", .{});
    if (file.stop_speed_mps < 0.001 or file.full_run_speed_mps <= file.stop_speed_mps or file.full_run_speed_mps > 100) return invalid(detail, "full_run_speed_mps: expected stop_speed_mps >= 0.001 < full_run_speed_mps <= 100", .{});
    if (file.stride_min < 0.1 or file.stride_max < file.stride_min or file.stride_max > 2) return invalid(detail, "stride_min/stride_max: expected 0.1 <= min <= max <= 2", .{});
    inline for (.{ "start_seconds", "stop_seconds", "turn_seconds", "release_seconds" }) |field| {
        if (@field(file, field) < 0.01 or @field(file, field) > 2) return invalid(detail, "{s}: expected 0.01..2 seconds", .{field});
    }
    inline for (.{ "plant_distance_m", "max_anchor_error_m", "surface_tolerance_m" }) |field| {
        if (@field(file, field) < 0.001 or @field(file, field) > 0.5) return invalid(detail, "{s}: expected 0.001..0.5 meters", .{field});
    }
    inline for (.{ "probe_up_m", "probe_down_m" }) |field| {
        if (@field(file.terrain, field) < 0.001 or @field(file.terrain, field) > 1) return invalid(detail, "terrain.{s}: expected 0.001..1 meters", .{field});
    }
    inline for (.{ "pelvis_limit_m", "lookahead_m" }) |field| {
        if (@field(file.terrain, field) < 0.001 or @field(file.terrain, field) > 0.5) return invalid(detail, "terrain.{s}: expected 0.001..0.5 meters", .{field});
    }
    if (file.terrain.max_slope_radians < 0 or file.terrain.max_slope_radians > std.math.pi / 3.0) return invalid(detail, "terrain.max_slope_radians: expected 0..pi/3", .{});
    if (file.terrain.blend_seconds < 0.01 or file.terrain.blend_seconds > 0.5) return invalid(detail, "terrain.blend_seconds: expected 0.01..0.5 seconds", .{});
    if (file.terrain.swing_clearance_m < 0 or file.terrain.swing_clearance_m > 0.15) return invalid(detail, "terrain.swing_clearance_m: expected 0..0.15 meters", .{});
}

fn validateActions(file: data.CharacterActionsData, rig: Rig, detail: *Diagnostic) !Actions {
    if (file.schema_version != 2) return invalid(detail, "schema_version: expected 2", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (file.blend_seconds < 0.01 or file.blend_seconds > 0.5) return invalid(detail, "blend_seconds: expected 0.01..0.5 seconds", .{});
    if (file.takeoff_speed_mps < 0.01 or file.takeoff_speed_mps > 2) return invalid(detail, "takeoff_speed_mps: expected 0.01..2", .{});
    if (file.min_landing_speed_mps < 0 or file.full_landing_speed_mps <= file.min_landing_speed_mps or file.full_landing_speed_mps > 100) return invalid(detail, "full_landing_speed_mps: expected 0 <= min_landing_speed_mps < full_landing_speed_mps <= 100", .{});
    var actions: Actions = .{ .settings = file, .jump = undefined, .fall = undefined, .landing = undefined, .kneel = undefined };
    inline for (.{ "jump", "fall", "landing", "kneel" }) |name| {
        const clip = @field(file, name);
        @field(actions, name) = validateMotion(clip, rig, detail) catch {
            const message = detail.message;
            return invalid(detail, "{s}.{s}", .{ name, message[0..detail.length] });
        };
        if (clip.loop or clip.reference_speed_mps != 0) return invalid(detail, "{s}: action clips must be non-looping with reference_speed_mps = 0", .{name});
        const airborne = std.mem.eql(u8, name, "jump") or std.mem.eql(u8, name, "fall");
        if (airborne and clip.contacts.len != 0) return invalid(detail, "{s}.contacts: airborne clips cannot plant feet", .{name});
    }
    const clips = [_]Motion{ actions.jump, actions.fall, actions.landing, actions.kneel };
    for (clips, 0..) |clip, index| {
        for (clips[0..index]) |previous| {
            if (std.mem.eql(u8, clip.id, previous.id)) return invalid(detail, "jump/fall/landing/kneel.id: expected distinct clip IDs", .{});
        }
    }
    return actions;
}

fn validateAiming(file: data.CharacterAimingData, rig: Rig, detail: *Diagnostic) !void {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (!std.mem.eql(u8, file.rig_id, rig.id)) return invalid(detail, "rig_id: does not match loaded rig", .{});
    const attachment = rig.attachments.get("weapon_hand").?;
    const limb = rig.limbs[@intFromEnum(if (attachment.joint == .right_hand) Limb.right_arm else Limb.left_arm)];
    const limits = reachLimits(rig.lengths[@intFromEnum(limb.middle)], rig.lengths[@intFromEnum(limb.end)], limb.min_bend_radians, limb.max_bend_radians);
    if (file.hand_distance_m <= limits[0] or file.hand_distance_m >= limits[1]) return invalid(detail, "hand_distance_m: must be inside the weapon arm's reachable range", .{});
    inline for (.{ "raise_seconds", "lower_seconds" }) |field| {
        if (@field(file, field) < 0.01 or @field(file, field) > 1) return invalid(detail, "{s}: expected 0.01..1 seconds", .{field});
    }
    if (file.shot_hold_seconds < 0 or file.shot_hold_seconds > 0.5) return invalid(detail, "shot_hold_seconds: expected 0..0.5 seconds", .{});
}

fn validateWalls(file: data.CharacterWallsData, rig: Rig, detail: *Diagnostic) !WallActions {
    if (file.schema_version != 1) return invalid(detail, "schema_version: expected 1", .{});
    if (file.id.len == 0 or file.id.len > 64) return invalid(detail, "id: expected 1..64 bytes", .{});
    if (!std.mem.eql(u8, file.rig_id, rig.id)) return invalid(detail, "rig_id: does not match loaded rig", .{});
    const holster = rig.attachments.get("weapon_holster") orelse return invalid(detail, "rig.attachments.weapon_holster: required for two-hand wall poses", .{});
    if (holster.joint != .pelvis) return invalid(detail, "rig.attachments.weapon_holster.joint: expected pelvis", .{});
    inline for (.{ "anticipation_seconds", "blend_seconds", "push_delay_seconds" }) |name| {
        if (@field(file, name) < 0.01 or @field(file, name) > 0.5) return invalid(detail, "{s}: expected 0.01..0.5 seconds", .{name});
    }
    if (file.contact_distance_m < 0.1 or file.contact_distance_m > 0.5 or file.probe_distance_m <= file.contact_distance_m or file.probe_distance_m > 1) return invalid(detail, "probe_distance_m: must exceed contact_distance_m (0.1..0.5), up to 1 meter", .{});
    if (file.full_impact_speed_mps < 1 or file.full_impact_speed_mps > 100) return invalid(detail, "full_impact_speed_mps: expected 1..100", .{});
    if (file.impact_compression_m < 0 or file.impact_compression_m > 0.2) return invalid(detail, "impact_compression_m: expected 0..0.2 meters", .{});
    var walls: WallActions = .{ .settings = file, .brace = undefined, .push = undefined, .slide = undefined, .jump = undefined };
    const names = [_][]const u8{ "brace", "push", "slide", "jump" };
    inline for (names, 0..) |name, index| {
        const clip = @field(file, name);
        @field(walls, name) = validateMotion(clip, rig, detail) catch {
            const message = detail.message;
            return invalid(detail, "{s}.{s}", .{ name, message[0..detail.length] });
        };
        if (clip.loop or clip.reference_speed_mps != 0) return invalid(detail, "{s}: expected a non-looping action with reference_speed_mps = 0", .{name});
        if (std.mem.eql(u8, name, "brace") and clip.contacts.len != 0) return invalid(detail, "brace.contacts: the approaching stride owns foot contacts", .{});
        if (std.mem.eql(u8, name, "jump")) {
            for (clip.contacts) |contact| {
                if (contact.start != 0) return invalid(detail, "jump.contacts.start: push-off contacts must begin at launch", .{});
            }
        }
        inline for (names[0..index]) |previous| {
            if (std.mem.eql(u8, clip.id, @field(file, previous).id)) return invalid(detail, "{s}.id: wall clips need distinct IDs", .{name});
        }
    }
    return walls;
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
    detail.file = data.characterAimingPath;
    try validateAiming(files.aiming, rig, detail);
    detail.file = data.characterWallsPath;
    const walls = try validateWalls(files.walls, rig, detail);
    return .{ .arena = arena, .rig = rig, .motion = motion, .locomotion = files.locomotion, .actions = actions, .aiming = files.aiming, .walls = walls };
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
        // Non-looping actions hold their final pose, including contacts that
        // extend to that endpoint. Looping intervals remain half-open.
        const held_end = !motion.loop and phase == 1 and interval.end == 1;
        if (interval.limb == limb and phase >= interval.start and (phase < interval.end or held_end)) return true;
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
    const transform = attachmentTransform(rig, pose, name) orelse return null;
    return transform.position;
}

pub fn attachmentTransform(rig: Rig, pose: Pose, name: []const u8) ?AttachmentTransform {
    const attachment = rig.attachments.get(name) orelse {
        std.log.warn("character_animation.attachmentTransform: attachment '{s}' is missing", .{name});
        return null;
    };
    const index = @intFromEnum(attachment.joint);
    const parent = rig.joints[index].parent;
    if (parent == null) return .{ .position = vec.add(pose.joints[index], attachment.local_offset), .angle = attachment.angle_offset_radians };
    const direction = vec.subtract(pose.joints[index], pose.joints[@intFromEnum(parent.?)]);
    const angle = std.math.atan2(direction.y, direction.x);
    return .{ .position = vec.add(pose.joints[index], rotate(attachment.local_offset, angle)), .angle = angle + attachment.angle_offset_radians };
}

// World is Y-down; a left-facing sprite is also mirrored horizontally at draw time.
pub fn attachmentToWorld(rig: Rig, transform: AttachmentTransform, body: vec.Vec2, facing_right: bool) AttachmentTransform {
    return .{
        .position = toWorld(rig, transform.position, body, facing_right),
        .angle = if (facing_right) -transform.angle else transform.angle,
    };
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

fn groundAt(x: f32, input: LocomotionInput, profile: data.CharacterLocomotionData) ?GroundSurface {
    if (input.ground_y == null or -input.ground_normal.y < @cos(profile.terrain.max_slope_radians)) return null;
    // Center on the controller's support plane at this X, so a downhill heel
    // gets the same step budget as an uphill toe, regardless of stride width.
    const floor_y = input.ground_y.? - (x - input.body.x) * input.ground_normal.x / input.ground_normal.y;
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_SENSOR;
    filter.maskBits = collision.MASK_SENSOR_FOOT;
    const settings = profile.terrain;
    const result = box2d.castRayClosest(.{ .x = x, .y = floor_y - settings.probe_up_m }, .{ .x = 0, .y = settings.probe_up_m + settings.probe_down_m }, filter);
    if (!result.hit or -result.normal.y < @cos(settings.max_slope_radians)) return null;
    const body = box2d.c.b2Shape_GetBody(result.shapeId);
    if (box2d.c.b2Body_GetType(body) != box2d.c.b2_staticBody or box2d.c.b2Shape_GetType(result.shapeId) != box2d.c.b2_polygonShape) return null;
    const polygon = box2d.c.b2Shape_GetPolygon(result.shapeId);
    const count: usize = @intCast(polygon.count);
    for (0..count) |index| {
        const a = vec.fromBox2d(box2d.c.b2Body_GetWorldPoint(body, polygon.vertices[index]));
        const b = vec.fromBox2d(box2d.c.b2Body_GetWorldPoint(body, polygon.vertices[(index + 1) % count]));
        const edge = vec.subtract(b, a);
        const normal = vec.normalize(.{ .x = edge.y, .y = -edge.x });
        if (vec.dot(normal, vec.fromBox2d(result.normal)) < 0.9999) continue;
        return .{ .point = vec.fromBox2d(result.point), .normal = normal, .minimum_x = @min(a.x, b.x), .maximum_x = @max(a.x, b.x) };
    }
    // Rounded polygon corners do not provide a planar foothold.
    return null;
}

fn surfaceHeight(surface: ?GroundSurface, x: f32) ?f32 {
    if (surface == null) return null;
    const face = surface.?;
    if (x < face.minimum_x - 0.00001 or x > face.maximum_x + 0.00001) return null;
    return face.point.y - (x - face.point.x) * face.normal.x / face.normal.y;
}

fn interpolatedSurface(before: ?GroundSurface, after: ?GroundSurface, x: f32) ?GroundSurface {
    if (after == null) return null; // Fresh probes released or lost this surface.
    const current_y = surfaceHeight(after, x);
    const previous_y = surfaceHeight(before, x);
    if (current_y == null) return if (previous_y == null) null else before;
    if (previous_y == null or current_y.? <= previous_y.?) return after;
    return before;
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

fn clearSoles(rig: Rig, controls: *[controlCount]f32, offsets: [4]vec.Vec2, surfaces: [4]?GroundSurface, body: vec.Vec2, facing_right: bool) void {
    for (0..2) |index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const toe_offset = offsets[index * 2];
        const heel_offset = vec.add(toe_offset, offsets[index * 2 + 1]);
        for ([_]vec.Vec2{ toe_offset, heel_offset }, surfaces[index * 2 ..][0..2]) |offset, surface| {
            const point = toWorld(rig, .{ .x = controls[x] + offset.x, .y = controls[y] + offset.y }, body, facing_right);
            const floor = surfaceHeight(surface, point.x) orelse continue;
            controls[y] += @max(0, point.y - floor);
        }
    }
}

fn kneesClearGround(rig: Rig, controls: [controlCount]f32, surfaces: [2]?GroundSurface, body: vec.Vec2, facing_right: bool) bool {
    const pelvis = vec.Vec2{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    for (rig.limbs[0..2], surfaces, 0..) |limb, surface, index| {
        if (surface == null) continue;
        const upper = rig.lengths[@intFromEnum(limb.middle)];
        const lower = rig.lengths[@intFromEnum(limb.end)];
        const ankle = vec.Vec2{ .x = controls[@intFromEnum(target_x[index])], .y = controls[@intFromEnum(target_y[index])] };
        const solution = solveLimb(pelvis, ankle, upper, lower, limb.bend_sign, reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians));
        const knee = toWorld(rig, solution.middle, body, facing_right);
        const floor = surfaceHeight(surface, knee.x) orelse continue;
        const minimum_y = body.y - rig.root_from_body.y - floor + rig.line_width / 2;
        if (solution.middle.y < minimum_y) return false;
    }
    return true;
}

fn clearKnees(rig: Rig, controls: *[controlCount]f32, surfaces: [2]?GroundSurface, body: vec.Vec2, facing_right: bool) void {
    if (kneesClearGround(rig, controls.*, surfaces, body, facing_right)) return;
    // A low hip can send a turning knee below the floor even when both soles
    // are clear. Lift the pelvis just enough, then solve the same ankle targets
    // again: planted feet and both leg lengths remain intact.
    const y = @intFromEnum(Control.pelvis_y);
    var low = controls[y];
    var high = low;
    for (rig.limbs[0..2], surfaces) |limb, surface| {
        if (surface == null) continue;
        const face = surface.?;
        const upper = rig.lengths[@intFromEnum(limb.middle)];
        const root_x = toWorld(rig, .{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = 0 }, body, facing_right).x;
        const high_x = std.math.clamp(root_x - std.math.sign(face.normal.x) * upper, face.minimum_x, face.maximum_x);
        const floor = surfaceHeight(face, high_x).?;
        high = @max(high, body.y - rig.root_from_body.y - floor + rig.line_width / 2 + upper);
    }
    for (0..12) |_| {
        controls[y] = (low + high) / 2;
        if (kneesClearGround(rig, controls.*, surfaces, body, facing_right)) {
            high = controls[y];
        } else {
            low = controls[y];
        }
    }
    controls[y] = high;
}

fn reachableFoot(rig: Rig, controls: [controlCount]f32, index: usize, ankle: vec.Vec2) bool {
    const limb = rig.limbs[index];
    const limits = reachLimits(rig.lengths[@intFromEnum(limb.middle)], rig.lengths[@intFromEnum(limb.end)], limb.min_bend_radians, limb.max_bend_radians);
    const pelvis = vec.Vec2{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    const distance = vec.magnitude(vec.subtract(ankle, pelvis));
    return distance >= limits[0] and distance <= limits[1] - 0.002;
}

fn unevenGround(surfaces: [4]?GroundSurface, tolerance: f32) bool {
    var flat_height: ?f32 = null;
    var uneven = false;
    for (surfaces) |surface| {
        if (surface == null) continue;
        if (flat_height == null) flat_height = surface.?.point.y;
        uneven = uneven or @abs(surface.?.normal.x) > 0.00001 or @abs(surface.?.point.y - flat_height.?) > tolerance;
    }
    return uneven;
}

fn fitGroundedPelvis(set: *const Assets, controls: *[controlCount]f32, surfaces: [4]?GroundSurface, reference_y: f32) void {
    if (!unevenGround(surfaces, set.locomotion.surface_tolerance_m)) return;
    var maximum_y = reference_y + set.locomotion.terrain.pelvis_limit_m;
    for (set.rig.limbs[0..2], 0..) |limb, index| {
        if (surfaces[index * 2] == null and surfaces[index * 2 + 1] == null) continue;
        const upper = set.rig.lengths[@intFromEnum(limb.middle)];
        const lower = set.rig.lengths[@intFromEnum(limb.end)];
        const reach: f32 = @floatCast(reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians)[1] - 0.002);
        const dx = controls[@intFromEnum(target_x[index])] - controls[@intFromEnum(Control.pelvis_x)];
        const height = @sqrt(@max(0, reach * reach - dx * dx));
        maximum_y = @min(maximum_y, controls[@intFromEnum(target_y[index])] + height);
    }
    const minimum_y = reference_y - set.locomotion.terrain.pelvis_limit_m;
    controls[@intFromEnum(Control.pelvis_y)] = @max(minimum_y, @min(controls[@intFromEnum(Control.pelvis_y)], maximum_y));
}

fn constrainGroundFeet(set: *const Assets, controls: *[controlCount]f32, offsets: [4]vec.Vec2, surfaces: [4]?GroundSurface, body: vec.Vec2, facing_right: bool) void {
    if (!unevenGround(surfaces, set.locomotion.surface_tolerance_m)) return;
    // If bounded hip motion exhausts a leg's reach, reposition the free foot.
    // Alternate the existing reach and sole constraints so an IK clamp cannot
    // move a previously cleared ankle back through a sloping surface.
    const pelvis = vec.Vec2{ .x = controls[@intFromEnum(Control.pelvis_x)], .y = controls[@intFromEnum(Control.pelvis_y)] };
    for (0..12) |_| {
        clearSoles(set.rig, controls, offsets, surfaces, body, facing_right);
        var clamped = false;
        for (set.rig.limbs[0..2], 0..) |limb, index| {
            const x = @intFromEnum(target_x[index]);
            const y = @intFromEnum(target_y[index]);
            const upper = set.rig.lengths[@intFromEnum(limb.middle)];
            const lower = set.rig.lengths[@intFromEnum(limb.end)];
            const solution = solveLimb(pelvis, .{ .x = controls[x], .y = controls[y] }, upper, lower, limb.bend_sign, reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians));
            if (!solution.clamped) continue;
            clamped = true;
            controls[x] = solution.end.x;
            controls[y] = solution.end.y;
        }
        if (!clamped) return;
    }
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
    } else if (airborne) {
        state.landing_strength = std.math.clamp((impact_speed - settings.min_landing_speed_mps) / (settings.full_landing_speed_mps - settings.min_landing_speed_mps), 0, 1);
        state.action = if (state.landing_strength > 0) .land else .grounded;
    } else if (previous != .land or state.action_seconds >= set.actions.landing.cycle_seconds) {
        const stationary = @abs(state.speed_mps) <= set.locomotion.stop_speed_mps and
            @abs(input.horizontal_speed_mps) <= set.locomotion.stop_speed_mps and input.movement_direction == 0;
        state.action = if (input.kneel_requested and stationary and state.wall.action == .none) .kneel else .grounded;
        state.landing_strength = 0;
    }
    if (state.action == previous) return false;
    state.action_seconds = 0;
    // Airborne transitions discard stance state. Finishing a grounded landing
    // preserves the running/standing contacts that are already in progress.
    if (airborne or state.action == .jump or state.action == .fall or previous == .kneel or state.action == .kneel) state.feet = .{ .{}, .{} };
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
        .land => set.actions.landing,
        .kneel => set.actions.kneel,
        .grounded => unreachable,
    };
    const phase = clipPhase(clip, state.action_seconds / clip.cycle_seconds);
    const compression = state.action == .land;
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

// Cosmetic contacts share the physics query/filter owner. Only static upright
// faces are supported here; moving supports belong to the later terrain phase.
fn wallPoint(origin: vec.Vec2, side: i8, distance: f32) ?vec.Vec2 {
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.CATEGORY_SENSOR;
    filter.maskBits = collision.MASK_SENSOR_WALL;
    const sign: f32 = @floatFromInt(side);
    const hit = box2d.castRayClosest(vec.toBox2d(origin), .{ .x = sign * distance, .y = 0 }, filter);
    if (!hit.hit or hit.normal.x * sign > -0.999) return null;
    if (box2d.c.b2Body_GetType(box2d.c.b2Shape_GetBody(hit.shapeId)) != box2d.c.b2_staticBody) return null;
    return vec.fromBox2d(hit.point);
}

fn updateWall(set: *const Assets, state: *PlayerState, input: LocomotionInput, previous_speed: f32, dt: f32) bool {
    const before = state.wall;
    const settings = set.walls.settings;
    state.wall.hands = .{ null, null };
    state.wall.seconds += dt;
    select: {
        if (input.wall_jump_direction != 0) {
            state.wall = .{ .action = .jump, .side = -input.wall_jump_direction, .weight = 1, .feet = if (before.side == -input.wall_jump_direction) before.feet else .{ null, null } };
            break :select;
        }
        if (before.action == .jump and state.wall.seconds < set.walls.jump.cycle_seconds and !input.supported) break :select;
        state.wall.action = .none;
        // Aiming can keep the free hand on an already reached wall even though
        // grounded aim consumes locomotion input. It cannot start a new push.
        const holding_contact = input.aiming and before.side != 0 and before.action != .jump;
        if (input.movement_direction == 0 and !holding_contact) break :select;
        const side: i8 = if (input.movement_direction == 0) before.side else if (input.movement_direction > 0) 1 else -1;
        const sign: f32 = @floatFromInt(side);
        const speed = @max(0, @max(input.horizontal_speed_mps * sign, previous_speed * sign));
        const distance = @min(settings.probe_distance_m, settings.contact_distance_m + speed * settings.anticipation_seconds);
        const origin: vec.Vec2 = .{ .x = input.body.x, .y = input.body.y - set.rig.root_from_body.y - set.rig.joints[@intFromEnum(Joint.chest)].rest_offset.y };
        const point = wallPoint(origin, side, distance) orelse break :select;
        const touching = @abs(point.x - input.body.x) <= settings.contact_distance_m;
        state.wall.side = side;
        if (side != before.side or before.action == .none or before.action == .jump) {
            state.wall.contact_seconds = 0;
            state.wall.impact = 0;
            state.wall.weight = 0;
        }
        if (touching) {
            if (state.wall.contact_seconds == 0) state.wall.impact = std.math.clamp(speed / settings.full_impact_speed_mps, 0, 1);
            state.wall.contact_seconds += dt;
        } else {
            state.wall.contact_seconds = 0;
        }
        state.wall.action = if (input.wall_sliding) .slide else if (input.supported and touching and input.movement_direction != 0 and state.wall.contact_seconds >= settings.push_delay_seconds) .push else .brace;
        state.wall.weight = @min(1, state.wall.weight + dt / settings.blend_seconds);
    }
    if (state.wall.action == .none) state.wall = .{};
    if (state.wall.side != before.side) state.wall.foot_surfaces = .{ null, null };
    if (state.wall.action != .slide and state.wall.action != .jump) {
        state.wall.feet = .{ null, null };
        state.wall.foot_surfaces = .{ null, null };
    }
    const changed = state.wall.action != before.action or state.wall.side != before.side;
    if (changed) state.wall.seconds = 0;
    return changed;
}

fn wallControls(set: *const Assets, state: *PlayerState) void {
    if (state.wall.action == .none) return;
    const clip = switch (state.wall.action) {
        .brace => set.walls.brace,
        .push => set.walls.push,
        .slide => set.walls.slide,
        .jump => set.walls.jump,
        .none => unreachable,
    };
    const phase = clipPhase(clip, state.wall.seconds / clip.cycle_seconds);
    var controls: [controlCount]f32 = undefined;
    for (&controls, clip.tracks) |*value, track| value.* = evaluateTrack(track, phase);
    if (state.wall.action == .brace) {
        const progress = std.math.clamp(state.wall.contact_seconds / set.walls.settings.push_delay_seconds, 0, 1);
        controls[@intFromEnum(Control.pelvis_y)] -= @sin(progress * std.math.pi) * state.wall.impact * set.walls.settings.impact_compression_m;
    }
    if (state.facing_right != (state.wall.side > 0)) controls = mirrorControls(set.rig, controls);
    for (&state.controls, controls, 0..) |*value, target, index| {
        // During approach the running stride continues beneath the bracing arms.
        const binding: Control = @enumFromInt(index);
        const foot = binding == .left_foot_x or binding == .left_foot_y or binding == .left_foot_angle or binding == .right_foot_x or binding == .right_foot_y or binding == .right_foot_angle;
        if (state.wall.action == .brace and foot) continue;
        value.* = std.math.lerp(value.*, target, state.wall.weight);
    }
    if (state.wall.action == .brace) return;
    // Airborne wall contacts are separate from the ground planting plane.
    state.contact_intent = if (state.wall.action == .push) .{ contactIntent(clip, .left_leg, phase), contactIntent(clip, .right_leg, phase) } else .{ false, false };
}

fn applyWallHandTargets(rig: Rig, controls: *[controlCount]f32, body: vec.Vec2, facing_right: bool, hands: [2]?vec.Vec2, weight: f32) void {
    const sign: f32 = if (facing_right) 1 else -1;
    for (hands, 0..) |hand, index| {
        if (hand == null) continue;
        const x = @intFromEnum(target_x[index + 2]);
        const y = @intFromEnum(target_y[index + 2]);
        controls[x] = std.math.lerp(controls[x], (hand.?.x - body.x) * sign - rig.root_from_body.x, weight);
        controls[y] = std.math.lerp(controls[y], body.y - rig.root_from_body.y - hand.?.y, weight);
    }
}

fn planWallHands(set: *const Assets, state: *PlayerState) void {
    if (state.wall.action == .none or state.wall.action == .jump) return;
    const settings = set.walls.settings;
    const clip = switch (state.wall.action) {
        .brace => set.walls.brace,
        .push => set.walls.push,
        .slide => set.walls.slide,
        .none, .jump => unreachable,
    };
    for (&state.wall.hands, state.previous_wall.hands, 0..) |*hand, before, index| {
        // The named weapon hand stays free on a slide on either wall side.
        if (state.wall.action == .slide and set.rig.limbs[index + 2].end == set.rig.attachments.get("weapon_hand").?.joint) continue;
        // Plan the authored contact height; interpolating toward it happens in
        // the pose. Locking a partly raised hand would trap it below the target.
        const height = evaluateTrack(clip.tracks[@intFromEnum(target_y[index + 2])], clipPhase(clip, state.wall.seconds / clip.cycle_seconds));
        const desired = toWorld(set.rig, .{ .x = 0, .y = height }, state.body, state.facing_right);
        const grounded = state.action != .jump and state.action != .fall;
        const keep = grounded and state.previous_wall.side == state.wall.side and before != null and
            @abs(before.?.x - state.body.x) <= settings.contact_distance_m and @abs(before.?.y - desired.y) < 0.25;
        const origin: vec.Vec2 = .{ .x = state.body.x, .y = if (keep) before.?.y else desired.y };
        hand.* = wallPoint(origin, state.wall.side, settings.probe_distance_m);
    }
    applyWallHandTargets(set.rig, &state.controls, state.body, state.facing_right, state.wall.hands, state.wall.weight);
}

fn planWallFeet(set: *const Assets, state: *PlayerState, launching: bool) void {
    if (state.wall.action == .brace and (state.action == .jump or state.action == .fall)) {
        // The airborne brace precedes slide entry; its free feet must already
        // clear the face before the knee changes branch at the next boundary.
        const offsets = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
        for (&state.wall.foot_surfaces, 0..) |*surface, index| {
            const toe = toWorld(set.rig, .{ .x = state.controls[@intFromEnum(target_x[index])] + offsets[index * 2].x, .y = state.controls[@intFromEnum(target_y[index])] + offsets[index * 2].y }, state.body, state.facing_right);
            const point = wallPoint(.{ .x = state.body.x, .y = toe.y }, state.wall.side, set.walls.settings.probe_distance_m);
            surface.* = if (point == null) null else point.?.x;
        }
        clearWallSoles(set.rig, &state.controls, offsets, state.wall, state.body, state.facing_right);
        return;
    }
    if (state.wall.action != .slide and state.wall.action != .jump) return;
    const jumping = state.wall.action == .jump;
    const clip = if (jumping) set.walls.jump else set.walls.slide;
    const phase = clipPhase(clip, state.wall.seconds / clip.cycle_seconds);
    const sign: f32 = if (state.facing_right) 1 else -1;
    const side: f32 = @floatFromInt(state.wall.side);
    const offsets = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
    for (&state.wall.feet, &state.wall.foot_surfaces, 0..) |*anchor, *surface_x, index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const offset = offsets[index * 2];
        const intent = contactIntent(clip, @enumFromInt(index), phase);
        if (!jumping or (launching and anchor.* == null)) {
            // A jump may start before the slide pose settles. Probe from the
            // pre-launch body so its first physics displacement cannot miss it.
            const body = if (launching) state.previous_body else state.body;
            const height = evaluateTrack(set.walls.slide.tracks[y], if (launching) 0 else phase);
            const origin: vec.Vec2 = .{ .x = body.x, .y = body.y - set.rig.root_from_body.y - height - offset.y };
            anchor.* = if (intent) wallPoint(origin, state.wall.side, set.walls.settings.contact_distance_m) else null;
        }
        if (anchor.* == null) {
            // An entry arc can continue into an immediate jump. It has no
            // planted toe, but still needs the nearby wall's clearance plane.
            if (surface_x.* == null) continue;
            const toe = toWorld(set.rig, .{ .x = state.controls[x] + offset.x, .y = state.controls[y] + offset.y }, state.body, state.facing_right);
            const surface = wallPoint(.{ .x = state.body.x, .y = toe.y }, state.wall.side, set.walls.settings.probe_distance_m);
            surface_x.* = if (surface == null) null else surface.?.x;
            continue;
        }
        const point = anchor.*.?;
        // Revalidate at the contact, not from the receding body. A removed wall
        // releases immediately, and a released jump foot never reattaches.
        const surface = wallPoint(.{ .x = point.x - side * 0.02, .y = point.y }, state.wall.side, 0.04);
        if (surface == null or @abs(surface.?.x - point.x) > 0.001) {
            anchor.* = null;
            surface_x.* = null;
            continue;
        }
        surface_x.* = point.x;
        const ankle: vec.Vec2 = .{ .x = (point.x - state.body.x) * sign - set.rig.root_from_body.x - offset.x, .y = state.body.y - set.rig.root_from_body.y - point.y - offset.y };
        if (intent and reachableFoot(set.rig, state.controls, index, ankle)) {
            state.controls[x] = ankle.x;
            state.controls[y] = ankle.y;
            continue;
        }
        anchor.* = null;
        if (!jumping) continue;
        // The hips have moved beyond reach: leave the wall at full extension,
        // then decay into the authored follow-through using the existing blend.
        const limb = set.rig.limbs[index];
        const upper = set.rig.lengths[@intFromEnum(limb.middle)];
        const lower = set.rig.lengths[@intFromEnum(limb.end)];
        const pelvis: vec.Vec2 = .{ .x = state.controls[@intFromEnum(Control.pelvis_x)], .y = state.controls[@intFromEnum(Control.pelvis_y)] };
        const released = solveLimb(pelvis, ankle, upper, lower, limb.bend_sign, reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians)).end;
        state.transition_offsets[x] += released.x - state.controls[x];
        state.transition_offsets[y] += released.y - state.controls[y];
        state.controls[x] = released.x;
        state.controls[y] = released.y;
    }
}

fn clearWallSoles(rig: Rig, controls: *[controlCount]f32, offsets: [4]vec.Vec2, wall: WallState, body: vec.Vec2, facing_right: bool) void {
    if (wall.side == 0) return;
    const side: f32 = @floatFromInt(wall.side);
    const sign: f32 = if (facing_right) 1 else -1;
    for (wall.foot_surfaces, 0..) |surface, index| {
        if (surface == null) continue;
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        for ([_]vec.Vec2{ offsets[index * 2], vec.add(offsets[index * 2], offsets[index * 2 + 1]) }) |offset| {
            const point = toWorld(rig, .{ .x = controls[x] + offset.x, .y = controls[y] + offset.y }, body, facing_right);
            controls[x] -= @max(0, (point.x - surface.?) * side) * side * sign;
        }
    }
}

fn adaptGround(set: *const Assets, state: *PlayerState, input: LocomotionInput, dt: f32) void {
    const profile = set.locomotion;
    const supported = input.ground_y != null and input.supported and state.action != .jump and state.action != .fall;
    const sign: f32 = if (state.facing_right) 1 else -1;
    const before = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
    const response = 1 - @exp(-dt / profile.terrain.blend_seconds);
    state.sole_surfaces = @splat(null);
    state.knee_surfaces = @splat(null);
    state.pelvis_reference_y = state.controls[@intFromEnum(Control.pelvis_y)];
    for (&state.feet, 0..) |*foot, index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const toe = toWorld(set.rig, vec.add(.{ .x = state.controls[x], .y = state.controls[y] }, before[index * 2]), input.body, state.facing_right);
        const surface = if (supported) groundAt(toe.x, input, profile) else null;
        state.sole_surfaces[index * 2] = surface;
        var target_y_offset: f32 = 0;
        var target_angle: f32 = 0;
        terrain: {
            if (surface == null) break :terrain;
            // Warp the authored flat-ground path to the local surface, retaining
            // its swing height and recovery shape. Foot tilt is world-relative.
            const rest_offset = rotate(set.rig.joints[@intFromEnum(toes[index])].rest_offset, set.rig.neutral[@intFromEnum(foot_angles[index])]);
            const reference_floor = input.body.y - set.rig.root_from_body.y - set.rig.neutral[y] - rest_offset.y;
            target_y_offset = reference_floor - surface.?.point.y;
            target_angle = -std.math.atan2(surface.?.normal.x, -surface.?.normal.y);
            if (!state.contact_intent[index] and @abs(state.speed_mps) > profile.stop_speed_mps) {
                const ahead = groundAt(toe.x + std.math.sign(state.speed_mps) * profile.terrain.lookahead_m, input, profile) orelse break :terrain;
                if (ahead.point.y < surface.?.point.y - profile.surface_tolerance_m) {
                    target_y_offset = @max(target_y_offset, reference_floor - ahead.point.y + profile.terrain.swing_clearance_m);
                }
            }
        }
        // A moving target follows a slope continuously. Filtering that height
        // would leave the foot hovering behind the surface during stance.
        const sloped = surface != null and @abs(surface.?.normal.x) > 0.00001;
        foot.terrain_y = if (sloped) target_y_offset else std.math.lerp(foot.terrain_y, target_y_offset, response);
        foot.terrain_angle = std.math.lerp(foot.terrain_angle, target_angle, response);
        state.controls[@intFromEnum(foot_angles[index])] += foot.terrain_angle * sign;
    }
    const after = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
    for (state.feet, 0..) |foot, index| {
        state.controls[@intFromEnum(target_x[index])] += before[index * 2].x - after[index * 2].x;
        state.controls[@intFromEnum(target_y[index])] += before[index * 2].y - after[index * 2].y + foot.terrain_y;
    }
    const pelvis_offset = (state.feet[0].terrain_y + state.feet[1].terrain_y) / 4;
    state.controls[@intFromEnum(Control.pelvis_y)] += std.math.clamp(pelvis_offset, -profile.terrain.pelvis_limit_m, profile.terrain.pelvis_limit_m);
    fitGroundedPelvis(set, &state.controls, state.sole_surfaces, state.pelvis_reference_y);
}

fn plantFeet(set: *const Assets, state: *PlayerState, input: LocomotionInput, dt: f32) void {
    const profile = set.locomotion;
    const sign: f32 = if (state.facing_right) 1 else -1;
    const moving = @abs(state.speed_mps) > profile.stop_speed_mps;
    const offsets = turnedFootOffsets(set.rig, state.controls, state.foot_heading, state.facing_right);
    for (&state.feet, 0..) |*foot, index| {
        const x = @intFromEnum(target_x[index]);
        const y = @intFromEnum(target_y[index]);
        const toe_offset = offsets[index * 2];
        const desired = vec.Vec2{ .x = state.controls[x], .y = state.controls[y] };
        const desired_toe = toWorld(set.rig, vec.add(desired, toe_offset), input.body, state.facing_right);
        const surface = state.sole_surfaces[index * 2];
        const heel_link = offsets[index * 2 + 1];
        const toe_can_support = surface != null and vec.dot(.{ .x = heel_link.x * sign, .y = -heel_link.y }, surface.?.normal) >= -0.000001;
        const intent = state.contact_intent[index];
        if (!intent or !moving) foot.blocked = false;
        const supported = input.ground_y != null and input.supported and state.action != .jump and state.action != .fall;
        if (foot.locked) {
            const correction = vec.subtract(foot.anchor, desired_toe);
            const ankle = vec.add(desired, .{ .x = correction.x * sign, .y = -correction.y });
            const anchor_surface = if (supported) groundAt(foot.anchor.x, input, profile) else null;
            const anchor_floor = surfaceHeight(anchor_surface, foot.anchor.x);
            const valid = supported and intent and toe_can_support and anchor_floor != null and
                @abs(anchor_floor.? - foot.anchor.y) <= 0.00001 and
                vec.magnitude(correction) <= profile.max_anchor_error_m and
                reachableFoot(set.rig, state.controls, index, ankle);
            if (!valid) {
                foot.locked = false;
                foot.blocked = intent;
            } else {
                foot.correction = correction;
            }
        }
        const candidate_floor = if (!foot.locked and !foot.blocked and supported and intent and toe_can_support) surfaceHeight(surface, desired_toe.x) else null;
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
        // Query both sole ends after anchoring: they may straddle different
        // steps. Every saved face retains its finite extent for interpolation.
        if (!supported) continue;
        const heel_offset = vec.add(toe_offset, offsets[index * 2 + 1]);
        for ([_]vec.Vec2{ toe_offset, heel_offset }, 0..) |offset, end| {
            const point = toWorld(set.rig, .{ .x = state.controls[x] + offset.x, .y = state.controls[y] + offset.y }, input.body, state.facing_right);
            state.sole_surfaces[index * 2 + end] = groundAt(point.x, input, profile);
        }
    }
    const before_clearance = state.controls;
    clearSoles(set.rig, &state.controls, offsets, state.sole_surfaces, input.body, state.facing_right);
    fitGroundedPelvis(set, &state.controls, state.sole_surfaces, state.pelvis_reference_y);
    for (&state.feet, 0..) |*foot, index| {
        if (!foot.locked) continue;
        const y = @intFromEnum(target_y[index]);
        if (state.controls[y] - before_clearance[y] <= 0.00001) continue;
        foot.locked = false;
        foot.blocked = moving;
    }
    if (input.ground_y == null or !input.supported or state.action == .jump or state.action == .fall) return;
    knees: {
        const pelvis_world_y = input.body.y - set.rig.root_from_body.y - state.controls[@intFromEnum(Control.pelvis_y)];
        const longest_thigh = @max(set.rig.lengths[@intFromEnum(Joint.left_knee)], set.rig.lengths[@intFromEnum(Joint.right_knee)]);
        if (pelvis_world_y + longest_thigh + set.rig.line_width / 2 < input.ground_y.? - profile.terrain.probe_up_m) break :knees;
        const pose = solvePoseWithFeet(set.rig, state.controls, offsets);
        for (set.rig.limbs[0..2], &state.knee_surfaces) |limb, *floor| {
            if (pelvis_world_y + set.rig.lengths[@intFromEnum(limb.middle)] + set.rig.line_width / 2 < input.ground_y.? - profile.terrain.probe_up_m) continue;
            const knee = toWorld(set.rig, pose.joints[@intFromEnum(limb.middle)], input.body, state.facing_right);
            floor.* = groundAt(knee.x, input, profile);
        }
        clearKnees(set.rig, &state.controls, state.knee_surfaces, input.body, state.facing_right);
    }
    constrainGroundFeet(set, &state.controls, offsets, state.sole_surfaces, input.body, state.facing_right);
    for (&state.feet, 0..) |*foot, index| {
        if (!foot.locked) continue;
        const ankle = vec.Vec2{ .x = state.controls[@intFromEnum(target_x[index])], .y = state.controls[@intFromEnum(target_y[index])] };
        if (reachableFoot(set.rig, state.controls, index, ankle) and vec.magnitude(vec.subtract(toWorld(set.rig, vec.add(ankle, offsets[index * 2]), input.body, state.facing_right), foot.anchor)) < 0.00001) continue;
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
    const before_state = state.*;
    // Respawn/reload initializes from the current position. A discontinuous
    // relocation cannot carry a planted foot or count as a running stride.
    const initialize = !state.initialized or vec.magnitude(vec.subtract(input.body, state.body)) > 2;
    if (initialize) {
        // A quick shot can precede the first animation update after registration.
        // Preserve that shot pose, but discard old holds across a teleport.
        const initial_hold = if (state.initialized) 0 else state.shot_hold_seconds;
        const initial_direction = state.aim_direction;
        const initial_angle = if (initial_hold > 0) state.weapon_angle else null;
        state.* = .{ .facing_right = input.facing_right, .previous_facing_right = input.facing_right, .body = input.body, .initialized = true, .controls = set.rig.neutral, .previous_controls = set.rig.neutral, .shot_hold_seconds = initial_hold, .aim_direction = initial_direction, .aim_weight = if (initial_hold > 0) 1 else 0, .weapon_angle = initial_angle };
        state.foot_heading = if (input.facing_right) 0 else 1;
    }
    state.previous_phase = state.phase;
    state.previous_controls = state.controls;
    state.previous_facing_right = state.facing_right;
    state.previous_feet = state.feet;
    state.previous_body = state.body;
    state.previous_foot_heading = state.foot_heading;
    state.previous_sole_surfaces = state.sole_surfaces;
    state.previous_knee_surfaces = state.knee_surfaces;
    state.previous_pelvis_reference_y = state.pelvis_reference_y;
    state.previous_wall = state.wall;
    state.previous_stow_weight = state.stow_weight;
    state.previous_limb_release_seconds = state.limb_release_seconds;
    state.limb_release_seconds += step;
    const previous_speed = state.speed_mps;
    state.speed_mps = (input.body.x - state.body.x) / step;
    state.body = input.body;
    state.previous_aim_weight = state.aim_weight;
    if (input.aiming) state.aim_direction = input.aim_direction;
    const raising = input.aiming or state.shot_hold_seconds > 0;
    state.shot_hold_seconds = @max(0, state.shot_hold_seconds - step);
    state.aim_weight = if (raising) @min(1, state.aim_weight + step / set.aiming.raise_seconds) else @max(0, state.aim_weight - step / set.aiming.lower_seconds);
    const speed = @abs(state.speed_mps);
    const wall_changed = if (playback == .locomotion) updateWall(set, state, input, previous_speed, step) else false;
    const stowing = playback == .locomotion and (state.wall.action == .brace or state.wall.action == .push) and !raising;
    state.stow_weight = if (stowing) @min(1, state.stow_weight + step / set.walls.settings.blend_seconds) else @max(0, state.stow_weight - step / set.walls.settings.blend_seconds);
    if (raising) {
        // Keep the current facing near vertical aim so stick noise cannot
        // repeatedly reverse the character. Use the normal planted-foot turn.
        if (@abs(state.aim_direction.x) > 0.1) state.facing_right = state.aim_direction.x > 0;
    } else if (playback == .locomotion and state.wall.action != .none) {
        // Slides and their push-off look into the arena while the contacts
        // continue to use the wall side. Grounded bracing faces the obstacle.
        state.facing_right = if (state.wall.action == .slide or state.wall.action == .jump) state.wall.side < 0 else state.wall.side > 0;
    } else if (playback != .locomotion) {
        state.facing_right = input.facing_right;
    } else if (speed > profile.stop_speed_mps) {
        state.facing_right = state.speed_mps > 0;
    }
    if (playback != .locomotion) {
        if (playback == .run) state.phase += dt / set.motion.cycle_seconds;
        updateWeaponAngle(set, state, raising);
        return;
    }
    const turning = state.facing_right != state.previous_facing_right;
    const action_changed = updateAction(set, state, input, step);
    const supported = state.action != .jump and state.action != .fall;
    // Outward feet rotate into the wall with toes down and ankles clear of the
    // surface. Keep that heading through push-off, independently of aiming.
    const foot_facing_right = if (state.wall.action == .slide or state.wall.action == .jump) state.wall.side < 0 else state.facing_right;
    state.foot_heading = std.math.lerp(state.foot_heading, if (foot_facing_right) @as(f32, 0) else 1, 1 - @exp(-step / profile.turn_seconds));
    const target_weight: f32 = if (supported and speed > profile.stop_speed_mps) 1 else 0;
    const response = if (target_weight > state.run_weight) profile.start_seconds else profile.stop_seconds;
    state.run_weight = std.math.lerp(state.run_weight, target_weight, 1 - @exp(-step / response));
    const target_intensity = std.math.clamp(speed / profile.full_run_speed_mps, 0, 1);
    state.intensity = std.math.lerp(state.intensity, target_intensity, 1 - @exp(-step / response));
    const stride = if (target_weight == 0) 1 else std.math.clamp(@sqrt(speed / set.motion.reference_speed_mps), profile.stride_min, profile.stride_max);
    state.stride_scale = std.math.lerp(state.stride_scale, stride, 1 - @exp(-step / response));
    if (supported and speed > profile.stop_speed_mps) {
        // Residual travel opposite the aim-facing direction plays the stride
        // backwards, keeping stance feet moving against the actual displacement.
        const forward: f64 = if (state.facing_right == (state.speed_mps > 0)) 1 else -1;
        state.phase += forward * speed * dt / (set.motion.reference_speed_mps * set.motion.cycle_seconds * state.stride_scale);
    }
    state.controls = locomotionControls(set, state);
    actionControls(set, state);
    wallControls(set, state);
    adaptGround(set, state, input, step);
    if (!initialize and (turning or action_changed or wall_changed)) {
        const previous = if (turning) mirrorControls(set.rig, state.previous_controls) else state.previous_controls;
        for (&state.transition_offsets, previous, state.controls) |*offset, before, after| offset.* = before - after;
        state.transition_seconds = if (turning) profile.turn_seconds else if (wall_changed) set.walls.settings.blend_seconds else set.actions.settings.blend_seconds;
        // Existing valid contacts survive a turn. Their corrections are already
        // included in the mirrored controls; plantFeet recomputes them once.
        for (&state.feet) |*foot| foot.correction = vec.zero;
    }
    for (&state.controls, &state.transition_offsets) |*control, *offset| {
        control.* += offset.*;
        offset.* *= @exp(-step / state.transition_seconds);
    }
    plantFeet(set, state, input, step);
    planWallHands(set, state);
    planWallFeet(set, state, input.wall_jump_direction != 0);
    const before_rig = wallPoseRig(set.rig, before_state.wall.action, before_state.wall.side, before_state.facing_right);
    const after_rig = wallPoseRig(set.rig, state.wall.action, state.wall.side, state.facing_right);
    var releasing: [limbCount]bool = @splat(false);
    for (before_rig.limbs, after_rig.limbs, &releasing, 0..) |before, after, *release, index| {
        const before_sign = before.bend_sign * @as(i8, if (before_state.facing_right) 1 else -1);
        const after_sign = after.bend_sign * @as(i8, if (state.facing_right) 1 else -1);
        const wall_transition = before_state.wall.action != .none or state.wall.action != .none;
        const sliding = before_state.wall.action == .slide or before_state.wall.action == .jump or state.wall.action == .slide or state.wall.action == .jump;
        release.* = wall_transition and before_sign != after_sign and (index >= 2 or sliding);
    }
    if (!initialize and std.mem.indexOfScalar(bool, &releasing, true) != null) {
        // Reuse the release arc for any limb changing IK branch. Only released
        // limbs blend; the supporting arm and planted feet retain their branch.
        const before_pose = interpolatedPose(set, before_state, 1);
        for (set.rig.limbs, &state.limb_release_angles, &state.limb_release_active, releasing) |limb, *angles, *active, release| {
            active.* = release or (active.* and before_state.limb_release_seconds < set.walls.settings.blend_seconds);
            const upper = vec.subtract(before_pose.joints[@intFromEnum(limb.middle)], before_pose.joints[@intFromEnum(limb.root)]);
            const lower = vec.subtract(before_pose.joints[@intFromEnum(limb.end)], before_pose.joints[@intFromEnum(limb.middle)]);
            angles.* = .{ std.math.atan2(upper.y, upper.x), std.math.atan2(lower.y, lower.x) };
        }
        state.limb_release_seconds = 0;
        state.previous_limb_release_seconds = 0;
        state.limb_release_facing_right = before_state.facing_right;
    }
    for (&state.wall.feet_planted, state.wall.feet, state.limb_release_active[0..2]) |*planted, target, active| {
        // Keep the target for an immediate push-off, but report a contact only
        // after the entry arc has put the sole on it.
        planted.* = target != null and !(active and state.limb_release_seconds < set.walls.settings.blend_seconds);
    }
    if (initialize) {
        state.previous_controls = state.controls;
        state.previous_facing_right = state.facing_right;
        state.previous_foot_heading = state.foot_heading;
        state.previous_feet = state.feet;
        state.previous_sole_surfaces = state.sole_surfaces;
        state.previous_knee_surfaces = state.knee_surfaces;
        state.previous_pelvis_reference_y = state.pelvis_reference_y;
        state.previous_wall = state.wall;
        state.previous_stow_weight = state.stow_weight;
    }
    updateWeaponAngle(set, state, raising);
}

fn wallPoseRig(rig: Rig, action: WallAction, side: i8, facing_right: bool) Rig {
    if (action == .none) return rig;
    var result = rig;
    const sliding = action == .slide or action == .jump;
    const facing_wall = facing_right == (side > 0);
    const weapon_joint = rig.attachments.get("weapon_hand").?.joint;
    for (&result.limbs, 0..) |*limb, index| {
        if (index < 2) {
            // Knees fold into the arena, clear of the wall, even when aiming
            // back at it. The soles retain their independent wall heading.
            if (sliding and facing_wall) limb.bend_sign *= -1;
            continue;
        }
        if (facing_wall or (sliding and limb.end == weapon_joint)) continue;
        limb.bend_sign *= -1;
    }
    return result;
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
    for (state.previous_feet, state.feet, state.previous_wall.feet, state.wall.feet, 0..) |before, foot, before_wall, wall, index| {
        const anchor: ?vec.Vec2 = if (before.locked and foot.locked and std.meta.eql(before.anchor, foot.anchor)) foot.anchor else if (state.previous_wall.feet_planted[index] and state.wall.feet_planted[index] and state.previous_wall.side == state.wall.side and before_wall != null and wall != null) vec.add(before_wall.?, vec.mul(vec.subtract(wall.?, before_wall.?), fraction)) else null;
        if (anchor == null) continue;
        const offset = offsets[index * 2];
        controls[@intFromEnum(target_x[index])] = (anchor.?.x - body.x) * sign - set.rig.root_from_body.x - offset.x;
        controls[@intFromEnum(target_y[index])] = body.y - set.rig.root_from_body.y - anchor.?.y - offset.y;
    }
    var surfaces: [4]?GroundSurface = @splat(null);
    for (&surfaces, state.previous_sole_surfaces, state.sole_surfaces, 0..) |*surface, before, after, index| {
        const leg = index / 2;
        const offset = if (index % 2 == 0) offsets[index] else vec.add(offsets[index - 1], offsets[index]);
        const point = toWorld(set.rig, .{ .x = controls[@intFromEnum(target_x[leg])] + offset.x, .y = controls[@intFromEnum(target_y[leg])] + offset.y }, body, state.facing_right);
        surface.* = interpolatedSurface(before, after, point.x);
    }
    clearSoles(set.rig, &controls, offsets, surfaces, body, state.facing_right);
    fitGroundedPelvis(set, &controls, surfaces, std.math.lerp(state.previous_pelvis_reference_y, state.pelvis_reference_y, fraction));
    var knee_surfaces: [2]?GroundSurface = @splat(null);
    const before_clearance = solvePoseWithFeet(set.rig, controls, offsets);
    for (&knee_surfaces, state.previous_knee_surfaces, state.knee_surfaces, set.rig.limbs[0..2]) |*surface, before, after, limb| {
        const knee = toWorld(set.rig, before_clearance.joints[@intFromEnum(limb.middle)], body, state.facing_right);
        surface.* = interpolatedSurface(before, after, knee.x);
    }
    clearKnees(set.rig, &controls, knee_surfaces, body, state.facing_right);
    constrainGroundFeet(set, &controls, offsets, surfaces, body, state.facing_right);
    clearWallSoles(set.rig, &controls, offsets, state.wall, body, state.facing_right);
    // Hand targets were resolved once in the fixed-step controls. Their linear
    // interpolation with the body already preserves stationary world contacts.
    // Support limbs keep their bend relative to the wall while the free gun
    // arm uses the ordinary facing convention, also used by the aim solver.
    const pose_rig = wallPoseRig(set.rig, state.wall.action, state.wall.side, state.facing_right);
    var pose = solvePoseWithFeet(pose_rig, controls, offsets);
    var floors: [4]?f32 = @splat(null);
    for (&floors, surfaces, foot_joints) |*floor, surface, joint| {
        const point = toWorld(set.rig, pose.joints[@intFromEnum(joint)], body, state.facing_right);
        floor.* = surfaceHeight(surface, point.x);
    }
    blendReleasedLimbs(set, state, &pose, offsets, floors, body, fraction);
    pose.contact_intent = state.contact_intent;
    return pose;
}

fn blendReleasedLimbs(set: *const Assets, state: PlayerState, pose: *Pose, offsets: [4]vec.Vec2, floors: [4]?f32, body: vec.Vec2, fraction: f32) void {
    const seconds = std.math.lerp(state.previous_limb_release_seconds, state.limb_release_seconds, fraction);
    const duration = set.walls.settings.blend_seconds;
    if (seconds >= duration) return;
    const progress = std.math.clamp(seconds / duration, 0, 1);
    const weight = 1 - progress * progress * (3 - 2 * progress);
    for (set.rig.limbs, state.limb_release_angles, state.limb_release_active, 0..) |limb, saved_angles, active, index| {
        if (!active) continue;
        const root = pose.joints[@intFromEnum(limb.root)];
        const middle = pose.joints[@intFromEnum(limb.middle)];
        const end = pose.joints[@intFromEnum(limb.end)];
        const upper = std.math.atan2(middle.y - root.y, middle.x - root.x);
        const lower = std.math.atan2(end.y - middle.y, end.x - middle.x);
        const before_upper = if (state.facing_right == state.limb_release_facing_right) saved_angles[0] else std.math.pi - saved_angles[0];
        const before_lower = if (state.facing_right == state.limb_release_facing_right) saved_angles[1] else std.math.pi - saved_angles[1];
        var angle = upper + std.math.atan2(@sin(before_upper - upper), @cos(before_upper - upper)) * weight;
        const bend = std.math.atan2(@sin(lower - upper), @cos(lower - upper));
        const before_bend = std.math.atan2(@sin(before_lower - before_upper), @cos(before_lower - before_upper));
        // Signed elbow/knee angles pass through extension when changing branch.
        const blended_bend = std.math.lerp(bend, before_bend, weight);
        const upper_length = set.rig.lengths[@intFromEnum(limb.middle)];
        const lower_length = set.rig.lengths[@intFromEnum(limb.end)];
        if (index < 2) {
            const ankle = vec.add(rotate(.{ .x = upper_length, .y = 0 }, angle), rotate(.{ .x = lower_length, .y = 0 }, angle + blended_bend));
            angle += releasedLegClearance(set.rig, state, root, ankle, offsets[index * 2 ..][0..2].*, floors[index * 2 ..][0..2].*, body, index);
        }
        pose.joints[@intFromEnum(limb.middle)] = vec.add(root, rotate(.{ .x = upper_length, .y = 0 }, angle));
        pose.joints[@intFromEnum(limb.end)] = vec.add(pose.joints[@intFromEnum(limb.middle)], rotate(.{ .x = lower_length, .y = 0 }, angle + blended_bend));
    }
    // Toe and heel links follow a released ankle, retaining their solved angles.
    for (foot_joints, 0..) |joint_id, index| {
        if (!state.limb_release_active[index / 2]) continue;
        const joint = set.rig.joints[@intFromEnum(joint_id)];
        pose.joints[@intFromEnum(joint_id)] = vec.add(pose.joints[@intFromEnum(joint.parent.?)], offsets[index]);
    }
}

// Rotate the entire bent leg around its hip to clear the wall/floor. Keeping
// its radius and relative knee angle preserves both bone lengths and the arc
// through a straight knee; clamping the ankle and re-solving IK would snap it.
fn releasedLegClearance(rig: Rig, state: PlayerState, root: vec.Vec2, ankle: vec.Vec2, offsets: [2]vec.Vec2, floors: [2]?f32, body: vec.Vec2, index: usize) f32 {
    const sign: f32 = if (state.facing_right) 1 else -1;
    const side: f32 = if (state.wall.side == 0) 1 else @floatFromInt(state.wall.side);
    const toward = side * sign;
    var wall_limit = std.math.inf(f32);
    var floor_limit = -std.math.inf(f32);
    for ([_]vec.Vec2{ offsets[0], vec.add(offsets[0], offsets[1]) }, floors) |offset, floor| {
        if (state.wall.foot_surfaces[index] != null) wall_limit = @min(wall_limit, (state.wall.foot_surfaces[index].? - body.x) * side - (rig.root_from_body.x + root.x + offset.x) * toward);
        if (floor != null) floor_limit = @max(floor_limit, body.y - rig.root_from_body.y - floor.? - root.y - offset.y);
    }
    const radius = vec.magnitude(ankle);
    const original = std.math.atan2(ankle.y, ankle.x * toward);
    if (ankle.x * toward <= wall_limit and ankle.y >= floor_limit) return 0;
    // The candidates are the boundaries of the permitted angular intervals.
    // A reachable plane intersects the circle at two angles; out-of-range
    // planes contribute no boundary. The current angle is already rejected.
    var candidates: [4]f32 = undefined;
    var count: usize = 0;
    if (@abs(wall_limit) <= radius) {
        const angle = std.math.acos(wall_limit / radius);
        candidates[count] = angle;
        candidates[count + 1] = -angle;
        count += 2;
    }
    if (@abs(floor_limit) <= radius) {
        const angle = std.math.asin(floor_limit / radius);
        candidates[count] = angle;
        candidates[count + 1] = std.math.pi - angle;
        count += 2;
    }
    var best: ?f32 = null;
    var distance = std.math.inf(f32);
    for (candidates[0..count]) |angle| {
        if (radius * @cos(angle) > wall_limit + 0.00001 or radius * @sin(angle) < floor_limit - 0.00001) continue;
        const delta = std.math.atan2(@sin(angle - original), @cos(angle - original));
        if (@abs(delta) >= distance) continue;
        distance = @abs(delta);
        best = delta * toward;
    }
    if (best == null) {
        std.log.warn("character_animation.releasedLegClearance: limb {d} cannot clear surface planes at its current bend", .{index});
        return 0;
    }
    return best.?;
}

fn basePlayerPose(set: *const Assets, state: PlayerState, alpha: f64) Pose {
    if (playback == .locomotion) return interpolatedPose(set, state, alpha);
    const phase = state.previous_phase + (state.phase - state.previous_phase) * alpha;
    return evaluatePose(set, phase, playback);
}

fn updateWeaponAngle(set: *const Assets, state: *PlayerState, raising: bool) void {
    const pose = basePlayerPose(set, state.*, 1);
    const carry = attachmentTransform(set.rig, pose, "weapon_hand").?;
    const sign: f32 = if (state.facing_right) 1 else -1;
    const carry_angle = std.math.atan2(-@sin(carry.angle), @cos(carry.angle) * sign);
    const before = state.weapon_angle orelse carry_angle;
    const target = if (raising) std.math.atan2(-state.aim_direction.y, state.aim_direction.x) else carry_angle;
    const remaining = if (raising) 1 - state.previous_aim_weight else state.previous_aim_weight;
    const fraction = if (remaining == 0) 1 else @abs(state.aim_weight - state.previous_aim_weight) / remaining;
    const delta = std.math.atan2(@sin(target - before), @cos(target - before));
    state.previous_weapon_angle = before;
    state.weapon_angle = before + delta * fraction;
}

// Only the weapon arm is overridden. Contact planning and the solved legs are
// preserved, even when aiming behind the direction of travel.
pub fn solveAimedPose(set: *const Assets, base: Pose, body: vec.Vec2, facing_right: bool, aim_direction: vec.Vec2, weight: f32, barrel_angle: ?f32) FramePose {
    const carry = attachmentTransform(set.rig, base, "weapon_hand").?;
    var result: FramePose = .{
        .pose = base,
        .body = body,
        .facing_right = facing_right,
        .weapon = attachmentToWorld(set.rig, carry, body, facing_right),
        .weapon_facing_right = facing_right,
    };
    if (weight == 0) return result;
    const attachment = set.rig.attachments.get("weapon_hand").?;
    const limb_index = @intFromEnum(if (attachment.joint == .right_hand) Limb.right_arm else Limb.left_arm);
    const limb = set.rig.limbs[limb_index];
    const root = base.joints[@intFromEnum(limb.root)];
    const sign: f32 = if (facing_right) 1 else -1;
    const local_direction: vec.Vec2 = .{ .x = aim_direction.x * sign, .y = aim_direction.y };
    const target = vec.add(root, vec.mul(local_direction, set.aiming.hand_distance_m));
    const blend = weight * weight * (3 - 2 * weight);
    const hand = base.joints[@intFromEnum(limb.end)];
    const blended_target = vec.add(hand, vec.mul(vec.subtract(target, hand), blend));
    const upper = set.rig.lengths[@intFromEnum(limb.middle)];
    const lower = set.rig.lengths[@intFromEnum(limb.end)];
    const solution = solveLimb(root, blended_target, upper, lower, limb.bend_sign, reachLimits(upper, lower, limb.min_bend_radians, limb.max_bend_radians));
    result.pose.joints[@intFromEnum(limb.middle)] = solution.middle;
    result.pose.joints[@intFromEnum(limb.end)] = solution.end;
    result.pose.desired_targets[limb_index] = blended_target;
    result.pose.clamped[limb_index] = solution.clamped;
    const grip = attachmentTransform(set.rig, result.pose, "weapon_hand").?;
    result.weapon.position = toWorld(set.rig, grip.position, body, facing_right);
    // Rotation is tracked continuously by the fixed step: recomputing a shortest
    // arc between two moving endpoints would jump when they cross +/-pi.
    const angle = barrel_angle orelse std.math.atan2(-aim_direction.y, aim_direction.x);
    const horizontal = if (barrel_angle == null or weight == 1) aim_direction.x else @cos(angle);
    result.weapon_facing_right = if (@abs(horizontal) < 0.000001) facing_right else horizontal > 0;
    result.weapon.angle = angle + (if (result.weapon_facing_right) @as(f32, 0) else std.math.pi);
    return result;
}

pub fn playerFrame(player_id: usize, sampling: Sampling, forced_aim: ?vec.Vec2) ?FramePose {
    if (assets == null) return null; // The normal sprite fallback remains available.
    const set = &assets.?;
    const state = states.get(player_id) orelse {
        std.log.warn("character_animation.playerFrame: state missing for player {d}", .{player_id});
        return null;
    };
    const p = player.players.get(player_id) orelse {
        std.log.warn("character_animation.playerFrame: player {d} is missing", .{player_id});
        return null;
    };
    var body = box2d.getState(p.bodyId);
    const alpha: f64 = if (sampling == .render) time.alpha else 1;
    if (sampling == .render) {
        const ent = entity.getEntity(p.bodyId) orelse {
            std.log.warn("character_animation.playerFrame: entity missing for player {d}", .{player_id});
            return null;
        };
        body = box2d.getInterpolatedState(ent.state, body);
    }
    const pose = basePlayerPose(set, state, alpha);
    const direction = forced_aim orelse state.aim_direction;
    const weight = if (!player.usesProceduralWeapon(p)) 0 else if (forced_aim != null) 1 else std.math.lerp(state.previous_aim_weight, state.aim_weight, @as(f32, @floatCast(alpha)));
    const angle = if (forced_aim != null or state.weapon_angle == null) null else std.math.lerp(state.previous_weapon_angle orelse state.weapon_angle.?, state.weapon_angle.?, @as(f32, @floatCast(alpha)));
    var frame = solveAimedPose(set, pose, vec.fromBox2d(body.pos), state.facing_right, direction, weight, angle);
    const stow = if (forced_aim != null or playback != .locomotion) 0 else std.math.lerp(state.previous_stow_weight, state.stow_weight, @as(f32, @floatCast(alpha))) * (1 - weight);
    if (stow == 0) return frame;
    const holster = attachmentToWorld(set.rig, attachmentTransform(set.rig, frame.pose, "weapon_holster").?, frame.body, frame.facing_right);
    frame.weapon.position = vec.add(frame.weapon.position, vec.mul(vec.subtract(holster.position, frame.weapon.position), stow));
    // Express both angles using the character's sprite flip before blending.
    const from = frame.weapon.angle + (if (frame.weapon_facing_right == frame.facing_right) @as(f32, 0) else std.math.pi);
    const delta = std.math.atan2(@sin(holster.angle - from), @cos(holster.angle - from));
    frame.weapon.angle = from + delta * stow;
    frame.weapon_facing_right = frame.facing_right;
    frame.weapon_stowed = stow > 0.5;
    return frame;
}

pub fn holdShotPose(player_id: usize, direction: vec.Vec2) void {
    if (assets == null) return;
    const state = states.getPtr(player_id) orelse {
        std.log.warn("character_animation.holdShotPose: state missing for player {d}", .{player_id});
        return;
    };
    state.aim_direction = direction;
    state.aim_weight = 1;
    state.previous_aim_weight = 1;
    state.shot_hold_seconds = assets.?.aiming.shot_hold_seconds;
    state.weapon_angle = std.math.atan2(-direction.y, direction.x);
    state.previous_weapon_angle = state.weapon_angle;
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
        var ground_y: ?f32 = null;
        const body_position = vec.fromBox2d(box2d.c.b2Body_GetPosition(p.bodyId));
        const contact = movement_state.groundState.groundContact;
        if (contact != null and -contact.?.normal.y >= @cos(assets.?.locomotion.terrain.max_slope_radians) and box2d.c.b2Body_GetType(contact.?.bodyId) == box2d.c.b2_staticBody) ground_y = contact.?.worldPoint.y - (body_position.x - contact.?.worldPoint.x) * contact.?.normal.x / contact.?.normal.y;
        const velocity = box2d.c.b2Body_GetLinearVelocity(p.bodyId);
        // A rising platform should not look like a jump away from its support.
        const support_velocity = if (contact == null or !movement_state.groundState.supported) vec.zero else vec.fromBox2d(box2d.c.b2Body_GetWorldPointVelocity(contact.?.bodyId, vec.toBox2d(contact.?.worldPoint)));
        const relative_velocity = vec.subtract(vec.fromBox2d(velocity), support_velocity);
        const direction = movement.locomotionDirection(player_id);
        // Towerfall hands the movement stick to aiming. Preserve an existing
        // kneel until that hold ends; aim direction must not choose a stance.
        // This loop's registered animation state remains present throughout.
        const hold_kneel = movement.mechanism == .towerfall and p.isAiming and states.get(player_id).?.action == .kneel;
        updatePlayer(player_id, .{
            .body = body_position,
            .supported = movement_state.groundState.supported,
            .ground_y = ground_y,
            .ground_normal = if (contact == null) .{ .x = 0, .y = -1 } else contact.?.normal,
            .facing_right = movement_state.facingRight,
            .vertical_speed_mps = relative_velocity.y,
            .separation_speed_mps = if (contact == null) 0 else vec.dot(relative_velocity, contact.?.normal),
            .kneel_requested = direction.y < 0 or hold_kneel,
            .aiming = p.isAiming,
            .aim_direction = p.aimDirection,
            .horizontal_speed_mps = velocity.x,
            .movement_direction = direction.x,
            .wall_sliding = movement_state.wallSliding,
            .wall_jump_direction = movement_state.wallJumpedDirection,
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
        const frame = playerFrame(player_id, .render, null) orelse continue;
        const pose = frame.pose;
        var points: [jointCount][2]f32 = undefined;
        for (pose.joints, 0..) |point, index| points[index] = toScreen(toWorld(set.rig, point, frame.body, state.facing_right));
        const width = @max(1.25 / renderer.zoom, set.rig.line_width * conv.met2pix);
        const carrying = player.usesProceduralWeapon(p);
        const weapon_joint = set.rig.attachments.get("weapon_hand").?.joint; // Validated at load.
        // Left/right identify anatomical limbs. Turning exchanges their depth,
        // while the weapon remains attached to the same named hand.
        for ([_]bool{ true, false }) |far| {
            const right = far == state.facing_right;
            // Keep the torso between far and near limbs, in the player's color.
            if (!far) {
                try gpu.setRenderDrawColor(limbColor(p.color, false));
                for ([_]Joint{ .chest, .neck }) |joint| {
                    const parent = set.rig.joints[@intFromEnum(joint)].parent.?;
                    try drawSegment(points[@intFromEnum(parent)], points[@intFromEnum(joint)], width);
                }
                try drawRing(points[@intFromEnum(Joint.head)], set.rig.head_radius * conv.met2pix, width * 0.75);
                const head = pose.joints[@intFromEnum(Joint.head)];
                const eye = toScreen(toWorld(set.rig, vec.add(head, .{ .x = set.rig.head_radius * 0.43, .y = set.rig.head_radius * 0.15 }), frame.body, state.facing_right));
                try drawSegment(.{ eye[0] - width * 0.2, eye[1] }, .{ eye[0] + width * 0.2, eye[1] }, width * 0.6);
                if (carrying and frame.weapon_stowed) try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            }
            // Insert the weapon under its hand, using the same solved render pose.
            const weapon_layer = right == (weapon_joint == .right_hand);
            if (carrying and !frame.weapon_stowed and weapon_layer) {
                try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            }
            try gpu.setRenderDrawColor(limbColor(p.color, far));
            for (set.rig.joints) |joint| {
                if (joint.id == .pelvis or joint.id == .chest or joint.id == .neck or joint.id == .head) continue;
                const right_joint = @intFromEnum(joint.id) >= @intFromEnum(Joint.right_shoulder);
                if (right_joint != right) continue;
                try drawSegment(points[@intFromEnum(joint.parent.?)], points[@intFromEnum(joint.id)], width);
            }
            const ankle: Joint = if (right) .right_ankle else .left_ankle;
            const heel: Joint = if (right) .right_heel else .left_heel;
            try drawSegment(points[@intFromEnum(ankle)], points[@intFromEnum(heel)], width * 0.6);
            if (carrying and !frame.weapon_stowed and weapon_layer) try drawRing(points[@intFromEnum(weapon_joint)], width * 0.6, width * 0.55);
        }
        if (!show_diagnostics) continue;
        try drawDiagnostics(set.rig, pose, points, frame.body, state.facing_right, width);
        if (playback != .locomotion) continue;
        try gpu.setRenderDrawColor(.{ .r = 70, .g = 255, .b = 120, .a = 255 });
        for (state.feet) |foot| {
            if (!foot.locked) continue;
            try drawRing(toScreen(foot.anchor), width * 3, width * 0.6);
        }
        try gpu.setRenderDrawColor(.{ .r = 90, .g = 210, .b = 255, .a = 255 });
        for (state.wall.hands ++ state.wall.feet, 0..) |contact, index| {
            if (index >= 2 and !state.wall.feet_planted[index - 2]) continue;
            if (contact == null) continue;
            try drawRing(toScreen(contact.?), width * 2, width * 0.6);
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
