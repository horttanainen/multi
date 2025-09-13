// In C, you would only import the headers you need.
// This is a binding, so ALL of the headers are included
pub const c = @cImport({
    // Many of these are unnessesary. They are all here since it was easiest to just
    // add all of them without thinking about which ones are actually needed
    @cInclude("box2d/base.h");
    @cInclude("box2d/box2d.h");
    @cInclude("box2d/collision.h");
    @cInclude("box2d/id.h");
    @cInclude("box2d/math_functions.h");
    @cInclude("box2d/types.h");
});

const std = @import("std");
const vec = @import("vector.zig");

const shared = @import("shared.zig");
const time = @import("time.zig");

const conv = @import("conversion.zig");

pub const State = struct {
    pos: c.b2Vec2,
    rotAngle: f32,
};

pub fn createNonRotatingDynamicBodyDef(position: vec.Vec2) c.b2BodyDef {
    var bodyDef = createDynamicBodyDef(position);
    bodyDef.fixedRotation = true;
    return bodyDef;
}

pub fn createDynamicBodyDef(position: vec.Vec2) c.b2BodyDef {
    var bodyDef = c.b2DefaultBodyDef();
    bodyDef.type = c.b2_dynamicBody;
    bodyDef.position = vec.toBox2d(position);
    return bodyDef;
}

pub fn createStaticBodyDef(position: vec.Vec2) c.b2BodyDef {
    var bodyDef = createDynamicBodyDef(position);
    bodyDef.type = c.b2_staticBody;
    return bodyDef;
}

pub fn createBody(bodyDef: c.b2BodyDef) !c.b2BodyId {
    const resources = try shared.getResources();
    const worldId = resources.worldId;
    const bodyId = c.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createPolygonShape(bodyId: c.b2BodyId, triangles: [][3]vec.IVec2, dimP: vec.IVec2, shapeDef: c.b2ShapeDef) ![]c.b2ShapeId {
    const polygons = try createPolygons(triangles, dimP);
    defer shared.allocator.free(polygons);
    var shapeIds = std.array_list.Managed(c.b2ShapeId).init(shared.allocator);

    for (polygons) |polygon| {
        const shapeId = c.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);
        try shapeIds.append(shapeId);
    }

    return shapeIds.toOwnedSlice();
}

fn createPolygons(triangles: [][3]vec.IVec2, dimP: vec.IVec2) ![]c.b2Polygon {
    var polygons = std.array_list.Managed(c.b2Polygon).init(shared.allocator);

    for (triangles) |tri| {
        var triangle: [3]vec.IVec2 = undefined;
        triangle[0] = .{ .x = tri[0].x - @divFloor(dimP.x, 2), .y = tri[0].y - @divFloor(dimP.y, 2) };
        triangle[1] = .{ .x = tri[1].x - @divFloor(dimP.x, 2), .y = tri[1].y - @divFloor(dimP.y, 2) };
        triangle[2] = .{ .x = tri[2].x - @divFloor(dimP.x, 2), .y = tri[2].y - @divFloor(dimP.y, 2) };
        var verts: [3]c.b2Vec2 = undefined;
        verts[0] = conv.p2m(triangle[0]);
        verts[1] = conv.p2m(triangle[1]);
        verts[2] = conv.p2m(triangle[2]);

        const hull = c.b2ComputeHull(&verts[0], 3);

        const poly: c.b2Polygon = c.b2MakePolygon(&hull, 0.01);

        try polygons.append(poly);
    }

    return polygons.toOwnedSlice();
}

pub fn getState(bodyId: c.b2BodyId) State {
    const position = c.b2Body_GetPosition(bodyId);
    const rotationAngle = c.b2Rot_GetAngle(c.b2Body_GetRotation(bodyId));

    return .{ .pos = position, .rotAngle = rotationAngle };
}

pub fn getInterpolatedState(maybeEarlierState: ?State, currentState: State) State {
    var interpolatedPosMeter = currentState.pos;
    var interpolatedRotationAngle = currentState.rotAngle;
    if (maybeEarlierState) |earlierState| {
        interpolatedPosMeter = c.b2Vec2{ .x = @floatCast(time.alpha * currentState.pos.x + (1 - time.alpha) * earlierState.pos.x), .y = @floatCast(time.alpha * currentState.pos.y + (1 - time.alpha) * earlierState.pos.y) };

        interpolatedRotationAngle = @floatCast(time.alpha * currentState.rotAngle + (1 - time.alpha) * earlierState.rotAngle);
    }

    return .{ .pos = interpolatedPosMeter, .rotAngle = interpolatedRotationAngle };
}

pub fn subtract(a: c.b2Vec2, b: c.b2Vec2) c.b2Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

pub fn add(a: c.b2Vec2, b: c.b2Vec2) c.b2Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

pub fn mul(a: c.b2Vec2, b: f32) c.b2Vec2 {
    return .{ .x = a.x * b, .y = a.y * b };
}
