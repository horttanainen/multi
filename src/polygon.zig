const std = @import("std");
const sdl = @import("sdl.zig");

const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const connected_components = @import("connected_components.zig");
const visvalingam = @import("visvalingam.zig").visvalingam;
const triangle = @import("triangle.zig");
const sprite = @import("sprite.zig");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const vec = @import("vector.zig");

const allocator = @import("allocator.zig").allocator;
const PI = std.math.pi;
const boundarySimplificationAreaFactor: f32 = 0.01;

var triangleCache = std.StringHashMap([][3]IVec2).init(allocator);
var triangleChunkCache = std.StringHashMap([]TriangleChunk).init(allocator);

pub const PolygonError = error{CouldNotCreateTriangle};
pub const TriangleChunk = struct {
    rect: vec.IRect,
    triangles: []const [3]IVec2,
};

const BoundaryEdge = struct {
    start: IVec2,
    end: IVec2,
    used: bool = false,
};

const BoundaryLoop = struct {
    vertices: []IVec2,
    isHole: bool,
    holePoint: Vec2,
};

fn spriteTriangleCacheKey(s: sprite.Sprite) ![]const u8 {
    const scaleXBits: u32 = @bitCast(s.scale.x);
    const scaleYBits: u32 = @bitCast(s.scale.y);
    return std.fmt.allocPrint(
        allocator,
        "{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}",
        .{
            s.imgPath,
            s.geometryId,
            s.texture.width,
            s.texture.height,
            s.sizeP.x,
            s.sizeP.y,
            scaleXBits,
            scaleYBits,
            s.offset.x,
            s.offset.y,
            s.geometryVersion,
        },
    );
}

fn spriteTriangleChunkCacheKey(s: sprite.Sprite, chunkSize: i32) ![]const u8 {
    const baseKey = try spriteTriangleCacheKey(s);
    defer allocator.free(baseKey);
    return std.fmt.allocPrint(allocator, "{s}|chunks|{d}", .{ baseKey, chunkSize });
}

pub fn triangulateCached(s: sprite.Sprite) ![]const [3]IVec2 {
    const cacheKey = try spriteTriangleCacheKey(s);
    errdefer allocator.free(cacheKey);

    const maybeTriangles = triangleCache.get(cacheKey);
    if (maybeTriangles != null) {
        allocator.free(cacheKey);
        return maybeTriangles.?;
    }

    const triangles = try triangulate(s);
    errdefer allocator.free(triangles);

    try triangleCache.put(cacheKey, triangles);
    return triangles;
}

pub fn triangulateChunksCached(s: sprite.Sprite, chunkSize: i32) ![]const TriangleChunk {
    const cacheKey = try spriteTriangleChunkCacheKey(s, chunkSize);
    errdefer allocator.free(cacheKey);

    const maybeChunks = triangleChunkCache.get(cacheKey);
    if (maybeChunks != null) {
        allocator.free(cacheKey);
        return maybeChunks.?;
    }

    const chunks = try triangulateChunks(s, chunkSize);
    errdefer freeTriangleChunks(chunks);

    try triangleChunkCache.put(cacheKey, chunks);
    return chunks;
}

pub fn clearCache() void {
    var iter = triangleCache.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    triangleCache.clearAndFree();

    var chunkIter = triangleChunkCache.iterator();
    while (chunkIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeTriangleChunks(entry.value_ptr.*);
    }
    triangleChunkCache.clearAndFree();
}

pub fn triangulate(s: sprite.Sprite) ![][3]IVec2 {
    return triangulateMask(s) catch |err| {
        std.log.warn("triangulate: full-mask triangulation failed for '{s}' with {}, falling back to largest component", .{ s.imgPath, err });
        return triangulateLargestComponent(s);
    };
}

pub fn triangulateMask(s: sprite.Sprite) ![][3]IVec2 {
    const img = s.surface;
    const surface = img.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const threshold: u8 = 150;

    const rect = fullSurfaceRect(width, height);
    var loops = try extractBoundaryLoopsInRect(pixels, width, height, pitch, threshold, rect);
    defer deinitBoundaryLoops(&loops);

    return triangulateBoundaryLoops(s, loops.items);
}

pub fn triangulateChunks(s: sprite.Sprite, chunkSize: i32) ![]TriangleChunk {
    if (chunkSize <= 0) {
        std.log.warn("triangulateChunks: invalid chunk size {d}", .{chunkSize});
        return PolygonError.CouldNotCreateTriangle;
    }

    const surface = s.surface.*;
    const width: i32 = @intCast(surface.w);
    const height: i32 = @intCast(surface.h);
    if (width <= 0 or height <= 0) {
        std.log.warn("triangulateChunks: invalid surface size {d}x{d}", .{ width, height });
        return PolygonError.CouldNotCreateTriangle;
    }

    var chunks = std.array_list.Managed(TriangleChunk).init(allocator);
    errdefer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.triangles);
        }
        chunks.deinit();
    }

    var y: i32 = 0;
    while (y < height) : (y += chunkSize) {
        var x: i32 = 0;
        while (x < width) : (x += chunkSize) {
            const rect = vec.IRect{
                .minX = x,
                .minY = y,
                .maxX = @min(width, x + chunkSize),
                .maxY = @min(height, y + chunkSize),
            };

            const triangles = triangulateRegion(s, rect) catch |err| {
                if (err != PolygonError.CouldNotCreateTriangle) {
                    std.log.warn("triangulateChunks: region ({d},{d})-({d},{d}) failed with {}", .{ rect.minX, rect.minY, rect.maxX, rect.maxY, err });
                }
                continue;
            };

            chunks.append(.{
                .rect = rect,
                .triangles = triangles,
            }) catch |err| {
                allocator.free(triangles);
                return err;
            };
        }
    }

    if (chunks.items.len == 0) {
        return PolygonError.CouldNotCreateTriangle;
    }

    return chunks.toOwnedSlice();
}

pub fn triangulateRegion(s: sprite.Sprite, rect: vec.IRect) ![][3]IVec2 {
    const surface = s.surface.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);
    const threshold: u8 = 150;
    const clampedRect = clampRect(rect, width, height);

    if (clampedRect.minX >= clampedRect.maxX or clampedRect.minY >= clampedRect.maxY) {
        return PolygonError.CouldNotCreateTriangle;
    }

    var loops = try extractBoundaryLoopsInRect(pixels, width, height, pitch, threshold, clampedRect);
    defer deinitBoundaryLoops(&loops);

    return triangulateBoundaryLoops(s, loops.items);
}

fn triangulateBoundaryLoops(s: sprite.Sprite, loops: []const BoundaryLoop) ![][3]IVec2 {
    if (loops.len == 0) {
        return PolygonError.CouldNotCreateTriangle;
    }

    var triangles = std.array_list.Managed([3]IVec2).init(allocator);
    errdefer triangles.deinit();

    for (loops) |outerLoop| {
        if (outerLoop.isHole) continue;

        var contours = std.array_list.Managed(triangle.PslgContour).init(allocator);
        defer contours.deinit();
        try contours.append(.{ .vertices = outerLoop.vertices });

        var holes = std.array_list.Managed(Vec2).init(allocator);
        defer holes.deinit();

        for (loops) |holeLoop| {
            if (!holeLoop.isHole) continue;
            if (!pointInPolygon(holeLoop.holePoint, outerLoop.vertices)) continue;

            try contours.append(.{ .vertices = holeLoop.vertices });
            try holes.append(holeLoop.holePoint);
        }

        const componentTriangles = triangle.splitPslg(contours.items, holes.items) catch |err| {
            std.log.warn("triangulateMask: failed to triangulate contour for '{s}' with {}", .{ s.imgPath, err });
            continue;
        };
        defer allocator.free(componentTriangles);

        for (componentTriangles) |componentTriangle| {
            try triangles.append(componentTriangle);
        }
    }

    if (triangles.items.len == 0) {
        return PolygonError.CouldNotCreateTriangle;
    }

    const ownedTriangles = try triangles.toOwnedSlice();
    scaleTriangles(ownedTriangles, s.scale);
    return ownedTriangles;
}

fn extractBoundaryLoopsInRect(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8, rect: vec.IRect) !std.array_list.Managed(BoundaryLoop) {
    var edges = std.array_list.Managed(BoundaryEdge).init(allocator);
    defer edges.deinit();

    var edgeStarts = std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize)).empty;
    defer deinitEdgeStarts(&edgeStarts);

    try buildBoundaryEdges(&edges, &edgeStarts, pixels, width, height, pitch, threshold, rect);
    return traceBoundaryLoops(&edges, &edgeStarts, pixels, width, height, pitch, threshold, rect);
}

fn buildBoundaryEdges(
    edges: *std.array_list.Managed(BoundaryEdge),
    edgeStarts: *std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize)),
    pixels: [*]const u8,
    width: usize,
    height: usize,
    pitch: usize,
    threshold: u8,
    rect: vec.IRect,
) !void {
    _ = height;

    var y = rect.minY;
    while (y < rect.maxY) : (y += 1) {
        var x = rect.minX;
        while (x < rect.maxX) : (x += 1) {
            const px = x;
            const py = y;
            if (!isSolidPixelInRect(pixels, width, pitch, threshold, rect, px, py)) continue;

            if (!isSolidPixelInRect(pixels, width, pitch, threshold, rect, px, py - 1)) {
                try appendBoundaryEdge(edges, edgeStarts, .{ .x = px, .y = py }, .{ .x = px + 1, .y = py });
            }
            if (!isSolidPixelInRect(pixels, width, pitch, threshold, rect, px + 1, py)) {
                try appendBoundaryEdge(edges, edgeStarts, .{ .x = px + 1, .y = py }, .{ .x = px + 1, .y = py + 1 });
            }
            if (!isSolidPixelInRect(pixels, width, pitch, threshold, rect, px, py + 1)) {
                try appendBoundaryEdge(edges, edgeStarts, .{ .x = px + 1, .y = py + 1 }, .{ .x = px, .y = py + 1 });
            }
            if (!isSolidPixelInRect(pixels, width, pitch, threshold, rect, px - 1, py)) {
                try appendBoundaryEdge(edges, edgeStarts, .{ .x = px, .y = py + 1 }, .{ .x = px, .y = py });
            }
        }
    }
}

fn appendBoundaryEdge(
    edges: *std.array_list.Managed(BoundaryEdge),
    edgeStarts: *std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize)),
    start: IVec2,
    end: IVec2,
) !void {
    const edgeIndex = edges.items.len;
    try edges.append(.{ .start = start, .end = end });

    const entry = try edgeStarts.getOrPut(allocator, start);
    if (!entry.found_existing) {
        entry.value_ptr.* = std.array_list.Managed(usize).init(allocator);
    }
    try entry.value_ptr.append(edgeIndex);
}

fn deinitEdgeStarts(edgeStarts: *std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize))) void {
    for (edgeStarts.values()) |*indices| {
        indices.deinit();
    }
    edgeStarts.deinit(allocator);
}

fn traceBoundaryLoops(
    edges: *std.array_list.Managed(BoundaryEdge),
    edgeStarts: *std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize)),
    pixels: [*]const u8,
    width: usize,
    height: usize,
    pitch: usize,
    threshold: u8,
    rect: vec.IRect,
) !std.array_list.Managed(BoundaryLoop) {
    var loops = std.array_list.Managed(BoundaryLoop).init(allocator);
    errdefer deinitBoundaryLoops(&loops);

    for (0..edges.items.len) |firstEdgeIndex| {
        if (edges.items[firstEdgeIndex].used) continue;

        var vertices = std.array_list.Managed(IVec2).init(allocator);
        defer vertices.deinit();

        const startPoint = edges.items[firstEdgeIndex].start;
        var edgeIndex = firstEdgeIndex;
        var closed = false;

        while (true) {
            if (edges.items[edgeIndex].used) {
                std.log.warn("traceBoundaryLoops: boundary edge was already used before loop closed", .{});
                break;
            }

            edges.items[edgeIndex].used = true;
            try vertices.append(edges.items[edgeIndex].start);

            const endPoint = edges.items[edgeIndex].end;
            if (vec.iequals(endPoint, startPoint)) {
                closed = true;
                break;
            }

            const maybeNextEdge = nextUnusedEdgeFrom(edgeStarts, edges, endPoint);
            if (maybeNextEdge == null) {
                std.log.warn("traceBoundaryLoops: open boundary at ({d},{d}), discarding loop", .{ endPoint.x, endPoint.y });
                break;
            }
            edgeIndex = maybeNextEdge.?;
        }

        if (!closed) continue;
        if (vertices.items.len < 3) continue;

        const simplified = try simplifyBoundaryLoop(vertices.items, rect);
        errdefer allocator.free(simplified);

        if (simplified.len < 3) {
            allocator.free(simplified);
            continue;
        }

        const area = signedArea(simplified);
        if (area == 0) {
            allocator.free(simplified);
            continue;
        }

        const isHole = area < 0;
        const holePoint = if (isHole)
            findPointInLoop(simplified, pixels, width, height, pitch, threshold, rect, false) orelse blk: {
                std.log.warn("traceBoundaryLoops: could not find transparent pixel inside hole, using centroid", .{});
                break :blk centroidPoint(simplified);
            }
        else
            centroidPoint(simplified);

        try loops.append(.{
            .vertices = simplified,
            .isHole = isHole,
            .holePoint = holePoint,
        });
    }

    return loops;
}

fn nextUnusedEdgeFrom(
    edgeStarts: *std.AutoArrayHashMapUnmanaged(IVec2, std.array_list.Managed(usize)),
    edges: *std.array_list.Managed(BoundaryEdge),
    point: IVec2,
) ?usize {
    const indices = edgeStarts.getPtr(point) orelse return null;
    for (indices.items) |edgeIndex| {
        if (!edges.items[edgeIndex].used) {
            return edgeIndex;
        }
    }
    return null;
}

fn deinitBoundaryLoops(loops: *std.array_list.Managed(BoundaryLoop)) void {
    for (loops.items) |boundaryLoop| {
        allocator.free(boundaryLoop.vertices);
    }
    loops.deinit();
}

fn fullSurfaceRect(width: usize, height: usize) vec.IRect {
    return .{
        .minX = 0,
        .minY = 0,
        .maxX = @intCast(width),
        .maxY = @intCast(height),
    };
}

fn clampRect(rect: vec.IRect, width: usize, height: usize) vec.IRect {
    const widthI: i32 = @intCast(width);
    const heightI: i32 = @intCast(height);
    return .{
        .minX = @max(0, @min(widthI, rect.minX)),
        .minY = @max(0, @min(heightI, rect.minY)),
        .maxX = @max(0, @min(widthI, rect.maxX)),
        .maxY = @max(0, @min(heightI, rect.maxY)),
    };
}

fn freeTriangleChunks(chunks: []const TriangleChunk) void {
    for (chunks) |chunk| {
        allocator.free(chunk.triangles);
    }
    allocator.free(chunks);
}

fn isSolidPixel(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;

    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return false;

    const alpha = pixels[uy * pitch + ux * 4 + 3];
    return alpha >= threshold;
}

fn isSolidPixelInRect(pixels: [*]const u8, width: usize, pitch: usize, threshold: u8, rect: vec.IRect, x: i32, y: i32) bool {
    if (x < rect.minX or y < rect.minY or x >= rect.maxX or y >= rect.maxY) return false;

    const ux: usize = @intCast(x);
    if (ux >= width) return false;

    const uy: usize = @intCast(y);
    const alpha = pixels[uy * pitch + ux * 4 + 3];
    return alpha >= threshold;
}

fn simplifyBoundaryLoop(vertices: []const IVec2, rect: vec.IRect) ![]IVec2 {
    const noDuplicates = try removeDuplicateVertices(vertices);
    defer allocator.free(noDuplicates);

    if (noDuplicates.len < 3) {
        return allocator.alloc(IVec2, 0);
    }

    const simplified = try visvalingam(noDuplicates, simplificationAreaForRect(rect));
    defer allocator.free(simplified);
    if (simplified.len < 3) {
        return allocator.alloc(IVec2, 0);
    }

    const simplifiedNoDuplicates = try removeDuplicateVertices(simplified);
    defer allocator.free(simplifiedNoDuplicates);
    if (simplifiedNoDuplicates.len < 3) {
        return allocator.alloc(IVec2, 0);
    }

    return removeCollinearVertices(simplifiedNoDuplicates);
}

fn simplificationAreaForRect(rect: vec.IRect) f32 {
    const width = @max(1, rect.maxX - rect.minX);
    const height = @max(1, rect.maxY - rect.minY);
    const area = @as(i64, width) * @as(i64, height);
    return boundarySimplificationAreaFactor * @as(f32, @floatFromInt(area));
}

fn removeCollinearVertices(vertices: []const IVec2) ![]IVec2 {
    var compact = std.array_list.Managed(IVec2).init(allocator);
    defer compact.deinit();

    if (vertices.len <= 3) {
        try compact.appendSlice(vertices);
        return compact.toOwnedSlice();
    }

    for (vertices, 0..) |current, i| {
        const prev = vertices[if (i == 0) vertices.len - 1 else i - 1];
        const next = vertices[(i + 1) % vertices.len];

        const dx1 = @as(i64, current.x) - @as(i64, prev.x);
        const dy1 = @as(i64, current.y) - @as(i64, prev.y);
        const dx2 = @as(i64, next.x) - @as(i64, current.x);
        const dy2 = @as(i64, next.y) - @as(i64, current.y);
        if (dx1 * dy2 == dy1 * dx2) continue;

        try compact.append(current);
    }

    return compact.toOwnedSlice();
}

fn signedArea(vertices: []const IVec2) i64 {
    var area: i64 = 0;
    for (vertices, 0..) |current, i| {
        const next = vertices[(i + 1) % vertices.len];
        area += @as(i64, current.x) * @as(i64, next.y) - @as(i64, next.x) * @as(i64, current.y);
    }
    return area;
}

fn centroidPoint(vertices: []const IVec2) Vec2 {
    var x: f32 = 0;
    var y: f32 = 0;
    for (vertices) |vertex| {
        x += @floatFromInt(vertex.x);
        y += @floatFromInt(vertex.y);
    }

    const len: f32 = @floatFromInt(vertices.len);
    return .{ .x = x / len, .y = y / len };
}

fn findPointInLoop(
    vertices: []const IVec2,
    pixels: [*]const u8,
    width: usize,
    height: usize,
    pitch: usize,
    threshold: u8,
    rect: vec.IRect,
    wantSolid: bool,
) ?Vec2 {
    var minX: i32 = vertices[0].x;
    var maxX: i32 = vertices[0].x;
    var minY: i32 = vertices[0].y;
    var maxY: i32 = vertices[0].y;

    for (vertices) |vertex| {
        minX = @min(minX, vertex.x);
        maxX = @max(maxX, vertex.x);
        minY = @min(minY, vertex.y);
        maxY = @max(maxY, vertex.y);
    }

    const widthI: i32 = @intCast(width);
    const heightI: i32 = @intCast(height);
    const startX = @max(rect.minX, @max(0, minX));
    const endX = @min(rect.maxX, @min(widthI, maxX));
    const startY = @max(rect.minY, @max(0, minY));
    const endY = @min(rect.maxY, @min(heightI, maxY));

    var y = startY;
    while (y < endY) : (y += 1) {
        var x = startX;
        while (x < endX) : (x += 1) {
            const point = Vec2{
                .x = @as(f32, @floatFromInt(x)) + 0.5,
                .y = @as(f32, @floatFromInt(y)) + 0.5,
            };
            if (!pointInPolygon(point, vertices)) continue;
            if (isSolidPixelInRect(pixels, width, pitch, threshold, rect, x, y) != wantSolid) continue;
            return point;
        }
    }

    return null;
}

fn pointInPolygon(point: Vec2, vertices: []const IVec2) bool {
    var inside = false;
    var j = vertices.len - 1;
    for (vertices, 0..) |vertex, i| {
        const xi: f32 = @floatFromInt(vertex.x);
        const yi: f32 = @floatFromInt(vertex.y);
        const xj: f32 = @floatFromInt(vertices[j].x);
        const yj: f32 = @floatFromInt(vertices[j].y);

        if ((yi > point.y) != (yj > point.y)) {
            const intersectX = (xj - xi) * (point.y - yi) / (yj - yi) + xi;
            if (point.x < intersectX) {
                inside = !inside;
            }
        }

        j = i;
    }
    return inside;
}

fn triangulateLargestComponent(s: sprite.Sprite) ![][3]IVec2 {
    // std.debug.print("Surface pixel format enum: {any}\n", .{img.format});

    const img = s.surface;
    const surface = img.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);

    // 1. Find the largest connected component and get its starting point
    const threshold: u8 = 150; // Isovalue threshold for alpha
    const start_point = try connected_components.findLargestComponentStart(pixels, width, height, pitch, threshold);
    if (start_point == null) {
        return PolygonError.CouldNotCreateTriangle;
    }

    // 2. Use pavlidis algorithm to calculate shape edges. Output list of points in ccw order. -> complex polygon
    const vertices = try pavlidisContour(pixels, width, height, pitch, threshold, start_point.?);
    defer allocator.free(vertices);
    // std.debug.print("Original polygon vertices: {}\n", .{vertices.len});

    if (vertices.len < 3) {
        return PolygonError.CouldNotCreateTriangle;
    }

    // 3. simplify the polygon.
    const epsilonArea: f32 = 0.01 * @as(f32, @floatFromInt(width * height));
    // std.debug.print("epsilonArea: {d}\n", .{epsilonArea});
    const simplified = try visvalingam(vertices, epsilonArea);
    defer allocator.free(simplified);
    // std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});

    if (simplified.len < 3) {
        return PolygonError.CouldNotCreateTriangle;
    }

    // 3. remove duplicates
    const withoutDuplicates = try removeDuplicateVertices(simplified);
    defer allocator.free(withoutDuplicates);
    // std.debug.print("Without duplicate vertices: {}\n", .{withoutDuplicates.len});

    if (withoutDuplicates.len < 3) {
        return PolygonError.CouldNotCreateTriangle;
    }

    // 4. ensure counter clockwise
    const ccw = try ensureCounterClockwise(withoutDuplicates);
    defer allocator.free(ccw);
    // std.debug.print("CCW vertices: {}\n", .{ccw.len});

    // 5. split into triangles
    const triangles = try triangle.split(ccw);
    // std.debug.print("triangles: {}\n", .{triangles.len});

    // 6. scale triangles in-place
    scaleTriangles(triangles, s.scale);

    return triangles;
}

pub fn removeDuplicateVertices(vertices: []const IVec2) ![]IVec2 {
    var unique = std.array_list.Managed(IVec2).init(allocator);
    defer unique.deinit();

    for (vertices, 0..) |v, i| {
        const next = if (i + 1 < vertices.len) vertices[i + 1] else vertices[0];
        if (!vec.iequals(v, next)) {
            try unique.append(v);
        }
    }

    return unique.toOwnedSlice();
}

pub fn ensureCounterClockwise(vertices: []const IVec2) ![]IVec2 {
    if (isCounterClockwise(vertices)) {
        const copy = try allocator.alloc(IVec2, vertices.len);
        @memcpy(copy, vertices);
        return copy;
    } else {
        var reversed = std.array_list.Managed(IVec2).init(allocator);

        var i: usize = vertices.len;
        while (i > 0) {
            i -= 1;
            try reversed.append(vertices[i]);
        }

        return reversed.toOwnedSlice();
    }
}

fn scaleTriangles(triangles: [][3]IVec2, scale: Vec2) void {
    for (triangles) |*t| {
        for (&t.*) |*v| {
            v.x = @intFromFloat(@as(f32, @floatFromInt(v.x)) * scale.x);
            v.y = @intFromFloat(@as(f32, @floatFromInt(v.y)) * scale.y);
        }
    }
}

fn isCounterClockwise(vertices: []const IVec2) bool {
    var sum: i64 = 0;
    const n = vertices.len;
    for (0..n) |i| {
        const current = vertices[i];
        const next = vertices[(i + 1) % n];
        sum += @as(i64, next.x - current.x) * @as(i64, next.y + current.y);
    }
    return sum > 0;
}
