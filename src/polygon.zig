const std = @import("std");
const sdl = @import("zsdl2");

const pavlidisContour = @import("pavlidis.zig").pavlidisContour;
const douglasPeucker = @import("douglas.zig").douglasPeucker;
const earClipping = @import("ear.zig").earClipping;

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const allocator = @import("shared.zig").allocator;
const PI = std.math.pi;
const ArrayList = std.ArrayList;

pub fn triangulate(img: *sdl.Surface) ![][3]IVec2 {
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

    // 2. simplify the polygon. E.g douglas pecker

    const epsilon: f32 = 0.05 * @as(f32, @floatFromInt(width));
    const simplified = try douglasPeucker(vertices, epsilon);
    defer allocator.free(simplified);

    // 3. remove duplicates

    // Remove last vertex since it is same as first
    const prunedVertices = simplified[0 .. simplified.len - 1];
    const withoutDuplicates = try removeDuplicateVertices(prunedVertices);
    defer allocator.free(withoutDuplicates);

    // 4. ensure counter clockwise
    const ccw = try ensureCounterClockwise(withoutDuplicates);

    // 5. split into triangles
    const triangles = try earClipping(ccw);

    std.debug.print("Original polygon vertices: {}\n", .{vertices.len});
    std.debug.print("Simplified polygon vertices: {}\n", .{simplified.len});
    std.debug.print("Pruned polygon vertices: {}\n", .{prunedVertices.len});
    std.debug.print("Without duplicate vertices: {}\n", .{withoutDuplicates.len});
    std.debug.print("CCW vertices: {}\n", .{ccw.len});

    std.debug.print("triangles: {}\n", .{triangles.len});
    return triangles;
}

pub fn removeDuplicateVertices(vertices: []IVec2) ![]IVec2 {
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

pub fn ensureCounterClockwise(vertices: []IVec2) ![]IVec2 {
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
