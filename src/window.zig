const std = @import("std");
const sdl = @import("sdl.zig");
const config = @import("config.zig");
const viewport = @import("viewport.zig");

pub var width: i32 = config.window.defaultWidth;
pub var height: i32 = config.window.defaultHeight;

var sdlWindow: ?*sdl.Window = null;

pub fn init() !void {
    try sdl.init(.{ .audio = true, .video = true, .gamepad = true });

    const displays = try sdl.getDisplays();
    if (displays.len < 1) {
        return error.NoDisplaysFound;
    }

    const displayIndex: usize = if (displays.len > 1) 1 else 0;
    const displayBounds = try sdl.getDisplayBounds(displays[displayIndex]);

    width = @divFloor(displayBounds.w * 9, 10);
    height = @divFloor(displayBounds.h * 9, 10);

    sdlWindow = try sdl.createWindow(
        "My Super Duper Game Window",
        @intCast(width),
        @intCast(height),
        .{ .resizable = true },
    );
}

pub fn cleanup() void {
    if (sdlWindow) |w| {
        sdl.destroyWindow(w);
        sdlWindow = null;
    }
    sdl.quit();
}

pub fn getWindow() !*sdl.Window {
    return sdlWindow orelse error.WindowNotInitialized;
}

pub fn handleResize(newWidth: i32, newHeight: i32) !void {
    width = newWidth;
    height = newHeight;
    try viewport.regenerateViewports();
}
