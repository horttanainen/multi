const std = @import("std");
const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const vec = @import("vector.zig");

const FsError = error{
    NotFound,
};

pub fn listFiles(folderPath: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(folderPath, .{}) catch |err| {
        std.debug.print("Warning: Could not open folder {s}: {}\n", .{ folderPath, err });
        return err;
    };
    defer dir.close();

    var names = std.array_list.Managed([]const u8).init(shared.allocator);
    errdefer {
        for (names.items) |name| shared.allocator.free(name);
        names.deinit();
    }

    var dirIter = dir.iterate();
    while (try dirIter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        try names.append(try shared.allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice();
}

pub fn readFile(path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytesRead = try file.readAll(buf);
    return buf[0..bytesRead];
}

pub fn loadSpritesFromFolder(folderPath: []const u8, scale: vec.Vec2, offset: vec.IVec2) ![]u64 {
    const fileNames = try listFiles(folderPath);
    defer {
        for (fileNames) |name| shared.allocator.free(name);
        shared.allocator.free(fileNames);
    }

    if (fileNames.len == 0) {
        std.debug.print("Warning: No sprites found in {s}\n", .{folderPath});
        return FsError.NotFound;
    }

    var spriteUuids = std.array_list.Managed(u64).init(shared.allocator);
    for (fileNames) |imageName| {
        var pathBuf: [256]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&pathBuf, "{s}/{s}", .{ folderPath, imageName });

        const uuid = try sprite.createFromImg(imagePath, scale, offset);
        try spriteUuids.append(uuid);
    }

    return spriteUuids.toOwnedSlice();
}
