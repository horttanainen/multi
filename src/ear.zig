const std = @import("std");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const equals = @import("vector.zig").equals;

const allocator = @import("shared.zig").allocator;
const PI = std.math.pi;
const ArrayList = std.ArrayList;

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

fn sign(p1: Vec2, p2: Vec2, p3: Vec2) f32 {
    return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
}

fn isPointInTriangle(p: IVec2, a: IVec2, b: IVec2, c: IVec2) bool {
    // Convert coordinates to floating–point.
    const pF = Vec2{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
    const aF = Vec2{ .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) };
    const bF = Vec2{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) };
    const cF = Vec2{ .x = @floatFromInt(c.x), .y = @floatFromInt(c.y) };

    const d1 = sign(pF, aF, bF);
    const d2 = sign(pF, bF, cF);
    const d3 = sign(pF, cF, aF);

    const hasNeg = (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0);
    const hasPos = (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0);

    return !(hasNeg and hasPos);
}

pub fn earClipping(vertices: []const IVec2) ![][3]IVec2 {
    var triangles = ArrayList([3]IVec2).init(allocator);

    // Make a mutable copy of the vertices.
    var verts = ArrayList(IVec2).init(allocator);
    defer verts.deinit();
    for (vertices) |v| {
        try verts.append(v);
    }

    while (verts.items.len > 3) {
        var maybeEarInd: ?usize = null;
        var prevIndex: usize = 0;
        var nextIndex: usize = 0;

        for (verts.items, 0..) |_, i| {
            prevIndex = @intCast(@mod(@as(i32, @intCast(i)) - 1, @as(i32, @intCast(verts.items.len))));
            nextIndex = @mod(i + 1, verts.items.len);

            const a = verts.items[@intCast(prevIndex)];
            const b = verts.items[i];
            const c = verts.items[nextIndex];

            // Only consider convex vertices.
            if (!isConvex(a, b, c)) continue;

            // Check that no other vertex lies inside triangle (a, b, c)
            var isEar = true;
            for (verts.items) |vertex| {
                if (equals(vertex, a) or equals(vertex, b) or equals(vertex, c)) continue;
                if (isPointInTriangle(vertex, a, b, c)) {
                    isEar = false;
                    break;
                }
            }
            if (isEar) {
                maybeEarInd = i;
                break;
            }
        }

        if (maybeEarInd) |earIndex| {

            // Form a triangle with the ear.
            const earTriangle: [3]IVec2 = .{
                verts.items[@intCast(prevIndex)],
                verts.items[earIndex],
                verts.items[@intCast(nextIndex)],
            };
            try triangles.append(earTriangle);

            // Remove the ear vertex.
            _ = verts.orderedRemove(earIndex);
        } else {
            return triangles.toOwnedSlice();
        }
    }

    // The remaining 3 vertices form the final triangle.
    const finalTriangle: [3]IVec2 = .{ verts.items[0], verts.items[1], verts.items[2] };
    try triangles.append(finalTriangle);

    return triangles.toOwnedSlice();
}
