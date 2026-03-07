const std = @import("std");
const sdl = @import("sdl.zig");

const cursor = @import("cursor.zig");
const entity = @import("entity.zig");
const allocator = @import("allocator.zig").allocator;
const state = @import("state.zig");
const conv = @import("conversion.zig");
const box2d = @import("box2d.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");
const config = @import("config.zig");
const sprite = @import("sprite.zig");

var maybeSelectedBodyId: ?box2d.c.b2BodyId = null;
var maybeCopiedBodyId: ?box2d.c.b2BodyId = null;

var editDirPathBuf: [100]u8 = undefined;
var editDirPath: []const u8 = undefined;
var maybeCurrentlyOpenLevelFile: ?std.fs.File = null;
var currentVersion: u32 = 0;

pub fn copySelection() void {
    maybeCopiedBodyId = maybeSelectedBodyId;
}

pub fn pasteSelection(position: vec.IVec2) !void {
    if (maybeCopiedBodyId) |copiedBodyId| {
        const maybeE = entity.getEntity(copiedBodyId);
        if (maybeE) |e| {
            if (e.spriteUuids.len == 0) return error.NoSpritesToCopy;
            const firstSprite = sprite.getSprite(e.spriteUuids[0]) orelse return error.SpriteNotFound;

            const spriteUuid = try sprite.createFromImg(
                firstSprite.imgPath,
                firstSprite.scale,
                firstSprite.offset,
            );
            const pos = conv.pixel2M(position);

            var bodyDef = box2d.createDynamicBodyDef(pos);
            bodyDef.type = box2d.c.b2Body_GetType(e.bodyId);
            var shapeDef = box2d.c.b2DefaultShapeDef();

            var shapes: [1]box2d.c.b2ShapeId = undefined;
            _ = box2d.c.b2Body_GetShapes(copiedBodyId, &shapes, 1);
            shapeDef.material.friction = box2d.c.b2Shape_GetFriction(shapes[0]);
            shapeDef.isSensor = box2d.c.b2Shape_IsSensor(shapes[0]);
            shapeDef.material.userMaterialId = box2d.c.b2Shape_GetMaterial(shapes[0]);

            std.debug.print("about to create\n", .{});
            const newEntity = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, e.type);

            const serializedE = entity.serialize(newEntity, position) orelse return error.SerializationFailed;
            try createNewVersion();
            try addEntityToLevel(serializedE);
        }
    }
}

fn createNewVersion() !void {
    const oldVersion = currentVersion;
    currentVersion += 1;
    var textBuf1: [100]u8 = undefined;
    const newFile = try std.fmt.bufPrint(&textBuf1, "{d}.json", .{currentVersion});
    var textBuf2: [100]u8 = undefined;
    const oldFile = try std.fmt.bufPrint(&textBuf2, "{d}.json", .{oldVersion});

    var editingD = try std.fs.cwd().openDir(editDirPath, .{});
    defer editingD.close();
    try std.fs.Dir.copyFile(editingD, oldFile, editingD, newFile, .{});

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenLevelFile| {
        currentlyOpenLevelFile.close();
    }

    maybeCurrentlyOpenLevelFile = try editingD.openFile(newFile, .{ .mode = .read_write });
}

fn addEntityToLevel(serializableEntity: entity.SerializableEntity) !void {
    if (maybeCurrentlyOpenLevelFile) |*currentlyOpenLevelFile| {
        try currentlyOpenLevelFile.seekTo(0);
        const data = try currentlyOpenLevelFile.readToEndAlloc(allocator, config.maxLevelSizeInBytes);
        defer allocator.free(data);
        const parsed = try level.parseFromData(data);
        defer parsed.deinit();
        var serializableLevel = parsed.value;

        var entities = std.array_list.Managed(entity.SerializableEntity).init(allocator);
        defer entities.deinit();

        try entities.appendSlice(serializableLevel.entities);
        try entities.append(serializableEntity);

        serializableLevel.entities = try entities.toOwnedSlice();
        defer allocator.free(serializableLevel.entities);

        try currentlyOpenLevelFile.setEndPos(0);
        try currentlyOpenLevelFile.seekTo(0);

        var buf: [config.maxLevelSizeInBytes]u8 = undefined;
        var writer = currentlyOpenLevelFile.writer(&buf);
        var s = std.json.Stringify{
            .writer = &writer.interface,
            .options = .{ .whitespace = .indent_2 },
        };
        try s.write(serializableLevel);
        try writer.interface.flush();
    }

    try reloadForEditor();
}

fn createRandomAlphabeticalString(length: usize) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);

    for (0..length) |_| {
        const randomInt = std.crypto.random.intRangeAtMost(u8, 97, 122);
        try buffer.append(randomInt);
    }

    return buffer.toOwnedSlice();
}

pub fn getEditorLevelPath(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}.json", .{ editDirPath, currentVersion });
}

pub fn reloadForEditor() !void {
    var pathBuf: [200]u8 = undefined;
    const path = try getEditorLevelPath(&pathBuf);
    try level.loadEditorLevel(path);
    cursor.initSprite();
}

pub fn createNewLevel() !void {
    // Create the drafts directory if it doesn't exist
    std.fs.cwd().makeDir("drafts") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const randomString = try createRandomAlphabeticalString(8);
    defer allocator.free(randomString);

    // Set up the versioned editing directory under drafts/ instead of levels/
    // so the game's level loader never sees this unfinished level.
    editDirPath = try std.fmt.bufPrint(&editDirPathBuf, "drafts/{s}", .{randomString});
    try std.fs.cwd().makeDir(editDirPath);

    currentVersion = 0;

    const emptyLevel =
        \\{"size":{"x":1920,"y":1080},"parallaxEntities":[],"entities":[]}
    ;

    var editingD = try std.fs.cwd().openDir(editDirPath, .{});
    defer editingD.close();

    const versionFile = try editingD.createFile("0.json", .{});
    try versionFile.writeAll(emptyLevel);
    versionFile.close();

    if (maybeCurrentlyOpenLevelFile) |f| f.close();
    maybeCurrentlyOpenLevelFile = try editingD.openFile("0.json", .{ .mode = .read_write });

    state.editingLevel = true;
    try cursor.create();
    try reloadForEditor();
}

pub fn enter() !void {
    state.editingLevel = true;

    if (maybeCurrentlyOpenLevelFile == null) {
        currentVersion = 0;
        try createCopyOfCurrentLevel();
    }

    try cursor.create();
    try reloadForEditor();
}

fn createCopyOfCurrentLevel() !void {
    const randomString = try createRandomAlphabeticalString(4);
    defer allocator.free(randomString);

    var it = std.mem.splitSequence(u8, level.json, ".");
    const levelName = it.first();

    std.debug.print("levelName: {s}\n", .{levelName});

    var textBuf1: [100]u8 = undefined;
    const levelToEditName = try std.fmt.bufPrint(&textBuf1, "{s}{s}", .{
        levelName,
        randomString,
    });

    std.debug.print("levelToEditName: {s}\n", .{levelToEditName});

    editDirPath = try std.fmt.bufPrint(&editDirPathBuf, "levels/{s}", .{levelToEditName});

    std.debug.print("editDirPath: {s}\n", .{editDirPath});

    try std.fs.cwd().makeDir(editDirPath);

    var textBuf2: [100]u8 = undefined;
    const version = try std.fmt.bufPrint(&textBuf2, "{d}.json", .{currentVersion});

    var levelsD = try std.fs.cwd().openDir("levels", std.fs.Dir.OpenOptions{});
    defer levelsD.close();
    var editingD = try std.fs.cwd().openDir(editDirPath, std.fs.Dir.OpenOptions{});
    defer editingD.close();
    try std.fs.Dir.copyFile(levelsD, level.json, editingD, version, .{});

    maybeCurrentlyOpenLevelFile = try editingD.openFile(version, .{ .mode = .read_write });
}

pub fn exit() void {
    if (maybeSelectedBodyId) |selectedBodyId| {
        setSelection(selectedBodyId, false);
    }
    cursor.deinit();
    state.editingLevel = false;
}

pub fn selectEntityAt(pos: vec.IVec2) !void {
    if (maybeSelectedBodyId) |selectedBodyId| {
        setSelection(selectedBodyId, false);
    }

    const posM = conv.p2m(pos);
    const aabb = box2d.c.b2AABB{
        .lowerBound = box2d.subtract(posM, .{ .x = 0.1, .y = 0.1 }),
        .upperBound = box2d.add(posM, .{ .x = 0.1, .y = 0.1 }),
    };
    const filter = box2d.c.b2DefaultQueryFilter();
    box2d.overlapAABB(aabb, filter, overlapAABBCallback, null);
}

fn setSelection(bodyId: box2d.c.b2BodyId, select: bool) void {
    maybeSelectedBodyId = null;
    const maybeE1 = entity.getEntity(bodyId);
    if (maybeE1) |e| {
        e.highlighted = select;
    }
    if (select) {
        maybeSelectedBodyId = bodyId;
    }
}

pub fn overlapAABBCallback(shapeId: box2d.c.b2ShapeId, context: ?*anyopaque) callconv(.c) bool {
    _ = context;

    const bodyId = box2d.c.b2Shape_GetBody(shapeId);

    setSelection(bodyId, true);
    // immediately stop searching for additional shapeIds
    return false;
}

fn findTemporaryFolders() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var folderList = std.array_list.Managed([]const u8).init(allocator);

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.directory) {
            try folderList.append(dirContent.name);
        }
    }

    return folderList.toOwnedSlice();
}

pub const Config = struct { gravity: f32, pixelsPerMeter: i32 };

pub fn getConfig() !Config {
    if (maybeCurrentlyOpenLevelFile) |*f| {
        try f.seekTo(0);
        const data = try f.readToEndAlloc(allocator, config.maxLevelSizeInBytes);
        defer allocator.free(data);
        const parsed = try level.parseFromData(data);
        defer parsed.deinit();
        return Config{ .gravity = parsed.value.gravity, .pixelsPerMeter = parsed.value.pixelsPerMeter };
    }
    return Config{ .gravity = 10.0, .pixelsPerMeter = 80 };
}

pub fn saveConfig(gravity: f32, pixelsPerMeter: i32) !void {
    if (maybeCurrentlyOpenLevelFile) |*currentlyOpenLevelFile| {
        try currentlyOpenLevelFile.seekTo(0);
        const data = try currentlyOpenLevelFile.readToEndAlloc(allocator, config.maxLevelSizeInBytes);
        defer allocator.free(data);
        const parsed = try level.parseFromData(data);
        defer parsed.deinit();
        var serializableLevel = parsed.value;

        serializableLevel.gravity = gravity;
        serializableLevel.pixelsPerMeter = pixelsPerMeter;

        try currentlyOpenLevelFile.setEndPos(0);
        try currentlyOpenLevelFile.seekTo(0);

        var buf: [config.maxLevelSizeInBytes]u8 = undefined;
        var writer = currentlyOpenLevelFile.writer(&buf);
        var s = std.json.Stringify{
            .writer = &writer.interface,
            .options = .{ .whitespace = .indent_2 },
        };
        try s.write(serializableLevel);
        try writer.interface.flush();
    }
}

pub fn cleanup() !void {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenFile| {
        try currentlyOpenFile.seekTo(0);
        const data = try currentlyOpenFile.readToEndAlloc(allocator, config.maxLevelSizeInBytes);
        defer allocator.free(data);

        const randomString = try createRandomAlphabeticalString(4);
        defer allocator.free(randomString);

        var buffer: [100]u8 = undefined;
        const newFileName = try std.fmt.bufPrint(&buffer, "{s}.json", .{randomString});

        const newFile = try dir.createFile(newFileName, .{});
        defer newFile.close();

        try newFile.writeAll(data);
    }

    const folders = try findTemporaryFolders();
    defer allocator.free(folders);

    // Capture before close so we can check it below
    const wasDraft = maybeCurrentlyOpenLevelFile != null and
        std.mem.startsWith(u8, editDirPath, "drafts/");

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenFile| {
        currentlyOpenFile.close();
    }

    for (folders) |folder| {
        try dir.deleteTree(folder);
    }

    // Remove draft directory (lives outside levels/, so not covered above)
    if (wasDraft) {
        std.fs.cwd().deleteTree(editDirPath) catch {};
    }
}
