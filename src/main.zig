const sdl = @import("zsdl2");
const image = @import("zsdl2_image");
const box2d = @import("box2d").native;
const assert = @import("std").debug.assert;
const print = @import("std").debug.print;
const std = @import("std");

const PI = std.math.pi;
const ArrayList = std.ArrayList;

const boxImgSrc = "images/box.png";
const starImgSrc = "images/star.png";

const Config = struct {
    window: struct { width: i32, height: i32 },
    met2pix: i32,
};

const conf: Config = .{ .window = .{ .width = 800, .height = 800 }, .met2pix = 80 };

const Sprite = struct { texture: *sdl.Texture, dim: struct {
    w: f32,
    h: f32,
} };

const IVec2 = struct {
    x: i32,
    y: i32,
};
const Vec2 = struct {
    x: f32,
    y: f32,
};

const Object = struct {
    bodyId: box2d.b2BodyId,
    sprite: Sprite,
};

const SharedResources = struct {
    worldId: box2d.b2WorldId,
    renderer: *sdl.Renderer,
    boxTexture: *sdl.Texture,
    starTexture: *sdl.Texture,
};

var debugPolygon: ?[]Vec2 = null; // Will store the simplified polygon vertices

// For displaying the star image along with its debug overlay:
var starImageWidth: i32 = 128;
var starImageHeight: i32 = 96;

var sharedResources: ?SharedResources = null;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var objects: ArrayList(Object) = ArrayList(Object).init(allocator);

fn isPointInTriangle(pt: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
    const v0 = Vec2{ .x = c.x - a.x, .y = c.y - a.y };
    const v1 = Vec2{ .x = b.x - a.x, .y = b.y - a.y };
    const v2 = Vec2{ .x = pt.x - a.x, .y = pt.y - a.y };

    const dot00 = v0.x * v0.x + v0.y * v0.y;
    const dot01 = v0.x * v1.x + v0.y * v1.y;
    const dot02 = v0.x * v2.x + v0.y * v2.y;
    const dot11 = v1.x * v1.x + v1.y * v1.y;
    const dot12 = v1.x * v2.x + v1.y * v2.y;

    const invDenom = 1.0 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * invDenom;
    const v = (dot00 * dot12 - dot01 * dot02) * invDenom;

    return (u >= 0.0) and (v >= 0.0) and (u + v < 1.0);
}

fn isConvex(a: Vec2, b: Vec2, c: Vec2) bool {
    const cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    return cross > 0.0;
}

fn findEar(vertices: []Vec2) ?usize {
    const n = vertices.len;

    for (0..n) |i| {
        const prevIndex = (i + n - 1) % n;
        const nextIndex = (i + 1) % n;

        const prev = vertices[prevIndex];
        const current = vertices[i];
        const next = vertices[nextIndex];

        if (!isConvex(prev, current, next)) {
            std.debug.print("Vertex {} is not convex: prev=({}, {}), current=({}, {}), next=({}, {})\n", .{ i, prev.x, prev.y, current.x, current.y, next.x, next.y });
            continue;
        }

        var isEar = true;
        for (0..n) |j| {
            if (j == prevIndex or j == i or j == nextIndex) continue;
            if (isPointInTriangle(vertices[j], prev, current, next)) {
                isEar = false;
                break;
            }
        }

        if (isEar) {
            return i;
        }
    }

    return null;
}

pub fn earClipping(vertices: []Vec2) ![]const [3]Vec2 {
    var triangles = ArrayList([3]Vec2).init(allocator);

    var verts = ArrayList(Vec2).init(allocator);
    for (vertices) |v| try verts.append(v);

    while (verts.items.len > 3) {
        const earIndex = findEar(verts.items) orelse {
            std.debug.panic("Could not find an ear. Is the polygon simple?", .{});
        };

        const prevIndex = (earIndex + verts.items.len - 1) % verts.items.len;
        const nextIndex = (earIndex + 1) % verts.items.len;

        const prev = verts.items[prevIndex];
        const current = verts.items[earIndex];
        const next = verts.items[nextIndex];

        try triangles.append(.{ prev, current, next });

        _ = verts.orderedRemove(earIndex);
    }

    // Add the final triangle
    triangles.append(.{ verts.items[0], verts.items[1], verts.items[2] }) catch {};

    return triangles.toOwnedSlice();
}

// CCW

fn isCounterClockwise(vertices: []Vec2) bool {
    var sum: f32 = 0.0;
    const n = vertices.len;
    for (0..n) |i| {
        const current = vertices[i];
        const next = vertices[(i + 1) % n];
        sum += (next.x - current.x) * (next.y + current.y);
    }
    return sum > 0.0;
}

// degenerates

fn removeDuplicateVertices(vertices: []Vec2) ![]Vec2 {
    var unique = ArrayList(Vec2).init(allocator);
    defer unique.deinit();

    for (vertices) |v| {
        if (unique.items.len == 0) {
            try unique.append(v);
            continue;
        }
        const item = unique.getLast();

        if (item.x != v.x and item.y != v.y) {
            try unique.append(v);
        }
    }

    return unique.toOwnedSlice();
}

fn ensureCounterClockwise(vertices: []Vec2) ![]Vec2 {
    if (isCounterClockwise(vertices)) {
        return vertices;
    } else {
        var reversed = ArrayList(Vec2).init(allocator);

        var i: usize = vertices.len;
        while (i > 0) {
            i -= 1;
            try reversed.append(vertices[i]);
        }

        return reversed.toOwnedSlice();
    }
}

// Douglas-Peucker

fn perpendicularDistance(point: Vec2, lineStart: Vec2, lineEnd: Vec2) f32 {
    const dx = lineEnd.x - lineStart.x;
    const dy = lineEnd.y - lineStart.y;

    if (dx == 0.0 and dy == 0.0) {
        // Line start and end are the same point
        return @abs(point.x - lineStart.x) + @abs(point.y - lineStart.y);
    }

    const numerator = @abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x);
    const denominator = @sqrt(dx * dx + dy * dy);
    return numerator / denominator;
}

fn douglasPeucker(vertices: []Vec2, epsilon: f32) ![]Vec2 {
    if (vertices.len <= 2) {
        return vertices;
    }

    var maxDistance: f32 = 0.0;
    var index: usize = 0;

    for (1..vertices.len - 1) |i| {
        const dist = perpendicularDistance(vertices[i], vertices[0], vertices[vertices.len - 1]);
        if (dist > maxDistance) {
            maxDistance = dist;
            index = i;
        }
    }

    if (maxDistance > epsilon) {
        const left = try douglasPeucker(vertices[0 .. index + 1], epsilon);
        const right = try douglasPeucker(vertices[index..], epsilon);

        // Merge the results, excluding the duplicate point at the junction
        var result = ArrayList(Vec2).init(allocator);
        defer result.deinit();

        try result.appendSlice(left[0 .. left.len - 1]);
        try result.appendSlice(right);

        return result.toOwnedSlice();
    } else {
        // Only keep the endpoints
        var simplified = ArrayList(Vec2).init(allocator);
        defer simplified.deinit();

        try simplified.append(vertices[0]);
        try simplified.append(vertices[vertices.len - 1]);

        return simplified.toOwnedSlice();
    }
}

// marching squares

fn getPixelAlpha(pixels: [*]const u8, pitch: usize, x: usize, y: usize) u8 {
    // ABGR8888: Alpha is the first byte of each pixel
    return pixels[y * pitch + x * 4];

    // Assuming the image is in SDL_PIXELFORMAT_RGBA8888
    // return pixels[y * pitch + x * 4 + 3];
}

fn interpolateEdge(v1: u8, v2: u8, p1: usize, p2: usize, threshold: u8) f32 {
    if (v1 == v2) return @as(f32, @floatFromInt(p1));
    return @as(f32, @floatFromInt(p1)) +
        (@as(f32, @floatFromInt(p2)) - @as(f32, @floatFromInt(p1))) *
        (@as(f32, @floatFromInt(threshold)) - @as(f32, @floatFromInt(v1))) /
        (@as(f32, @floatFromInt(v2)) - @as(f32, @floatFromInt(v1)));
}

fn marchingSquareCase(topLeft: u8, topRight: u8, bottomLeft: u8, bottomRight: u8, threshold: u8) u8 {
    return (if (topLeft >= threshold) @as(u8, 8) else @as(u8, 0)) |
        (if (topRight >= threshold) @as(u8, 4) else @as(u8, 0)) |
        (if (bottomRight >= threshold) @as(u8, 2) else @as(u8, 0)) |
        (if (bottomLeft >= threshold) @as(u8, 1) else @as(u8, 0));
}

pub fn marchingSquares(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) ![]Vec2 {
    var vertices = std.ArrayList(Vec2).init(allocator);

    for (0..height - 1) |y| {
        for (0..width - 1) |x| {
            const topLeft = getPixelAlpha(pixels, pitch, x, y);
            const topRight = getPixelAlpha(pixels, pitch, x + 1, y);
            const bottomLeft = getPixelAlpha(pixels, pitch, x, y + 1);
            const bottomRight = getPixelAlpha(pixels, pitch, x + 1, y + 1);

            const caseId = marchingSquareCase(topLeft, topRight, bottomLeft, bottomRight, threshold);

            switch (caseId) {
                // Single corner cases
                1 => {
                    const p1 = interpolateEdge(bottomLeft, topLeft, y + 1, y, threshold);
                    const p2 = interpolateEdge(bottomLeft, bottomRight, x, x + 1, threshold);
                    vertices.append(.{ .x = @floatFromInt(x), .y = p1 }) catch {};
                    vertices.append(.{ .x = p2, .y = @floatFromInt(y + 1) }) catch {};
                },
                2 => {
                    const p1 = interpolateEdge(bottomRight, topRight, y + 1, y, threshold);
                    const p2 = interpolateEdge(bottomLeft, bottomRight, x, x + 1, threshold);
                    vertices.append(.{ .x = @floatFromInt(x + 1), .y = p1 }) catch {};
                    vertices.append(.{ .x = p2, .y = @floatFromInt(y + 1) }) catch {};
                },
                4 => {
                    const p1 = interpolateEdge(topRight, bottomRight, y, y + 1, threshold);
                    const p2 = interpolateEdge(topLeft, topRight, x, x + 1, threshold);
                    vertices.append(.{ .x = p1, .y = @floatFromInt(y) }) catch {};
                    vertices.append(.{ .x = @floatFromInt(x + 1), .y = p2 }) catch {};
                },
                8 => {
                    const p1 = interpolateEdge(topLeft, bottomLeft, y, y + 1, threshold);
                    const p2 = interpolateEdge(topLeft, topRight, x, x + 1, threshold);
                    vertices.append(.{ .x = @floatFromInt(x), .y = p1 }) catch {};
                    vertices.append(.{ .x = p2, .y = @floatFromInt(y) }) catch {};
                },

                // Saddle point cases
                5 => {
                    const p1 = interpolateEdge(bottomLeft, topLeft, y + 1, y, threshold);
                    const p2 = interpolateEdge(topLeft, topRight, x, x + 1, threshold);
                    const p3 = interpolateEdge(bottomRight, topRight, y + 1, y, threshold);
                    const p4 = interpolateEdge(bottomLeft, bottomRight, x, x + 1, threshold);
                    vertices.append(.{ .x = @floatFromInt(x), .y = p1 }) catch {};
                    vertices.append(.{ .x = p2, .y = @floatFromInt(y) }) catch {};
                    vertices.append(.{ .x = @floatFromInt(x + 1), .y = p3 }) catch {};
                    vertices.append(.{ .x = p4, .y = @floatFromInt(y + 1) }) catch {};
                },

                // Other cases (symmetry)
                10 => {
                    const p1 = interpolateEdge(topRight, bottomRight, y, y + 1, threshold);
                    const p2 = interpolateEdge(topLeft, topRight, x, x + 1, threshold);
                    const p3 = interpolateEdge(bottomLeft, topLeft, y + 1, y, threshold);
                    const p4 = interpolateEdge(bottomLeft, bottomRight, x, x + 1, threshold);
                    vertices.append(.{ .x = p1, .y = @floatFromInt(y) }) catch {};
                    vertices.append(.{ .x = p2, .y = @floatFromInt(y) }) catch {};
                    vertices.append(.{ .x = p3, .y = @floatFromInt(y + 1) }) catch {};
                    vertices.append(.{ .x = p4, .y = @floatFromInt(y + 1) }) catch {};
                },

                else => {
                    // Skip empty or fully filled cells
                },
            }
        }
    }

    return try vertices.toOwnedSlice();
}

fn createCube(position: IVec2) void {
    if (sharedResources) |shared| {
        const worldId = shared.worldId;
        const boxTexture = shared.boxTexture;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
        const dynamicBox = box2d.b2MakeBox(0.5, 0.5);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
        const sprite = Sprite{ .texture = boxTexture, .dim = .{ .w = 1, .h = 1 } };

        const object = Object{ .bodyId = bodyId, .sprite = sprite };
        objects.append(object) catch {};
    }
}

fn drawObject(object: Object) !void {
    if (sharedResources) |shared| {
        const renderer = shared.renderer;

        const bodyId = object.bodyId;
        const sprite = object.sprite;
        const boxPosMeter = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);

        const pos = m2PixelPos(boxPosMeter.x, boxPosMeter.y, sprite.dim.w, sprite.dim.h);
        const rect = sdl.Rect{
            .x = pos.x,
            .y = pos.y,
            .w = m2P(sprite.dim.w),
            .h = m2P(sprite.dim.h),
        };
        try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
    }
}

fn imgIntoShape(img: *sdl.Surface) !void {
    std.debug.print("Surface pixel format enum: {any}\n", .{img.format});

    // 1. use marching squares algorithm to calculate shape edges. Output list of points in ccw order. -> complex polygon
    const surface = img.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);

    const threshold: u8 = 128; // Isovalue threshold for alpha
    const vertices = try marchingSquares(pixels, width, height, pitch, threshold);
    debugPolygon = vertices;

    // Print the resulting vertices
    for (vertices) |vertex| {
        std.debug.print("Vertex: ({d}, {d})\n", .{ vertex.x, vertex.y });
    }
    std.debug.print("Original polygon vertices: {}\n", .{vertices.len});

    // 2. simplify the polygon. E.g douglas pecker

    //     const epsilon: f32 = 0.1 * @as(f32, @floatFromInt(width));
    //     const simplified = try douglasPeucker(vertices, epsilon);
    //     defer allocator.free(simplified);

    //     // Print the simplified polygon
    //     for (simplified) |point| {
    //         std.debug.print("Simplified vertex: ({d}, {d})\n", .{ point.x, point.y });
    //     }

    //     std.debug.print("Original polygon vertices: {}\n", .{vertices.len});
    //     std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});

    // // 3. use earclipping to triangulate the polygon

    // const ccwVertices = try ensureCounterClockwise(simplified);

    // const withoutDuplicates = try removeDuplicateVertices(ccwVertices);

    // // Print the "corrected" polygon
    // for (withoutDuplicates) |point| {
    //     std.debug.print("ccw and duplicate corrected vertex: ({}, {})\n", .{ point.x, point.y });
    // }

    // const triangles = try earClipping(withoutDuplicates);

    // for (triangles) |triangle| {
    //     std.debug.print("Triangle: ({}, {}) -> ({}, {}) -> ({}, {})\n", .{
    //         triangle[0].x, triangle[0].y,
    //         triangle[1].x, triangle[1].y,
    //         triangle[2].x, triangle[2].y,
    //     });
    // }
    // // 4. assing polygons to box2d body. Box2d will treat them as single body
}

pub fn main() !void {
    try sdl.init(.{ .audio = true, .video = true });
    defer sdl.quit();

    const window = try sdl.createWindow("My Super Duper Game Window", 0, 0, conf.window.width, conf.window.height, .{ .opengl = true, .shown = true });
    defer sdl.destroyWindow(window);

    const renderer = try sdl.createRenderer(window, -1, .{ .accelerated = true, .present_vsync = true });
    defer sdl.destroyRenderer(renderer);

    // Initialize Box2D World
    const gravity = box2d.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.b2CreateWorld(&worldDef);

    // load box texture
    const boxSurface = try image.load(boxImgSrc);
    const boxTexture = try sdl.createTextureFromSurface(renderer, boxSurface);
    defer sdl.freeSurface(boxSurface);
    defer sdl.destroyTexture(boxTexture);

    // load star texture
    const starSurface = try image.load(starImgSrc);
    const starTexture = try sdl.createTextureFromSurface(renderer, starSurface);

    try imgIntoShape(starSurface);
    defer sdl.freeSurface(starSurface);

    // instantiate shared resources
    sharedResources = SharedResources{ .renderer = renderer, .boxTexture = boxTexture, .worldId = worldId, .starTexture = starTexture };

    // Ground (Static Body)
    var groundDef = box2d.b2DefaultBodyDef();
    groundDef.position = meters(5, 1);
    const groundId = box2d.b2CreateBody(worldId, &groundDef);
    const groundBox = box2d.b2MakeBox(5, 0.5);
    const groundShapeDef = box2d.b2DefaultShapeDef();
    _ = box2d.b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);

    const groundSprite = Sprite{ .texture = boxTexture, .dim = .{ .w = 10, .h = 1 } };

    const timeStep: f32 = 1.0 / 60.0;
    const subStepCount = 4;
    var running = true;

    while (running) {
        // Event handling
        var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.EventType.quit => {
                    running = false;
                },
                sdl.EventType.mousebuttondown => {
                    mouseButtonDown(event.button);
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(worldId, timeStep, subStepCount);

        try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(renderer);

        // Draw ground
        const gPosMeter = box2d.b2Body_GetPosition(groundId);

        const groundPos = m2PixelPos(gPosMeter.x, gPosMeter.y, groundSprite.dim.w, groundSprite.dim.h);
        const groundRect = sdl.Rect{
            .x = groundPos.x,
            .y = groundPos.y,
            .w = m2P(groundSprite.dim.w),
            .h = m2P(groundSprite.dim.h),
        };
        try sdl.renderCopyEx(renderer, groundSprite.texture, null, &groundRect, 0, null, sdl.RendererFlip.none);

        for (objects.items) |object| {
            try drawObject(object);
        }

        if (sharedResources) |sharedR| {
            const starT = sharedR.starTexture;
            // Define where on the screen you want the star image.
            // For instance, here we place it at (100, 100)
            const starRect = sdl.Rect{
                .x = 100,
                .y = 100,
                .w = starImageWidth,
                .h = starImageHeight,
            };
            try sdl.renderCopyEx(renderer, starT, null, &starRect, 0, null, sdl.RendererFlip.none);

            // Now overlay the debug polygon, offset by the starRect position.
            if (debugPolygon) |poly| {
                try debugDrawPolygon(renderer, poly, .{ .x = starRect.x, .y = starRect.y });
            }
        }

        // Debug
        try sdl.setRenderDrawColor(renderer, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
        try sdl.renderDrawLine(renderer, conf.window.width / 2, 0, conf.window.width / 2, conf.window.height);
        sdl.renderPresent(renderer);
    }
}

fn mouseButtonDown(event: sdl.MouseButtonEvent) void {
    print("Click!!", .{});
    createCube(.{ .x = event.x, .y = event.y });
}

fn m2PixelPos(x: f32, y: f32, w: f32, h: f32) IVec2 {
    return IVec2{
        .x = @as(i32, @intFromFloat(((w / 2.0) + x) * conf.met2pix - conf.met2pix * w)),
        .y = @as(i32, @intFromFloat(((h / 2.0) + y) * conf.met2pix - conf.met2pix * h / 2.0)),
    };
}

fn p2m(p: IVec2) box2d.b2Vec2 {
    return box2d.b2Vec2{ .x = @as(f32, @floatFromInt(p.x)) / conf.met2pix, .y = @as(f32, @floatFromInt(p.y)) / conf.met2pix };
}

fn meters(x: f32, y: f32) box2d.b2Vec2 {
    return box2d.b2Vec2{ .x = x, .y = (conf.window.height / conf.met2pix) - y };
}

fn m2Pixel(
    coord: box2d.b2Vec2,
) IVec2 {
    return .{ .x = @as(i32, @intFromFloat(coord.x * conf.met2pix)), .y = @as(i32, @intFromFloat(coord.y * conf.met2pix)) };
}
fn m2P(x: f32) i32 {
    return @as(i32, @intFromFloat(x * conf.met2pix));
}

fn debugDrawPolygon(renderer: *sdl.Renderer, polygon: []Vec2, offset: IVec2) !void {
    // Set a bright color for the overlay (magenta here)
    try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 255, .a = 255 });

    const n = polygon.len;
    if (n == 0) return;

    // Draw lines connecting the vertices (wrap-around at the end)
    for (0..n) |i| {
        const current = polygon[i];
        const next = polygon[(i + 1) % n];
        try sdl.renderDrawLine(renderer, offset.x + @as(i32, @intFromFloat(current.x)), offset.y + @as(i32, @intFromFloat(current.y)), offset.x + @as(i32, @intFromFloat(next.x)), offset.y + @as(i32, @intFromFloat(next.y)));
    }

    // For each vertex, compute an arrow showing the edge direction.
    // (Here we take the vector from current to next and normalize it.)
    const arrowLength: f32 = 10.0;
    for (0..n) |i| {
        const current = polygon[i];
        const next = polygon[(i + 1) % n];
        const dx = next.x - current.x;
        const dy = next.y - current.y;
        const len = std.math.sqrt(dx * dx + dy * dy);
        var dirX: f32 = 0;
        var dirY: f32 = 0;
        if (len > 0.0) {
            dirX = dx / len;
            dirY = dy / len;
        }
        const tipX = current.x + arrowLength * dirX;
        const tipY = current.y + arrowLength * dirY;
        // Draw the arrow line
        try sdl.renderDrawLine(renderer, offset.x + @as(i32, @intFromFloat(current.x)), offset.y + @as(i32, @intFromFloat(current.y)), offset.x + @as(i32, @intFromFloat(tipX)), offset.y + @as(i32, @intFromFloat(tipY)));
        // Draw a point at the vertex
        try sdl.renderDrawPoint(
            renderer,
            offset.x + @as(i32, @intFromFloat(current.x)),
            offset.y + @as(i32, @intFromFloat(current.y)),
        );
    }
}
