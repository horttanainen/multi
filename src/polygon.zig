const std = @import("std");
const sdl = @import("zsdl");

const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const connected_components = @import("connected_components.zig");
const visvalingam = @import("visvalingam.zig").visvalingam;
const triangle = @import("triangle.zig");
const shared = @import("shared.zig");
const sprite = @import("sprite.zig");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const vec = @import("vector.zig");

const allocator = @import("shared.zig").allocator;
const PI = std.math.pi;

pub const PolygonError = error{
    CouldNotCreateTriangle
};

pub fn triangulate(s: sprite.Sprite) ![][3]IVec2 {
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
    defer shared.allocator.free(ccw);
    // std.debug.print("CCW vertices: {}\n", .{ccw.len});

    // 5. split into triangles
    const triangles = try triangle.split(ccw);
    // std.debug.print("triangles: {}\n", .{triangles.len});

    // 6. scale triangles in-place
    scaleTriangles(triangles, s.scale);

    return triangles;
}

pub fn removeDuplicateVertices(vertices: []IVec2) ![]IVec2 {
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

pub fn ensureCounterClockwise(vertices: []IVec2) ![]IVec2 {
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

fn isCounterClockwise(vertices: []IVec2) bool {
    var sum: i64 = 0;
    const n = vertices.len;
    for (0..n) |i| {
        const current = vertices[i];
        const next = vertices[(i + 1) % n];
        sum += @as(i64, next.x - current.x) * @as(i64, next.y + current.y);
    }
    return sum > 0;
}
