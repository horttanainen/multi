const std = @import("std");

const box2d = @import("box2d.zig");

const allocator = @import("allocator.zig").allocator;

pub const Id = u64;

pub const ExhaustionPolicy = enum {
    return_null,
    recycle_oldest,
};

pub const Acquisition = struct {
    bodyId: box2d.c.b2BodyId,
    recycled: bool,
};

const BodyPool = struct {
    bodyIds: std.ArrayListUnmanaged(box2d.c.b2BodyId),
    availableIndices: std.ArrayListUnmanaged(usize),
    activeIndices: std.ArrayListUnmanaged(usize),
};

var bodyPools = std.AutoArrayHashMapUnmanaged(Id, BodyPool).empty;
var bodyToPool = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, Id).empty;
var nextPoolId: Id = 1;

fn validateBodyIds(bodyIds: []const box2d.c.b2BodyId) !void {
    if (bodyIds.len == 0) {
        std.log.err("pool.validateBodyIds: cannot add an empty body batch", .{});
        return error.EmptyBodyBatch;
    }

    for (bodyIds, 0..) |bodyId, index| {
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            std.log.err("pool.validateBodyIds: body at index {d} is invalid", .{index});
            return error.InvalidBody;
        }
        if (bodyToPool.contains(bodyId)) {
            std.log.err("pool.validateBodyIds: body at index {d} already belongs to a pool", .{index});
            return error.BodyAlreadyPooled;
        }

        for (bodyIds[0..index]) |previousBodyId| {
            if (!box2d.c.B2_ID_EQUALS(bodyId, previousBodyId)) continue;
            std.log.err("pool.validateBodyIds: body at index {d} is duplicated", .{index});
            return error.DuplicateBody;
        }
    }
}

fn deinitBodyPool(bodyPool: *BodyPool) void {
    bodyPool.bodyIds.deinit(allocator);
    bodyPool.availableIndices.deinit(allocator);
    bodyPool.activeIndices.deinit(allocator);
    bodyPool.* = undefined;
}

fn removeTrackedIndex(indices: *std.ArrayListUnmanaged(usize), bodyIndex: usize) bool {
    for (indices.items, 0..) |candidateIndex, index| {
        if (candidateIndex != bodyIndex) continue;
        _ = indices.orderedRemove(index);
        return true;
    }
    return false;
}

fn replaceTrackedIndex(indices: *std.ArrayListUnmanaged(usize), oldIndex: usize, newIndex: usize) bool {
    for (indices.items) |*candidateIndex| {
        if (candidateIndex.* != oldIndex) continue;
        candidateIndex.* = newIndex;
        return true;
    }
    return false;
}

pub fn create(bodyIds: []const box2d.c.b2BodyId) !Id {
    const poolId = nextPoolId;
    if (poolId == 0) {
        std.log.err("pool.create: pool ID space is exhausted", .{});
        return error.PoolIdExhausted;
    }

    try bodyPools.put(allocator, poolId, .{
        .bodyIds = .empty,
        .availableIndices = .empty,
        .activeIndices = .empty,
    });
    errdefer {
        const removed = bodyPools.fetchSwapRemove(poolId);
        if (removed != null) {
            var bodyPool = removed.?.value;
            deinitBodyPool(&bodyPool);
        }
    }

    try addBodies(poolId, bodyIds);
    nextPoolId +%= 1;
    return poolId;
}

pub fn addBodies(poolId: Id, bodyIds: []const box2d.c.b2BodyId) !void {
    try validateBodyIds(bodyIds);

    const bodyPool = bodyPools.getPtr(poolId) orelse {
        std.log.err("pool.addBodies: pool {d} is missing", .{poolId});
        return error.BodyPoolNotFound;
    };
    const oldBodyCount = bodyPool.bodyIds.items.len;
    const newBodyCount = try std.math.add(usize, oldBodyCount, bodyIds.len);

    try bodyPool.bodyIds.ensureTotalCapacity(allocator, newBodyCount);
    try bodyPool.availableIndices.ensureTotalCapacity(allocator, newBodyCount);
    try bodyPool.activeIndices.ensureTotalCapacity(allocator, newBodyCount);
    try bodyToPool.ensureUnusedCapacity(allocator, bodyIds.len);

    bodyPool.bodyIds.appendSliceAssumeCapacity(bodyIds);
    for (bodyIds) |bodyId| {
        bodyToPool.putAssumeCapacityNoClobber(bodyId, poolId);
    }

    var index = newBodyCount;
    while (index > oldBodyCount) {
        index -= 1;
        bodyPool.availableIndices.appendAssumeCapacity(index);
    }
}

pub fn bodyCount(poolId: Id) !usize {
    const bodyPool = bodyPools.get(poolId) orelse {
        std.log.err("pool.bodyCount: pool {d} is missing", .{poolId});
        return error.BodyPoolNotFound;
    };
    return bodyPool.bodyIds.items.len;
}

fn discardInvalidBody(poolId: Id, bodyId: box2d.c.b2BodyId) !void {
    std.log.warn("pool.acquire: discarding invalid body from pool {d}", .{poolId});
    if (!discardBody(bodyId)) {
        std.log.err("pool.acquire: invalid body in pool {d} has no reverse membership", .{poolId});
        return error.BodyPoolMembershipCorrupt;
    }
}

pub fn acquire(poolId: Id, exhaustionPolicy: ExhaustionPolicy) !?Acquisition {
    const bodyPool = bodyPools.getPtr(poolId) orelse {
        std.log.err("pool.acquire: pool {d} is missing", .{poolId});
        return error.BodyPoolNotFound;
    };

    while (bodyPool.availableIndices.items.len > 0) {
        const availableIndex = bodyPool.availableIndices.getLast();
        const bodyId = bodyPool.bodyIds.items[availableIndex];
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            try discardInvalidBody(poolId, bodyId);
            continue;
        }

        _ = bodyPool.availableIndices.pop();
        bodyPool.activeIndices.appendAssumeCapacity(availableIndex);
        return .{
            .bodyId = bodyId,
            .recycled = false,
        };
    }
    if (exhaustionPolicy == .return_null) return null;

    while (bodyPool.activeIndices.items.len > 0) {
        const recycledIndex = bodyPool.activeIndices.items[0];
        const bodyId = bodyPool.bodyIds.items[recycledIndex];
        if (!box2d.c.b2Body_IsValid(bodyId)) {
            try discardInvalidBody(poolId, bodyId);
            continue;
        }

        _ = bodyPool.activeIndices.orderedRemove(0);
        bodyPool.activeIndices.appendAssumeCapacity(recycledIndex);
        return .{
            .bodyId = bodyId,
            .recycled = true,
        };
    }
    return null;
}

pub fn release(poolId: Id, bodyId: box2d.c.b2BodyId) !void {
    const registeredPoolId = bodyToPool.get(bodyId) orelse {
        std.log.err("pool.release: body is not registered with a pool", .{});
        return error.BodyNotInPool;
    };
    if (registeredPoolId != poolId) {
        std.log.err("pool.release: body belongs to pool {d}, not pool {d}", .{ registeredPoolId, poolId });
        return error.BodyInDifferentPool;
    }

    const bodyPool = bodyPools.getPtr(poolId) orelse {
        std.log.err("pool.release: pool {d} is missing", .{poolId});
        return error.BodyPoolNotFound;
    };
    var bodyIndex: ?usize = null;
    for (bodyPool.bodyIds.items, 0..) |candidateBodyId, index| {
        if (!box2d.c.B2_ID_EQUALS(bodyId, candidateBodyId)) continue;
        bodyIndex = index;
        break;
    }
    if (bodyIndex == null) {
        std.log.err("pool.release: body map and pool {d} disagree", .{poolId});
        return error.BodyNotInPool;
    }
    if (!removeTrackedIndex(&bodyPool.activeIndices, bodyIndex.?)) {
        std.log.err("pool.release: body in pool {d} is not active", .{poolId});
        return error.BodyNotActive;
    }

    bodyPool.availableIndices.appendAssumeCapacity(bodyIndex.?);
}

// Removes a body before its owner destroys it. Returns false for non-pooled bodies.
pub fn discardBody(bodyId: box2d.c.b2BodyId) bool {
    const removedMembership = bodyToPool.fetchSwapRemove(bodyId) orelse return false;
    const poolId = removedMembership.value;
    const bodyPool = bodyPools.getPtr(poolId) orelse {
        std.log.err("pool.discardBody: pool {d} is missing for registered body", .{poolId});
        return true;
    };

    var bodyIndex: ?usize = null;
    for (bodyPool.bodyIds.items, 0..) |candidateBodyId, index| {
        if (!box2d.c.B2_ID_EQUALS(bodyId, candidateBodyId)) continue;
        bodyIndex = index;
        break;
    }
    if (bodyIndex == null) {
        std.log.err("pool.discardBody: body map and pool {d} disagree", .{poolId});
        return true;
    }

    const removedAvailable = removeTrackedIndex(&bodyPool.availableIndices, bodyIndex.?);
    const removedActive = removeTrackedIndex(&bodyPool.activeIndices, bodyIndex.?);
    if (removedAvailable == removedActive) {
        std.log.err("pool.discardBody: body in pool {d} has invalid availability state", .{poolId});
    }

    const oldLastIndex = bodyPool.bodyIds.items.len - 1;
    _ = bodyPool.bodyIds.swapRemove(bodyIndex.?);
    if (bodyIndex.? == oldLastIndex) return true;

    const replacedAvailable = replaceTrackedIndex(&bodyPool.availableIndices, oldLastIndex, bodyIndex.?);
    const replacedActive = replaceTrackedIndex(&bodyPool.activeIndices, oldLastIndex, bodyIndex.?);
    if (replacedAvailable == replacedActive) {
        std.log.err("pool.discardBody: moved body in pool {d} has invalid availability state", .{poolId});
    }
    return true;
}

// Removes a pool and transfers its allocated body ID slice to the caller.
pub fn takeBodyIds(poolId: Id) ![]box2d.c.b2BodyId {
    const removed = bodyPools.fetchSwapRemove(poolId) orelse {
        std.log.err("pool.takeBodyIds: pool {d} is missing", .{poolId});
        return error.BodyPoolNotFound;
    };

    var bodyPool = removed.value;
    for (bodyPool.bodyIds.items) |bodyId| {
        const removedMembership = bodyToPool.fetchSwapRemove(bodyId);
        if (removedMembership != null) continue;
        std.log.err("pool.takeBodyIds: body in pool {d} has no reverse membership", .{poolId});
    }
    bodyPool.availableIndices.deinit(allocator);
    bodyPool.activeIndices.deinit(allocator);
    return bodyPool.bodyIds.toOwnedSlice(allocator) catch |err| {
        std.log.err("pool.takeBodyIds: could not transfer body IDs for pool {d}: {}", .{ poolId, err });
        bodyPool.bodyIds.deinit(allocator);
        return err;
    };
}

pub fn cleanup() void {
    if (bodyPools.count() != 0) {
        std.log.warn("pool.cleanup: {d} body pools were not released by their owners", .{bodyPools.count()});
    }

    for (bodyPools.values()) |*bodyPool| {
        deinitBodyPool(bodyPool);
    }
    bodyPools.deinit(allocator);
    bodyToPool.deinit(allocator);
    bodyPools = .empty;
    bodyToPool = .empty;
    nextPoolId = 1;
}
