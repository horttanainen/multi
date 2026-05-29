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
const c = sdl.c;

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
    levelHeightMeters: f32,
    cameraZoomMeters: f32 = defaultCameraZoomMeters,
    aspectRatio: AspectRatio,
    gravity: f32 = 10.0,
    pixelsPerMeter: i32 = defaultPixelsPerMeter,
    splitscreen: bool = false,
    parallaxEntities: []background.SerializableParallaxEntity,
    entities: []entity.SerializableEntity,
};

pub const AspectRatio = struct {
    width: i32,
    height: i32,
};

pub const defaultPixelsPerMeter: i32 = 80;
pub const defaultLevelHeightMeters: f32 = 12.0;
pub const defaultCameraZoomMeters: f32 = defaultLevelHeightMeters;
pub const defaultAspectRatio = AspectRatio{ .width = 16, .height = 9 };

pub var splitscreen: bool = false;
pub var cameraZoomMeters: f32 = defaultCameraZoomMeters;

pub fn sanitizeCameraZoomMeters(value: f32) f32 {
    if (value <= 0) {
        std.log.warn("sanitizeCameraZoomMeters: invalid camera zoom {d}, using default", .{value});
        return defaultCameraZoomMeters;
    }
    return value;
}

pub fn sizeFromHeightAndAspect(levelHeightMeters: f32, aspectRatio: AspectRatio, pixelsPerMeter: i32) vec.IVec2 {
    var safeHeightMeters = levelHeightMeters;
    if (safeHeightMeters <= 0) {
        std.log.warn("sizeFromHeightAndAspect: invalid level height {d}, using default", .{safeHeightMeters});
        safeHeightMeters = defaultLevelHeightMeters;
    }

    var safeAspectRatio = aspectRatio;
    if (safeAspectRatio.width <= 0 or safeAspectRatio.height <= 0) {
        std.log.warn("sizeFromHeightAndAspect: invalid aspect ratio {d}:{d}, using default", .{ safeAspectRatio.width, safeAspectRatio.height });
        safeAspectRatio = defaultAspectRatio;
    }

    var safePixelsPerMeter = pixelsPerMeter;
    if (safePixelsPerMeter <= 0) {
        std.log.warn("sizeFromHeightAndAspect: invalid pixels per meter {d}, using default", .{safePixelsPerMeter});
        safePixelsPerMeter = defaultPixelsPerMeter;
    }

    const heightPixelsF = safeHeightMeters * @as(f32, @floatFromInt(safePixelsPerMeter));
    const ratio = @as(f32, @floatFromInt(safeAspectRatio.width)) / @as(f32, @floatFromInt(safeAspectRatio.height));

    return .{
        .x = @intFromFloat(@round(heightPixelsF * ratio)),
        .y = @intFromFloat(@round(heightPixelsF)),
    };
}

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

pub fn applyLevelSettings(lev: Level) void {
    box2d.setGravity(lev.gravity);
    conv.met2pix = @floatFromInt(defaultPixelsPerMeter);
    spawnLocation = vec.IVec2{ .x = 0, .y = 0 };
    cameraZoomMeters = sanitizeCameraZoomMeters(lev.cameraZoomMeters);
    splitscreen = lev.splitscreen;
    size = sizeFromHeightAndAspect(lev.levelHeightMeters, lev.aspectRatio, defaultPixelsPerMeter);
}

pub fn spawnParallaxEntity(e: background.SerializableParallaxEntity) !void {
    const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);
    try background.create(s, e.pos, e.parallaxDistance, e.scale, e.fog);
}

fn appendSpawnedEntityBody(bodyIds: *std.array_list.Managed(box2d.c.b2BodyId), spawnedEntity: Entity) !void {
    bodyIds.append(spawnedEntity.bodyId) catch |err| {
        _ = entity.remove(spawnedEntity.bodyId);
        return err;
    };
}

fn appendSpawnedSensorBody(bodyIds: *std.array_list.Managed(box2d.c.b2BodyId), bodyId: box2d.c.b2BodyId) !void {
    bodyIds.append(bodyId) catch |err| {
        _ = sensor.remove(bodyId);
        return err;
    };
}

fn cleanupSpawnedBodies(bodyIds: []const box2d.c.b2BodyId) void {
    for (bodyIds) |bodyId| {
        if (entity.remove(bodyId)) continue;
        _ = sensor.remove(bodyId);
    }
}

fn staticShapeDef(serializedEntity: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) box2d.c.b2ShapeDef {
    var staticDef = shapeDef;
    staticDef.filter.categoryBits = if (serializedEntity.breakable) collision.CATEGORY_TERRAIN else collision.CATEGORY_UNBREAKABLE;
    staticDef.filter.maskBits = if (serializedEntity.breakable) collision.MASK_TERRAIN else collision.MASK_UNBREAKABLE;
    return staticDef;
}

fn shouldTileStaticSurface(surface: *sdl.Surface) bool {
    return surface.w > entity.terrainColliderChunkSizeP or surface.h > entity.terrainColliderChunkSizeP;
}

fn surfaceRectHasSolidPixels(surface: *sdl.Surface, rect: sdl.Rect) bool {
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const bytesPerPixel: usize = 4;
    const threshold: u8 = 150;

    const minX: usize = @intCast(rect.x);
    const maxX: usize = @intCast(rect.x + rect.w);
    const minY: usize = @intCast(rect.y);
    const maxY: usize = @intCast(rect.y + rect.h);

    var y = minY;
    while (y < maxY) : (y += 1) {
        var x = minX;
        while (x < maxX) : (x += 1) {
            const pixelIndex = y * pitch + x * bytesPerPixel;
            if (pixels[pixelIndex + 3] > threshold) {
                return true;
            }
        }
    }

    return false;
}

fn createSurfaceRegion(sourceSurface: *sdl.Surface, rect: sdl.Rect) !*sdl.Surface {
    const tileSurface = c.SDL_CreateSurface(rect.w, rect.h, sourceSurface.format) orelse return error.CreateSurfaceFailed;
    errdefer sdl.destroySurface(tileSurface);

    try sdl.blitSurface(sourceSurface, &rect, tileSurface, null);
    return tileSurface;
}

fn tileCenterPosition(basePos: vec.IVec2, sourceSurface: *sdl.Surface, rect: sdl.Rect, scale: vec.Vec2) vec.IVec2 {
    const tileCenterX = @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) * 0.5;
    const tileCenterY = @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) * 0.5;
    const sourceCenterX = @as(f32, @floatFromInt(sourceSurface.w)) * 0.5;
    const sourceCenterY = @as(f32, @floatFromInt(sourceSurface.h)) * 0.5;

    return .{
        .x = basePos.x + @as(i32, @intFromFloat(@round((tileCenterX - sourceCenterX) * scale.x))),
        .y = basePos.y + @as(i32, @intFromFloat(@round((tileCenterY - sourceCenterY) * scale.y))),
    };
}

fn spawnSingleStaticEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    const spriteUuid = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);
    errdefer sprite.cleanupLater(spriteUuid);

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer cleanupSpawnedBodies(bodyIds.items);
    errdefer bodyIds.deinit();

    const bodyDef = box2d.createStaticBodyDef(conv.pixel2M(e.pos));
    const spawnedEntity = entity.createFromImg(spriteUuid, shapeDef, bodyDef, "static") catch |err| {
        if (err == polygon.PolygonError.CouldNotCreateTriangle) {
            std.log.warn("spawnSingleStaticEntity: static entity {d} produced no collider triangles", .{e.id});
            sprite.cleanupLater(spriteUuid);
            return bodyIds.toOwnedSlice();
        }
        return err;
    };

    try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
    return bodyIds.toOwnedSlice();
}

fn spawnTiledStaticEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef, sourceSurface: *sdl.Surface) ![]box2d.c.b2BodyId {
    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer cleanupSpawnedBodies(bodyIds.items);
    errdefer bodyIds.deinit();

    const width = sourceSurface.w;
    const height = sourceSurface.h;
    const tileSize = entity.terrainColliderChunkSizeP;

    var y: i32 = 0;
    while (y < height) : (y += tileSize) {
        var x: i32 = 0;
        while (x < width) : (x += tileSize) {
            const rect = sdl.Rect{
                .x = x,
                .y = y,
                .w = @min(tileSize, width - x),
                .h = @min(tileSize, height - y),
            };
            if (!surfaceRectHasSolidPixels(sourceSurface, rect)) continue;

            const tileSurface = try createSurfaceRegion(sourceSurface, rect);
            const tileSpriteUuid = try sprite.createFromOwnedSurface(e.imgPath, tileSurface, e.scale, vec.izero);

            const tilePos = tileCenterPosition(e.pos, sourceSurface, rect, e.scale);
            const bodyDef = box2d.createStaticBodyDef(conv.pixel2M(tilePos));
            const spawnedEntity = entity.createFromImg(tileSpriteUuid, shapeDef, bodyDef, "static") catch |err| {
                sprite.cleanupLater(tileSpriteUuid);
                if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                    continue;
                }
                return err;
            };

            try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
        }
    }

    return bodyIds.toOwnedSlice();
}

fn spawnStaticSerializableEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    const staticDef = staticShapeDef(e, shapeDef);

    const imgPathZ = try allocator.dupeZ(u8, e.imgPath);
    defer allocator.free(imgPathZ);
    const loadedSurface = try sdl.image.load(imgPathZ);
    defer sdl.destroySurface(loadedSurface);

    if (!shouldTileStaticSurface(loadedSurface)) {
        return spawnSingleStaticEntity(e, staticDef);
    }

    const sourceSurface = c.SDL_ConvertSurface(loadedSurface, c.SDL_PIXELFORMAT_BGRA32);
    if (sourceSurface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(sourceSurface);

    return spawnTiledStaticEntity(e, staticDef, sourceSurface);
}

pub fn spawnSerializableEntity(e: entity.SerializableEntity) ![]box2d.c.b2BodyId {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = e.friction;
    shapeDef.enableSensorEvents = true;

    if (std.mem.eql(u8, e.type, "static")) {
        return spawnStaticSerializableEntity(e, shapeDef);
    }

    const spriteUuid = try sprite.createFromImg(e.imgPath, e.scale, vec.izero);
    errdefer sprite.cleanupLater(spriteUuid);

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer cleanupSpawnedBodies(bodyIds.items);
    errdefer bodyIds.deinit();

    const pos = conv.pixel2M(e.pos);

    if (std.mem.eql(u8, e.type, "dynamic")) {
        const bodyDef = box2d.createDynamicBodyDef(pos);
        shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
        shapeDef.filter.maskBits = collision.MASK_DYNAMIC;
        const spawnedEntity = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");
        try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
        return bodyIds.toOwnedSlice();
    }

    if (std.mem.eql(u8, e.type, "goal")) {
        var goalShapeDef = box2d.c.b2DefaultShapeDef();
        goalShapeDef.isSensor = true;
        goalShapeDef.enableSensorEvents = true;
        goalShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
        goalShapeDef.filter.maskBits = collision.MASK_SENSOR_GOAL;
        const goalBodyDef = box2d.createStaticBodyDef(pos);
        const bodyId = try sensor.createSensorEntityFromImg(spriteUuid, goalShapeDef, goalBodyDef, "goal", onGoalBegin);
        try appendSpawnedSensorBody(&bodyIds, bodyId);
        return bodyIds.toOwnedSlice();
    }

    if (std.mem.eql(u8, e.type, "spawn")) {
        const bodyDef = box2d.createStaticBodyDef(pos);
        shapeDef.isSensor = true;
        shapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
        shapeDef.filter.maskBits = collision.MASK_SENSOR_SPAWN;
        const spawnedEntity = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "spawn");
        try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
        return bodyIds.toOwnedSlice();
    }

    std.log.warn("spawnSerializableEntity: unknown entity type '{s}' for entity {d}", .{ e.type, e.id });
    return error.UnknownEntityType;
}

// Loads parallax backgrounds and entities from a parsed Level. Returns true if a spawn point was found.
fn loadLevelContents(lev: Level) !bool {
    var hasSpawn = false;

    for (lev.parallaxEntities) |e| {
        try spawnParallaxEntity(e);
    }

    for (lev.entities) |e| {
        const bodyIds = try spawnSerializableEntity(e);
        defer allocator.free(bodyIds);

        if (std.mem.eql(u8, e.type, "spawn")) {
            spawnLocation = e.pos;
            hasSpawn = true;
        }
    }

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

    applyLevelSettings(lev);
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
    polygon.clearCache();
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
