const std = @import("std");
const box2d = @import("box2dnative.zig");
const vec = @import("vector.zig");

const shared = @import("shared.zig");
const time = @import("time.zig");

const conv = @import("conversion.zig");

pub const State = struct {
    pos: box2d.b2Vec2,
    rotAngle: f32,
};

pub fn createNonRotatingDynamicBodyDef(position: vec.Vec2) box2d.b2BodyDef {
    var bodyDef = createDynamicBodyDef(position);
    bodyDef.fixedRotation = true;
    return bodyDef;
}

pub fn createDynamicBodyDef(position: vec.Vec2) box2d.b2BodyDef {
    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_dynamicBody;
    bodyDef.position = vec.toBox2d(position);
    return bodyDef;
}

pub fn createStaticBodyDef(position: vec.Vec2) box2d.b2BodyDef {
    var bodyDef = createDynamicBodyDef(position);
    bodyDef.type = box2d.b2_staticBody;
    return bodyDef;
}

pub fn createBody(bodyDef: box2d.b2BodyDef) !box2d.b2BodyId {
    const resources = try shared.getResources();
    const worldId = resources.worldId;
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createPolygonShape(bodyId: box2d.b2BodyId, triangles: [][3]vec.IVec2, dimP: vec.IVec2, shapeDef: box2d.b2ShapeDef) ![]box2d.b2ShapeId {
    const polygons = try createPolygons(triangles, dimP);
    defer shared.allocator.free(polygons);
    var shapeIds = std.ArrayList(box2d.b2ShapeId).init(shared.allocator);

    for (polygons) |polygon| {
        const shapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);
        try shapeIds.append(shapeId);
    }

    return shapeIds.toOwnedSlice();
}

fn createPolygons(triangles: [][3]vec.IVec2, dimP: vec.IVec2) ![]box2d.b2Polygon {
    var polygons = std.ArrayList(box2d.b2Polygon).init(shared.allocator);

    for (triangles) |tri| {
        var triangle: [3]vec.IVec2 = undefined;
        triangle[0] = .{ .x = tri[0].x - @divFloor(dimP.x, 2), .y = tri[0].y - @divFloor(dimP.y, 2) };
        triangle[1] = .{ .x = tri[1].x - @divFloor(dimP.x, 2), .y = tri[1].y - @divFloor(dimP.y, 2) };
        triangle[2] = .{ .x = tri[2].x - @divFloor(dimP.x, 2), .y = tri[2].y - @divFloor(dimP.y, 2) };
        var verts: [3]box2d.b2Vec2 = undefined;
        verts[0] = conv.p2m(triangle[0]);
        verts[1] = conv.p2m(triangle[1]);
        verts[2] = conv.p2m(triangle[2]);

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

pub fn getInterpolatedState(maybeEarlierState: ?State, currentState: State) State {
    var interpolatedPosMeter = currentState.pos;
    var interpolatedRotationAngle = currentState.rotAngle;
    if (maybeEarlierState) |earlierState| {
        interpolatedPosMeter = box2d.b2Vec2{ .x = @floatCast(time.alpha * currentState.pos.x + (1 - time.alpha) * earlierState.pos.x), .y = @floatCast(time.alpha * currentState.pos.y + (1 - time.alpha) * earlierState.pos.y) };

        interpolatedRotationAngle = @floatCast(time.alpha * currentState.rotAngle + (1 - time.alpha) * earlierState.rotAngle);
    }

    return .{ .pos = interpolatedPosMeter, .rotAngle = interpolatedRotationAngle };
}

pub fn subtract(a: box2d.b2Vec2, b: box2d.b2Vec2) box2d.b2Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

pub fn add(a: box2d.b2Vec2, b: box2d.b2Vec2) box2d.b2Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
