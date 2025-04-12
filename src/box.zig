const std = @import("std");
const box2d = @import("box2dnative.zig");
const IVec2 = @import("vector.zig").IVec2;

const entity = @import("entity.zig");
const Entity = entity.Entity;

const player = @import("player.zig");

const shared = @import("shared.zig");

const p2m = @import("conversion.zig").p2m;
const m2P = @import("conversion.zig").m2P;

pub const State = struct {
    pos: box2d.b2Vec2,
    rotAngle: f32,
};

pub fn createNonRotatingDynamicBody(position: IVec2) !box2d.b2BodyId {
    const resources = try shared.getResources();
    const worldId = resources.worldId;
    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_dynamicBody;
    bodyDef.position = p2m(position);
    bodyDef.fixedRotation = true;
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createDynamicBody(position: IVec2) !box2d.b2BodyId {
    const resources = try shared.getResources();
    const worldId = resources.worldId;
    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_dynamicBody;
    bodyDef.position = p2m(position);
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createStaticBody(position: IVec2) !box2d.b2BodyId {
    const resources = try shared.getResources();
    const worldId = resources.worldId;
    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_staticBody;
    bodyDef.position = p2m(position);
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createPolygonShape(bodyId: box2d.b2BodyId, triangles: [][3]IVec2, dimP: IVec2, shapeDef: box2d.b2ShapeDef) ![]box2d.b2ShapeId {
    const polygons = try createPolygons(triangles, dimP);
    defer shared.allocator.free(polygons);
    var shapeIds = std.ArrayList(box2d.b2ShapeId).init(shared.allocator);

    for (polygons) |polygon| {
        const shapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);
        try shapeIds.append(shapeId);
    }

    return shapeIds.toOwnedSlice();
}

fn createPolygons(triangles: [][3]IVec2, dimP: IVec2) ![]box2d.b2Polygon {
    var polygons = std.ArrayList(box2d.b2Polygon).init(shared.allocator);

    for (triangles) |tri| {
        var triangle: [3]IVec2 = undefined;
        triangle[0] = .{ .x = tri[0].x - @divFloor(dimP.x, 2), .y = tri[0].y - @divFloor(dimP.y, 2) };
        triangle[1] = .{ .x = tri[1].x - @divFloor(dimP.x, 2), .y = tri[1].y - @divFloor(dimP.y, 2) };
        triangle[2] = .{ .x = tri[2].x - @divFloor(dimP.x, 2), .y = tri[2].y - @divFloor(dimP.y, 2) };
        var verts: [3]box2d.b2Vec2 = undefined;
        verts[0] = p2m(triangle[0]);
        verts[1] = p2m(triangle[1]);
        verts[2] = p2m(triangle[2]);

        const hull = box2d.b2ComputeHull(&verts[0], 3);

        const poly: box2d.b2Polygon = box2d.b2MakePolygon(&hull, 0.01);

        try polygons.append(poly);
    }

    return polygons.toOwnedSlice();
}

pub fn getState(bodyId: box2d.b2BodyId) State {
    const position = box2d.b2Body_GetPosition(bodyId);
    const rotationAngle = box2d.b2Rot_GetAngle(box2d.b2Body_GetRotation(bodyId));

    return .{ .pos = position, .rotAngle = rotationAngle };
}

pub fn updateStates() void {
    for (entity.entities.values()) |*e| {
        e.state = getState(e.bodyId);
    }
    if (player.player) |*p| {
        p.entity.state = getState(p.entity.bodyId);
    }
}
