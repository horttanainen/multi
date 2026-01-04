const std = @import("std");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const vec = @import("vector.zig");

pub fn loadSpritesFromFolder(folderPath: []const u8, scale: vec.Vec2, offset: vec.IVec2) ![]sprite.Sprite {
    var dir = std.fs.cwd().openDir(folderPath, .{}) catch |err| {
        std.debug.print("Warning: Could not open sprite folder {s}: {}\n", .{ folderPath, err });
        return &[_]sprite.Sprite{};
    };
    defer dir.close();

    var images = std.array_list.Managed([]const u8).init(shared.allocator);
    defer images.deinit();

    var dirIterator = dir.iterate();
    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind != std.fs.File.Kind.file) {
            continue;
        }
        if (std.mem.eql(u8, dirContent.name, ".DS_Store")) {
            continue;
        }
        try images.append(dirContent.name);
    }

    if (images.items.len == 0) {
        std.debug.print("Warning: No sprites found in {s}\n", .{folderPath});
        return &[_]sprite.Sprite{};
    }

    std.mem.sort([]const u8, images.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var sprites = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
    for (images.items) |imageName| {
        var pathBuf: [256]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&pathBuf, "{s}/{s}", .{ folderPath, imageName });

        const s = try sprite.createFromImg(imagePath, scale, offset);
        try sprites.append(s);
    }

    return sprites.toOwnedSlice();
}
