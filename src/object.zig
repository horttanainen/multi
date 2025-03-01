const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2d").native;

const ArrayList = std.ArrayList;

const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const douglasPeucker = @import("douglas.zig").douglasPeucker;
const earClipping = @import("ear.zig").earClipping;
const removeDuplicateVertices = @import("polygon.zig").removeDuplicateVertices;
const ensureCounterClockwise = @import("polygon.zig").ensureCounterClockwise;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const p2m = @import("conversion.zig").p2m;

pub const Sprite = struct { texture: *sdl.Texture, dimM: Vec2 };
pub const Object = struct {
    bodyId: box2d.b2BodyId,
    sprite: Sprite,
};

pub var objects: ArrayList(Object) = ArrayList(Object).init(allocator);

pub fn createCube(position: IVec2) void {
    if (shared.resources) |resources| {
        const worldId = resources.worldId;
        const boxTexture = resources.boxTexture;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
        const dynamicBox = box2d.b2MakeBox(0.5, 0.5);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
        const sprite = Sprite{ .texture = boxTexture, .dimM = .{ .x = 1, .y = 1 } };

        const object = Object{ .bodyId = bodyId, .sprite = sprite };
        objects.append(object) catch {};
    }
}

pub fn imgIntoShape(position: IVec2, texture: *sdl.Texture, img: *sdl.Surface) !void {
    std.debug.print("Surface pixel format enum: {any}\n", .{img.format});

    // 1. use marching squares algorithm to calculate shape edges. Output list of points in ccw order. -> complex polygon
    const surface = img.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);

    const threshold: u8 = 125; // Isovalue threshold for alpha
    const vertices = try pavlidisContour(pixels, width, height, pitch, threshold);
    defer allocator.free(vertices);
    // Print the resulting vertices
    for (vertices) |vertex| {
        std.debug.print("Vertex: ({d}, {d})\n", .{ vertex.x, vertex.y });
    }
    std.debug.print("Original polygon vertices: {}\n", .{vertices.len});

    // 2. simplify the polygon. E.g douglas pecker

    const epsilon: f32 = 0.05 * @as(f32, @floatFromInt(width));
    const simplified = try douglasPeucker(vertices, epsilon);
    defer allocator.free(simplified);

    // Print the simplified polygon
    for (simplified) |point| {
        std.debug.print("Simplified vertex: ({d}, {d})\n", .{ point.x, point.y });
    }

    // 3. remove duplicates

    // Remove last vertex since it is same as first
    const prunedVertices = simplified[0 .. simplified.len - 1];
    const withoutDuplicates = try removeDuplicateVertices(prunedVertices);
    defer allocator.free(withoutDuplicates);

    for (withoutDuplicates) |point| {
        std.debug.print("Without duplicate vertex: ({d}, {d})\n", .{ point.x, point.y });
    }

    // 4. ensure counter clockwise
    const ccw = try ensureCounterClockwise(withoutDuplicates);

    for (ccw) |point| {
        std.debug.print("CCW vertex: ({d}, {d})\n", .{ point.x, point.y });
    }

    std.debug.print("Original polygon vertices: {}\n", .{vertices.len});
    std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});
    std.debug.print("Pruned polygon vertices: {}\n", .{prunedVertices.len});
    std.debug.print("Without duplicate vertices: {}\n", .{withoutDuplicates.len});
    std.debug.print("CCW vertices: {}\n", .{ccw.len});

    const triangles = try earClipping(ccw);
    std.debug.print("triangles: {}\n", .{triangles.len});

    try createShape(position, texture, triangles);
}

pub fn createShape(position: IVec2, texture: *sdl.Texture, triangles: [][3]IVec2) !void {
    if (shared.resources) |resources| {
        const worldId = resources.worldId;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);

        var size: sdl.Point = undefined;
        try sdl.queryTexture(texture, null, null, &size.x, &size.y);
        const dimM = p2m(.{ .x = size.x, .y = size.y });
        createBox2DMultiPolygon(bodyId, triangles, .{ .x = size.x, .y = size.y });

        const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

        const object = Object{ .bodyId = bodyId, .sprite = sprite };
        objects.append(object) catch {};
    }
}

pub fn createBox2DMultiPolygon(bodyId: box2d.b2BodyId, triangles: [][3]IVec2, dimP: IVec2) void {
    // For each triangle, create a polygon fixture on the body.
    for (triangles) |tri| {
        var triangle: [3]IVec2 = undefined;
        triangle[0] = .{ .x = tri[0].x - @divFloor(dimP.x, 2), .y = tri[0].y - @divFloor(dimP.y, 2) };
        triangle[1] = .{ .x = tri[1].x - @divFloor(dimP.x, 2), .y = tri[1].y - @divFloor(dimP.y, 2) };
        triangle[2] = .{ .x = tri[2].x - @divFloor(dimP.x, 2), .y = tri[2].y - @divFloor(dimP.y, 2) };

        // Convert the triangle's vertices from IVec2 (pixel space)
        // to box2d.b2Vec2 (meter space) using the provided conversion.
        var verts: [3]box2d.b2Vec2 = undefined;
        verts[0] = p2m(triangle[0]);
        verts[1] = p2m(triangle[1]);
        verts[2] = p2m(triangle[2]);

        // Create a default shape definition.
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        // (You may adjust properties like density, friction, or restitution as needed.)

        const hull = box2d.b2ComputeHull(&verts[0], 3);

        const poly: box2d.b2Polygon = box2d.b2MakePolygon(&hull, 0.01);

        // Create a polygon shape (fixture) on the body using the triangle vertices.
        // The b2CreatePolygonShape function expects a pointer to an array of b2Vec2
        // and the number of vertices is inferred by the fixture or shape definition.
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &poly);
    }
}
