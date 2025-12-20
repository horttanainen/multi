const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const text = @import("text.zig");
const viewport = @import("viewport.zig");

pub fn drawMode() !void {
    const mode = if (shared.editingLevel) "LEVEL EDITOR" else "PLAY";

    const vp = viewport.activeViewport;

    const xPos = @divFloor(vp.width, 2);
    try text.writeAt(mode, .{ .x = xPos, .y = 2 });
}

pub fn drawFps() !void {
    var fpsTextBuf: [100]u8 = undefined;

    const fps = time.calculateFps();

    const vp = viewport.activeViewport;

    const fpsText = try std.fmt.bufPrintZ(&fpsTextBuf, "FPS: {d}", .{fps});
    const xPos = vp.width - 90;
    try text.writeAt(fpsText, .{ .x = xPos, .y = 2 });
}
