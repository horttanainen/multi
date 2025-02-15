const std = @import("std");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const allocator = @import("shared.zig").allocator;

const PI = std.math.pi;
const ArrayList = std.ArrayList;

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

pub fn douglasPeucker(vertices: []IVec2, epsilon: f32) ![]IVec2 {
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
