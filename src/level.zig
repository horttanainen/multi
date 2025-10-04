const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");

const config = @import("config.zig");
const polygon = @import("polygon.zig");
const box2d = @import("box2d.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const sensor = @import("sensor.zig");
const camera = @import("camera.zig");
const sprite = @import("sprite.zig");
const background = @import("background.zig");
const animation = @import("animation.zig");

const conv = @import("conversion.zig");

const vec = @import("vector.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var levelNumber: usize = 0;

var jsonTextBuf: [100]u8 = undefined;
pub var json: []const u8 = undefined;

pub var position: vec.IVec2 = .{
    .x = 0,
    .y = 0,
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
    parallaxEntities: []background.SerializableParallaxEntity,
    entities: []entity.SerializableEntity,
};

pub fn parseFromData(data: []const u8) !std.json.Parsed(Level) {
    const parsed = try std.json.parseFromSlice(Level, shared.allocator, data, .{ .allocate = .alloc_always });
    return parsed;
}

pub fn parseFromPath(path: []const u8) !std.json.Parsed(Level) {
    const data = try std.fs.cwd().readFileAlloc(shared.allocator, path, config.maxLevelSizeInBytes);
    defer shared.allocator.free(data);
    return parseFromData(data);
}

pub fn findLevels() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var fileList = std.array_list.Managed([]const u8).init(shared.allocator);

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

    for (levelToDeserialize.parallaxEntities) |e| {
        const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);

        try background.create(s, e.pos, e.parallaxDistance, e.scale, e.fog);
    }

    for (levelToDeserialize.entities) |e| {
        var shapeDef = box2d.c.b2DefaultShapeDef();
        shapeDef.friction = e.friction;
        const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);
        const pos = conv.pixel2MPos(e.pos.x, e.pos.y, s.sizeM.x, s.sizeM.y);
        if (std.mem.eql(u8, e.type, "dynamic")) {
            const bodyDef = box2d.createDynamicBodyDef(pos);
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "dynamic");
        } else if (std.mem.eql(u8, e.type, "static")) {
            const bodyDef = box2d.createStaticBodyDef(pos);
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "static");
        } else if (std.mem.eql(u8, e.type, "goal")) {
            try sensor.createGoalSensorFromImg(pos, s);
        } else if (std.mem.eql(u8, e.type, "spawn")) {
            const bodyDef = box2d.createStaticBodyDef(pos);
            shapeDef.isSensor = true;
            shapeDef.material = config.spawnMaterialId;
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "spawn");
            spawnLocation = e.pos;
        }
    }

    size = levelToDeserialize.size;

    try player.spawn(spawnLocation);
}

pub fn reload() !void {
    reset();
    try loadByName(json);
}

pub fn cleanup() void {
    player.cleanup();
    sensor.cleanup();
    projectile.cleanup();
    entity.cleanup();
    background.cleanup();
    animation.cleanup();
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
