const std = @import("std");
const sdl = @import("sdl.zig");

const config = @import("config.zig");
const collision = @import("collision.zig");
const polygon = @import("polygon.zig");
const box2d = @import("box2d.zig");
const allocator = @import("allocator.zig").allocator;
const state = @import("state.zig");
const player = @import("player.zig");
const sensor = @import("sensor.zig");
const camera = @import("camera.zig");
const viewport = @import("viewport.zig");
const sprite = @import("sprite.zig");
const background = @import("background.zig");
const animation = @import("animation.zig");
const controller = @import("controller.zig");
const rope = @import("rope.zig");
const weapon = @import("weapon.zig");

const gpu = @import("gpu.zig");
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
pub var spawnLocation: vec.IVec2 = .{
    .x = 0,
    .y = 0,
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
    const parsed = try std.json.parseFromSlice(Level, allocator, data, .{ .allocate = .alloc_always });
    return parsed;
}

pub fn parseFromPath(path: []const u8) !std.json.Parsed(Level) {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, config.maxLevelSizeInBytes);
    defer allocator.free(data);
    return parseFromData(data);
}

pub fn findLevels() ![][]const u8 {
    var dir = try std.fs.cwd().openDir("levels", .{});
    defer dir.close();

    var fileList = std.array_list.Managed([]const u8).init(allocator);

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            try fileList.append(dirContent.name);
        }
    }

    return fileList.toOwnedSlice();
}

fn onGoalBegin(visitorShapeId: box2d.c.b2ShapeId) !void {
    for (player.players.values()) |p| {
        if (box2d.c.B2_ID_EQUALS(visitorShapeId, p.bodyShapeId)) {
            state.goalReached = true;
            return;
        }
    }
}

fn loadByName(levelName: []const u8) !void {
    var textBuf: [100]u8 = undefined;
    const levelP = try std.fmt.bufPrint(&textBuf, "levels/{s}", .{levelName});
    json = levelName;

    const parsed = try parseFromPath(levelP);
    defer parsed.deinit();
    const levelToDeserialize = parsed.value;

    spawnLocation = vec.IVec2{ .x = 0, .y = 0 };

    for (levelToDeserialize.parallaxEntities) |e| {
        const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);

        try background.create(s, e.pos, e.parallaxDistance, e.scale, e.fog);
    }

    for (levelToDeserialize.entities) |e| {
        var shapeDef = box2d.c.b2DefaultShapeDef();
        shapeDef.material.friction = e.friction;
        shapeDef.enableSensorEvents = true;
        const spriteUuid = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);

        const pos = conv.pixel2M(e.pos);

        if (std.mem.eql(u8, e.type, "dynamic")) {
            const bodyDef = box2d.createDynamicBodyDef(pos);
            shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
            shapeDef.filter.maskBits = collision.MASK_DYNAMIC;
            _ = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");
        } else if (std.mem.eql(u8, e.type, "static")) {
            // Split large static terrain into tiles for better performance
            const tiles = try sprite.splitIntoTiles(spriteUuid, 64);
            defer allocator.free(tiles);

            const categoryBits = if (e.breakable) collision.CATEGORY_TERRAIN else collision.CATEGORY_UNBREAKABLE;
            const maskBits = if (e.breakable) collision.MASK_TERRAIN else collision.MASK_UNBREAKABLE;

            for (tiles) |tile| {
                // Calculate position for this tile (original position + tile offset)
                const tilePos = vec.Vec2{
                    .x = pos.x + tile.offsetPos.x,
                    .y = pos.y + tile.offsetPos.y,
                };
                const bodyDef = box2d.createStaticBodyDef(tilePos);
                shapeDef.filter.categoryBits = categoryBits;
                shapeDef.filter.maskBits = maskBits;
                _ = entity.createFromImg(tile.spriteUuid, shapeDef, bodyDef, "static") catch |err| {
                    if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                        // Clean up the tile sprite since entity creation failed
                        sprite.cleanupLater(tile.spriteUuid);
                    } else {
                        return err;
                    }
                };
            }

            // Clean up the original sprite if it was split
            if (tiles.len > 1) {
                sprite.cleanupLater(spriteUuid);
            }
        } else if (std.mem.eql(u8, e.type, "goal")) {
            var goalShapeDef = box2d.c.b2DefaultShapeDef();
            goalShapeDef.isSensor = true;
            goalShapeDef.enableSensorEvents = true;
            goalShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
            goalShapeDef.filter.maskBits = collision.MASK_SENSOR_GOAL;
            const goalBodyDef = box2d.createStaticBodyDef(pos);
            try sensor.createSensorEntityFromImg(spriteUuid, goalShapeDef, goalBodyDef, "goal", onGoalBegin);
        } else if (std.mem.eql(u8, e.type, "spawn")) {
            const bodyDef = box2d.createStaticBodyDef(pos);
            shapeDef.isSensor = true;
            shapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
            shapeDef.filter.maskBits = collision.MASK_SENSOR_SPAWN;
            _ = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "spawn");
            spawnLocation = e.pos;
        }
    }

    size = levelToDeserialize.size;

    const playerId1 = try player.spawn(spawnLocation);
    if (!controller.controllers.contains(playerId1)) {
        const color1 = try controller.createControllerForPlayer(playerId1);
        player.setColor(playerId1, color1);
    } else {
        player.setColor(playerId1, controller.controllers.get(playerId1).?.color);
    }

    const p2Position = vec.IVec2{
        .x = spawnLocation.x + 10,
        .y = spawnLocation.y,
    };
    const playerId2 = try player.spawn(p2Position);
    if (!controller.controllers.contains(playerId2)) {
        const color2 = try controller.createControllerForPlayer(playerId2);
        player.setColor(playerId2, color2);
    } else {
        player.setColor(playerId2, controller.controllers.get(playerId2).?.color);
    }
}

pub fn reload() !void {
    reset();
    try loadByName(json);
}

pub fn cleanup() void {
    rope.cleanup();
    player.cleanup();
    sensor.cleanup();
    projectile.cleanup();
    weapon.cleanupTrails();
    entity.cleanup();
    background.cleanup();
    animation.cleanup();
    sprite.clearTextureCache();
    gpu.resetAtlasToCheckpoint();
    viewport.cleanup();
    camera.resetPlayerCameraIds();
}

pub fn reset() void {
    state.goalReached = false;
    cleanup();
}

pub fn next() !void {
    reset();

    const levels = try findLevels();
    defer allocator.free(levels);
    levelNumber = @mod(levelNumber + 1, levels.len);

    const levelName = levels[levelNumber];

    const j = try std.fmt.bufPrint(&jsonTextBuf, "{s}", .{levelName});
    try loadByName(j);
}
