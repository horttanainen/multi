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
const controller = @import("controller.zig");

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
            shapeDef.filter.categoryBits = config.CATEGORY_DYNAMIC;
            shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_PLAYER | config.CATEGORY_PROJECTILE | config.CATEGORY_DYNAMIC | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "dynamic");
        } else if (std.mem.eql(u8, e.type, "static")) {
            // Split large static terrain into tiles for better performance
            const tiles = try sprite.splitIntoTiles(s, 64);
            defer shared.allocator.free(tiles);

            const categoryBits = if (e.breakable) config.CATEGORY_TERRAIN else config.CATEGORY_UNBREAKABLE;

            for (tiles) |tile| {
                // Calculate position for this tile (original position + tile offset)
                const tilePos = vec.Vec2{
                    .x = pos.x + tile.offsetPos.x,
                    .y = pos.y + tile.offsetPos.y,
                };
                const bodyDef = box2d.createStaticBodyDef(tilePos);
                shapeDef.filter.categoryBits = categoryBits;
                shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_PLAYER | config.CATEGORY_PROJECTILE | config.CATEGORY_DYNAMIC | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;
                _ = entity.createFromImg(tile.sprite, shapeDef, bodyDef, "static") catch |err| {
                    if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                        // Clean up the tile sprite since entity creation failed
                        sprite.cleanup(tile.sprite);
                    } else {
                        return err;
                    }
                };
            }

            // Clean up the original sprite if it was split
            if (tiles.len > 1) {
                sprite.cleanup(s);
            }
        } else if (std.mem.eql(u8, e.type, "goal")) {
            try sensor.createGoalSensorFromImg(pos, s);
        } else if (std.mem.eql(u8, e.type, "spawn")) {
            const bodyDef = box2d.createStaticBodyDef(pos);
            shapeDef.isSensor = true;
            shapeDef.filter.categoryBits = config.CATEGORY_SENSOR;
            shapeDef.filter.maskBits = config.CATEGORY_PLAYER;
            _ = try entity.createFromImg(s, shapeDef, bodyDef, "spawn");
            spawnLocation = e.pos;
        }
    }

    size = levelToDeserialize.size;

    const playerId1 = try player.spawn(spawnLocation);
    const color1 = try controller.createControllerForPlayer(playerId1);
    player.setColor(playerId1, color1);

    const p2Position = vec.IVec2{
        .x = spawnLocation.x + 10,
        .y = spawnLocation.y,
    };
    const playerId2 = try player.spawn(p2Position);
    const color2 = try controller.createControllerForPlayer(playerId2);
    player.setColor(playerId2, color2);
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
