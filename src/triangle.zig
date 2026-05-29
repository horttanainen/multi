const std = @import("std");
const vec = @import("vector.zig");
const gpa_allocator = @import("allocator.zig").allocator;

pub const triangulateio = extern struct {
    pointlist: ?[*]f64,
    pointattributelist: ?[*]f64,
    pointmarkerlist: ?[*]c_int,
    numberofpoints: c_int,
    numberofpointattributes: c_int,

    trianglelist: ?[*]c_int,
    triangleattributelist: ?[*]f64,
    trianglearealist: ?[*]f64,
    neighborlist: ?[*]c_int,
    numberoftriangles: c_int,
    numberofcorners: c_int,
    numberoftriangleattributes: c_int,

    segmentlist: ?[*]c_int,
    segmentmarkerlist: ?[*]c_int,
    numberofsegments: c_int,

    holelist: ?[*]f64,
    numberofholes: c_int,

    regionlist: ?[*]f64,
    numberofregions: c_int,

    edgelist: ?[*]c_int,
    edgemarkerlist: ?[*]c_int,
    normlist: ?[*]f64,
    numberofedges: c_int,
};

extern fn triangulate(flags: [*:0]const u8, in_: *triangulateio, out: *triangulateio, vorout: ?*triangulateio) void;
pub extern fn trifree(ptr: ?*anyopaque) void;

const allocator = std.heap.c_allocator;

pub const TriangleError = error{
    TriangulationFailed,
};

pub const PslgContour = struct {
    vertices: []const vec.IVec2,
};

const SegmentKey = struct {
    a: usize,
    b: usize,
};

pub fn split(vertices: []const vec.IVec2) ![][3]vec.IVec2 {
    const contours = [_]PslgContour{.{ .vertices = vertices }};
    return splitPslg(&contours, &.{});
}

pub fn splitPslg(contours: []const PslgContour, holes: []const vec.Vec2) ![][3]vec.IVec2 {
    var point_indices = std.AutoArrayHashMap(vec.IVec2, usize).init(gpa_allocator);
    defer point_indices.deinit();

    var points = std.array_list.Managed(vec.IVec2).init(gpa_allocator);
    defer points.deinit();

    var segments = std.array_list.Managed([2]usize).init(gpa_allocator);
    defer segments.deinit();

    var segment_keys = std.AutoArrayHashMap(SegmentKey, void).init(gpa_allocator);
    defer segment_keys.deinit();

    for (contours) |contour| {
        if (contour.vertices.len < 3) {
            return TriangleError.TriangulationFailed;
        }

        var first_index: ?usize = null;
        var previous_index: ?usize = null;
        var contour_segments: usize = 0;

        for (contour.vertices) |vertex| {
            const point_index = try getOrPutPointIndex(&point_indices, &points, vertex);
            if (first_index == null) {
                first_index = point_index;
            }

            if (previous_index != null) {
                if (try appendUniqueSegment(&segments, &segment_keys, previous_index.?, point_index)) {
                    contour_segments += 1;
                }
            }

            previous_index = point_index;
        }

        if (first_index != null and previous_index != null) {
            if (try appendUniqueSegment(&segments, &segment_keys, previous_index.?, first_index.?)) {
                contour_segments += 1;
            }
        }

        if (contour_segments < 3) {
            return TriangleError.TriangulationFailed;
        }
    }

    if (points.items.len < 3 or segments.items.len < 3) {
        return TriangleError.TriangulationFailed;
    }

    // Allocate and convert input pointlist (as f64 x/y pairs)
    const pointlist = try allocator.alloc(f64, points.items.len * 2);
    defer allocator.free(pointlist);

    for (points.items, 0..) |point, i| {
        pointlist[i * 2 + 0] = @floatFromInt(point.x);
        pointlist[i * 2 + 1] = @floatFromInt(point.y);
    }

    // Segment list: connect every vertex to the next
    const segmentlist = try allocator.alloc(c_int, segments.items.len * 2);
    defer allocator.free(segmentlist);

    for (segments.items, 0..) |segment, i| {
        segmentlist[i * 2 + 0] = @intCast(segment[0]);
        segmentlist[i * 2 + 1] = @intCast(segment[1]);
    }

    const maybe_holelist = if (holes.len > 0) try allocator.alloc(f64, holes.len * 2) else null;
    defer {
        if (maybe_holelist) |holelist| {
            allocator.free(holelist);
        }
    }

    if (maybe_holelist) |holelist| {
        for (holes, 0..) |hole, i| {
            holelist[i * 2 + 0] = hole.x;
            holelist[i * 2 + 1] = hole.y;
        }
    }

    var in_data: triangulateio = std.mem.zeroes(triangulateio);
    in_data.numberofpoints = @as(c_int, @intCast(points.items.len));
    in_data.pointlist = pointlist.ptr;
    in_data.numberofsegments = @intCast(segments.items.len);
    in_data.segmentlist = segmentlist.ptr;
    in_data.numberofholes = @intCast(holes.len);
    in_data.holelist = if (maybe_holelist) |holelist| holelist.ptr else null;

    var out_data: triangulateio = std.mem.zeroes(triangulateio);
    defer trifree(out_data.pointlist);
    defer trifree(out_data.trianglelist);
    defer trifree(out_data.segmentlist);
    defer trifree(out_data.segmentmarkerlist);

    // std.debug.print("numberofpoints: {}\n", .{in_data.numberofpoints});

    // std.debug.print("pointlist ptr: {x}\n", .{@intFromPtr(in_data.pointlist)});
    // for (0..@min(point_count * 2, 10)) |i| {
    //     std.debug.print("pointlist[{}] = {d}\n", .{ i, in_data.pointlist.?[i] });

    // }

    // std.debug.print("segmentlist ptr: {x}\n", .{@intFromPtr(in_data.segmentlist)});
    // std.debug.print("numberofsegments: {}\n", .{in_data.numberofsegments});

    triangulate("pzqQ", &in_data, &out_data, null);

    if (out_data.numberoftriangles <= 0 or out_data.trianglelist == null or out_data.pointlist == null) {
        return TriangleError.TriangulationFailed;
    }

    // Triangle may add Steiner points, so use the full output pointlist
    const triangle_count = out_data.numberoftriangles;
    const triangle_indices = out_data.trianglelist;
    const output_vertex_count = @as(usize, @intCast(out_data.numberofpoints));
    const output_vertices = try allocator.alloc(vec.IVec2, output_vertex_count);
    defer allocator.free(output_vertices);

    for (output_vertices, 0..) |*out_v, i| {
        const x = out_data.pointlist.?[i * 2 + 0];
        const y = out_data.pointlist.?[i * 2 + 1];
        out_v.* = vec.IVec2{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
        };
    }
    const tris = try gpa_allocator.alloc([3]vec.IVec2, @as(usize, @intCast(triangle_count)));

    for (tris, 0..) |*tri, i| {
        const ia = triangle_indices.?[i * 3 + 0];
        const ib = triangle_indices.?[i * 3 + 1];
        const ic = triangle_indices.?[i * 3 + 2];
        tri.* = .{
            output_vertices[@as(usize, @intCast(ia))],
            output_vertices[@as(usize, @intCast(ib))],
            output_vertices[@as(usize, @intCast(ic))],
        };
    }
    return tris;
}

fn getOrPutPointIndex(
    point_indices: *std.AutoArrayHashMap(vec.IVec2, usize),
    points: *std.array_list.Managed(vec.IVec2),
    point: vec.IVec2,
) !usize {
    const entry = try point_indices.getOrPut(point);
    if (entry.found_existing) {
        return entry.value_ptr.*;
    }

    const index = points.items.len;
    try points.append(point);
    entry.value_ptr.* = index;
    return index;
}

fn appendUniqueSegment(
    segments: *std.array_list.Managed([2]usize),
    segment_keys: *std.AutoArrayHashMap(SegmentKey, void),
    a: usize,
    b: usize,
) !bool {
    if (a == b) {
        return false;
    }

    const key = if (a < b) SegmentKey{ .a = a, .b = b } else SegmentKey{ .a = b, .b = a };
    const entry = try segment_keys.getOrPut(key);
    if (entry.found_existing) {
        return false;
    }

    try segments.append(.{ a, b });
    return true;
}
