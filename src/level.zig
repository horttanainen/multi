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

const IVec2 = @import("vector.zig").IVec2;
const entity = @import("entity.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var levelNumber: usize = 0;

var textBuf2: [100]u8 = undefined;
pub var json: [:0]const u8 = undefined;

pub const position: IVec2 = .{
    .x = 400,
    .y = 400,
};
pub var size: IVec2 = .{
    .x = 100,
    .y = 100,
};

const LevelError = error{
    Uninitialized,
};

pub const SerializableEntity = struct {
    type: []const u8,
    friction: f32,
    imgPath: [:0]const u8,
    pos: IVec2,
};

pub const Level = struct {
    size: IVec2,
    entities: []SerializableEntity,
};

pub fn parseLevel(path: []const u8) !std.json.Parsed(Level) {
    const data = try std.fs.cwd().readFileAlloc(shared.allocator, path, 4096);
    defer shared.allocator.free(data);
    const parsed = try std.json.parseFromSlice(Level, shared.allocator, data, .{ .allocate = .alloc_always });
    return parsed;
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

pub fn create() !void {
    const levels = try findLevels();
    defer shared.allocator.free(levels);

    var textBuf: [100]u8 = undefined;
    const levelP = try std.fmt.bufPrintZ(&textBuf, "levels/{s}", .{levels[levelNumber]});

    json = try std.fmt.bufPrintZ(&textBuf2, "{s}", .{levels[levelNumber]});

    const parsed = try parseLevel(levelP);
    defer parsed.deinit();
    const levelToDeserialize = parsed.value;

    var spawnLocation = IVec2{ .x = 0, .y = 0 };

    for (levelToDeserialize.entities) |e| {
        const surface = try image.load(e.imgPath);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.friction = e.friction;

        if (std.mem.eql(u8, e.type, "dynamic")) {
            const bodyDef = box.createDynamicBodyDef(e.pos);
            try entity.createFromImg(surface, shapeDef, bodyDef);
        } else if (std.mem.eql(u8, e.type, "static")) {
            const bodyDef = box.createStaticBodyDef(e.pos);
            try entity.createFromImg(surface, shapeDef, bodyDef);
        } else if (std.mem.eql(u8, e.type, "goal")) {
            try sensor.createGoalSensorFromImg(e.pos, surface);
        } else if (std.mem.eql(u8, e.type, "spawn")) {
            const bodyDef = box.createStaticBodyDef(e.pos);
            shapeDef.isSensor = true;
            shapeDef.material = config.spawnMaterialId;
            try entity.createFromImg(surface, shapeDef, bodyDef);
            spawnLocation = e.pos;
        }
    }

    try player.spawn(spawnLocation);

    levelNumber = @mod(levelNumber + 1, levels.len);
    size = levelToDeserialize.size;
}

pub fn cleanup() void {
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
}

pub fn reset() !void {
    shared.goalReached = false;
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
    try create();
}
