const std = @import("std");

const config = @import("config.zig");
const data = @import("data.zig");
const movement = @import("movement.zig");
const collision = @import("collision.zig");
const polygon = @import("polygon.zig");
const box2d = @import("box2d.zig");
const allocator = @import("allocator.zig").allocator;
const state = @import("state.zig");
const player = @import("player.zig");
const spawn = @import("spawn.zig");
const sensor = @import("sensor.zig");
const camera = @import("camera.zig");
const viewport = @import("viewport.zig");
const sprite = @import("sprite.zig");
const background = @import("background.zig");
const animation = @import("animation.zig");
const controller = @import("controller.zig");
const gravestone = @import("gravestone.zig");
const rope = @import("rope.zig");
const runtime = @import("runtime.zig");
const weapon = @import("weapon.zig");

const gpu = @import("gpu.zig");
const conv = @import("conversion.zig");
const fs = @import("fs.zig");

const vec = @import("vector.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const damage = @import("damage.zig");
const destruction = @import("destruction.zig");
const rubble = @import("rubble.zig");
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
    movementFile: []const u8 = defaultMovementFile,
    parallaxEntities: []background.SerializableParallaxEntity,
    entities: []entity.SerializableEntity,
};

pub const AspectRatio = struct {
    width: i32,
    height: i32,
};

pub const defaultPixelsPerMeter = conv.defaultPixelsPerMeter;
pub const defaultLevelHeightMeters: f32 = 12.0;
pub const defaultCameraZoomMeters: f32 = defaultLevelHeightMeters;
pub const defaultAspectRatio = AspectRatio{ .width = 16, .height = 9 };
pub const defaultMovementFile = "movements/liero_default.json";
const defaultDynamicHealth: f32 = 100;

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

pub fn parseFromData(jsonData: []const u8) !std.json.Parsed(Level) {
    const parsed = try std.json.parseFromSlice(Level, allocator, jsonData, .{ .allocate = .alloc_always });
    return parsed;
}

pub fn parseFromPath(path: []const u8) !std.json.Parsed(Level) {
    const jsonData = try std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, allocator, .limited(config.maxLevelSizeInBytes));
    defer allocator.free(jsonData);
    return parseFromData(jsonData);
}

pub fn loadLevelPaths() !std.json.Parsed([][]const u8) {
    var jsonBuf: [4096]u8 = undefined;
    const jsonData = try fs.readFile("levels.json", &jsonBuf);
    return std.json.parseFromSlice([][]const u8, allocator, jsonData, .{ .allocate = .alloc_always });
}

fn onGoalBegin(visitorShapeId: box2d.c.b2ShapeId) !void {
    for (player.players.values()) |p| {
        if (box2d.c.B2_ID_EQUALS(visitorShapeId, p.bodyShapeId)) {
            state.goalReached = true;
            return;
        }
    }
}

pub fn applyLevelSettings(lev: Level) !void {
    if (lev.pixelsPerMeter <= 0) {
        std.log.err("level.applyLevelSettings: pixelsPerMeter must be positive, got {d}", .{lev.pixelsPerMeter});
        return error.InvalidPixelsPerMeter;
    }
    if (lev.size.x <= 0 or lev.size.y <= 0) {
        std.log.err("level.applyLevelSettings: level size must be positive, got {d}x{d}", .{ lev.size.x, lev.size.y });
        return error.InvalidLevelSize;
    }

    const movementData = try data.loadMovementData(lev.movementFile);
    movement.configure(movementData);
    box2d.setGravity(lev.gravity);
    conv.met2pix = @floatFromInt(lev.pixelsPerMeter);
    sprite.applyPixelsPerMeter();
    spawn.locations.clearRetainingCapacity();
    cameraZoomMeters = sanitizeCameraZoomMeters(lev.cameraZoomMeters);
    splitscreen = lev.splitscreen;
    size = lev.size;
}

pub fn spawnParallaxEntity(e: background.SerializableParallaxEntity) !void {
    const s = try sprite.createFromImg(e.imgPath, e.scale, vec.izero, .canvas_pixels);
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

fn staticSpriteBacking(serializedEntity: entity.SerializableEntity) sprite.Backing {
    if (serializedEntity.breakable) return .mutable;
    return .immutable;
}

fn entitySpriteBacking(serializedEntity: entity.SerializableEntity) sprite.Backing {
    if (std.mem.eql(u8, serializedEntity.type, "dynamic")) return .mutable;
    return .immutable;
}

fn bodyDefWithRotation(bodyDef: box2d.c.b2BodyDef, rotationDegrees: f32) box2d.c.b2BodyDef {
    var rotatedBodyDef = bodyDef;
    rotatedBodyDef.rotation = box2d.c.b2MakeRot(std.math.degreesToRadians(rotationDegrees));
    return rotatedBodyDef;
}

fn spawnSingleStaticEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    if (e.colliderSource == .rectangle and e.breakable) {
        std.log.err("spawnSingleStaticEntity: entity {d} uses a rectangular collider but is breakable", .{e.id});
        return error.BreakableRectangleCollider;
    }

    const spriteUuid = try sprite.createFromImgWithBacking(e.imgPath, e.scale, vec.izero, staticSpriteBacking(e), .canvas_pixels);
    errdefer sprite.cleanupLater(spriteUuid);

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer bodyIds.deinit();
    errdefer cleanupSpawnedBodies(bodyIds.items);

    const bodyDef = bodyDefWithRotation(box2d.createStaticBodyDef(conv.pixel2M(e.pos)), e.rotationDegrees);
    const spawnedEntity = switch (e.colliderSource) {
        .rectangle => try entity.createRectangle(spriteUuid, shapeDef, bodyDef, "static"),
        .image => entity.createFromImg(spriteUuid, shapeDef, bodyDef, "static") catch |err| {
            if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                std.log.warn("spawnSingleStaticEntity: static entity {d} produced no collider triangles", .{e.id});
                sprite.cleanupLater(spriteUuid);
                return bodyIds.toOwnedSlice();
            }
            return err;
        },
    };

    if (e.breakable) {
        damage.register(spawnedEntity.bodyId, .{
            .model = .{ .surface_cutout = .{} },
        }) catch |err| {
            _ = entity.remove(spawnedEntity.bodyId);
            return err;
        };
    }

    try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
    return bodyIds.toOwnedSlice();
}

fn spawnStaticSerializableEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    const staticDef = staticShapeDef(e, shapeDef);
    return spawnSingleStaticEntity(e, staticDef);
}

pub fn spawnSerializableEntity(e: entity.SerializableEntity) ![]box2d.c.b2BodyId {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = e.friction;
    shapeDef.enableSensorEvents = true;

    if (std.mem.eql(u8, e.type, "static")) {
        return spawnStaticSerializableEntity(e, shapeDef);
    }

    const sizeBasis: sprite.SizeBasis = if (std.mem.eql(u8, e.type, "dynamic")) .world_meters else .canvas_pixels;
    const spriteUuid = try sprite.createFromImgWithBacking(e.imgPath, e.scale, vec.izero, entitySpriteBacking(e), sizeBasis);
    errdefer sprite.cleanupLater(spriteUuid);

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer bodyIds.deinit();
    errdefer cleanupSpawnedBodies(bodyIds.items);

    const pos = conv.pixel2M(e.pos);

    if (std.mem.eql(u8, e.type, "dynamic")) {
        const maximumHealth = e.health orelse defaultDynamicHealth;
        if (!std.math.isFinite(maximumHealth) or maximumHealth <= 0) {
            std.log.err("spawnSerializableEntity: dynamic entity {d} has invalid health {d}", .{ e.id, maximumHealth });
            return error.InvalidDynamicHealth;
        }

        const bodyDef = bodyDefWithRotation(box2d.createDynamicBodyDef(pos), e.rotationDegrees);
        shapeDef.filter.categoryBits = collision.CATEGORY_DYNAMIC;
        shapeDef.filter.maskBits = collision.MASK_DYNAMIC;
        const spawnedEntity = try entity.createFromImg(spriteUuid, shapeDef, bodyDef, "dynamic");
        const rubbleTemplateId = rubble.prepare(spriteUuid, e.id) catch |err| {
            _ = entity.remove(spawnedEntity.bodyId);
            return err;
        };
        damage.register(spawnedEntity.bodyId, .{
            .model = .{ .health = .{
                .current = maximumHealth,
                .maximum = maximumHealth,
            } },
            .onDestroyed = .{ .spawn_rubble = rubbleTemplateId },
        }) catch |err| {
            _ = entity.remove(spawnedEntity.bodyId);
            return err;
        };
        try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
        return bodyIds.toOwnedSlice();
    }

    if (std.mem.eql(u8, e.type, "goal")) {
        var goalShapeDef = box2d.c.b2DefaultShapeDef();
        goalShapeDef.isSensor = true;
        goalShapeDef.enableSensorEvents = true;
        goalShapeDef.filter.categoryBits = collision.CATEGORY_SENSOR;
        goalShapeDef.filter.maskBits = collision.MASK_SENSOR_GOAL;
        const goalBodyDef = bodyDefWithRotation(box2d.createStaticBodyDef(pos), e.rotationDegrees);
        const bodyId = try sensor.createSensorEntityFromImg(spriteUuid, goalShapeDef, goalBodyDef, "goal", onGoalBegin);
        try appendSpawnedSensorBody(&bodyIds, bodyId);
        return bodyIds.toOwnedSlice();
    }

    if (std.mem.eql(u8, e.type, "spawn")) {
        const bodyDef = bodyDefWithRotation(box2d.createStaticBodyDef(pos), e.rotationDegrees);
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
    for (lev.parallaxEntities) |e| {
        try spawnParallaxEntity(e);
    }

    for (lev.entities) |e| {
        const bodyIds = try spawnSerializableEntity(e);
        defer allocator.free(bodyIds);

        if (std.mem.eql(u8, e.type, "spawn")) {
            try spawn.addLocation(e.pos);
        }
    }

    return spawn.locations.count() > 0;
}

fn spawnTwoPlayers() !void {
    const playerId1 = try player.spawn();
    if (!controller.controllers.contains(playerId1)) {
        const color1 = try controller.createControllerForPlayer(playerId1);
        player.setColor(playerId1, color1);
    } else {
        player.setColor(playerId1, controller.controllers.get(playerId1).?.color);
    }

    const playerId2 = if (splitscreen)
        try player.spawn()
    else
        try player.spawnWithSharedCamera(player.players.get(playerId1).?.cameraId);
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
    try gravestone.warmCaches();

    const parsed = try parseFromPath(path);
    defer parsed.deinit();
    const lev = parsed.value;

    try applyLevelSettings(lev);
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
    movement.cleanup();
    gravestone.clearScheduledSpawns();
    sensor.cleanup();
    projectile.cleanup();
    rubble.cleanup();
    destruction.cleanup();
    weapon.cleanupTrails();
    entity.cleanup();
    background.cleanup();
    animation.cleanup();
    polygon.clearCache();
    sprite.clearTextureCache();
    gpu.resetAtlasToCheckpoint();
    viewport.cleanup();
    camera.resetPlayerCameraIds();
    spawn.cleanup();
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
