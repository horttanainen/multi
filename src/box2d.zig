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

const time = @import("time.zig");

const conv = @import("conversion.zig");
const allocator = @import("allocator.zig").allocator;

var world_id: ?c.b2WorldId = null;

fn getWorldId() c.b2WorldId {
    return world_id orelse @panic("box2d: world not initialized");
}

pub fn initWorld() void {
    const gravity = c.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = c.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    world_id = c.b2CreateWorld(&worldDef);
}

pub fn destroyWorld() void {
    if (world_id) |wid| {
        c.b2DestroyWorld(wid);
        world_id = null;
    }
}

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
    const worldId = getWorldId();
    const bodyId = c.b2CreateBody(worldId, &bodyDef);
    return bodyId;
}

pub fn createPolygonShape(bodyId: c.b2BodyId, triangles: [][3]vec.IVec2, dimP: vec.IVec2, shapeDef: c.b2ShapeDef) ![]c.b2ShapeId {
    const polygons = try createPolygons(triangles, dimP);
    defer allocator.free(polygons);
    var shapeIds = std.array_list.Managed(c.b2ShapeId).init(allocator);

    for (polygons) |polygon| {
        const shapeId = c.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);
        try shapeIds.append(shapeId);
    }

    return shapeIds.toOwnedSlice();
}

fn createPolygons(triangles: [][3]vec.IVec2, dimP: vec.IVec2) ![]c.b2Polygon {
    var polygons = std.array_list.Managed(c.b2Polygon).init(allocator);

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

        if (hull.count < 3 or !c.b2ValidateHull(&hull)) {
            std.debug.print("box2d: skipping degenerate triangle ({d},{d}) ({d},{d}) ({d},{d})\n", .{
                verts[0].x, verts[0].y,
                verts[1].x, verts[1].y,
                verts[2].x, verts[2].y,
            });
            continue;
        }

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

// ============================================================
// World-level wrappers (hide worldId)
// ============================================================

pub fn worldStep(dt: f32, subStepCount: c_int) void {
    c.b2World_Step(getWorldId(), dt, subStepCount);
}

pub fn worldDraw(debugDraw: *c.b2DebugDraw) void {
    c.b2World_Draw(getWorldId(), debugDraw);
}

pub fn getSensorEvents() c.b2SensorEvents {
    return c.b2World_GetSensorEvents(getWorldId());
}

pub fn getContactEvents() c.b2ContactEvents {
    return c.b2World_GetContactEvents(getWorldId());
}

pub fn setFrictionCallback(callback: ?*const c.b2FrictionCallback) void {
    c.b2World_SetFrictionCallback(getWorldId(), callback);
}

pub fn overlapCircle(circle: *const c.b2Circle, transform: c.b2Transform, filter: c.b2QueryFilter, callback: ?*const c.b2OverlapResultFcn, userContext: ?*anyopaque) void {
    const proxy = c.b2MakeOffsetProxy(&circle.center, 1, circle.radius, transform.p, transform.q);
    _ = c.b2World_OverlapShape(getWorldId(), &proxy, filter, callback, userContext);
}

pub fn overlapAABB(aabb: c.b2AABB, filter: c.b2QueryFilter, callback: ?*const c.b2OverlapResultFcn, userContext: ?*anyopaque) void {
    _ = c.b2World_OverlapAABB(getWorldId(), aabb, filter, callback, userContext);
}

pub fn castRayClosest(origin: c.b2Vec2, translation: c.b2Vec2, filter: c.b2QueryFilter) c.b2RayResult {
    return c.b2World_CastRayClosest(getWorldId(), origin, translation, filter);
}

pub fn createWeldJoint(def: *const c.b2WeldJointDef) c.b2JointId {
    return c.b2CreateWeldJoint(getWorldId(), def);
}
