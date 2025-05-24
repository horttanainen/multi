const std = @import("std");
const image = @import("zsdl_image");
const box2d = @import("box2dnative.zig");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const conv = @import("conversion.zig");
const box = @import("box.zig");
const vec = @import("vector.zig");

var maybeSelectedBodyId: ?box2d.b2BodyId = null;

var maybeCopiedBodyId: ?box2d.b2BodyId = null;

pub fn copySelection() void {
    maybeCopiedBodyId = maybeSelectedBodyId;
}

pub fn pasteSelection(pos: vec.IVec2) !void {
    if (maybeCopiedBodyId) |copiedBodyId| {
        const maybeE = entity.getEntity(copiedBodyId);
        if (maybeE) |e| {
            var bodyDef = box.createDynamicBodyDef(pos);
            bodyDef.type = box2d.b2Body_GetType(e.bodyId);
            var shapeDef = box2d.b2DefaultShapeDef();

            var shapes: [1]box2d.b2ShapeId = undefined;
            _ = box2d.b2Body_GetShapes(copiedBodyId, &shapes, 1);
            shapeDef.friction = box2d.b2Shape_GetFriction(shapes[0]);

            try entity.createFromImg(e.sprite.surface, shapeDef, bodyDef);
        }
    }
}

pub fn selectEntityAt(pos: vec.IVec2) !void {
    const posM = conv.p2m(pos);
    const aabb = box2d.b2AABB{
        .lowerBound = box.subtract(posM, .{ .x = 0.1, .y = 0.1 }),
        .upperBound = box.add(posM, .{ .x = 0.1, .y = 0.1 }),
    };
    const resources = try shared.getResources();

    const filter = box2d.b2DefaultQueryFilter();
    _ = box2d.b2World_OverlapAABB(resources.worldId, aabb, filter, &overlapAABBCallback, null);
}

pub fn overlapAABBCallback(shapeId: box2d.b2ShapeId, context: ?*anyopaque) callconv(.C) bool {
    _ = context;

    const bodyId = box2d.b2Shape_GetBody(shapeId);

    if (maybeSelectedBodyId) |selectedBodyId| {
        const maybeE1 = entity.getEntity(selectedBodyId);
        if (maybeE1) |e| {
            e.highlighted = false;
        }

        const maybeE2 = entity.getEntity(bodyId);
        if (maybeE2) |e| {
            e.highlighted = true;
        }
    } else {
        const maybeE = entity.getEntity(bodyId);
        if (maybeE) |e| {
            e.highlighted = true;
        }
    }

    maybeSelectedBodyId = bodyId;
    // immediately stop searching for additional shapeIds
    return false;
}
