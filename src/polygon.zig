const std = @import("std");
const sdl = @import("zsdl");

const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const visvalingam = @import("visvalingam.zig").visvalingam;
const douglasPeucker = @import("douglas.zig").douglasPeucker;
const triangle = @import("triangle.zig");
const shared = @import("shared.zig");
const sprite = @import("sprite.zig");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const vec = @import("vector.zig");

const allocator = @import("shared.zig").allocator;
const PI = std.math.pi;

pub fn triangulate(s: sprite.Sprite) ![][3]IVec2 {
    // std.debug.print("Surface pixel format enum: {any}\n", .{img.format});

    const img = s.surface;
    const surface = img.*;
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);

    // 1. use marching squares algorithm to calculate shape edges. Output list of points in ccw order. -> complex polygon
    const threshold: u8 = 150; // Isovalue threshold for alpha
    const vertices = try pavlidisContour(pixels, width, height, pitch, threshold);
    defer allocator.free(vertices);
    // std.debug.print("Original polygon vertices: {}\n", .{vertices.len});

    // 2. simplify the polygon.
    const epsilonArea: f32 = 0.001 * @as(f32, @floatFromInt(width * height));
    // std.debug.print("epsilonArea: {d}\n", .{epsilonArea});
    const simplified = try visvalingam(vertices, epsilonArea);
    defer allocator.free(simplified);
    // std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});

    // 3. remove duplicates
    const withoutDuplicates = try removeDuplicateVertices(simplified);
    defer allocator.free(withoutDuplicates);
    // std.debug.print("Without duplicate vertices: {}\n", .{withoutDuplicates.len});

    // 4. ensure counter clockwise
    const ccw = try ensureCounterClockwise(withoutDuplicates);
    defer shared.allocator.free(ccw);
    // std.debug.print("CCW vertices: {}\n", .{ccw.len});

    // 5. split into triangles
    const triangles = try triangle.split(ccw);
    defer shared.allocator.free(triangles);
    // std.debug.print("triangles: {}\n", .{triangles.len});

    // 6. scale triangles
    const scaledTriangles = try scaleTriangles(triangles, s.scale);

    return scaledTriangles;
}

pub fn removeDuplicateVertices(vertices: []IVec2) ![]IVec2 {
    var unique = std.array_list.Managed(IVec2).init(allocator);
    defer unique.deinit();

    for (vertices) |v| {
        var isUnique = true;
        for (unique.items) |uV| {
            if (vec.iequals(uV, v)) {
                isUnique = false;
                break;
            }
        }
        if (isUnique) {
            try unique.append(v);
        }
    }

    return unique.toOwnedSlice();
}

pub fn ensureCounterClockwise(vertices: []IVec2) ![]IVec2 {
    if (isCounterClockwise(vertices)) {
        return vertices;
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

fn scaleTriangles(triangles: [][3]IVec2, scale: Vec2) ![][3]IVec2 {
    var scaledTriangles = std.array_list.Managed([3]IVec2).init(allocator);
    for (triangles) |t| {
        const v1 = t[0];
        const v2 = t[1];
        const v3 = t[2];
        const scaledTriangle: [3]IVec2 = .{
            .{
                .x = @intFromFloat(@as(f32, @floatFromInt(v1.x)) * scale.x),
                .y = @intFromFloat(@as(f32, @floatFromInt(v1.y)) * scale.y),
            },
            .{
                .x = @intFromFloat(@as(f32, @floatFromInt(v2.x)) * scale.x),
                .y = @intFromFloat(@as(f32, @floatFromInt(v2.y)) * scale.y),
            },
            .{
                .x = @intFromFloat(@as(f32, @floatFromInt(v3.x)) * scale.x),
                .y = @intFromFloat(@as(f32, @floatFromInt(v3.y)) * scale.y),
            },
        };
        try scaledTriangles.append(scaledTriangle);
    }

    return scaledTriangles.toOwnedSlice();
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
