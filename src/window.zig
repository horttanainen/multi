const std = @import("std");
const sdl = @import("zsdl");
const config = @import("config.zig");
const viewport = @import("viewport.zig");

// SDL functions not exposed in zsdl
extern fn SDL_GetNumVideoDisplays() c_int;
extern fn SDL_GetDisplayBounds(displayIndex: c_int, rect: *sdl.Rect) c_int;

pub var width: i32 = config.window.defaultWidth;
pub var height: i32 = config.window.defaultHeight;

var sdlWindow: ?*sdl.Window = null;

pub fn init() !void {
    try sdl.init(.{ .audio = true, .video = true, .timer = true, .gamecontroller = true });

    const numDisplays = SDL_GetNumVideoDisplays();
    if (numDisplays < 1) {
        return error.NoDisplaysFound;
    }

    const displayIndex: c_int = if (numDisplays > 1) 1 else 0;

    var displayBounds: sdl.Rect = undefined;
    if (SDL_GetDisplayBounds(displayIndex, &displayBounds) != 0) {
        return error.GetDisplayBoundsFailed;
    }

    width = @divFloor(displayBounds.w * 9, 10);
    height = @divFloor(displayBounds.h * 9, 10);

    sdlWindow = try sdl.createWindow(
        "My Super Duper Game Window",
        sdl.Window.posUndefinedDisplay(displayIndex),
        sdl.Window.posUndefinedDisplay(displayIndex),
        @intCast(width),
        @intCast(height),
        .{ .opengl = true, .shown = true, .resizable = true },
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
