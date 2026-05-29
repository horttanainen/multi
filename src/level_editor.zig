const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const background = @import("background.zig");
const box2d = @import("box2d.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const cursor = @import("cursor.zig");
const entity = @import("entity.zig");
const level = @import("level.zig");
const sensor = @import("sensor.zig");
const state = @import("state.zig");
const uuid = @import("uuid.zig");
const vec = @import("vector.zig");

const RuntimeBody = struct {
    bodyId: box2d.c.b2BodyId,
    offsetM: vec.Vec2,
};

const EntityUpdateCommand = struct {
    before: entity.SerializableEntity,
    after: entity.SerializableEntity,
};

const ConfigUpdateCommand = struct {
    before: Config,
    after: Config,
};

const EditorCommand = union(enum) {
    add_entity: entity.SerializableEntity,
    delete_entity: entity.SerializableEntity,
    update_entity: EntityUpdateCommand,
    update_config: ConfigUpdateCommand,
};

const LevelDocument = struct {
    levelData: level.Level,
    dirty: bool,
    undoHistory: std.array_list.Managed(EditorCommand),
    redoHistory: std.array_list.Managed(EditorCommand),
};

var maybeSelectedEntityId: ?u64 = null;
var maybeCopiedEntityId: ?u64 = null;

var editDirPathBuf: [100]u8 = undefined;
var editDirPath: []const u8 = "";
var editFilePathBuf: [200]u8 = undefined;
var editFilePath: []const u8 = "";

var maybeDocument: ?LevelDocument = null;
var tryingLevel: bool = false;

var entityBodies = std.AutoArrayHashMap(u64, []RuntimeBody).init(allocator);
var bodyToEntity = std.AutoArrayHashMap(box2d.c.b2BodyId, u64).init(allocator);

const default_config = Config{
    .gravity = 10.0,
    .levelHeightMeters = level.defaultLevelHeightMeters,
    .cameraZoomMeters = level.defaultCameraZoomMeters,
    .aspectRatio = level.defaultAspectRatio,
    .splitscreen = false,
};

pub const Config = struct {
    gravity: f32,
    levelHeightMeters: f32,
    cameraZoomMeters: f32,
    aspectRatio: level.AspectRatio,
    splitscreen: bool,
};

fn getDocument() !*LevelDocument {
    if (maybeDocument == null) {
        std.log.warn("getDocument: no editor document is open", .{});
        return error.NoOpenLevel;
    }

    return &maybeDocument.?;
}

fn setEditFilePath(fileName: []const u8) !void {
    editFilePath = try std.fmt.bufPrint(&editFilePathBuf, "{s}/{s}", .{ editDirPath, fileName });
}

fn createRandomAlphabeticalString(length: usize) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);

    for (0..length) |_| {
        const randomInt = std.crypto.random.intRangeAtMost(u8, 97, 122);
        try buffer.append(randomInt);
    }

    return buffer.toOwnedSlice();
}

fn cloneParallaxEntity(e: background.SerializableParallaxEntity) !background.SerializableParallaxEntity {
    return .{
        .parallaxDistance = e.parallaxDistance,
        .fog = e.fog,
        .imgPath = try allocator.dupe(u8, e.imgPath),
        .scale = e.scale,
        .pos = e.pos,
    };
}

fn freeParallaxEntity(e: background.SerializableParallaxEntity) void {
    allocator.free(e.imgPath);
}

fn cloneSerializableEntity(e: entity.SerializableEntity) !entity.SerializableEntity {
    const entityType = try allocator.dupe(u8, e.type);
    errdefer allocator.free(entityType);

    const imgPath = try allocator.dupe(u8, e.imgPath);
    errdefer allocator.free(imgPath);

    return .{
        .id = e.id,
        .type = entityType,
        .friction = e.friction,
        .imgPath = imgPath,
        .scale = e.scale,
        .pos = e.pos,
        .breakable = e.breakable,
    };
}

fn freeSerializableEntity(e: entity.SerializableEntity) void {
    allocator.free(e.type);
    allocator.free(e.imgPath);
}

fn cloneLevelData(src: level.Level) !level.Level {
    var parallaxEntities = try allocator.alloc(background.SerializableParallaxEntity, src.parallaxEntities.len);
    errdefer allocator.free(parallaxEntities);
    var parallaxInitialized: usize = 0;
    errdefer {
        for (parallaxEntities[0..parallaxInitialized]) |e| {
            freeParallaxEntity(e);
        }
    }

    for (src.parallaxEntities, 0..) |e, idx| {
        parallaxEntities[idx] = try cloneParallaxEntity(e);
        parallaxInitialized += 1;
    }

    var entities = try allocator.alloc(entity.SerializableEntity, src.entities.len);
    errdefer allocator.free(entities);
    var entitiesInitialized: usize = 0;
    errdefer {
        for (entities[0..entitiesInitialized]) |e| {
            freeSerializableEntity(e);
        }
    }

    for (src.entities, 0..) |e, idx| {
        entities[idx] = try cloneSerializableEntity(e);
        entitiesInitialized += 1;
    }

    return .{
        .size = src.size,
        .levelHeightMeters = src.levelHeightMeters,
        .cameraZoomMeters = level.sanitizeCameraZoomMeters(src.cameraZoomMeters),
        .aspectRatio = src.aspectRatio,
        .gravity = src.gravity,
        .pixelsPerMeter = level.defaultPixelsPerMeter,
        .splitscreen = src.splitscreen,
        .parallaxEntities = parallaxEntities,
        .entities = entities,
    };
}

fn freeLevelData(lev: *level.Level) void {
    for (lev.parallaxEntities) |e| {
        freeParallaxEntity(e);
    }
    allocator.free(lev.parallaxEntities);

    for (lev.entities) |e| {
        freeSerializableEntity(e);
    }
    allocator.free(lev.entities);

    lev.parallaxEntities = &.{};
    lev.entities = &.{};
}

fn cloneCommand(command: EditorCommand) !EditorCommand {
    return switch (command) {
        .add_entity => |e| .{ .add_entity = try cloneSerializableEntity(e) },
        .delete_entity => |e| .{ .delete_entity = try cloneSerializableEntity(e) },
        .update_entity => |update| blk: {
            const before = try cloneSerializableEntity(update.before);
            errdefer freeSerializableEntity(before);

            const after = try cloneSerializableEntity(update.after);
            errdefer freeSerializableEntity(after);

            break :blk .{
                .update_entity = .{
                    .before = before,
                    .after = after,
                },
            };
        },
        .update_config => |update| .{ .update_config = update },
    };
}

fn freeCommand(command: *EditorCommand) void {
    switch (command.*) {
        .add_entity => |e| freeSerializableEntity(e),
        .delete_entity => |e| freeSerializableEntity(e),
        .update_entity => |update| {
            freeSerializableEntity(update.before);
            freeSerializableEntity(update.after);
        },
        .update_config => {},
    }
}

fn clearCommandHistory(history: *std.array_list.Managed(EditorCommand)) void {
    for (history.items) |*command| {
        freeCommand(command);
    }
    history.deinit();
    history.* = std.array_list.Managed(EditorCommand).init(allocator);
}

fn freeDocument(document: *LevelDocument) void {
    freeLevelData(&document.levelData);
    clearCommandHistory(&document.undoHistory);
    clearCommandHistory(&document.redoHistory);
}

fn closeDocument() void {
    if (maybeDocument == null) return;

    freeDocument(&maybeDocument.?);
    maybeDocument = null;
}

fn createDocument(lev: level.Level) void {
    maybeDocument = .{
        .levelData = lev,
        .dirty = false,
        .undoHistory = std.array_list.Managed(EditorCommand).init(allocator),
        .redoHistory = std.array_list.Managed(EditorCommand).init(allocator),
    };
}

fn loadDocumentFromPath(path: []const u8) !void {
    const parsed = try level.parseFromPath(path);
    defer parsed.deinit();

    const lev = try cloneLevelData(parsed.value);
    closeDocument();
    createDocument(lev);
}

fn createEmptyLevelData() !level.Level {
    const parallaxEntities = try allocator.alloc(background.SerializableParallaxEntity, 0);
    errdefer allocator.free(parallaxEntities);

    const entities = try allocator.alloc(entity.SerializableEntity, 0);
    errdefer allocator.free(entities);

    return .{
        .size = level.sizeFromHeightAndAspect(level.defaultLevelHeightMeters, level.defaultAspectRatio, level.defaultPixelsPerMeter),
        .levelHeightMeters = level.defaultLevelHeightMeters,
        .cameraZoomMeters = level.defaultCameraZoomMeters,
        .aspectRatio = level.defaultAspectRatio,
        .gravity = 10.0,
        .pixelsPerMeter = level.defaultPixelsPerMeter,
        .splitscreen = false,
        .parallaxEntities = parallaxEntities,
        .entities = entities,
    };
}

fn writeLevelToPath(lev: level.Level, path: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    var buf: [config.maxLevelSizeInBytes]u8 = undefined;
    var writer = f.writer(&buf);
    var s = std.json.Stringify{
        .writer = &writer.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try s.write(lev);
    try writer.interface.flush();
}

fn saveDocumentToWorkingFile() !void {
    const document = try getDocument();
    if (editFilePath.len == 0) {
        std.log.warn("saveDocumentToWorkingFile: no edit file path is set", .{});
        return error.NoOpenLevel;
    }

    try writeLevelToPath(document.levelData, editFilePath);
    document.dirty = false;
}

fn findEntityIndex(document: *LevelDocument, entityId: u64) ?usize {
    for (document.levelData.entities, 0..) |e, idx| {
        if (e.id == entityId) return idx;
    }

    return null;
}

fn getDocumentEntity(document: *LevelDocument, entityId: u64) !entity.SerializableEntity {
    const idx = findEntityIndex(document, entityId) orelse {
        std.log.warn("getDocumentEntity: entity {d} not found in document", .{entityId});
        return error.EntityNotFound;
    };

    return document.levelData.entities[idx];
}

fn generateEntityId(document: *LevelDocument) u64 {
    while (true) {
        const id = uuid.generate();
        if (id == 0) continue;
        if (findEntityIndex(document, id) != null) continue;
        return id;
    }
}

fn appendEntityToDocument(document: *LevelDocument, newEntity: entity.SerializableEntity) !void {
    var entities = try allocator.alloc(entity.SerializableEntity, document.levelData.entities.len + 1);
    errdefer allocator.free(entities);

    for (document.levelData.entities, 0..) |e, idx| {
        entities[idx] = e;
    }
    entities[document.levelData.entities.len] = newEntity;

    allocator.free(document.levelData.entities);
    document.levelData.entities = entities;
    document.dirty = true;
}

fn removeEntityFromDocument(document: *LevelDocument, entityId: u64) !entity.SerializableEntity {
    const idx = findEntityIndex(document, entityId) orelse {
        std.log.warn("removeEntityFromDocument: entity {d} not found in document", .{entityId});
        return error.EntityNotFound;
    };

    const removedEntity = document.levelData.entities[idx];
    var entities = try allocator.alloc(entity.SerializableEntity, document.levelData.entities.len - 1);
    errdefer allocator.free(entities);

    var outIdx: usize = 0;
    for (document.levelData.entities, 0..) |e, inIdx| {
        if (inIdx == idx) continue;
        entities[outIdx] = e;
        outIdx += 1;
    }

    allocator.free(document.levelData.entities);
    document.levelData.entities = entities;
    document.dirty = true;
    return removedEntity;
}

fn replaceEntityInDocument(document: *LevelDocument, replacement: entity.SerializableEntity) !entity.SerializableEntity {
    const idx = findEntityIndex(document, replacement.id) orelse {
        std.log.warn("replaceEntityInDocument: entity {d} not found in document", .{replacement.id});
        return error.EntityNotFound;
    };

    const oldEntity = document.levelData.entities[idx];
    document.levelData.entities[idx] = replacement;
    document.dirty = true;
    return oldEntity;
}

fn updateSpawnLocationFromDocument() void {
    if (maybeDocument == null) return;

    level.spawnLocation = vec.IVec2{ .x = 0, .y = 0 };
    for (maybeDocument.?.levelData.entities) |e| {
        if (!std.mem.eql(u8, e.type, "spawn")) continue;
        level.spawnLocation = e.pos;
        return;
    }
}

fn destroyBodyId(bodyId: box2d.c.b2BodyId) bool {
    if (entity.remove(bodyId)) return true;
    if (sensor.remove(bodyId)) return true;
    return false;
}

fn destroyRawBodyIds(bodyIds: []const box2d.c.b2BodyId) void {
    for (bodyIds) |bodyId| {
        if (destroyBodyId(bodyId)) continue;
        std.log.warn("destroyRawBodyIds: body was not found while cleaning editor runtime entity", .{});
    }
}

fn destroyRuntimeBodies(runtimeBodies: []const RuntimeBody) void {
    for (runtimeBodies) |runtimeBody| {
        _ = bodyToEntity.swapRemove(runtimeBody.bodyId);
        if (destroyBodyId(runtimeBody.bodyId)) continue;
        std.log.warn("destroyRuntimeBodies: body was not found while cleaning editor runtime entity", .{});
    }
}

fn clearRuntimeIndex() void {
    for (entityBodies.values()) |runtimeBodies| {
        allocator.free(runtimeBodies);
    }
    entityBodies.clearRetainingCapacity();
    bodyToEntity.clearRetainingCapacity();
}

fn destroyRuntimeEntity(entityId: u64) bool {
    const maybeKV = entityBodies.fetchSwapRemove(entityId);
    if (maybeKV == null) return false;

    destroyRuntimeBodies(maybeKV.?.value);
    allocator.free(maybeKV.?.value);
    return true;
}

fn registerRuntimeEntity(serializedEntity: entity.SerializableEntity, bodyIds: []box2d.c.b2BodyId) !void {
    const entityPos = conv.pixel2M(serializedEntity.pos);
    var runtimeBodies = try allocator.alloc(RuntimeBody, bodyIds.len);
    errdefer allocator.free(runtimeBodies);

    for (bodyIds, 0..) |bodyId, idx| {
        const bodyState = box2d.getState(bodyId);
        runtimeBodies[idx] = .{
            .bodyId = bodyId,
            .offsetM = .{
                .x = bodyState.pos.x - entityPos.x,
                .y = bodyState.pos.y - entityPos.y,
            },
        };
    }

    try entityBodies.put(serializedEntity.id, runtimeBodies);
    errdefer _ = entityBodies.swapRemove(serializedEntity.id);

    var mappedBodies: usize = 0;
    errdefer {
        for (runtimeBodies[0..mappedBodies]) |runtimeBody| {
            _ = bodyToEntity.swapRemove(runtimeBody.bodyId);
        }
    }

    for (runtimeBodies) |runtimeBody| {
        try bodyToEntity.put(runtimeBody.bodyId, serializedEntity.id);
        mappedBodies += 1;
    }
}

fn spawnRuntimeEntity(serializedEntity: entity.SerializableEntity) !void {
    const bodyIds = try level.spawnSerializableEntity(serializedEntity);
    defer allocator.free(bodyIds);
    errdefer destroyRawBodyIds(bodyIds);

    try registerRuntimeEntity(serializedEntity, bodyIds);
}

fn recreateRuntimeEntity(serializedEntity: entity.SerializableEntity) !void {
    _ = destroyRuntimeEntity(serializedEntity.id);
    try spawnRuntimeEntity(serializedEntity);
}

fn setRuntimeEntityHighlight(entityId: u64, highlighted: bool) void {
    const runtimeBodies = entityBodies.get(entityId) orelse {
        std.log.warn("setRuntimeEntityHighlight: entity {d} has no runtime bodies", .{entityId});
        return;
    };

    for (runtimeBodies) |runtimeBody| {
        const maybeE = entity.getEntity(runtimeBody.bodyId);
        if (maybeE != null) {
            maybeE.?.highlighted = highlighted;
            continue;
        }

        if (sensor.setHighlighted(runtimeBody.bodyId, highlighted)) continue;
    }
}

fn selectEntity(entityId: u64) void {
    if (maybeSelectedEntityId) |selectedEntityId| {
        setRuntimeEntityHighlight(selectedEntityId, false);
    }

    maybeSelectedEntityId = entityId;
    setRuntimeEntityHighlight(entityId, true);
}

fn clearSelection() void {
    if (maybeSelectedEntityId) |selectedEntityId| {
        setRuntimeEntityHighlight(selectedEntityId, false);
    }

    maybeSelectedEntityId = null;
}

fn recordCommand(command: EditorCommand) void {
    if (maybeDocument == null) {
        std.log.warn("recordCommand: no document is open", .{});
        return;
    }

    var ownedCommand = cloneCommand(command) catch |err| {
        std.log.warn("recordCommand: failed to clone command: {}", .{err});
        return;
    };
    errdefer freeCommand(&ownedCommand);

    maybeDocument.?.undoHistory.append(ownedCommand) catch |err| {
        std.log.warn("recordCommand: failed to append undo command: {}", .{err});
        return;
    };
    clearCommandHistory(&maybeDocument.?.redoHistory);
}

fn addEntity(serializedEntity: entity.SerializableEntity, recordHistory: bool) !void {
    const document = try getDocument();

    const documentEntity = try cloneSerializableEntity(serializedEntity);
    errdefer freeSerializableEntity(documentEntity);

    try spawnRuntimeEntity(serializedEntity);
    errdefer _ = destroyRuntimeEntity(serializedEntity.id);

    try appendEntityToDocument(document, documentEntity);

    if (recordHistory) {
        recordCommand(.{ .add_entity = serializedEntity });
    }

    updateSpawnLocationFromDocument();
}

fn deleteEntity(entityId: u64, recordHistory: bool) !void {
    const document = try getDocument();

    const removedEntity = try removeEntityFromDocument(document, entityId);
    if (!destroyRuntimeEntity(entityId)) {
        std.log.warn("deleteEntity: entity {d} had no runtime mapping", .{entityId});
    }

    if (maybeSelectedEntityId != null and maybeSelectedEntityId.? == entityId) {
        maybeSelectedEntityId = null;
    }
    if (maybeCopiedEntityId != null and maybeCopiedEntityId.? == entityId) {
        maybeCopiedEntityId = null;
    }

    if (recordHistory) {
        recordCommand(.{ .delete_entity = removedEntity });
    }

    freeSerializableEntity(removedEntity);
    updateSpawnLocationFromDocument();
}

fn updateEntity(serializedEntity: entity.SerializableEntity, recordHistory: bool) !void {
    const document = try getDocument();

    const documentEntity = try cloneSerializableEntity(serializedEntity);
    errdefer freeSerializableEntity(documentEntity);

    const oldEntityForHistory = try cloneSerializableEntity(try getDocumentEntity(document, serializedEntity.id));
    defer freeSerializableEntity(oldEntityForHistory);

    try recreateRuntimeEntity(serializedEntity);

    const oldDocumentEntity = try replaceEntityInDocument(document, documentEntity);
    freeSerializableEntity(oldDocumentEntity);

    if (recordHistory) {
        recordCommand(.{ .update_entity = .{
            .before = oldEntityForHistory,
            .after = serializedEntity,
        } });
    }

    if (maybeSelectedEntityId != null and maybeSelectedEntityId.? == serializedEntity.id) {
        setRuntimeEntityHighlight(serializedEntity.id, true);
    }

    updateSpawnLocationFromDocument();
}

fn applyCommand(command: EditorCommand, isUndo: bool) !void {
    switch (command) {
        .add_entity => |e| {
            if (isUndo) {
                try deleteEntity(e.id, false);
                return;
            }
            try addEntity(e, false);
        },
        .delete_entity => |e| {
            if (isUndo) {
                try addEntity(e, false);
                return;
            }
            try deleteEntity(e.id, false);
        },
        .update_entity => |update| {
            if (isUndo) {
                try updateEntity(update.before, false);
                return;
            }
            try updateEntity(update.after, false);
        },
        .update_config => |update| {
            if (isUndo) {
                try applyConfig(update.before);
                return;
            }
            try applyConfig(update.after);
        },
    }
}

fn popCommand(history: *std.array_list.Managed(EditorCommand)) ?EditorCommand {
    if (history.items.len == 0) return null;
    return history.pop();
}

pub fn undo() !void {
    const document = try getDocument();
    const command = popCommand(&document.undoHistory) orelse return;
    defer {
        var commandToFree = command;
        freeCommand(&commandToFree);
    }

    try applyCommand(command, true);
    var redoCommand = try cloneCommand(command);
    errdefer freeCommand(&redoCommand);
    try document.redoHistory.append(redoCommand);
}

pub fn redo() !void {
    const document = try getDocument();
    const command = popCommand(&document.redoHistory) orelse return;
    defer {
        var commandToFree = command;
        freeCommand(&commandToFree);
    }

    try applyCommand(command, false);
    var undoCommand = try cloneCommand(command);
    errdefer freeCommand(&undoCommand);
    try document.undoHistory.append(undoCommand);
}

pub fn copySelection() void {
    maybeCopiedEntityId = maybeSelectedEntityId;
}

pub fn pasteSelection(position: vec.IVec2) !void {
    const document = try getDocument();
    const copiedEntityId = maybeCopiedEntityId orelse return;
    const copiedEntity = try getDocumentEntity(document, copiedEntityId);

    var pastedEntity = try cloneSerializableEntity(copiedEntity);
    defer freeSerializableEntity(pastedEntity);

    pastedEntity.id = generateEntityId(document);
    pastedEntity.pos = position;

    try addEntity(pastedEntity, true);
    selectEntity(pastedEntity.id);
}

pub fn getEditorLevelPath(buf: []u8) ![]const u8 {
    if (editFilePath.len == 0) {
        std.log.warn("getEditorLevelPath: no edit file path is set", .{});
        return error.NoOpenLevel;
    }

    return std.fmt.bufPrint(buf, "{s}", .{editFilePath});
}

pub fn hasOpenLevel() bool {
    return maybeDocument != null;
}

pub fn isTryingLevel() bool {
    return tryingLevel;
}

pub fn stopTryingLevel() void {
    tryingLevel = false;
}

pub fn tryCurrentLevel() !void {
    _ = try getDocument();
    try saveDocumentToWorkingFile();
    clearSelection();
    clearRuntimeIndex();
    try level.tryEditorLevel(editFilePath);
    tryingLevel = true;
}

fn spawnDocumentRuntime() !void {
    const document = try getDocument();

    level.applyLevelSettings(document.levelData);

    for (document.levelData.parallaxEntities) |e| {
        try level.spawnParallaxEntity(e);
    }

    for (document.levelData.entities) |e| {
        try spawnRuntimeEntity(e);
    }

    updateSpawnLocationFromDocument();
}

pub fn reloadForEditor() !void {
    level.reset();
    clearRuntimeIndex();
    try spawnDocumentRuntime();
    cursor.refreshSprite();

    if (maybeSelectedEntityId) |selectedEntityId| {
        setRuntimeEntityHighlight(selectedEntityId, true);
    }
}

pub fn createNewLevel() !void {
    tryingLevel = false;

    std.fs.cwd().makeDir("drafts") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const randomString = try createRandomAlphabeticalString(8);
    defer allocator.free(randomString);

    editDirPath = try std.fmt.bufPrint(&editDirPathBuf, "drafts/{s}", .{randomString});
    try std.fs.cwd().makeDir(editDirPath);
    try setEditFilePath("level.json");

    const lev = try createEmptyLevelData();
    closeDocument();
    createDocument(lev);
    try saveDocumentToWorkingFile();

    state.editingLevel = true;
    try cursor.create();
    try reloadForEditor();
}

pub fn enter() !void {
    tryingLevel = false;
    state.editingLevel = true;

    if (maybeDocument == null) {
        try createCopyOfCurrentLevel();
        try loadDocumentFromPath(editFilePath);
    }

    try cursor.create();
    try reloadForEditor();
}

fn createCopyOfCurrentLevel() !void {
    const randomString = try createRandomAlphabeticalString(4);
    defer allocator.free(randomString);

    const basename = std.fs.path.basename(level.currentPath);
    var it = std.mem.splitSequence(u8, basename, ".");
    const levelName = it.first();

    var textBuf1: [100]u8 = undefined;
    const levelToEditName = try std.fmt.bufPrint(&textBuf1, "{s}{s}", .{
        levelName,
        randomString,
    });

    editDirPath = try std.fmt.bufPrint(&editDirPathBuf, "levels/{s}", .{levelToEditName});
    try std.fs.cwd().makeDir(editDirPath);
    try setEditFilePath("level.json");

    const srcDir = std.fs.path.dirname(level.currentPath) orelse ".";
    const srcFile = std.fs.path.basename(level.currentPath);

    var srcD = try std.fs.cwd().openDir(srcDir, std.fs.Dir.OpenOptions{});
    defer srcD.close();
    var editingD = try std.fs.cwd().openDir(editDirPath, std.fs.Dir.OpenOptions{});
    defer editingD.close();
    try std.fs.Dir.copyFile(srcD, srcFile, editingD, "level.json", .{});
}

pub fn exit() void {
    clearSelection();
    cursor.deinit();
    state.editingLevel = false;
}

pub fn placeSprite(imgPath: []const u8, scale: vec.Vec2, position: vec.IVec2) !void {
    const document = try getDocument();

    const serializedE = entity.SerializableEntity{
        .id = generateEntityId(document),
        .type = "static",
        .friction = 0.5,
        .imgPath = imgPath,
        .scale = scale,
        .pos = position,
        .breakable = false,
    };

    try addEntity(serializedE, true);
    selectEntity(serializedE.id);
}

pub fn selectEntityAtCursor() ?box2d.c.b2BodyId {
    const worldPos = cursor.getWorldPos();
    return selectEntityAtPosition(worldPos, .{ .x = 0.5, .y = 0.5 });
}

fn selectEntityAtPosition(pos: vec.IVec2, halfExtents: box2d.c.b2Vec2) ?box2d.c.b2BodyId {
    const posM = conv.p2m(pos);
    const aabb = box2d.c.b2AABB{
        .lowerBound = box2d.subtract(posM, halfExtents),
        .upperBound = box2d.add(posM, halfExtents),
    };
    const filter = box2d.c.b2DefaultQueryFilter();
    var result: ?box2d.c.b2BodyId = null;
    box2d.overlapAABB(aabb, filter, cursorOverlapCallback, &result);

    const bodyId = result orelse {
        clearSelection();
        return null;
    };

    const entityId = bodyToEntity.get(bodyId) orelse {
        std.log.warn("selectEntityAtPosition: selected body has no entity mapping", .{});
        clearSelection();
        return null;
    };

    selectEntity(entityId);
    return bodyId;
}

fn cursorOverlapCallback(shapeId: box2d.c.b2ShapeId, context: ?*anyopaque) callconv(.c) bool {
    const result: *?box2d.c.b2BodyId = @ptrCast(@alignCast(context.?));
    const bodyId = box2d.c.b2Shape_GetBody(shapeId);
    if (bodyToEntity.get(bodyId) == null) return true;

    result.* = bodyId;
    return false;
}

pub fn changeEntityType(bodyId: box2d.c.b2BodyId, newType: []const u8) !void {
    const document = try getDocument();
    const entityId = bodyToEntity.get(bodyId) orelse {
        std.log.warn("changeEntityType: body has no entity mapping", .{});
        return error.EntityNotFound;
    };

    const currentEntity = try getDocumentEntity(document, entityId);
    var updatedEntity = try cloneSerializableEntity(currentEntity);
    defer freeSerializableEntity(updatedEntity);

    const updatedType = try allocator.dupe(u8, newType);
    allocator.free(updatedEntity.type);
    updatedEntity.type = updatedType;

    try updateEntity(updatedEntity, true);
}

pub fn moveEntity(entityId: u64, position: vec.IVec2) !void {
    const document = try getDocument();
    const currentEntity = try getDocumentEntity(document, entityId);

    const oldEntityForHistory = try cloneSerializableEntity(currentEntity);
    defer freeSerializableEntity(oldEntityForHistory);

    var updatedEntity = try cloneSerializableEntity(currentEntity);
    defer freeSerializableEntity(updatedEntity);
    updatedEntity.pos = position;

    try setRuntimeEntityPosition(entityId, position);
    const oldDocumentEntity = try replaceEntityInDocument(document, try cloneSerializableEntity(updatedEntity));
    freeSerializableEntity(oldDocumentEntity);

    recordCommand(.{ .update_entity = .{
        .before = oldEntityForHistory,
        .after = updatedEntity,
    } });
    updateSpawnLocationFromDocument();
}

pub fn resizeEntity(entityId: u64, scale: vec.Vec2) !void {
    const document = try getDocument();
    const currentEntity = try getDocumentEntity(document, entityId);

    var updatedEntity = try cloneSerializableEntity(currentEntity);
    defer freeSerializableEntity(updatedEntity);
    updatedEntity.scale = scale;

    try updateEntity(updatedEntity, true);
}

pub fn setRuntimeEntityPosition(entityId: u64, position: vec.IVec2) !void {
    const runtimeBodies = entityBodies.get(entityId) orelse {
        std.log.warn("setRuntimeEntityPosition: entity {d} has no runtime bodies", .{entityId});
        return error.EntityNotFound;
    };

    const basePos = conv.pixel2M(position);
    for (runtimeBodies) |runtimeBody| {
        const pos = box2d.c.b2Vec2{
            .x = basePos.x + runtimeBody.offsetM.x,
            .y = basePos.y + runtimeBody.offsetM.y,
        };
        box2d.c.b2Body_SetTransform(runtimeBody.bodyId, pos, box2d.c.b2Body_GetRotation(runtimeBody.bodyId));
    }
}

pub fn selectEntityAt(pos: vec.IVec2) !void {
    _ = selectEntityAtPosition(pos, .{ .x = 0.1, .y = 0.1 });
}

fn findTemporaryFolders() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var folderList = std.array_list.Managed([]const u8).init(allocator);

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind != std.fs.File.Kind.directory) continue;
        try folderList.append(try allocator.dupe(u8, dirContent.name));
    }

    return folderList.toOwnedSlice();
}

pub fn getConfig() Config {
    if (maybeDocument == null) return default_config;

    return configFromDocument(&maybeDocument.?);
}

fn configFromDocument(document: *LevelDocument) Config {
    return Config{
        .gravity = document.levelData.gravity,
        .levelHeightMeters = document.levelData.levelHeightMeters,
        .cameraZoomMeters = level.sanitizeCameraZoomMeters(document.levelData.cameraZoomMeters),
        .aspectRatio = document.levelData.aspectRatio,
        .splitscreen = document.levelData.splitscreen,
    };
}

fn applyConfig(newConfig: Config) !void {
    const document = try getDocument();

    document.levelData.gravity = newConfig.gravity;
    document.levelData.levelHeightMeters = newConfig.levelHeightMeters;
    document.levelData.cameraZoomMeters = level.sanitizeCameraZoomMeters(newConfig.cameraZoomMeters);
    document.levelData.aspectRatio = newConfig.aspectRatio;
    document.levelData.pixelsPerMeter = level.defaultPixelsPerMeter;
    document.levelData.size = level.sizeFromHeightAndAspect(newConfig.levelHeightMeters, newConfig.aspectRatio, level.defaultPixelsPerMeter);
    document.levelData.splitscreen = newConfig.splitscreen;
    document.dirty = true;
}

pub fn saveConfig(gravity: f32, levelHeightMeters: f32, cameraZoomMeters: f32, aspectRatio: level.AspectRatio, splitscreen: bool) !void {
    const document = try getDocument();
    const before = configFromDocument(document);
    const after = Config{
        .gravity = gravity,
        .levelHeightMeters = levelHeightMeters,
        .cameraZoomMeters = level.sanitizeCameraZoomMeters(cameraZoomMeters),
        .aspectRatio = aspectRatio,
        .splitscreen = splitscreen,
    };

    try applyConfig(after);
    recordCommand(.{ .update_config = .{
        .before = before,
        .after = after,
    } });
}

pub fn cleanup() !void {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    if (maybeDocument != null) {
        const randomString = try createRandomAlphabeticalString(4);
        defer allocator.free(randomString);

        var buffer: [100]u8 = undefined;
        const newFileName = try std.fmt.bufPrint(&buffer, "{s}.json", .{randomString});

        const path = try std.fmt.allocPrint(allocator, "levels/{s}", .{newFileName});
        defer allocator.free(path);
        try writeLevelToPath(maybeDocument.?.levelData, path);
    }

    const folders = try findTemporaryFolders();
    defer {
        for (folders) |folder| {
            allocator.free(folder);
        }
        allocator.free(folders);
    }

    const wasDraft = maybeDocument != null and std.mem.startsWith(u8, editDirPath, "drafts/");

    closeDocument();
    clearRuntimeIndex();

    for (folders) |folder| {
        try dir.deleteTree(folder);
    }

    if (wasDraft) {
        std.fs.cwd().deleteTree(editDirPath) catch {};
    }
}
