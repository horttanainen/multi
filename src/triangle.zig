const std = @import("std");
const vec = @import("vector.zig");
const shared = @import("shared.zig");

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

pub fn split(vertices: []const vec.IVec2) ![][3]vec.IVec2 {
    const point_count = vertices.len;

    // Allocate and convert input pointlist (as f64 x/y pairs)
    const pointlist = try allocator.alloc(f64, point_count * 2);
    defer allocator.free(pointlist);

    for (vertices, 0..) |v, i| {
        pointlist[i * 2 + 0] = @floatFromInt(v.x);
        pointlist[i * 2 + 1] = @floatFromInt(v.y);
    }

    // Segment list: connect every vertex to the next
    const segmentlist = try allocator.alloc(c_int, point_count * 2);
    defer allocator.free(segmentlist);

    for (vertices, 0..) |_, i| {
        segmentlist[i * 2 + 0] = @intCast(i);
        segmentlist[i * 2 + 1] = @intCast((i + 1) % point_count);
    }

    var in_data: triangulateio = std.mem.zeroes(triangulateio);
    in_data.numberofpoints = @as(c_int, @intCast(point_count));
    in_data.pointlist = pointlist.ptr;
    in_data.numberofsegments = @intCast(point_count);
    in_data.segmentlist = segmentlist.ptr;

    var out_data: triangulateio = std.mem.zeroes(triangulateio);
    defer trifree(out_data.pointlist);
    defer trifree(out_data.trianglelist);

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
    const output_vertices = try shared.allocator.alloc(vec.IVec2, output_vertex_count);
    defer shared.allocator.free(output_vertices);

    for (output_vertices, 0..) |*out_v, i| {
        const x = out_data.pointlist.?[i * 2 + 0];
        const y = out_data.pointlist.?[i * 2 + 1];
        out_v.* = vec.IVec2{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
        };
    }
    const tris = try shared.allocator.alloc([3]vec.IVec2, @as(usize, @intCast(triangle_count)));

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
