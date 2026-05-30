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
const runtime = @import("runtime.zig");
const weapon = @import("weapon.zig");
const perf = @import("perf.zig");

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
    const data = try std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, allocator, .limited(config.maxLevelSizeInBytes));
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

fn staticSpriteBacking(serializedEntity: entity.SerializableEntity) sprite.Backing {
    return if (serializedEntity.breakable) .mutable else .immutable;
}

fn entitySpriteBacking(serializedEntity: entity.SerializableEntity) sprite.Backing {
    if (std.mem.eql(u8, serializedEntity.type, "dynamic")) return .mutable;
    return .immutable;
}

fn shouldTileStaticSurface(surface: *sdl.Surface) bool {
    return surface.w > entity.terrainColliderChunkSizeP or surface.h > entity.terrainColliderChunkSizeP;
}

const TileSolidity = enum {
    empty,
    full,
    partial,
};

fn surfaceRectSolidity(surface: *sdl.Surface, rect: sdl.Rect) TileSolidity {
    const pixels: [*]const u8 = @ptrCast(surface.pixels);
    const pitch: usize = @intCast(surface.pitch);
    const bytesPerPixel: usize = 4;
    const threshold: u8 = 150;

    const minX: usize = @intCast(rect.x);
    const maxX: usize = @intCast(rect.x + rect.w);
    const minY: usize = @intCast(rect.y);
    const maxY: usize = @intCast(rect.y + rect.h);

    var hasSolidPixels = false;
    var hasTransparentPixels = false;

    var y = minY;
    while (y < maxY) : (y += 1) {
        var x = minX;
        while (x < maxX) : (x += 1) {
            const pixelIndex = y * pitch + x * bytesPerPixel;
            if (pixels[pixelIndex + 3] >= threshold) {
                hasSolidPixels = true;
            } else {
                hasTransparentPixels = true;
            }

            if (hasSolidPixels and hasTransparentPixels) {
                return .partial;
            }
        }
    }

    if (hasSolidPixels) return .full;
    return .empty;
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

fn fullTileBoxShape(rect: sdl.Rect, scale: vec.Vec2) box2d.c.b2Polygon {
    const halfWidthM = @as(f32, @floatFromInt(rect.w)) * scale.x / conv.met2pix * 0.5;
    const halfHeightM = @as(f32, @floatFromInt(rect.h)) * scale.y / conv.met2pix * 0.5;
    return box2d.c.b2MakeBox(halfWidthM, halfHeightM);
}

fn spawnSingleStaticEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    const totalStart = perf.begin(.level_editor_static_spawn);
    const spriteStart = perf.begin(.level_editor_static_spawn);
    const spriteUuid = try sprite.createFromImgWithBacking(e.imgPath, e.scale, vec.izero, staticSpriteBacking(e));
    errdefer sprite.cleanupLater(spriteUuid);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_single entity={d} stage=create_sprite sprite={d} us={d}",
        .{ e.id, spriteUuid, perf.elapsedUs(spriteStart) },
    );

    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer cleanupSpawnedBodies(bodyIds.items);
    errdefer bodyIds.deinit();

    const bodyDef = box2d.createStaticBodyDef(conv.pixel2M(e.pos));
    const entityStart = perf.begin(.level_editor_static_spawn);
    const spawnedEntity = entity.createFromImg(spriteUuid, shapeDef, bodyDef, "static") catch |err| {
        const entityUs = perf.elapsedUs(entityStart);
        if (err == polygon.PolygonError.CouldNotCreateTriangle) {
            std.log.warn("spawnSingleStaticEntity: static entity {d} produced no collider triangles", .{e.id});
            sprite.cleanupLater(spriteUuid);
            const emptyBodies = try bodyIds.toOwnedSlice();
            perf.log(
                .level_editor_static_spawn,
                "perf.level_static_single entity={d} stage=create_entity_no_triangles us={d} total_us={d}",
                .{ e.id, entityUs, perf.elapsedUs(totalStart) },
            );
            return emptyBodies;
        }
        return err;
    };
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_single entity={d} stage=create_entity us={d}",
        .{ e.id, perf.elapsedUs(entityStart) },
    );

    const appendStart = perf.begin(.level_editor_static_spawn);
    try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_single entity={d} stage=append_body body_count={d} us={d}",
        .{ e.id, bodyIds.items.len, perf.elapsedUs(appendStart) },
    );

    const ownedStart = perf.begin(.level_editor_static_spawn);
    const result = try bodyIds.toOwnedSlice();
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_single entity={d} stage=to_owned_slice body_count={d} us={d} total_us={d}",
        .{ e.id, result.len, perf.elapsedUs(ownedStart), perf.elapsedUs(totalStart) },
    );
    return result;
}

fn spawnTiledStaticEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef, sourceSurface: *sdl.Surface) ![]box2d.c.b2BodyId {
    const totalStart = perf.begin(.level_editor_static_spawn);
    var bodyIds = std.array_list.Managed(box2d.c.b2BodyId).init(allocator);
    errdefer cleanupSpawnedBodies(bodyIds.items);
    errdefer bodyIds.deinit();

    const width = sourceSurface.w;
    const height = sourceSurface.h;
    const tileSize = entity.terrainColliderChunkSizeP;
    var tilesVisited: usize = 0;
    var solidTiles: usize = 0;
    var fullTiles: usize = 0;
    var partialTiles: usize = 0;
    var noColliderTiles: usize = 0;
    var solidCheckUs: u64 = 0;
    var surfaceUs: u64 = 0;
    var spriteUs: u64 = 0;
    var entityUs: u64 = 0;
    var fullEntityUs: u64 = 0;
    var appendUs: u64 = 0;

    var y: i32 = 0;
    while (y < height) : (y += tileSize) {
        var x: i32 = 0;
        while (x < width) : (x += tileSize) {
            tilesVisited += 1;
            const rect = sdl.Rect{
                .x = x,
                .y = y,
                .w = @min(tileSize, width - x),
                .h = @min(tileSize, height - y),
            };
            const solidStart = perf.begin(.level_editor_static_spawn);
            const solidity = surfaceRectSolidity(sourceSurface, rect);
            solidCheckUs += perf.elapsedUs(solidStart);
            if (solidity == .empty) continue;
            solidTiles += 1;

            const surfaceStart = perf.begin(.level_editor_static_spawn);
            const tileSurface = try createSurfaceRegion(sourceSurface, rect);
            surfaceUs += perf.elapsedUs(surfaceStart);

            const spriteStart = perf.begin(.level_editor_static_spawn);
            const tileSpriteUuid = try sprite.createFromOwnedSurfaceWithBacking(e.imgPath, tileSurface, e.scale, vec.izero, staticSpriteBacking(e));
            spriteUs += perf.elapsedUs(spriteStart);

            const tilePos = tileCenterPosition(e.pos, sourceSurface, rect, e.scale);
            const bodyDef = box2d.createStaticBodyDef(conv.pixel2M(tilePos));
            const entityStart = perf.begin(.level_editor_static_spawn);
            var tileEntityUs: u64 = 0;
            const spawnedEntity = if (solidity == .full) blk: {
                fullTiles += 1;
                const boxShape = fullTileBoxShape(rect, e.scale);
                const fullTileEntity = entity.createFromShape(tileSpriteUuid, boxShape, shapeDef, bodyDef, "static") catch |err| {
                    sprite.cleanupLater(tileSpriteUuid);
                    return err;
                };
                tileEntityUs = perf.elapsedUs(entityStart);
                fullEntityUs += tileEntityUs;
                break :blk fullTileEntity;
            } else blk: {
                partialTiles += 1;
                const partialTileEntity = entity.createFromImg(tileSpriteUuid, shapeDef, bodyDef, "static") catch |err| {
                    tileEntityUs = perf.elapsedUs(entityStart);
                    entityUs += tileEntityUs;
                    sprite.cleanupLater(tileSpriteUuid);
                    if (err == polygon.PolygonError.CouldNotCreateTriangle) {
                        noColliderTiles += 1;
                        continue;
                    }
                    return err;
                };
                tileEntityUs = perf.elapsedUs(entityStart);
                break :blk partialTileEntity;
            };
            entityUs += tileEntityUs;

            const appendStart = perf.begin(.level_editor_static_spawn);
            try appendSpawnedEntityBody(&bodyIds, spawnedEntity);
            appendUs += perf.elapsedUs(appendStart);
        }
    }

    const ownedStart = perf.begin(.level_editor_static_spawn);
    const result = try bodyIds.toOwnedSlice();
    const ownedUs = perf.elapsedUs(ownedStart);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_tiles entity={d} size={d}x{d} tile_size={d} visited={d} solid={d} full={d} partial={d} no_collider={d} bodies={d} solid_check_us={d} surface_us={d} sprite_us={d} entity_us={d} full_entity_us={d} append_us={d} owned_slice_us={d} total_us={d}",
        .{ e.id, width, height, tileSize, tilesVisited, solidTiles, fullTiles, partialTiles, noColliderTiles, result.len, solidCheckUs, surfaceUs, spriteUs, entityUs, fullEntityUs, appendUs, ownedUs, perf.elapsedUs(totalStart) },
    );
    return result;
}

fn logStaticSpawnMetrics(entityId: u64) void {
    const entityMetrics = perf.levelEditorStaticEntityMetrics();
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_entity_metrics entity={d} create_from_img_calls={d} create_body_us={d} create_entity_us={d} entities_put_us={d} create_from_img_total_us={d} entity_for_body_calls={d} dupe_type_us={d} get_sprite_us={d} collider_chunks_us={d} shape_ids_us={d} sprite_uuid_alloc_us={d} entity_for_body_total_us={d}",
        .{
            entityId,
            entityMetrics.create_from_img_calls,
            entityMetrics.create_body_us,
            entityMetrics.create_entity_us,
            entityMetrics.entities_put_us,
            entityMetrics.create_from_img_total_us,
            entityMetrics.entity_for_body_calls,
            entityMetrics.dupe_type_us,
            entityMetrics.get_sprite_us,
            entityMetrics.collider_chunks_us,
            entityMetrics.shape_ids_us,
            entityMetrics.sprite_uuid_alloc_us,
            entityMetrics.entity_for_body_total_us,
        },
    );

    const colliderMetrics = perf.levelEditorStaticColliderMetrics();
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_collider_metrics entity={d} calls={d} no_triangle_calls={d} chunks_in={d} chunks_out={d} triangles={d} shapes={d} empty_shape_chunks={d} triangulate_us={d} shape_us={d} append_us={d} owned_slice_us={d} total_us={d}",
        .{
            entityId,
            colliderMetrics.calls,
            colliderMetrics.no_triangle_calls,
            colliderMetrics.chunks_in,
            colliderMetrics.chunks_out,
            colliderMetrics.triangles,
            colliderMetrics.shapes,
            colliderMetrics.empty_shape_chunks,
            colliderMetrics.triangulate_us,
            colliderMetrics.shape_us,
            colliderMetrics.append_us,
            colliderMetrics.owned_slice_us,
            colliderMetrics.total_us,
        },
    );

    const polygonMetrics = perf.levelEditorStaticPolygonMetrics();
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_polygon_metrics entity={d} extract_calls={d} boundary_edges={d} loops={d} raw_vertices={d} simplified_vertices={d} simplify_calls={d} triangle_calls={d} output_triangles={d} build_edges_us={d} trace_loops_us={d} simplify_us={d} triangle_us={d} scale_us={d} extract_us={d} boundary_triangulate_us={d}",
        .{
            entityId,
            polygonMetrics.extract_calls,
            polygonMetrics.boundary_edges,
            polygonMetrics.loops,
            polygonMetrics.raw_vertices,
            polygonMetrics.simplified_vertices,
            polygonMetrics.simplify_calls,
            polygonMetrics.triangle_calls,
            polygonMetrics.output_triangles,
            polygonMetrics.build_edges_us,
            polygonMetrics.trace_loops_us,
            polygonMetrics.simplify_us,
            polygonMetrics.triangle_us,
            polygonMetrics.scale_us,
            polygonMetrics.extract_us,
            polygonMetrics.boundary_triangulate_us,
        },
    );
}

fn spawnStaticSerializableEntity(e: entity.SerializableEntity, shapeDef: box2d.c.b2ShapeDef) ![]box2d.c.b2BodyId {
    const totalStart = perf.begin(.level_editor_static_spawn);
    perf.resetLevelEditorStaticMetrics();
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_spawn begin entity={d} image='{s}' pos=({d},{d}) scale=({d},{d})",
        .{ e.id, e.imgPath, e.pos.x, e.pos.y, e.scale.x, e.scale.y },
    );

    const staticDef = staticShapeDef(e, shapeDef);

    const dupeStart = perf.begin(.level_editor_static_spawn);
    const imgPathZ = try allocator.dupeZ(u8, e.imgPath);
    defer allocator.free(imgPathZ);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_spawn entity={d} stage=dupe_image_path us={d}",
        .{ e.id, perf.elapsedUs(dupeStart) },
    );

    const loadStart = perf.begin(.level_editor_static_spawn);
    const loadedSurface = try sdl.image.load(imgPathZ);
    defer sdl.destroySurface(loadedSurface);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_spawn entity={d} stage=load_image size={d}x{d} us={d}",
        .{ e.id, loadedSurface.w, loadedSurface.h, perf.elapsedUs(loadStart) },
    );

    if (!shouldTileStaticSurface(loadedSurface)) {
        const singleStart = perf.begin(.level_editor_static_spawn);
        const bodyIds = try spawnSingleStaticEntity(e, staticDef);
        perf.log(
            .level_editor_static_spawn,
            "perf.level_static_spawn entity={d} stage=single_static body_count={d} us={d} total_us={d}",
            .{ e.id, bodyIds.len, perf.elapsedUs(singleStart), perf.elapsedUs(totalStart) },
        );
        logStaticSpawnMetrics(e.id);
        return bodyIds;
    }

    const convertStart = perf.begin(.level_editor_static_spawn);
    const sourceSurface = c.SDL_ConvertSurface(loadedSurface, c.SDL_PIXELFORMAT_BGRA32);
    if (sourceSurface == null) {
        std.log.warn("spawnStaticSerializableEntity: failed to convert surface for static entity {d}", .{e.id});
        return error.ConvertSurfaceFailed;
    }
    defer c.SDL_DestroySurface(sourceSurface);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_spawn entity={d} stage=convert_surface us={d}",
        .{ e.id, perf.elapsedUs(convertStart) },
    );

    const tiledStart = perf.begin(.level_editor_static_spawn);
    const bodyIds = try spawnTiledStaticEntity(e, staticDef, sourceSurface);
    perf.log(
        .level_editor_static_spawn,
        "perf.level_static_spawn entity={d} stage=tiled_static body_count={d} us={d} total_us={d}",
        .{ e.id, bodyIds.len, perf.elapsedUs(tiledStart), perf.elapsedUs(totalStart) },
    );
    logStaticSpawnMetrics(e.id);
    return bodyIds;
}

pub fn spawnSerializableEntity(e: entity.SerializableEntity) ![]box2d.c.b2BodyId {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = e.friction;
    shapeDef.enableSensorEvents = true;

    if (std.mem.eql(u8, e.type, "static")) {
        return spawnStaticSerializableEntity(e, shapeDef);
    }

    const spriteUuid = try sprite.createFromImgWithBacking(e.imgPath, e.scale, vec.izero, entitySpriteBacking(e));
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
