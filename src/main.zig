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
const beanImgSrc = "images/bean.png";

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
    beanTexture: *sdl.Texture,
};

var debugPolygon: ?[]IVec2 = null;
var debugTriangles: ?[][3]IVec2 = null;

var sharedResources: ?SharedResources = null;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var objects: ArrayList(Object) = ArrayList(Object).init(allocator);

//Pavlidis
fn getPixelAlpha(pixels: [*]const u8, pitch: usize, x: usize, y: usize) u8 {
    // ABGR8888: Alpha is the first byte of each pixel
    return pixels[y * pitch + x * 4];
}

fn isInside(x: i32, y: i32, pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) bool {
    if (x < 0 or y < 0 or @as(usize, @intCast(x)) >= width or @as(usize, @intCast(y)) >= height) return false;
    const alpha = getPixelAlpha(pixels, pitch, @as(usize, @intCast(x)), @as(usize, @intCast(y)));
    return alpha >= threshold;
}

// Define the 8–neighbor offsets in clockwise order starting from North.
const neighbors: [8]IVec2 = .{
    .{ .x = 0, .y = -1 }, // N, index 0
    .{ .x = 1, .y = -1 }, // NE, index 1
    .{ .x = 1, .y = 0 }, // E,  index 2
    .{ .x = 1, .y = 1 }, // SE, index 3
    .{ .x = 0, .y = 1 }, // S,  index 4
    .{ .x = -1, .y = 1 }, // SW, index 5
    .{ .x = -1, .y = 0 }, // W,  index 6
    .{ .x = -1, .y = -1 }, // NW, index 7
};

// Helper: given a direction vector, return its neighbor index.
fn neighborIndex(dir: IVec2) !usize {
    for (0..8) |i| {
        if (neighbors[i].x == dir.x and neighbors[i].y == dir.y) return @intCast(i);
    }
    return error.OverFlow;
}

fn findP123Directions(dir: IVec2) ![3]IVec2 {
    const p2 = try neighborIndex(dir);
    const p1 = @mod(@as(i32, @intCast(p2)) - 1, 8);
    const p3 = p2 + 1 % 8;

    return [3]IVec2{ neighbors[@intCast(p1)], neighbors[p2], neighbors[@intCast(p3)] };
}

fn turnRight(dir: IVec2) !IVec2 {
    const curDirInd = try neighborIndex(dir);
    const rightInd = (curDirInd + 2) % 8;
    return neighbors[rightInd];
}

fn turnLeft(dir: IVec2) !IVec2 {
    const curDirInd = try neighborIndex(dir);
    const leftInd = @mod(@as(i32, @intCast(curDirInd)) - 2, 8);
    return neighbors[@intCast(leftInd)];
}
/// Traces a contour using a Pavlidis/Moore neighbor–tracing algorithm.
/// Returns an array of Vec2 points (in pixel coordinates) that form the contour.
pub fn pavlidisContour(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) ![]IVec2 {
    var contour = std.ArrayList(IVec2).init(allocator);

    // Step 1. Find a starting boundary pixel.
    // A starting boundary pixel is one that is inside but its left pixel is not
    var start: IVec2 = undefined;
    var foundStart = false;
    for (0..width) |x| {
        for (0..height) |yk| {
            const y = (height - 1) - yk;
            if (isInside(@intCast(x), @intCast(y), pixels, width, height, pitch, threshold)) {
                if (isInside(@as(i32, @intCast(x)) - 1, @intCast(y), pixels, width, height, pitch, threshold)) {
                    break;
                }
                if (isInside(@as(i32, @intCast(x)) - 1, @intCast(y + 1), pixels, width, height, pitch, threshold)) {
                    break;
                }
                if (isInside(@intCast(x + 1), @intCast(y + 1), pixels, width, height, pitch, threshold)) {
                    break;
                }
                start = IVec2{ .x = @intCast(x), .y = @intCast(y) };
                foundStart = true;
                break;
            }
        }
        if (foundStart) break;
    }
    if (!foundStart) {
        std.debug.print("Did not find countour!\n", .{});
        return contour.toOwnedSlice();
    }

    var encounteredStart: i32 = 0;
    // Step 2. Initialize the tracing.
    var current = start;

    // Append the starting point.
    try contour.append(start);

    var curDir: IVec2 = .{ .x = 0, .y = -1 };

    var rotations: i32 = 0;
    // Step 3. Trace the contour.
    while (encounteredStart < 1) {
        const p123Directions = try findP123Directions(curDir);
        const p1 = IVec2{ .x = current.x + p123Directions[0].x, .y = current.y + p123Directions[0].y };
        const p2 = IVec2{ .x = current.x + p123Directions[1].x, .y = current.y + p123Directions[1].y };
        const p3 = IVec2{ .x = current.x + p123Directions[2].x, .y = current.y + p123Directions[2].y };

        if (isInside(@intCast(p1.x), @intCast(p1.y), pixels, width, height, pitch, threshold)) {
            try contour.append(p1);
            current = p1;
            curDir = try turnLeft(curDir);
            rotations = 0;
        } else if (isInside(@intCast(p2.x), @intCast(p2.y), pixels, width, height, pitch, threshold)) {
            try contour.append(p2);
            current = p2;
            rotations = 0;
        } else if (isInside(@intCast(p3.x), @intCast(p3.y), pixels, width, height, pitch, threshold)) {
            try contour.append(p3);
            current = p3;
            rotations = 0;
        } else if (rotations > 2) {
            std.debug.print("Isolated pixel!!!\n", .{});
            return contour.toOwnedSlice();
        } else {
            curDir = try turnRight(curDir);
            rotations += 1;
        }
        if (rotations == 0 and current.x == start.x and current.y == start.y) {
            encounteredStart += 1;
        }
    }
    return contour.toOwnedSlice();
}

fn perpendicularDistance(pointI: IVec2, lineStartI: IVec2, lineEndI: IVec2) f32 {
    const point = Vec2{ .x = @floatFromInt(pointI.x), .y = @floatFromInt(pointI.y) };
    const lineStart = Vec2{ .x = @floatFromInt(lineStartI.x), .y = @floatFromInt(lineStartI.y) };
    const lineEnd = Vec2{ .x = @floatFromInt(lineEndI.x), .y = @floatFromInt(lineEndI.y) };

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

fn douglasPeucker(vertices: []IVec2, epsilon: f32) ![]IVec2 {
    if (vertices.len <= 2) {
        return vertices;
    }

    var maxDistance: f32 = 0.0;
    var index: usize = 0;

    for (1..vertices.len) |i| {
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
        var result = ArrayList(IVec2).init(allocator);
        defer result.deinit();

        try result.appendSlice(left[0 .. left.len - 1]);
        try result.appendSlice(right);

        return result.toOwnedSlice();
    } else {
        // Only keep the endpoints
        var simplified = ArrayList(IVec2).init(allocator);
        defer simplified.deinit();

        try simplified.append(vertices[0]);
        try simplified.append(vertices[vertices.len - 1]);

        return simplified.toOwnedSlice();
    }
}

fn removeDuplicateVertices(vertices: []IVec2) ![]IVec2 {
    var unique = ArrayList(IVec2).init(allocator);
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

fn isCounterClockwise(vertices: []IVec2) bool {
    var sum: i32 = 0.0;
    const n = vertices.len;
    for (0..n) |i| {
        const current = vertices[i];
        const next = vertices[(i + 1) % n];
        sum += (next.x - current.x) * (next.y + current.y);
    }
    return sum > 0.0;
}

fn ensureCounterClockwise(vertices: []IVec2) ![]IVec2 {
    if (isCounterClockwise(vertices)) {
        return vertices;
    } else {
        var reversed = ArrayList(IVec2).init(allocator);

        var i: usize = vertices.len;
        while (i > 0) {
            i -= 1;
            try reversed.append(vertices[i]);
        }

        return reversed.toOwnedSlice();
    }
}

// Helper: Return true if the triple (a, b, c) makes a convex vertex at b.
// Assumes the polygon is CCW.
fn isConvex(a: IVec2, b: IVec2, c: IVec2) bool {
    // Compute the vector from a to b.
    const ab_x = b.x - a.x;
    const ab_y = b.y - a.y;

    // Compute the vector from a to c.
    const ac_x = c.x - a.x;
    const ac_y = c.y - a.y;

    // Compute the z–component of the cross product of (b−a) and (c−a).
    const cross = ab_x * ac_y - ab_y * ac_x;

    // In a CCW polygon, a positive cross product means b is a convex vertex. But since our y is growing down it is reversed
    return cross < 0;
}

// Helper: Returns true if point p lies inside the triangle defined by a, b, c.
// This implementation converts coordinates to float and uses barycentric coordinates.
fn isPointInTriangle(p: IVec2, a: IVec2, b: IVec2, c: IVec2) bool {
    // Convert integer coordinates to floating–point values.
    const pFloat = Vec2{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
    const aFloat = Vec2{ .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) };
    const bFloat = Vec2{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) };
    const cFloat = Vec2{ .x = @floatFromInt(c.x), .y = @floatFromInt(c.y) };

    // Compute twice the signed area of triangle ABC using the cross product.
    // areaABC = (b - a) × (c - a)
    const vectorBA_x = bFloat.x - aFloat.x;
    const vectorBA_y = bFloat.y - aFloat.y;
    const vectorCA_x = cFloat.x - aFloat.x;
    const vectorCA_y = cFloat.y - aFloat.y;
    const areaABC = vectorBA_x * vectorCA_y - vectorBA_y * vectorCA_x;

    // If the area is zero, the triangle is degenerate (vertices are collinear).
    if (areaABC == 0.0) return false;

    // Compute barycentric coordinates (s and t) for point p with respect to triangle ABC.
    // These formulas come from solving:
    //    p = a + s*(c - a) + t*(b - a)
    // Rearranging and solving for s and t gives:
    const s_numerator = (cFloat.x - aFloat.x) * (aFloat.y - pFloat.y) - (cFloat.y - aFloat.y) * (aFloat.x - pFloat.x);
    const t_numerator = (bFloat.x - aFloat.x) * (aFloat.y - pFloat.y) - (bFloat.y - aFloat.y) * (aFloat.x - pFloat.x);
    const s = s_numerator / areaABC;
    const t = t_numerator / areaABC;

    // For point p to be inside the triangle, both s and t must be nonnegative
    // and their sum must not exceed 1.
    return (s >= 0.0 and t >= 0.0 and (s + t) <= 1.0);
}

pub fn earClipping(vertices: []const IVec2) ![][3]IVec2 {
    var triangles = ArrayList([3]IVec2).init(allocator);

    // Make a mutable copy of the vertices.
    var verts = ArrayList(IVec2).init(allocator);
    for (vertices) |v| {
        try verts.append(v);
    }

    while (verts.items.len > 3) {
        std.debug.print("number of remaining vertices: {}\n", .{verts.items.len});
        var maybeEarInd: ?usize = null;

        for (0..verts.items.len) |i| {
            const prevIndex = @mod(@as(i32, @intCast(i)) - 1, @as(i32, @intCast(verts.items.len)));
            std.debug.print("prevIndex: {}\n", .{prevIndex});
            std.debug.print("index: {}\n", .{i});
            const nextIndex = @mod(i + 1, verts.items.len);
            std.debug.print("nextIndex: {}\n", .{nextIndex});

            const a = verts.items[@intCast(prevIndex)];
            const b = verts.items[i];
            const c = verts.items[nextIndex];

            // Only consider convex vertices.
            if (!isConvex(a, b, c)) continue;
            std.debug.print("Is convex!!\n", .{});

            // Check that no other vertex lies inside triangle (a, b, c)
            for (0..verts.items.len) |j| {
                if (j == prevIndex or j == i or j == nextIndex) continue;
                if (isPointInTriangle(verts.items[j], a, b, c)) {
                    continue;
                }
                std.debug.print("No points inside triangle!!\n", .{});

                maybeEarInd = i;
                break;
            }
            if (maybeEarInd) |_| {
                break;
            }
        }

        if (maybeEarInd) |earIndex| {
            std.debug.print("Found ear!!\n\n", .{});

            // Form a triangle with the ear.
            const prevIndex = @mod(@as(i32, @intCast(earIndex)) - 1, @as(i32, @intCast(verts.items.len)));
            const nextIndex = @mod(earIndex + 1, verts.items.len);
            const earTriangle: [3]IVec2 = .{
                verts.items[@intCast(prevIndex)],
                verts.items[earIndex],
                verts.items[nextIndex],
            };
            try triangles.append(earTriangle);

            // Remove the ear vertex.
            _ = verts.orderedRemove(earIndex);
        } else {
            std.debug.print("No ear found; polygon may be non-simple.\n", .{});
            return triangles.toOwnedSlice();
        }
    }

    // The remaining 3 vertices form the final triangle.
    const finalTriangle: [3]IVec2 = .{ verts.items[0], verts.items[1], verts.items[2] };
    try triangles.append(finalTriangle);

    return triangles.toOwnedSlice();
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

    debugPolygon = ccw;

    std.debug.print("Original polygon vertices: {}\n", .{vertices.len});
    std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});
    std.debug.print("Pruned polygon vertices: {}\n", .{prunedVertices.len});
    std.debug.print("Withoud duplicate vertices: {}\n", .{withoutDuplicates.len});
    std.debug.print("CCW vertices: {}\n", .{ccw.len});

    const triangles = try earClipping(ccw);
    debugTriangles = triangles;
    std.debug.print("triangles: {}\n", .{triangles.len});
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
    defer sdl.freeSurface(starSurface);
    const starTexture = try sdl.createTextureFromSurface(renderer, starSurface);

    // load bean texture
    const beanSurface = try image.load(beanImgSrc);
    defer sdl.freeSurface(beanSurface);
    const beanTexture = try sdl.createTextureFromSurface(renderer, beanSurface);

    try imgIntoShape(beanSurface);

    // instantiate shared resources
    sharedResources = SharedResources{ .renderer = renderer, .boxTexture = boxTexture, .worldId = worldId, .starTexture = starTexture, .beanTexture = beanTexture };

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
            const texture = sharedR.starTexture;

            var size: sdl.Point = undefined;
            try sdl.queryTexture(texture, null, null, &size.x, &size.y);
            // Define where on the screen you want the star image.
            // For instance, here we place it at (100, 100)
            const starRect = sdl.Rect{
                .x = 100,
                .y = 100,
                .w = size.x,
                .h = size.y,
            };
            try sdl.renderCopyEx(renderer, texture, null, &starRect, 0, null, sdl.RendererFlip.none);

            // if (debugPolygon) |poly| {
            //     try debugDrawPolygon(renderer, poly, .{ .x = starRect.x, .y = starRect.y });
            // }
            if (debugTriangles) |triangles| {
                for (triangles) |triangle| {
                    try debugDrawPolygon(renderer, &triangle, .{ .x = starRect.x, .y = starRect.y });
                }
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

fn debugDrawPolygon(renderer: *sdl.Renderer, polygon: []const IVec2, offset: IVec2) !void {
    // Set a bright color for the overlay (magenta here)
    try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 255, .a = 255 });

    const n = polygon.len;
    if (n == 0) return;

    // Draw lines connecting the vertices (wrap-around at the end)
    for (0..n) |i| {
        const current = polygon[i];
        const next = polygon[(i + 1) % n];
        try sdl.renderDrawLine(renderer, offset.x + current.x, offset.y + current.y, offset.x + next.x, offset.y + next.y);
    }
}
