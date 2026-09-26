const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const character_art = @import("character_art.zig");
const damage = @import("damage.zig");
const destruction = @import("destruction.zig");
const gibbing = @import("gibbing.zig");
const pool = @import("pool.zig");
const runtime = @import("runtime.zig");
const vec = @import("vector.zig");

pub const Corpse = struct {
    snapshot: gibbing.Snapshot,
    bodies: [64]box2d.c.b2BodyId = undefined,
    body_count: usize = 0,
    joints: [63]box2d.c.b2JointId = undefined,
    joint_count: usize = 0,
    collision_group: i32,
};

// The root body owns shared health in damage.components. Limb shared_health
// entries provide the body-to-corpse lookup without a second health registry.
// Preserve insertion order so the limit always retires the oldest whole corpse.
pub var corpses = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, Corpse).empty;

pub fn prepareCapacity() !void {
    try corpses.ensureTotalCapacity(allocator, damage.rules.maximumRagdolls + 1);
}

fn releaseJoints(corpse: *const Corpse) void {
    for (corpse.joints[0..corpse.joint_count]) |joint| {
        if (!box2d.c.b2Joint_IsValid(joint)) continue;
        box2d.c.b2DestroyJoint(joint);
    }
}

fn releaseBodies(corpse: *const Corpse) void {
    releaseJoints(corpse);
    for (corpse.bodies[0..corpse.body_count]) |body| {
        gibbing.releasePart(body);
    }
}

fn retireOldest() void {
    const oldest = corpses.values()[0];
    const root = corpses.keys()[0];
    _ = corpses.orderedRemove(root);
    releaseBodies(&oldest);
}

fn availableCollisionGroup() i32 {
    var group: i32 = -1;
    search: while (true) : (group -= 1) {
        for (corpses.values()) |corpse| {
            if (corpse.collision_group == group) continue :search;
        }
        return group;
    }
}

fn sourceAngle(pack: *const character_art.Pack, part: gibbing.PartSnapshot) f32 {
    const definition = pack.parts[part.placed.part].definition;
    const sign: f32 = if (part.placed.facing_right) 1 else -1;
    return std.math.atan2(
        definition.axis_end[1] - definition.pivot[1],
        (definition.axis_end[0] - definition.pivot[0]) * sign,
    );
}

pub fn create(snapshot: gibbing.Snapshot, pack: *const character_art.Pack) !?box2d.c.b2BodyId {
    var root_index: ?usize = null;
    var by_binding: [64]usize = undefined;
    if (snapshot.count != pack.bindings.len or snapshot.count == 0) {
        std.log.err("ragdoll.create: incomplete anatomical snapshot", .{});
        return error.IncompleteRagdollSnapshot;
    }
    var roots: usize = 0;
    for (snapshot.parts[0..snapshot.count], 0..) |part, index| {
        by_binding[part.binding] = index;
        if (pack.bindings[part.binding].ragdoll != null) continue;
        root_index = index;
        roots += 1;
    }
    if (roots == snapshot.count) return null; // Legacy art without a ragdoll graph.
    if (roots != 1) {
        std.log.err("ragdoll.create: expected one anatomical root", .{});
        return error.InvalidRagdollGraph;
    }
    try corpses.ensureUnusedCapacity(allocator, 1);
    while (corpses.count() >= damage.rules.maximumRagdolls) retireOldest();

    var corpse: Corpse = .{ .snapshot = snapshot, .collision_group = availableCollisionGroup() };
    errdefer releaseBodies(&corpse);
    for (snapshot.parts[0..snapshot.count]) |part| {
        const body = try gibbing.activatePart(part, vec.zero, 0);
        corpse.bodies[corpse.body_count] = body;
        corpse.body_count += 1;
        pool.memberships.getPtr(body).?.reserved = true;
        character_art.bodyParts.getPtr(body).?.severed = false;
        gibbing.setCollisionGroup(body, corpse.collision_group);
    }
    const root = corpse.bodies[root_index.?];
    const facing_sign: f32 = if (snapshot.parts[root_index.?].placed.facing_right) 1 else -1;
    for (snapshot.parts[0..snapshot.count], 0..) |part, index| {
        const definition = pack.bindings[part.binding].ragdoll orelse continue;
        const parent_index = by_binding[definition.parent];
        const parent = snapshot.parts[parent_index];
        var joint = box2d.c.b2DefaultRevoluteJointDef();
        joint.bodyIdA = corpse.bodies[parent_index];
        joint.bodyIdB = corpse.bodies[index];
        const anchor = vec.toBox2d(part.placed.position);
        joint.localAnchorA = box2d.c.b2Body_GetLocalPoint(joint.bodyIdA, anchor);
        joint.localAnchorB = box2d.c.b2Body_GetLocalPoint(joint.bodyIdB, anchor);
        const reference = sourceAngle(pack, parent) - sourceAngle(pack, part) +
            definition.reference_angle * facing_sign;
        joint.referenceAngle = std.math.atan2(@sin(reference), @cos(reference));
        joint.enableLimit = true;
        joint.lowerAngle = @min(definition.limits[0] * facing_sign, definition.limits[1] * facing_sign);
        joint.upperAngle = @max(definition.limits[0] * facing_sign, definition.limits[1] * facing_sign);
        joint.collideConnected = false;
        const created = box2d.createRevoluteJoint(&joint);
        if (!box2d.c.b2Joint_IsValid(created)) {
            std.log.err("ragdoll.create: failed to create anatomical hinge", .{});
            return error.RagdollJointCreationFailed;
        }
        corpse.joints[corpse.joint_count] = created;
        corpse.joint_count += 1;
    }
    for (corpse.bodies[0..corpse.body_count]) |body| {
        const component = damage.components.getPtr(body).?;
        component.model = if (box2d.c.B2_ID_EQUALS(body, root))
            .{ .health = .{ .current = damage.rules.ragdollHealth, .maximum = damage.rules.ragdollHealth } }
        else
            .{ .shared_health = root };
        component.destructionLifecycle = .ragdoll;
    }
    corpses.putAssumeCapacityNoClobber(root, corpse);
    return root;
}

pub fn createForPlayer(player_id: usize) !void {
    const snapshot = gibbing.snapshotPlayer(player_id) orelse return;
    _ = try create(snapshot, &character_art.assets.?);
}

pub fn destroy(body: box2d.c.b2BodyId, event: damage.Event) void {
    const root = damage.healthOwner(body);
    const component = damage.components.get(root) orelse {
        std.log.err("ragdoll.destroy: shared health owner is missing", .{});
        return;
    };
    const removed = corpses.fetchOrderedRemove(root) orelse {
        std.log.err("ragdoll.destroy: corpse is missing", .{});
        return;
    };
    const corpse = removed.value;
    const gibbed = component.model.health.current <= damage.rules.gibHealthThreshold;
    const selected = if (gibbed)
        gibbing.selectSurvivors(corpse.snapshot, runtime.random())
    else
        [_]bool{false} ** 64;
    releaseJoints(&corpse);
    for (corpse.bodies[0..corpse.body_count], selected[0..corpse.body_count]) |part, survives| {
        gibbing.resetPartDamage(part);
        pool.memberships.getPtr(part).?.reserved = false;
        gibbing.setCollisionGroup(part, 0);
        if (survives) {
            character_art.bodyParts.getPtr(part).?.severed = true;
            continue;
        }
        var response = damage.markDestroyed(part).?;
        switch (response.effect) {
            .particle_burst => |*burst| {
                // One corpse-wide burst distributed across the current limbs.
                // Gibbing uses the same consumed-part amount as a living death.
                burst.amount = if (gibbed)
                    gibbing.consumedPartBloodAmount
                else
                    burst.amount / @as(f32, @floatFromInt(corpse.body_count));
            },
            else => {},
        }
        destruction.destroy(part, event, response);
    }
}

pub fn cleanup() void {
    for (corpses.values()) |*corpse| releaseBodies(corpse);
    corpses.clearAndFree(allocator);
}
