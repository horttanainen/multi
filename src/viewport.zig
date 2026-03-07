const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const config = @import("config.zig");
const allocator = @import("allocator.zig").allocator;
const window = @import("window.zig");

pub const Viewport = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub var activeViewport: Viewport = .{
    .x = 0,
    .y = 0,
    .width = config.window.defaultWidth,
    .height = config.window.defaultHeight,
};

pub var viewports: std.AutoArrayHashMapUnmanaged(usize, Viewport) = .{};

pub fn addViewportForCamera(cameraId: usize) !void {
    try viewports.put(allocator, cameraId, .{
        .x = 0,
        .y = 0,
        .width = window.width,
        .height = window.height,
    });
    try regenerateViewports();
}

pub fn regenerateViewports() !void {
    const cameraIds = viewports.keys();

    const count = cameraIds.len;

    if (count == 0) {
        return;
    }

    if (count == 1) {
        // Full screen
        try viewports.put(allocator, cameraIds[0], .{
            .x = 0,
            .y = 0,
            .width = window.width,
            .height = window.height,
        });
        return;
    }

    if (count == 2) {
        // Vertical split
        try viewports.put(allocator, cameraIds[0], .{
            .x = 0,
            .y = 0,
            .width = @divFloor(window.width, 2),
            .height = window.height,
        });
        try viewports.put(allocator, cameraIds[1], .{
            .x = @divFloor(window.width, 2),
            .y = 0,
            .width = @divFloor(window.width, 2),
            .height = window.height,
        });
    }
    // Could add 3-4 player layouts later
}

pub fn getViewportForCamera(cameraId: usize) ?Viewport {
    const maybeVp = viewports.get(cameraId);
    return maybeVp;
}

pub fn cleanup() void {
    viewports.deinit(allocator);
    viewports = .{};
}

pub fn setActiveViewport(cameraId: usize) !void {
    const maybeVp = getViewportForCamera(cameraId);

    if (maybeVp) |vp| {
        const sdlVp = sdl.Rect{
            .x = vp.x,
            .y = vp.y,
            .w = vp.width,
            .h = vp.height,
        };
        try gpu.renderSetViewport(&sdlVp);
        activeViewport = vp;
    } else {
        try gpu.renderSetViewport(null);
        activeViewport = .{ .x = 0, .y = 0, .width = window.width, .height = window.height };
    }
}
