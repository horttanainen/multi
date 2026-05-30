const std = @import("std");

const config = @import("config.zig");
const sdl = @import("sdl.zig");

pub const Scope = enum {
    explosion,
    level_editor_static_spawn,
};

pub const StaticEntityMetrics = struct {
    create_from_img_calls: usize = 0,
    create_body_us: u64 = 0,
    create_entity_us: u64 = 0,
    entities_put_us: u64 = 0,
    create_from_img_total_us: u64 = 0,

    entity_for_body_calls: usize = 0,
    dupe_type_us: u64 = 0,
    get_sprite_us: u64 = 0,
    collider_chunks_us: u64 = 0,
    shape_ids_us: u64 = 0,
    sprite_uuid_alloc_us: u64 = 0,
    entity_for_body_total_us: u64 = 0,
};

pub const StaticColliderMetrics = struct {
    calls: usize = 0,
    no_triangle_calls: usize = 0,
    chunks_in: usize = 0,
    chunks_out: usize = 0,
    triangles: usize = 0,
    shapes: usize = 0,
    empty_shape_chunks: usize = 0,
    triangulate_us: u64 = 0,
    shape_us: u64 = 0,
    append_us: u64 = 0,
    owned_slice_us: u64 = 0,
    total_us: u64 = 0,
};

pub const StaticPolygonMetrics = struct {
    extract_calls: usize = 0,
    boundary_edges: usize = 0,
    loops: usize = 0,
    raw_vertices: usize = 0,
    simplified_vertices: usize = 0,
    simplify_calls: usize = 0,
    triangle_calls: usize = 0,
    output_triangles: usize = 0,
    build_edges_us: u64 = 0,
    trace_loops_us: u64 = 0,
    simplify_us: u64 = 0,
    triangle_us: u64 = 0,
    scale_us: u64 = 0,
    extract_us: u64 = 0,
    boundary_triangulate_us: u64 = 0,
};

var levelEditorStaticSpawnDepth: u32 = 0;
var staticEntityMetrics: StaticEntityMetrics = .{};
var staticColliderMetrics: StaticColliderMetrics = .{};
var staticPolygonMetrics: StaticPolygonMetrics = .{};

pub fn enabled(comptime scope: Scope) bool {
    return switch (scope) {
        .explosion => config.perf.explosion,
        .level_editor_static_spawn => config.perf.level_editor_static_spawn and levelEditorStaticSpawnDepth > 0,
    };
}

pub fn enter(comptime scope: Scope) void {
    switch (scope) {
        .explosion => {},
        .level_editor_static_spawn => levelEditorStaticSpawnDepth += 1,
    }
}

pub fn exit(comptime scope: Scope) void {
    switch (scope) {
        .explosion => {},
        .level_editor_static_spawn => {
            if (levelEditorStaticSpawnDepth == 0) {
                std.log.warn("perf.exit: level editor static spawn scope was not active", .{});
                return;
            }
            levelEditorStaticSpawnDepth -= 1;
        },
    }
}

pub fn begin(comptime scope: Scope) u64 {
    if (!enabled(scope)) return 0;
    return sdl.getPerformanceCounter();
}

pub fn elapsedUs(start: u64) u64 {
    if (start == 0) return 0;

    const elapsed = sdl.getPerformanceCounter() - start;
    return elapsed * 1_000_000 / sdl.getPerformanceFrequency();
}

pub fn log(comptime scope: Scope, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(scope)) return;
    std.log.info(fmt, args);
}

pub fn resetLevelEditorStaticMetrics() void {
    if (!enabled(.level_editor_static_spawn)) return;

    staticEntityMetrics = .{};
    staticColliderMetrics = .{};
    staticPolygonMetrics = .{};
}

pub fn addLevelEditorStaticEntityMetrics(metrics: StaticEntityMetrics) void {
    if (!enabled(.level_editor_static_spawn)) return;

    staticEntityMetrics.create_from_img_calls += metrics.create_from_img_calls;
    staticEntityMetrics.create_body_us += metrics.create_body_us;
    staticEntityMetrics.create_entity_us += metrics.create_entity_us;
    staticEntityMetrics.entities_put_us += metrics.entities_put_us;
    staticEntityMetrics.create_from_img_total_us += metrics.create_from_img_total_us;
    staticEntityMetrics.entity_for_body_calls += metrics.entity_for_body_calls;
    staticEntityMetrics.dupe_type_us += metrics.dupe_type_us;
    staticEntityMetrics.get_sprite_us += metrics.get_sprite_us;
    staticEntityMetrics.collider_chunks_us += metrics.collider_chunks_us;
    staticEntityMetrics.shape_ids_us += metrics.shape_ids_us;
    staticEntityMetrics.sprite_uuid_alloc_us += metrics.sprite_uuid_alloc_us;
    staticEntityMetrics.entity_for_body_total_us += metrics.entity_for_body_total_us;
}

pub fn addLevelEditorStaticColliderMetrics(metrics: StaticColliderMetrics) void {
    if (!enabled(.level_editor_static_spawn)) return;

    staticColliderMetrics.calls += metrics.calls;
    staticColliderMetrics.no_triangle_calls += metrics.no_triangle_calls;
    staticColliderMetrics.chunks_in += metrics.chunks_in;
    staticColliderMetrics.chunks_out += metrics.chunks_out;
    staticColliderMetrics.triangles += metrics.triangles;
    staticColliderMetrics.shapes += metrics.shapes;
    staticColliderMetrics.empty_shape_chunks += metrics.empty_shape_chunks;
    staticColliderMetrics.triangulate_us += metrics.triangulate_us;
    staticColliderMetrics.shape_us += metrics.shape_us;
    staticColliderMetrics.append_us += metrics.append_us;
    staticColliderMetrics.owned_slice_us += metrics.owned_slice_us;
    staticColliderMetrics.total_us += metrics.total_us;
}

pub fn addLevelEditorStaticPolygonMetrics(metrics: StaticPolygonMetrics) void {
    if (!enabled(.level_editor_static_spawn)) return;

    staticPolygonMetrics.extract_calls += metrics.extract_calls;
    staticPolygonMetrics.boundary_edges += metrics.boundary_edges;
    staticPolygonMetrics.loops += metrics.loops;
    staticPolygonMetrics.raw_vertices += metrics.raw_vertices;
    staticPolygonMetrics.simplified_vertices += metrics.simplified_vertices;
    staticPolygonMetrics.simplify_calls += metrics.simplify_calls;
    staticPolygonMetrics.triangle_calls += metrics.triangle_calls;
    staticPolygonMetrics.output_triangles += metrics.output_triangles;
    staticPolygonMetrics.build_edges_us += metrics.build_edges_us;
    staticPolygonMetrics.trace_loops_us += metrics.trace_loops_us;
    staticPolygonMetrics.simplify_us += metrics.simplify_us;
    staticPolygonMetrics.triangle_us += metrics.triangle_us;
    staticPolygonMetrics.scale_us += metrics.scale_us;
    staticPolygonMetrics.extract_us += metrics.extract_us;
    staticPolygonMetrics.boundary_triangulate_us += metrics.boundary_triangulate_us;
}

pub fn levelEditorStaticEntityMetrics() StaticEntityMetrics {
    return staticEntityMetrics;
}

pub fn levelEditorStaticColliderMetrics() StaticColliderMetrics {
    return staticColliderMetrics;
}

pub fn levelEditorStaticPolygonMetrics() StaticPolygonMetrics {
    return staticPolygonMetrics;
}
