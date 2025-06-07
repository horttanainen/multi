const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");
const box2d = @import("box2dnative.zig");

const config = @import("config.zig");
const polygon = @import("polygon.zig");
const box = @import("box.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const sensor = @import("sensor.zig");
const camera = @import("camera.zig");

const m2P = @import("conversion.zig").m2P;
const p2m = @import("conversion.zig").p2m;
const m2PixelPos = @import("conversion.zig").m2PixelPos;

const vec = @import("vector.zig");
const entity = @import("entity.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var levelNumber: usize = 0;

var jsonTextBuf: [100]u8 = undefined;
pub var json: []const u8 = undefined;

pub const position: vec.IVec2 = .{
    .x = 400,
    .y = 400,
};
pub var size: vec.IVec2 = .{
    .x = 100,
    .y = 100,
};

const LevelError = error{
    Uninitialized,
};

pub const Level = struct {
    size: vec.IVec2,
    entities: []entity.SerializableEntity,
};

pub fn parseFromData(data: []const u8) !std.json.Parsed(Level) {
    const parsed = try std.json.parseFromSlice(Level, shared.allocator, data, .{ .allocate = .alloc_always });
    return parsed;
}

pub fn parseFromPath(path: []const u8) !std.json.Parsed(Level) {
    const data = try std.fs.cwd().readFileAlloc(shared.allocator, path, 4096);
    defer shared.allocator.free(data);
    return parseFromData(data);
}

pub fn findLevels() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var fileList = std.ArrayList([]const u8).init(shared.allocator);

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            try fileList.append(dirContent.name);
        }
    }

    return fileList.toOwnedSlice();
}

fn loadByName(levelName: []const u8) !void {
    var textBuf: [100]u8 = undefined;
    const levelP = try std.fmt.bufPrint(&textBuf, "levels/{s}", .{levelName});
    json = levelName;

    const parsed = try parseFromPath(levelP);
    defer parsed.deinit();
    const levelToDeserialize = parsed.value;

    var spawnLocation = vec.IVec2{ .x = 0, .y = 0 };

    for (levelToDeserialize.entities) |e| {
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.friction = e.friction;
        if (std.mem.eql(u8, e.type, "dynamic")) {
            const bodyDef = box.createDynamicBodyDef(e.pos);
            _ = try entity.createFromImg(e.imgPath, shapeDef, bodyDef, "dynamic");
        } else if (std.mem.eql(u8, e.type, "static")) {
            const bodyDef = box.createStaticBodyDef(e.pos);
            _ = try entity.createFromImg(e.imgPath, shapeDef, bodyDef, "static");
        } else if (std.mem.eql(u8, e.type, "goal")) {
            try sensor.createGoalSensorFromImg(e.pos, e.imgPath);
        } else if (std.mem.eql(u8, e.type, "spawn")) {
            const bodyDef = box.createStaticBodyDef(e.pos);
            shapeDef.isSensor = true;
            shapeDef.material = config.spawnMaterialId;
            _ = try entity.createFromImg(e.imgPath, shapeDef, bodyDef, "spawn");
            spawnLocation = e.pos;
        }
    }

    try player.spawn(spawnLocation);
    size = levelToDeserialize.size;
}

pub fn reload() !void {
    reset();
    try loadByName(json);
}

pub fn cleanup() void {
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
}

pub fn reset() void {
    shared.goalReached = false;
    cleanup();
}

pub fn next() !void {
    reset();

    const levels = try findLevels();
    defer shared.allocator.free(levels);
    levelNumber = @mod(levelNumber + 1, levels.len);

    const levelName = levels[levelNumber];

    const j = try std.fmt.bufPrint(&jsonTextBuf, "{s}", .{levelName});
    try loadByName(j);
}
