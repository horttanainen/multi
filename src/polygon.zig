const std = @import("std");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const allocator = @import("shared.zig").allocator;
const PI = std.math.pi;
const ArrayList = std.ArrayList;

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
