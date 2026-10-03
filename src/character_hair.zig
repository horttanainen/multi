const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const data = @import("data.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const character_art = @import("character_art.zig");
const character_animation = @import("character_animation.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const damage = @import("damage.zig");
const ragdoll = @import("ragdoll.zig");
const sprite = @import("sprite.zig");
const gpu = @import("gpu.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const time = @import("time.zig");

pub const Node = struct {
    position: vec.Vec2 = vec.zero,
    previous: vec.Vec2 = vec.zero,
    velocity: vec.Vec2 = vec.zero,
};
pub const Capsule = struct { a: vec.Vec2, b: vec.Vec2, radius: f32 };
pub const Frame = struct {
    head: character_art.PlacedPart,
    appearance: data.CharacterHairAppearance,
    velocity: vec.Vec2 = vec.zero,
    torso: ?Capsule = null,
};
pub const State = struct {
    player_id: ?usize,
    nodes: std.ArrayList(Node) = .empty,
    initialized: bool = false,
    points_per_lock: usize = 0,
    frame: Frame = undefined,
    sleeping: bool = false,
    quiet_seconds: f32 = 0,
    resting_seconds: f32 = 0,
    rest_frame: Frame = undefined,
};
// Player bodies and pooled head bodies have separate entries. Storage is reserved
// during spawn/pool preparation, retained on release, and freed with the entity.
pub var states: std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, State) = .empty;

pub fn validate(motion: data.CharacterHairMotion, detail: *data.CharacterAssetDiagnostic) !void {
    if (motion.points_per_lock < 3 or motion.points_per_lock > 12 or
        motion.iterations < 1 or motion.iterations > 12)
    {
        return data.invalidCharacterAsset(detail, "hair.motion: expected 3..12 points and 1..12 iterations", .{});
    }
    const checks = [_]struct { name: []const u8, value: f32, min: f32, max: f32 }{
        .{ .name = "gravity_mps2", .value = motion.gravity_mps2, .min = 0, .max = 60 },
        .{ .name = "damping_per_second", .value = motion.damping_per_second, .min = 0.1, .max = 30 },
        .{ .name = "stiffness_per_second", .value = motion.stiffness_per_second, .min = 0, .max = 60 },
        .{ .name = "root_bend_radians", .value = motion.root_bend_radians, .min = 0.05, .max = 3 },
        .{ .name = "bend_radians", .value = motion.bend_radians, .min = 0.05, .max = 1.5 },
        .{ .name = "head_radius_m", .value = motion.head_radius_m, .min = 0, .max = 0.3 },
        .{ .name = "torso_radius_m", .value = motion.torso_radius_m, .min = 0, .max = 0.3 },
        .{ .name = "teleport_distance_m", .value = motion.teleport_distance_m, .min = 0.5, .max = 10 },
        .{ .name = "sleep_speed_mps", .value = motion.sleep_speed_mps, .min = 0.001, .max = 0.2 },
        .{ .name = "sleep_seconds", .value = motion.sleep_seconds, .min = 0.1, .max = 5 },
        .{ .name = "settle_seconds", .value = motion.settle_seconds, .min = 0.2, .max = 5 },
        .{ .name = "rest_distance_m", .value = motion.rest_distance_m, .min = 0.0001, .max = 0.02 },
        .{ .name = "bend_damping_per_second", .value = motion.bend_damping_per_second, .min = 0, .max = 60 },
        .{ .name = "motion_transfer", .value = motion.motion_transfer, .min = 0, .max = 1 },
    };
    for (checks) |check| {
        if (!std.math.isFinite(check.value) or check.value < check.min or check.value > check.max) {
            return data.invalidCharacterAsset(detail, "hair.motion.{s}: expected {d}..{d}", .{ check.name, check.min, check.max });
        }
    }
}

pub fn prepare(body_id: box2d.c.b2BodyId, player_id: ?usize, definition: data.CharacterHairData) !void {
    const entry = try states.getOrPut(allocator, body_id);
    errdefer {
        if (!entry.found_existing) {
            _ = states.swapRemove(body_id);
        }
    }
    if (!entry.found_existing) {
        entry.value_ptr.* = .{ .player_id = player_id };
    }
    // Growing a candidate's reserve preserves the installed simulation if reload fails.
    try entry.value_ptr.nodes.ensureTotalCapacity(allocator, definition.anchors.len * @as(usize, definition.motion.points_per_lock));
}

pub fn preparePlayers(pack: *const character_art.Pack) !void {
    const hair = pack.hair orelse return;
    for (player.players.values()) |p| {
        try prepare(p.bodyId, p.id, hair.definition);
    }
}

pub fn reset(body_id: box2d.c.b2BodyId) void {
    const state = states.getPtr(body_id) orelse return; // Hair is optional.
    state.initialized = false;
    state.sleeping = false;
    state.quiet_seconds = 0;
    state.resting_seconds = 0;
}

pub fn resetAll() void {
    for (states.keys()) |body_id| reset(body_id);
}

pub fn remove(body_id: box2d.c.b2BodyId) void {
    const removed = states.fetchSwapRemove(body_id) orelse return;
    var state = removed.value;
    state.nodes.deinit(allocator);
}

pub fn cleanup() void {
    for (states.values()) |*state| state.nodes.deinit(allocator);
    states.clearAndFree(allocator);
}

fn rotate(p: vec.Vec2, angle: f32) vec.Vec2 {
    return .{ .x = p.x * @cos(angle) - p.y * @sin(angle), .y = p.x * @sin(angle) + p.y * @cos(angle) };
}

fn direction(p: vec.Vec2, fallback: vec.Vec2) vec.Vec2 {
    const length = vec.magnitude(p);
    if (length < 0.000001) return fallback; // A collapsed link has a defined rest direction.
    return vec.mul(p, 1 / length);
}

fn headCollider(pack: *const character_art.Pack, frame: Frame) Capsule {
    const part = pack.parts[frame.head.part].definition;
    const sign: f32 = if (frame.head.facing_right) 1 else -1;
    const local = vec.Vec2{
        .x = (part.physics.center[0] - part.pivot[0]) * part.meters_per_pixel * sign,
        .y = (part.physics.center[1] - part.pivot[1]) * part.meters_per_pixel,
    };
    const center = vec.add(frame.head.position, rotate(local, frame.head.angle));
    return .{ .a = center, .b = center, .radius = pack.hair.?.definition.motion.head_radius_m };
}

pub fn closestCapsulePoint(p: vec.Vec2, capsule: Capsule) vec.Vec2 {
    const axis = vec.subtract(capsule.b, capsule.a);
    const squared = vec.dot(axis, axis);
    if (squared < 0.000001) return capsule.a;
    const t = std.math.clamp(vec.dot(vec.subtract(p, capsule.a), axis) / squared, 0, 1);
    return vec.add(capsule.a, vec.mul(axis, t));
}

fn constrainObstacle(
    parent: vec.Vec2,
    desired: vec.Vec2,
    obstacle: ?Capsule,
    margin: f32,
    fallback: vec.Vec2,
) vec.Vec2 {
    const capsule = obstacle orelse return desired;
    if (capsule.radius == 0) return desired;
    const separation = vec.subtract(parent, closestCapsulePoint(parent, capsule));
    const clearance = vec.magnitude(separation);
    // An authored root can be inside the approximate obstacle. Let its links
    // emerge from that attachment region without stretching them to the surface.
    const radius = @min(capsule.radius + margin, clearance);
    const contact_center = closestCapsulePoint(desired, capsule);
    const offset = vec.subtract(desired, contact_center);
    if (vec.dot(offset, offset) >= radius * radius) return desired;
    const delta = vec.subtract(desired, parent);
    const length = vec.magnitude(delta);
    if (length < 0.000001) return desired; // Subpixel cuts may collapse at float precision.
    var normal = direction(offset, direction(separation, fallback));
    var plane_distance = radius - vec.dot(vec.subtract(parent, contact_center), normal);
    if (plane_distance > length) {
        // A deeply embedded target may choose the far side of the obstacle.
        // The plane nearest the parent is always reachable at this clearance.
        normal = direction(separation, fallback);
        plane_distance = radius - clearance;
    }
    const side = vec.Vec2{ .x = normal.y, .y = -normal.x };
    // Rotate onto the contact's outward tangent plane without changing length.
    // Using the contact normal keeps shallow corrections continuous.
    const outward = std.math.clamp(plane_distance / length, -1, 1);
    const sideways = @sqrt(@max(0, 1 - outward * outward));
    const sign: f32 = if (vec.dot(delta, side) < 0) -1 else 1;
    const tangent = vec.add(vec.mul(normal, outward), vec.mul(side, sideways * sign));
    return vec.add(parent, vec.mul(tangent, length));
}

fn mirrorNode(node: Node, from: character_art.PlacedPart, to: character_art.PlacedPart) Node {
    var local = rotate(vec.subtract(node.position, from.position), -from.angle);
    var velocity = rotate(node.velocity, -from.angle);
    local.x = -local.x;
    velocity.x = -velocity.x;
    const position = vec.add(to.position, rotate(local, to.angle));
    return .{ .position = position, .previous = position, .velocity = rotate(velocity, to.angle) };
}

pub fn registerPlayer(player_id: usize) !void {
    if (character_art.assets == null) return;
    const hair = character_art.assets.?.hair orelse return;
    const p = player.players.get(player_id) orelse {
        std.log.warn("character_hair.registerPlayer: player {d} is missing", .{player_id});
        return error.MissingPlayer;
    };
    try prepare(p.bodyId, player_id, hair.definition);
}

fn initialize(state: *State, pack: *const character_art.Pack, frame: Frame) void {
    const definition = pack.hair.?.definition;
    const count: usize = definition.motion.points_per_lock;
    state.nodes.items.len = definition.anchors.len * count;
    for (definition.anchors, 0..) |anchor, lock| {
        const placed = character_art.placeHairLock(pack, frame.head, anchor, frame.appearance);
        const segment = frame.appearance.length_m * anchor.length_scale /
            @as(f32, @floatFromInt(count - 1));
        var position = placed.position;
        for (state.nodes.items[lock * count ..][0..count], 0..) |*node, index| {
            if (index > 0) {
                // Only the root hints at the authored emergence direction.
                // Seed the remaining length hanging with gravity, avoiding a
                // rigid swept-back stick that must whip around after spawning.
                const angle = std.math.atan2(@sin(placed.angle), @cos(placed.angle));
                const root_weight = 0.25 / @as(f32, @floatFromInt(index * index));
                const tangent = rotate(.{ .x = 0, .y = 1 }, angle * root_weight);
                position = vec.add(position, vec.mul(tangent, segment));
            }
            node.* = .{ .position = position, .previous = position, .velocity = frame.velocity };
        }
    }
    state.points_per_lock = count;
    state.frame = frame;
    state.rest_frame = frame;
    state.initialized = true;
    state.sleeping = false;
    state.quiet_seconds = 0;
    state.resting_seconds = 0;
}

// Carry positions and velocities across a live-head to pooled-head transition.
pub fn inherit(
    source_id: ?box2d.c.b2BodyId,
    target_id: box2d.c.b2BodyId,
    head: character_art.PlacedPart,
    added_velocity: vec.Vec2,
) void {
    reset(target_id);
    const source = states.get(source_id orelse return) orelse return;
    if (!source.initialized) return;
    const target = states.getPtr(target_id) orelse {
        std.log.warn("character_hair.inherit: target head was not prepared", .{});
        return;
    };
    if (target.nodes.capacity < source.nodes.items.len) {
        std.log.warn("character_hair.inherit: target reserve is too small", .{});
        return;
    }
    target.nodes.items.len = source.nodes.items.len;
    const offset = vec.subtract(head.position, source.frame.head.position);
    for (source.nodes.items, target.nodes.items) |old, *node| {
        node.* = old;
        if (source.frame.head.facing_right != head.facing_right) {
            node.* = mirrorNode(old, source.frame.head, head);
        } else {
            node.position = vec.add(old.position, offset);
        }
        node.previous = node.position;
        node.velocity = vec.add(node.velocity, added_velocity);
    }
    target.points_per_lock = source.points_per_lock;
    target.frame = source.frame;
    target.frame.head = head;
    target.frame.torso = null;
    target.rest_frame = target.frame;
    target.initialized = true;
}

fn unchangedFrame(a: Frame, b: Frame, tolerance: f32) bool {
    const angle = a.head.angle - b.head.angle;
    const rotation_distance = @abs(std.math.atan2(@sin(angle), @cos(angle))) * 0.2;
    if (vec.magnitude(vec.subtract(a.head.position, b.head.position)) > tolerance or
        rotation_distance > tolerance or
        a.head.facing_right != b.head.facing_right)
    {
        return false;
    }
    if (a.torso == null or b.torso == null) {
        return a.torso == null and b.torso == null;
    }
    return vec.magnitude(vec.subtract(a.torso.?.a, b.torso.?.a)) < tolerance and
        vec.magnitude(vec.subtract(a.torso.?.b, b.torso.?.b)) < tolerance;
}

// A small position-based chain; all storage was reserved before the fixed step.
pub fn step(state: *State, pack: *const character_art.Pack, frame: Frame, dt: f32) void {
    const hair = pack.hair orelse return;
    if (frame.appearance.length_m == 0) {
        state.initialized = false;
        return;
    }
    if (!std.math.isFinite(dt) or dt <= 0 or dt > 0.1) {
        std.log.warn("character_hair.step: invalid fixed timestep {d}", .{dt});
        return;
    }
    const settings = hair.definition.motion;
    const count: usize = settings.points_per_lock;
    const needed = hair.definition.anchors.len * count;
    if (state.nodes.capacity < needed) {
        std.log.warn("character_hair.step: chain storage was not prepared", .{});
        return;
    }
    if (!state.initialized or state.nodes.items.len != needed or state.points_per_lock != count) {
        initialize(state, pack, frame);
    }
    if (state.frame.appearance.length_m != frame.appearance.length_m or
        vec.magnitude(vec.subtract(frame.head.position, state.frame.head.position)) > settings.teleport_distance_m)
    {
        initialize(state, pack, frame);
    }
    if (frame.head.facing_right != state.frame.head.facing_right) {
        for (state.nodes.items) |*node| {
            node.* = mirrorNode(node.*, state.frame.head, frame.head);
        }
    }
    // Compare with the beginning of the rest interval, not the last tick.
    // This tolerates contact jitter without hiding slow accumulated motion.
    const resting = unchangedFrame(state.rest_frame, frame, settings.rest_distance_m);
    if (!resting) {
        state.rest_frame = frame;
        state.resting_seconds = 0;
        state.quiet_seconds = 0;
        state.sleeping = false;
    }
    if (state.sleeping) {
        for (state.nodes.items) |*node| node.previous = node.position;
        return;
    }
    if (resting) state.resting_seconds += dt;
    const collider = headCollider(pack, frame);
    // Fade residual energy when the attachment remains still. Sleeping still
    // requires measured quiet motion; elapsed time never freezes an arbitrary pose.
    const settling = std.math.clamp(state.resting_seconds / settings.settle_seconds, 0, 1);
    const damping = @exp(-(settings.damping_per_second + 24 * settling * settling) * dt);
    const bend_damping = 1 - @exp(-settings.bend_damping_per_second * dt);
    const stiffness = (1 - @exp(-settings.stiffness_per_second * dt)) /
        @as(f32, @floatFromInt(settings.iterations));
    var maximum_speed: f32 = 0;
    for (hair.definition.anchors, 0..) |anchor, lock| {
        const nodes = state.nodes.items[lock * count ..][0..count];
        const placed = character_art.placeHairLock(pack, frame.head, anchor, frame.appearance);
        const rest = rotate(.{ .x = 0, .y = 1 }, placed.angle);
        // Near-side locks lie in front of the body in depth. Their projected
        // overlap with the head/shoulder is intentional, matching the art layer.
        const head_obstacle: ?Capsule = if (anchor.layer == .back) collider else null;
        const torso_obstacle = if (anchor.layer == .back) frame.torso else null;
        const root_speed = vec.magnitude(vec.subtract(placed.position, nodes[0].position)) / dt;
        const segment = frame.appearance.length_m * anchor.length_scale /
            @as(f32, @floatFromInt(count - 1));
        for (nodes) |*node| {
            node.previous = node.position;
            node.velocity = vec.mul(node.velocity, damping);
            node.velocity.y += settings.gravity_mps2 * dt;
            node.position = vec.add(node.position, vec.mul(node.velocity, dt));
        }
        nodes[0].position = placed.position;
        for (0..settings.iterations) |_| {
            // Symmetric distance corrections let a moving tip pull its preceding links.
            var index = count - 1;
            while (index > 0) : (index -= 1) {
                const delta = vec.subtract(nodes[index].position, nodes[index - 1].position);
                const correction = vec.mul(direction(delta, rest), vec.magnitude(delta) - segment);
                const weight: f32 = if (index == 1) 1 else 0.5;
                nodes[index].position = vec.subtract(nodes[index].position, vec.mul(correction, weight));
                if (index > 1) {
                    nodes[index - 1].position = vec.add(nodes[index - 1].position, vec.mul(correction, 0.5));
                }
            }
            var preceding = rest;
            for (1..count) |i| {
                var tangent = direction(vec.subtract(nodes[i].position, nodes[i - 1].position), preceding);
                const cross = preceding.x * tangent.y - preceding.y * tangent.x;
                const angle = std.math.atan2(cross, vec.dot(preceding, tangent));
                const limit = if (i == 1) settings.root_bend_radians else settings.bend_radians;
                const fraction = @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(count - 1));
                const bend = std.math.clamp(angle, -limit, limit) * (1 - stiffness * (1 - fraction));
                tangent = rotate(preceding, bend);
                var p = vec.add(nodes[i - 1].position, vec.mul(tangent, segment));
                const fallback = vec.Vec2{ .x = if (frame.head.facing_right) -1 else 1, .y = 0 };
                p = constrainObstacle(nodes[i - 1].position, p, head_obstacle, anchor.width_m * 0.5, fallback);
                p = constrainObstacle(nodes[i - 1].position, p, torso_obstacle, anchor.width_m * 0.5, fallback);
                nodes[i].position = p;
                preceding = direction(vec.subtract(p, nodes[i - 1].position), tangent);
            }
        }
        for (nodes, 0..) |*node, index| {
            const displacement_velocity = vec.mul(vec.subtract(node.position, node.previous), 1 / dt);
            const speed = vec.magnitude(displacement_velocity);
            maximum_speed = @max(maximum_speed, speed);
            // Distance/bend/contact corrections are not free kinetic energy.
            // Retain incoming momentum, allowing limited work from the moving
            // attachment, with less transmission farther down the lock.
            const transfer = settings.motion_transfer / @as(f32, @floatFromInt(index + 1));
            const speed_limit = @min(30, vec.magnitude(node.velocity) + root_speed * transfer);
            node.velocity = displacement_velocity;
            if (speed > speed_limit) {
                node.velocity = vec.mul(displacement_velocity, speed_limit / speed);
            }
        }
        // Dampen small ripples between free links while retaining the lock's
        // shared momentum. Equal/opposite impulses cannot add kinetic energy.
        for (1..count - 1) |i| {
            const difference = vec.subtract(nodes[i + 1].velocity, nodes[i].velocity);
            const impulse = vec.mul(difference, 0.5 * bend_damping);
            nodes[i].velocity = vec.add(nodes[i].velocity, impulse);
            nodes[i + 1].velocity = vec.subtract(nodes[i + 1].velocity, impulse);
        }
    }
    if (resting and maximum_speed < settings.sleep_speed_mps) {
        state.quiet_seconds += dt;
        state.sleeping = state.quiet_seconds >= settings.sleep_seconds;
    } else {
        state.quiet_seconds = 0;
    }
    if (state.sleeping) {
        for (state.nodes.items) |*node| node.velocity = vec.zero;
    }
    state.frame = frame;
}

fn playerFrame(player_id: usize, pack: *const character_art.Pack, hair: character_art.Hair) ?Frame {
    const p = player.players.get(player_id) orelse {
        std.log.warn("character_hair.playerFrame: player {d} is missing", .{player_id});
        return null;
    };
    if (p.isDead) return null;
    const rig = (character_animation.assets orelse return null).rig;
    const pose = character_animation.playerFrame(p.id, .physics, null) orelse return null;
    // Pose lookup reports missing animation/entity state itself.
    const joints = character_art.worldJoints(rig, pose);
    return .{
        .head = character_art.placePart(pack, hair.head_binding, joints, pose, false),
        .appearance = character_art.hairForPlayer(pack, p.id).?,
        .velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(p.bodyId)),
        .torso = .{
            .a = joints[@intFromEnum(character_animation.Joint.neck)],
            .b = joints[@intFromEnum(character_animation.Joint.pelvis)],
            .radius = hair.definition.motion.torso_radius_m,
        },
    };
}

fn currentFrame(body_id: box2d.c.b2BodyId, state: State, pack: *const character_art.Pack) ?Frame {
    const hair = pack.hair orelse return null;
    if (state.player_id != null) {
        return playerFrame(state.player_id.?, pack, hair);
    }
    const visual = character_art.bodyParts.get(body_id) orelse return null;
    const appearance = visual.hair orelse return null;
    const e = entity.getEntity(body_id) orelse {
        std.log.warn("character_hair.currentFrame: prepared head entity is missing", .{});
        return null;
    };
    if (!e.enabled) return null;
    const body = box2d.getState(body_id);
    var frame: Frame = .{
        .head = .{
            .part = visual.part,
            .position = vec.fromBox2d(body.pos),
            .angle = body.rotAngle,
            .facing_right = visual.facing_right,
            .far = false,
        },
        .appearance = appearance,
        .velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(body_id)),
    };
    const root = damage.healthOwner(body_id);
    if (ragdoll.corpses.contains(root)) {
        frame.torso = .{
            .a = frame.head.position,
            .b = vec.fromBox2d(box2d.c.b2Body_GetPosition(root)),
            .radius = hair.definition.motion.torso_radius_m,
        };
    }
    return frame;
}

pub fn fixedUpdate(dt: f64) void {
    if (character_art.assets == null) return;
    const pack = &character_art.assets.?;
    for (states.keys(), states.values()) |body_id, *state| {
        const frame = currentFrame(body_id, state.*, pack) orelse {
            reset(body_id);
            continue;
        };
        step(state, pack, frame, @floatCast(dt));
    }
}

fn interpolatedPoint(node: Node, alpha: f32) vec.Vec2 {
    return vec.add(node.previous, vec.mul(vec.subtract(node.position, node.previous), alpha));
}

pub fn ribbonRow(
    nodes: []const Node,
    fraction: f32,
    alpha: f32,
    correction: vec.Vec2,
    across: [2]f32,
) [2]vec.Vec2 {
    const coordinate = fraction * @as(f32, @floatFromInt(nodes.len - 1));
    const last_segment: f32 = @floatFromInt(nodes.len - 2);
    const index: usize = @intFromFloat(std.math.clamp(@floor(coordinate), 0, last_segment));
    const a = interpolatedPoint(nodes[index], alpha);
    const b = interpolatedPoint(nodes[index + 1], alpha);
    const fraction_in_segment = coordinate - @as(f32, @floatFromInt(index));
    const center = vec.add(correction, vec.add(a, vec.mul(vec.subtract(b, a), fraction_in_segment)));
    const tangent = direction(vec.subtract(b, a), .{ .x = 0, .y = 1 });
    const normal = vec.Vec2{ .x = tangent.y, .y = -tangent.x };
    return .{ vec.add(center, vec.mul(normal, across[0])), vec.add(center, vec.mul(normal, across[1])) };
}

// Returns false during initial setup, letting the existing static artwork draw.
pub fn drawLock(
    owner: ?box2d.c.b2BodyId,
    lock: usize,
    image: character_art.Image,
    placed: character_art.ImagePlacement,
    color: sprite.Color,
) !bool {
    const state = states.get(owner orelse return false) orelse return false;
    if (!state.initialized) return false;
    const pack = &character_art.assets.?; // Artwork caller already resolved this pack.
    const definition = pack.hair.?.definition;
    const count = state.points_per_lock;
    if ((lock + 1) * count > state.nodes.items.len) {
        std.log.warn("character_hair.drawLock: stale chain layout", .{});
        return false;
    }
    const sprite_id = image.sprite_id orelse {
        std.log.warn("character_hair.drawLock: shared lock has no loaded sprite", .{});
        return false;
    };
    const visual = sprite.getSprite(sprite_id) orelse {
        std.log.warn("character_hair.drawLock: shared lock sprite is missing", .{});
        return false;
    };
    const nodes = state.nodes.items[lock * count ..][0..count];
    const alpha: f32 = @floatCast(std.math.clamp(time.alpha, 0, 1));
    const root = interpolatedPoint(nodes[0], alpha);
    const correction = vec.subtract(placed.position, root);
    const pivot = image.definition.pivot;
    const width: f32 = @floatFromInt(visual.surface.w);
    const height: f32 = @floatFromInt(visual.surface.h);
    const sign: f32 = if (placed.facing_right) 1 else -1;
    const across = [2]f32{
        -pivot[0] * placed.scale.x * sign,
        (width - pivot[0]) * placed.scale.x * sign,
    };
    const offset = camera.relativePosition(.{ .x = 0, .y = 0 });
    var previous_y: f32 = 0;
    const source_length = definition.lock.source_size[1];
    var previous_row = ribbonRow(nodes, -pivot[1] / source_length, alpha, correction, across);
    // Extra end strips retain the source's transparent padding and rounded tip.
    for (0..count + 1) |row| {
        const y = if (row == count) height else pivot[1] + source_length * @as(f32, @floatFromInt(row)) /
            @as(f32, @floatFromInt(count - 1));
        const current = ribbonRow(nodes, (y - pivot[1]) / source_length, alpha, correction, across);
        var corners: [4][2]f32 = undefined;
        for ([_]vec.Vec2{ previous_row[0], previous_row[1], current[1], current[0] }, &corners) |p, *corner| {
            corner.* = .{ p.x * conv.met2pix + @as(f32, @floatFromInt(offset.x)), p.y * conv.met2pix + @as(f32, @floatFromInt(offset.y)) };
        }
        try gpu.renderTexturedQuad(visual.texture, corners, .{
            .{ 0, previous_y / height }, .{ 1, previous_y / height },
            .{ 1, y / height },          .{ 0, y / height },
        }, .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 });
        previous_y = y;
        previous_row = current;
    }
    return true;
}
