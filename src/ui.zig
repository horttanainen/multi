const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const text = @import("text.zig");

pub fn drawMode() !void {
    const mode = if (shared.editingLevel) "LEVEL EDITOR" else "PLAY";

    try text.writeAt(mode, .{ .x = config.window.width / 2, .y = 2 });
}

pub fn drawFps() !void {
    var fpsTextBuf: [100]u8 = undefined;

    const fps = time.calculateFps();

    const fpsText = try std.fmt.bufPrintZ(&fpsTextBuf, "FPS: {d}", .{fps});
    try text.writeAt(fpsText, .{ .x = config.window.width - 90, .y = 2 });
}
