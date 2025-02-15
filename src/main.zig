const sdl = @import("zsdl2");
const box2d = @import("box2d").native;
const print = @import("std").debug.print;
const std = @import("std");

const config = @import("config.zig").config;
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const init = @import("shared.zig").init;
const shared = @import("shared.zig");
const SharedResources = @import("shared.zig").SharedResources;
const allocator = @import("shared.zig").allocator;
const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const douglasPeucker = @import("douglas.zig").douglasPeucker;
const earClipping = @import("ear.zig").earClipping;
const removeDuplicateVertices = @import("polygon.zig").removeDuplicateVertices;
const ensureCounterClockwise = @import("polygon.zig").ensureCounterClockwise;

const meters = @import("conversion.zig").meters;
const p2m = @import("conversion.zig").p2m;
const m2PixelPos = @import("conversion.zig").m2PixelPos;
const m2P = @import("conversion.zig").m2P;

const debugDrawSolidPolygon = @import("debug.zig").debugDrawSolidPolygon;
const debugDrawPolygon = @import("debug.zig").debugDrawPolygon;
const debugDrawSegment = @import("debug.zig").debugDrawSegment;
const debugDrawPoint = @import("debug.zig").debugDrawPoint;

const PI = std.math.pi;
const ArrayList = std.ArrayList;

const Sprite = struct { texture: *sdl.Texture, dimM: Vec2 };

const Object = struct {
    bodyId: box2d.b2BodyId,
    sprite: Sprite,
};

var objects: ArrayList(Object) = ArrayList(Object).init(allocator);

fn createCube(position: IVec2) void {
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

fn createShape(position: IVec2, texture: *sdl.Texture, triangles: [][3]IVec2) !void {
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

/// Creates a Box2D compound (multi–polygon) shape on the given body,
/// using the provided triangles (each triangle is a [3]IVec2).
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

fn drawObject(object: Object) !void {
    if (shared.resources) |resources| {
        const renderer = resources.renderer;

        const bodyId = object.bodyId;
        const sprite = object.sprite;
        const boxPosMeter = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);

        const pos = m2PixelPos(boxPosMeter.x, boxPosMeter.y, sprite.dimM.x, sprite.dimM.y);
        const rect = sdl.Rect{
            .x = pos.x,
            .y = pos.y,
            .w = m2P(sprite.dimM.x),
            .h = m2P(sprite.dimM.y),
        };
        try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
    }
}

fn imgIntoShape(position: IVec2, texture: *sdl.Texture, img: *sdl.Surface) !void {
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

pub fn main() !void {
    const resources = try init();

    // clean up
    defer sdl.quit();

    defer sdl.destroyWindow(resources.window);
    defer sdl.destroyRenderer(resources.renderer);

    try imgIntoShape(.{ .x = 300, .y = 200 }, resources.starTexture, resources.starSurface);
    try imgIntoShape(.{ .x = 600, .y = 150 }, resources.beanTexture, resources.beanSurface);
    try imgIntoShape(.{ .x = 400, .y = 100 }, resources.ballTexture, resources.ballSurface);

    // Ground (Static Body)
    var groundDef = box2d.b2DefaultBodyDef();
    groundDef.position = meters(5, 1);
    const groundId = box2d.b2CreateBody(resources.worldId, &groundDef);
    const groundBox = box2d.b2MakeBox(5, 0.5);
    const groundShapeDef = box2d.b2DefaultShapeDef();
    _ = box2d.b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);

    const groundSprite = Sprite{ .texture = resources.boxTexture, .dimM = .{ .x = 10, .y = 1 } };

    const timeStep: f32 = 1.0 / 60.0;
    const subStepCount = 4;
    var running = true;

    var debugDraw = box2d.b2DefaultDebugDraw();
    debugDraw.context = &shared.resources;
    debugDraw.DrawSolidPolygon = &debugDrawSolidPolygon;
    debugDraw.DrawPolygon = &debugDrawPolygon;
    debugDraw.DrawSegment = &debugDrawSegment;
    debugDraw.DrawPoint = &debugDrawPoint;
    debugDraw.drawShapes = true;
    debugDraw.drawAABBs = false;
    debugDraw.drawContacts = true;

    while (running) {
        // Event handling
        var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.EventType.quit => {
                    running = false;
                },
                sdl.EventType.keydown => {
                    running = keyDown(event.key);
                },
                sdl.EventType.mousebuttondown => {
                    mouseButtonDown(event.button);
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(resources.worldId, timeStep, subStepCount);

        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(resources.renderer);

        // Draw ground
        const gPosMeter = box2d.b2Body_GetPosition(groundId);

        const groundPos = m2PixelPos(gPosMeter.x, gPosMeter.y, groundSprite.dimM.x, groundSprite.dimM.y);
        const groundRect = sdl.Rect{
            .x = groundPos.x,
            .y = groundPos.y,
            .w = m2P(groundSprite.dimM.x),
            .h = m2P(groundSprite.dimM.y),
        };
        try sdl.renderCopyEx(resources.renderer, groundSprite.texture, null, &groundRect, 0, null, sdl.RendererFlip.none);

        for (objects.items) |object| {
            try drawObject(object);
        }
        box2d.b2World_Draw(resources.worldId, &debugDraw);

        // Debug
        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
        try sdl.renderDrawLine(resources.renderer, config.window.width / 2, 0, config.window.width / 2, config.window.height);
        sdl.renderPresent(resources.renderer);
    }
}

fn keyDown(event: sdl.KeyboardEvent) bool {
    print("Clack!!\n", .{});
    var running = true;
    switch (event.keysym.scancode) {
        sdl.Scancode.escape => {
            running = false;
        },
        else => {},
    }
    return running;
}
fn mouseButtonDown(event: sdl.MouseButtonEvent) void {
    print("Click!!\n", .{});
    createCube(.{ .x = event.x, .y = event.y });
}
