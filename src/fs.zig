const std = @import("std");
const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const runtime = @import("runtime.zig");
const vec = @import("vector.zig");

const FsError = error{
    NotFound,
};

pub fn listFiles(folderPath: []const u8) ![][]const u8 {
    const io_value = runtime.io();
    var dir = std.Io.Dir.cwd().openDir(io_value, folderPath, .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open folder {s}: {}\n", .{ folderPath, err });
        return err;
    };
    defer dir.close(io_value);

    var names = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }

    var dirIter = dir.iterate();
    while (try dirIter.next(io_value)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice();
}

pub fn readFile(path: []const u8, buf: []u8) ![]const u8 {
    const io_value = runtime.io();
    const file = try std.Io.Dir.cwd().openFile(io_value, path, .{});
    defer file.close(io_value);
    const bytesRead = try file.readPositionalAll(io_value, buf, 0);
    return buf[0..bytesRead];
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
    const io_value = runtime.io();
    const file = try std.Io.Dir.cwd().createFile(io_value, path, .{ .truncate = true });
    defer file.close(io_value);
    try file.writeStreamingAll(io_value, contents);
}

pub fn loadSpritesFromFolder(folderPath: []const u8, scale: vec.Vec2, offset: vec.IVec2) ![]u64 {
    return loadSpritesFromFolderWithBacking(folderPath, scale, offset, .immutable);
}

pub fn loadSpritesFromFolderWithBacking(folderPath: []const u8, scale: vec.Vec2, offset: vec.IVec2, backing: sprite.Backing) ![]u64 {
    const fileNames = try listFiles(folderPath);
    defer {
        for (fileNames) |name| allocator.free(name);
        allocator.free(fileNames);
    }

    if (fileNames.len == 0) {
        std.debug.print("Warning: No sprites found in {s}\n", .{folderPath});
        return FsError.NotFound;
    }

    var spriteUuids = std.array_list.Managed(u64).init(allocator);
    for (fileNames) |imageName| {
        var pathBuf: [256]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&pathBuf, "{s}/{s}", .{ folderPath, imageName });

        const uuid = try sprite.createFromImgWithBacking(imagePath, scale, offset, backing);
        try spriteUuids.append(uuid);
    }

    return spriteUuids.toOwnedSlice();
}
