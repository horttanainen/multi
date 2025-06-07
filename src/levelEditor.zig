const std = @import("std");
const image = @import("zsdl_image");
const box2d = @import("box2dnative.zig");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const conv = @import("conversion.zig");
const box = @import("box.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");

var maybeSelectedBodyId: ?box2d.b2BodyId = null;
var maybeCopiedBodyId: ?box2d.b2BodyId = null;

var editDirPathBuf: [100]u8 = undefined;
var editDirPath: []const u8 = undefined;
var maybeCurrentlyOpenLevelFile: ?std.fs.File = null;
var currentVersion: u32 = 0;

pub fn copySelection() void {
    maybeCopiedBodyId = maybeSelectedBodyId;
}

pub fn pasteSelection(pos: vec.IVec2) !void {
    if (maybeCopiedBodyId) |copiedBodyId| {
        const maybeE = entity.getEntity(copiedBodyId);
        if (maybeE) |e| {
            var bodyDef = box.createDynamicBodyDef(pos);
            bodyDef.type = box2d.b2Body_GetType(e.bodyId);
            var shapeDef = box2d.b2DefaultShapeDef();

            var shapes: [1]box2d.b2ShapeId = undefined;
            _ = box2d.b2Body_GetShapes(copiedBodyId, &shapes, 1);
            shapeDef.friction = box2d.b2Shape_GetFriction(shapes[0]);
            shapeDef.isSensor = box2d.b2Shape_IsSensor(shapes[0]);
            shapeDef.material = box2d.b2Shape_GetMaterial(shapes[0]);

            std.debug.print("about to create\n", .{});
            const newEntity = try entity.createFromImg(e.sprite.imgPath, shapeDef, bodyDef, e.type);

            const serializedE = entity.serialize(newEntity, pos);
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

    var editingD = try std.fs.cwd().openDir(editDirPath, std.fs.Dir.OpenOptions{});
    defer editingD.close();
    try std.fs.Dir.copyFile(editingD, oldFile, editingD, newFile, std.fs.Dir.CopyFileOptions{});

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenLevelFile| {
        currentlyOpenLevelFile.close();
    }

    maybeCurrentlyOpenLevelFile = try editingD.openFile(newFile, .{ .mode = .read_write });
}

fn addEntityToLevel(serializableEntity: entity.SerializableEntity) !void {
    if (maybeCurrentlyOpenLevelFile) |currentlyOpenLevelFile| {
        try currentlyOpenLevelFile.seekTo(0);
        const data = try currentlyOpenLevelFile.readToEndAlloc(shared.allocator, 100000);
        defer shared.allocator.free(data);
        const parsed = try level.parseFromData(data);
        defer parsed.deinit();
        var serializableLevel = parsed.value;

        var entities = std.ArrayList(entity.SerializableEntity).init(shared.allocator);
        defer entities.deinit();

        try entities.appendSlice(serializableLevel.entities);
        try entities.append(serializableEntity);

        serializableLevel.entities = try entities.toOwnedSlice();
        defer shared.allocator.free(serializableLevel.entities);

        try currentlyOpenLevelFile.setEndPos(0);
        try currentlyOpenLevelFile.seekTo(0);
        try std.json.stringify(serializableLevel, .{ .whitespace = .indent_2 }, currentlyOpenLevelFile.writer());
    }
}

fn createRandomAlphabeticalString(length: usize) ![]const u8 {
    var buffer = std.ArrayList(u8).init(shared.allocator);

    for (0..length) |_| {
        const randomInt = std.crypto.random.intRangeAtMost(u8, 97, 122);
        try buffer.append(randomInt);
    }

    return buffer.toOwnedSlice();
}

pub fn enter() !void {
    shared.editingLevel = true;

    if (maybeCurrentlyOpenLevelFile == null) {
        currentVersion = 0;
        try createCopyOfCurrentLevel();
    }
}

fn createCopyOfCurrentLevel() !void {
    const randomString = try createRandomAlphabeticalString(4);
    defer shared.allocator.free(randomString);

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
    try std.fs.Dir.copyFile(levelsD, level.json, editingD, version, std.fs.Dir.CopyFileOptions{});

    maybeCurrentlyOpenLevelFile = try editingD.openFile(version, .{ .mode = .read_write });
}

pub fn exit() void {
    if (maybeSelectedBodyId) |selectedBodyId| {
        setSelection(selectedBodyId, false);
    }
    shared.editingLevel = false;
}

pub fn selectEntityAt(pos: vec.IVec2) !void {
    if (maybeSelectedBodyId) |selectedBodyId| {
        setSelection(selectedBodyId, false);
    }

    const posM = conv.p2m(pos);
    const aabb = box2d.b2AABB{
        .lowerBound = box.subtract(posM, .{ .x = 0.1, .y = 0.1 }),
        .upperBound = box.add(posM, .{ .x = 0.1, .y = 0.1 }),
    };
    const resources = try shared.getResources();

    const filter = box2d.b2DefaultQueryFilter();
    _ = box2d.b2World_OverlapAABB(resources.worldId, aabb, filter, &overlapAABBCallback, null);
}

fn setSelection(bodyId: box2d.b2BodyId, select: bool) void {
    maybeSelectedBodyId = null;
    const maybeE1 = entity.getEntity(bodyId);
    if (maybeE1) |e| {
        e.highlighted = select;
    }
    if (select) {
        maybeSelectedBodyId = bodyId;
    }
}

pub fn overlapAABBCallback(shapeId: box2d.b2ShapeId, context: ?*anyopaque) callconv(.C) bool {
    _ = context;

    const bodyId = box2d.b2Shape_GetBody(shapeId);

    setSelection(bodyId, true);
    // immediately stop searching for additional shapeIds
    return false;
}

fn findTemporaryFolders() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var folderList = std.ArrayList([]const u8).init(shared.allocator);

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.directory) {
            try folderList.append(dirContent.name);
        }
    }

    return folderList.toOwnedSlice();
}

pub fn cleanup() !void {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenFile| {
        try currentlyOpenFile.seekTo(0);
        const data = try currentlyOpenFile.readToEndAlloc(shared.allocator, 100000);
        defer shared.allocator.free(data);

        const randomString = try createRandomAlphabeticalString(4);
        defer shared.allocator.free(randomString);

        var buffer: [100]u8 = undefined;
        const newFileName = try std.fmt.bufPrint(&buffer, "{s}.json", .{randomString});

        const newFile = try dir.createFile(newFileName, .{});
        defer newFile.close();

        try newFile.writeAll(data);
    }

    const folders = try findTemporaryFolders();
    defer shared.allocator.free(folders);

    if (maybeCurrentlyOpenLevelFile) |currentlyOpenFile| {
        currentlyOpenFile.close();
    }

    for (folders) |folder| {
        try dir.deleteTree(folder);
    }
}
