const std = @import("std");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

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
