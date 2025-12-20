const std = @import("std");
const sdl = @import("zsdl");
const config = @import("config.zig");
const shared = @import("shared.zig");

pub const Viewport = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub var activeViewport: Viewport = .{
    .x = 0,
    .y = 0,
    .width = config.window.width,
    .height = config.window.height,
};

pub var viewports: std.AutoArrayHashMapUnmanaged(usize, Viewport) = .{};

pub fn addViewportForCamera(cameraId: usize) !void {
    try viewports.put(shared.allocator, cameraId, .{
        .x = 0,
        .y = 0,
        .width = config.window.width,
        .height = config.window.height,
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
        try viewports.put(shared.allocator, cameraIds[0], .{
            .x = 0,
            .y = 0,
            .width = config.window.width,
            .height = config.window.height,
        });
        return;
    }

    if (count == 2) {
        // Vertical split
        try viewports.put(shared.allocator, cameraIds[0], .{
            .x = 0,
            .y = 0,
            .width = @divFloor(config.window.width, 2),
            .height = config.window.height,
        });
        try viewports.put(shared.allocator, cameraIds[1], .{
            .x = @divFloor(config.window.width, 2),
            .y = 0,
            .width = @divFloor(config.window.width, 2),
            .height = config.window.height,
        });
    }
    // Could add 3-4 player layouts later
}

pub fn getViewportForCamera(cameraId: usize) ?Viewport {
    const maybeVp = viewports.get(cameraId);
    return maybeVp;
}

pub fn cleanup() void {
    viewports.deinit(shared.allocator);
}

pub fn setActiveViewport(renderer: *sdl.Renderer, cameraId: usize) !void {
    const maybeVp = getViewportForCamera(cameraId);

    if (maybeVp) |vp| {
        const sdlVp = sdl.Rect{
            .x = vp.x,
            .y = vp.y,
            .w = vp.width,
            .h = vp.height,
        };
        try sdl.renderSetViewport(renderer, &sdlVp);
        activeViewport = vp;
    }
}
