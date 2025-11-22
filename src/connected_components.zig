const std = @import("std");
const IVec2 = @import("vector.zig").IVec2;
const allocator = @import("shared.zig").allocator;
const config = @import("config.zig");

pub const ConnectedComponent = struct {
    pixels: std.array_list.Managed(IVec2),
    size: usize,
};

fn getPixelAlpha(pixels: [*]const u8, pitch: usize, x: usize, y: usize) u8 {
    const a = pixels[y * pitch + x * 4 + 3];
    return a;
}

fn isInside(x: i32, y: i32, pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) bool {
    if (x < 0 or y < 0 or @as(usize, @intCast(x)) >= width or @as(usize, @intCast(y)) >= height) return false;
    const alpha = getPixelAlpha(pixels, pitch, @as(usize, @intCast(x)), @as(usize, @intCast(y)));
    return alpha >= threshold;
}

/// Find all connected components in the image using flood fill (4-connected)
pub fn findConnectedComponents(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) !std.array_list.Managed(ConnectedComponent) {
    // Create a visited map
    var visited = try allocator.alloc(bool, width * height);
    defer allocator.free(visited);
    @memset(visited, false);

    var components = std.array_list.Managed(ConnectedComponent).init(allocator);

    // Scan through all pixels
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;
            if (!visited[idx] and isInside(@intCast(x), @intCast(y), pixels, width, height, pitch, threshold)) {
                // Start a new component with flood fill
                var component_pixels = std.array_list.Managed(IVec2).init(allocator);
                var queue = std.array_list.Managed(IVec2).init(allocator);
                defer queue.deinit();

                try queue.append(IVec2{ .x = @intCast(x), .y = @intCast(y) });
                visited[idx] = true;

                while (queue.items.len > 0) {
                    const current = queue.pop() orelse unreachable; // Safe because we checked len > 0
                    try component_pixels.append(current);

                    // Check 4-connected neighbors (N, E, S, W)
                    const directions = [4]IVec2{
                        .{ .x = 0, .y = -1 }, // N
                        .{ .x = 1, .y = 0 },  // E
                        .{ .x = 0, .y = 1 },  // S
                        .{ .x = -1, .y = 0 }, // W
                    };

                    for (directions) |dir| {
                        const nx = current.x + dir.x;
                        const ny = current.y + dir.y;

                        if (nx >= 0 and ny >= 0 and nx < width and ny < height) {
                            const nidx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                            if (!visited[nidx] and isInside(nx, ny, pixels, width, height, pitch, threshold)) {
                                visited[nidx] = true;
                                try queue.append(IVec2{ .x = nx, .y = ny });
                            }
                        }
                    }
                }

                try components.append(ConnectedComponent{
                    .pixels = component_pixels,
                    .size = component_pixels.items.len,
                });
            }
        }
    }

    return components;
}

/// Find the starting boundary pixel for the largest connected component
/// Returns null if no components are found
pub fn findLargestComponentStart(pixels: [*]const u8, width: usize, height: usize, pitch: usize, threshold: u8) !?IVec2 {
    var components = try findConnectedComponents(pixels, width, height, pitch, threshold);
    defer {
        for (components.items) |*component| {
            component.pixels.deinit();
        }
        components.deinit();
    }

    if (components.items.len == 0) {
        if (config.debugLog) std.debug.print("No components found!\n", .{});
        return null;
    }

    // Find the largest component
    var largest_component_idx: usize = 0;
    var largest_size: usize = 0;
    for (components.items, 0..) |component, i| {
        if (component.size > largest_size) {
            largest_size = component.size;
            largest_component_idx = i;
        }
    }

    const largest_component = &components.items[largest_component_idx];
    if (config.debugLog) std.debug.print("Found {d} components, using largest with {d} pixels\n", .{ components.items.len, largest_size });

    // Find the leftmost pixel in the largest component
    var min_x: i32 = @intCast(width);
    for (largest_component.pixels.items) |pixel| {
        if (pixel.x < min_x) {
            min_x = pixel.x;
        }
    }

    // The 8 neighbors for boundary checking
    const neighbors = [8]IVec2{
        .{ .x = 0, .y = -1 },  // N
        .{ .x = 1, .y = -1 },  // NE
        .{ .x = 1, .y = 0 },   // E
        .{ .x = 1, .y = 1 },   // SE
        .{ .x = 0, .y = 1 },   // S
        .{ .x = -1, .y = 1 },  // SW
        .{ .x = -1, .y = 0 },  // W
        .{ .x = -1, .y = -1 }, // NW
    };

    // Among pixels with minimum x, find a boundary pixel
    for (largest_component.pixels.items) |pixel| {
        if (pixel.x == min_x) {
            // Check if this is a boundary pixel (has at least one non-inside neighbor)
            var is_boundary = false;
            for (neighbors) |neighbor| {
                const nx = pixel.x + neighbor.x;
                const ny = pixel.y + neighbor.y;
                if (!isInside(nx, ny, pixels, width, height, pitch, threshold)) {
                    is_boundary = true;
                    break;
                }
            }

            if (is_boundary) {
                return pixel;
            }
        }
    }

    if (config.debugLog) std.debug.print("Did not find contour start!\n", .{});
    return null;
}
