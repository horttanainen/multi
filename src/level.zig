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
const fs = @import("fs.zig");

const vec = @import("vector.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var levelNumber: usize = 0;

var currentPathBuf: [200]u8 = undefined;
pub var currentPath: []const u8 = undefined;

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
    gravity: f32 = 10.0,
    pixelsPerMeter: i32 = 80,
    splitscreen: bool = true,
    parallaxEntities: []background.SerializableParallaxEntity,
    entities: []entity.SerializableEntity,
};

pub var splitscreen: bool = true;

pub fn parseFromData(data: []const u8) !std.json.Parsed(Level) {
    const parsed = try std.json.parseFromSlice(Level, allocator, data, .{ .allocate = .alloc_always });
    return parsed;
}

pub fn parseFromPath(path: []const u8) !std.json.Parsed(Level) {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, config.maxLevelSizeInBytes);
    defer allocator.free(data);
    return parseFromData(data);
}

pub fn loadLevelPaths() !std.json.Parsed([][]const u8) {
    var jsonBuf: [4096]u8 = undefined;
    const data = try fs.readFile("levels.json", &jsonBuf);
    return std.json.parseFromSlice([][]const u8, allocator, data, .{ .allocate = .alloc_always });
}

fn onGoalBegin(visitorShapeId: box2d.c.b2ShapeId) !void {
    for (player.players.values()) |p| {
        if (box2d.c.B2_ID_EQUALS(visitorShapeId, p.bodyShapeId)) {
            state.goalReached = true;
            return;
        }
    }
}

// Loads parallax backgrounds and entities from a parsed Level. Returns true if a spawn point was found.
fn loadLevelContents(lev: Level) !bool {
    var hasSpawn = false;

    for (lev.parallaxEntities) |e| {
        const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);
        try background.create(s, e.pos, e.parallaxDistance, e.scale, e.fog);
    }

    for (lev.entities) |e| {
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
            const tiles = try sprite.splitIntoTiles(spriteUuid, 64);
            defer allocator.free(tiles);

            const categoryBits = if (e.breakable) collision.CATEGORY_TERRAIN else collision.CATEGORY_UNBREAKABLE;
            const maskBits = if (e.breakable) collision.MASK_TERRAIN else collision.MASK_UNBREAKABLE;

            for (tiles) |tile| {
                const tilePos = vec.Vec2{
                    .x = pos.x + tile.offsetPos.x,
                    .y = pos.y + tile.offsetPos.y,
                };
                const bodyDef = box2d.createStaticBodyDef(tilePos);
                shapeDef.filter.categoryBits = categoryBits;
                shapeDef.filter.maskBits = maskBits;
                _ = entity.createFromImg(tile.spriteUuid, shapeDef, bodyDef, "static") catch |err| {
                    if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                        sprite.cleanupLater(tile.spriteUuid);
                    } else {
                        return err;
                    }
                };
            }

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
            hasSpawn = true;
        }
    }

    size = lev.size;
    splitscreen = lev.splitscreen;
    return hasSpawn;
}

fn spawnTwoPlayers() !void {
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
    const playerId2 = if (splitscreen)
        try player.spawn(p2Position)
    else
        try player.spawnWithSharedCamera(p2Position, player.players.get(playerId1).?.cameraId);
    if (!controller.controllers.contains(playerId2)) {
        const color2 = try controller.createControllerForPlayer(playerId2);
        player.setColor(playerId2, color2);
    } else {
        player.setColor(playerId2, controller.controllers.get(playerId2).?.color);
    }
}

// Load a level from any path without spawning players (for level editor view).
pub fn loadLevel(path: []const u8) !bool {
    reset();
    const parsed = try parseFromPath(path);
    defer parsed.deinit();
    const lev = parsed.value;

    box2d.setGravity(lev.gravity);
    conv.met2pix = @floatFromInt(lev.pixelsPerMeter);
    spawnLocation = vec.IVec2{ .x = 0, .y = 0 };
    const hasSpawn = try loadLevelContents(lev);
    return hasSpawn;
}

// Load a level from any path as a playable game level. Spawns players only if a spawn point exists.
pub fn tryEditorLevel(path: []const u8) !void {
    const hasSpawn = try loadLevel(path);
    if (hasSpawn) {
        try spawnTwoPlayers();
    }
    state.editingLevel = false;
}

pub fn reload() !void {
    reset();
    const hasSpawn = try loadLevel(currentPath);
    if (hasSpawn) {
        try spawnTwoPlayers();
    }
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

    const parsed = try loadLevelPaths();
    defer parsed.deinit();
    levelNumber = @mod(levelNumber + 1, parsed.value.len);

    currentPath = try std.fmt.bufPrint(&currentPathBuf, "{s}", .{parsed.value[levelNumber]});

    const hasSpawn = try loadLevel(currentPath);
    if (hasSpawn) {
        try spawnTwoPlayers();
    }
}
