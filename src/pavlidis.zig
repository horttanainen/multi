const std = @import("std");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const allocator = @import("shared.zig").allocator;

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
