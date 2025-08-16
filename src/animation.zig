const std = @import("std");

const vec = @import("vector.zig");
const shared = @import("shared.zig");
const sprite = @import("sprite.zig");

pub const Animation = struct {
    fps: i32,
    current: usize,
    lastTime: f64,
    frames: []sprite.Sprite,
};

pub fn load(pathToAnimationDir: []const u8, fps: i32, scale: vec.Vec2, offset: vec.IVec2) !Animation {
    var dir = try std.fs.cwd().openDir(pathToAnimationDir, .{});
    defer dir.close();

    var images = std.ArrayList([]const u8).init(shared.allocator);
    defer images.deinit();
    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            try images.append(dirContent.name);
        }
    }

    var frames = std.ArrayList(sprite.Sprite).init(shared.allocator);
    for (images.items) |image| {
        var textBuf: [100]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&textBuf, "{s}/{s}", .{ pathToAnimationDir, image });
        const s = try sprite.createFromImg(imagePath, scale, offset);
        try frames.append(s);
    }

    return .{
        .fps = fps,
        .lastTime = 0,
        .current = 0,
        .frames = try frames.toOwnedSlice(),
    };
}
