const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const damage = @import("damage.zig");
const entity = @import("entity.zig");
const pool = @import("pool.zig");
const particle_effect = @import("particle_effect.zig");
const rubble = @import("rubble.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");

const SurfaceEdit = struct {
    spriteUuid: u64,
    dirtyRect: vec.IRect,
};

const surfaceTextureUpdatesPerFrame: usize = 2;
const surfaceColliderUpdatesPerFrame: usize = 1;

var surfaceEdits = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, SurfaceEdit).empty;
var surfaceTextureUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, SurfaceEdit).empty;
var surfaceColliderUpdates = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, vec.IRect).empty;

pub fn pendingSurfaceTextureUpdateCount() usize {
    return surfaceTextureUpdates.count();
}

pub fn pendingSurfaceColliderUpdateCount() usize {
    return surfaceColliderUpdates.count();
}

fn queueSurfaceEdit(bodyId: box2d.c.b2BodyId, spriteUuid: u64, dirtyRect: vec.IRect) !void {
    const maybeEdit = surfaceEdits.getPtr(bodyId);
    if (maybeEdit == null) {
        try surfaceEdits.put(allocator, bodyId, .{
            .spriteUuid = spriteUuid,
            .dirtyRect = dirtyRect,
        });
        return;
    }

    const edit = maybeEdit.?;
    edit.dirtyRect = vec.irectUnion(edit.dirtyRect, dirtyRect);
}

fn queueSurfaceColliderUpdate(bodyId: box2d.c.b2BodyId, dirtyRect: vec.IRect) !void {
    const maybeDirtyRect = surfaceColliderUpdates.getPtr(bodyId);
    if (maybeDirtyRect == null) {
        try surfaceColliderUpdates.put(allocator, bodyId, dirtyRect);
        return;
    }

    const dirtyRectPtr = maybeDirtyRect.?;
    dirtyRectPtr.* = vec.irectUnion(dirtyRectPtr.*, dirtyRect);
}

fn queueSurfaceTextureUpdate(bodyId: box2d.c.b2BodyId, edit: SurfaceEdit) !void {
    const maybeEdit = surfaceTextureUpdates.getPtr(bodyId);
    if (maybeEdit == null) {
        try surfaceTextureUpdates.put(allocator, bodyId, edit);
        return;
    }

    const pendingEdit = maybeEdit.?;
    pendingEdit.dirtyRect = vec.irectUnion(pendingEdit.dirtyRect, edit.dirtyRect);
}

pub fn flushSurfaceEdits() !void {
    if (surfaceEdits.count() == 0) return;
    defer surfaceEdits.clearRetainingCapacity();

    for (surfaceEdits.keys(), surfaceEdits.values()) |bodyId, edit| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("destruction.flushSurfaceEdits: body became invalid before flush", .{});
            continue;
        }

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("destruction.flushSurfaceEdits: entity missing before flush", .{});
            continue;
        };
        if (ent.spriteUuids.len == 0) {
            std.log.warn("destruction.flushSurfaceEdits: entity has no sprites", .{});
            continue;
        }

        try queueSurfaceTextureUpdate(bodyId, edit);
    }
}

fn emitDestructionEffect(
    effect: damage.DestructionEffect,
    bodyId: box2d.c.b2BodyId,
    position: vec.Vec2,
    direction: vec.Vec2,
    inheritedVelocity: vec.Vec2,
    debrisVelocity: vec.Vec2,
) void {
    switch (effect) {
        .none => {},
        .particle_burst => |particleBurst| {
            particle_effect.emit(particleBurst.effectId, .{
                .position = position,
                .amount = particleBurst.amount,
                .direction = if (vec.magnitude(direction) < 0.001) null else direction,
                .spread_radians = particleBurst.spreadRadians,
                .inherited_velocity = inheritedVelocity,
                .inherited_velocity_scale = particleBurst.inheritedVelocityScale,
                .color = particleBurst.color,
            }) catch |err| {
                std.log.err("destruction.emitDestructionEffect: could not emit particle burst: {}", .{err});
            };
        },
        .spawn_rubble => |templateId| rubble.activate(templateId, bodyId, direction, debrisVelocity) catch |err| {
            std.log.err("destruction.emitDestructionEffect: could not activate rubble template {d}: {}", .{ templateId, err });
        },
    }
}

fn deactivatePooledBody(bodyId: box2d.c.b2BodyId) void {
    const ent = entity.entities.getPtrLocking(bodyId) orelse {
        std.log.err("destruction.deactivatePooledBody: pooled body has no entity", .{});
        _ = damage.unregister(bodyId);
        _ = pool.discardBody(bodyId);
        box2d.c.b2DestroyBody(bodyId);
        return;
    };

    box2d.c.b2Body_Disable(bodyId);
    ent.enabled = false;
    pool.queueRelease(bodyId);
}

fn destroy(bodyId: box2d.c.b2BodyId, event: damage.Event, response: damage.DestructionResponse) void {
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("destruction.destroy: body became invalid before destruction", .{});
        return;
    }

    const ent = entity.entities.getLocking(bodyId) orelse {
        std.log.warn("destruction.destroy: body has no entity", .{});
        return;
    };
    const bodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId));
    const inheritedVelocity = if (box2d.c.b2Body_GetType(bodyId) == box2d.c.b2_dynamicBody)
        vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(bodyId))
    else
        vec.zero;

    emitDestructionEffect(response.effect, bodyId, bodyPosition, event.direction, inheritedVelocity, event.debrisVelocity);

    if (response.lifecycle == .return_to_pool) {
        deactivatePooledBody(bodyId);
        return;
    }

    _ = pool.discardBody(bodyId);
    entity.cleanupLater(ent);
}

fn cutSurface(bodyId: box2d.c.b2BodyId, event: damage.Event, surfaceCutout: damage.SurfaceCutout) !void {
    if (!box2d.c.b2Body_IsValid(bodyId)) {
        std.log.warn("destruction.cutSurface: body became invalid before surface damage", .{});
        return;
    }

    const ent = entity.entities.getPtrLocking(bodyId) orelse {
        std.log.warn("destruction.cutSurface: body has no entity", .{});
        return;
    };
    if (ent.spriteUuids.len == 0) {
        std.log.warn("destruction.cutSurface: entity has no sprites", .{});
        return;
    }

    const firstSprite = sprite.getSprite(ent.spriteUuids[0]) orelse {
        std.log.warn("destruction.cutSurface: sprite {d} not found", .{ent.spriteUuids[0]});
        return;
    };
    const state = box2d.getState(bodyId);
    const radius = @max(surfaceCutout.minimumRadius, event.radius * surfaceCutout.radiusScale);
    const dirtyRect = try sprite.removeCircleFromSurface(
        firstSprite,
        event.position,
        radius,
        vec.fromBox2d(state.pos),
        state.rotAngle,
    );
    if (dirtyRect == null) return;

    try queueSurfaceEdit(bodyId, ent.spriteUuids[0], dirtyRect.?);
}

pub fn apply(bodyId: box2d.c.b2BodyId, event: damage.Event) !void {
    switch (damage.apply(bodyId, event)) {
        .ignored, .damaged => {},
        .surface_cutout => |surfaceCutout| try cutSurface(bodyId, event, surfaceCutout),
        .destroyed => |response| destroy(bodyId, event, response),
    }
}

pub fn processSurfaceTextureUpdates() void {
    var processed: usize = 0;
    while (processed < surfaceTextureUpdatesPerFrame and surfaceTextureUpdates.count() > 0) : (processed += 1) {
        const bodyId = surfaceTextureUpdates.keys()[0];
        const edit = surfaceTextureUpdates.values()[0];
        _ = surfaceTextureUpdates.swapRemove(bodyId);

        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("destruction.processSurfaceTextureUpdates: body became invalid before texture update", .{});
            continue;
        }

        sprite.updateTextureGeometryRegionFromSurface(edit.spriteUuid, edit.dirtyRect) catch |err| {
            std.log.warn("destruction.processSurfaceTextureUpdates: texture update failed with {}", .{err});
        };
        queueSurfaceColliderUpdate(bodyId, edit.dirtyRect) catch |err| {
            std.log.warn("destruction.processSurfaceTextureUpdates: failed to queue collider update with {}", .{err});
        };
    }
}

pub fn processSurfaceColliderUpdates() void {
    var processed: usize = 0;
    while (processed < surfaceColliderUpdatesPerFrame and surfaceColliderUpdates.count() > 0) : (processed += 1) {
        const bodyId = surfaceColliderUpdates.keys()[0];
        const dirtyRect = surfaceColliderUpdates.values()[0];
        _ = surfaceColliderUpdates.swapRemove(bodyId);

        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.warn("destruction.processSurfaceColliderUpdates: body became invalid before collider rebuild", .{});
            continue;
        }

        const ent = entity.entities.getPtrLocking(bodyId) orelse {
            std.log.warn("destruction.processSurfaceColliderUpdates: entity missing before collider rebuild", .{});
            continue;
        };
        const stillExists = entity.regenerateCollidersInPixelRect(ent, dirtyRect) catch |err| {
            std.log.warn("destruction.processSurfaceColliderUpdates: collider rebuild failed with {}", .{err});
            continue;
        };
        if (stillExists) continue;

        const response = damage.markDestroyed(bodyId) orelse continue;
        destroy(bodyId, .{
            .source = .explosion,
            .amount = 0,
            .position = vec.fromBox2d(box2d.c.b2Body_GetPosition(bodyId)),
        }, response);
    }
}

pub fn cleanup() void {
    surfaceEdits.clearAndFree(allocator);
    surfaceTextureUpdates.clearAndFree(allocator);
    surfaceColliderUpdates.clearAndFree(allocator);
}
