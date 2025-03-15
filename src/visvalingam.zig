const std = @import("std");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const allocator = @import("shared.zig").allocator;

const PI = std.math.pi;
const ArrayList = std.ArrayList;

fn triangleArea(pointA: IVec2, pointB: IVec2, pointC: IVec2) f32 {
    const a = Vec2{ .x = @floatFromInt(pointA.x), .y = @floatFromInt(pointA.y) };
    const b = Vec2{ .x = @floatFromInt(pointB.x), .y = @floatFromInt(pointB.y) };
    const c = Vec2{ .x = @floatFromInt(pointC.x), .y = @floatFromInt(pointC.y) };

    const vectorBA_x = b.x - a.x;
    const vectorBA_y = b.y - a.y;
    const vectorCA_x = c.x - a.x;
    const vectorCA_y = c.y - a.y;
    const area = @abs(vectorBA_x * vectorCA_y - vectorBA_y * vectorCA_x) / 2;
    return area;
}

pub fn visvalingam(vertices: []IVec2, epsilonArea: f32) ![]IVec2 {
    if (vertices.len <= 2) {
        return vertices;
    }

    // Make a mutable copy of the vertices.
    var verts = ArrayList(IVec2).init(allocator);
    for (vertices) |v| {
        try verts.append(v);
    }

    var minimumArea = epsilonArea;
    var leastContributingPointInd: ?usize = null;

    while (minimumArea <= epsilonArea) {
        if (leastContributingPointInd) |ind| {
            _ = verts.orderedRemove(ind);
        }

        minimumArea = std.math.floatMax(f32);
        leastContributingPointInd = null;

        for (0..verts.items.len) |i| {
            const prevIndex = @mod(@as(i32, @intCast(i)) - 1, @as(i32, @intCast(verts.items.len)));
            const nextIndex = @mod(i + 1, verts.items.len);

            const a = verts.items[@intCast(prevIndex)];
            const b = verts.items[i];
            const c = verts.items[nextIndex];

            const area = triangleArea(a, b, c);
            // std.debug.print("a: {}\n", .{a});
            // std.debug.print("b: {}\n", .{b});
            // std.debug.print("c: {}\n", .{c});
            // std.debug.print("Area: {d}\n", .{area});
            // std.debug.print("epsilonArea: {d}\n", .{epsilonArea});

            if (area < minimumArea) {
                minimumArea = area;
                leastContributingPointInd = i;
            }
        }
    }

    return verts.toOwnedSlice();
}
