const std = @import("std");
const triangle = @import("trianglenative.zig");
const vec = @import("vector.zig");
const shared = @import("shared.zig");
const allocator = std.heap.c_allocator;

const IVec2 = vec.IVec2;

pub fn triangulate(vertices: []const IVec2) ![][3]IVec2 {
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

    var in_data: triangle.triangulateio = std.mem.zeroes(triangle.triangulateio);
    in_data.numberofpoints = @as(c_int, @intCast(point_count));
    in_data.pointlist = pointlist.ptr;
    in_data.numberofsegments = @intCast(point_count);
    in_data.segmentlist = segmentlist.ptr;

    var out_data: triangle.triangulateio = std.mem.zeroes(triangle.triangulateio);
    defer triangle.trifree(out_data.pointlist);
    defer triangle.trifree(out_data.trianglelist);

    triangle.triangulate("pzqV", &in_data, &out_data, @as(?[*:0]const u8, null));

    // Triangle may add Steiner points, so use the full output pointlist
    const triangle_count = out_data.numberoftriangles;
    const triangle_indices = out_data.trianglelist;
    const output_vertex_count = @as(usize, @intCast(out_data.numberofpoints));
    const output_vertices = try shared.allocator.alloc(IVec2, output_vertex_count);
    defer shared.allocator.free(output_vertices);

    for (output_vertices, 0..) |*out_v, i| {
        const x = out_data.pointlist[i * 2 + 0];
        const y = out_data.pointlist[i * 2 + 1];
        out_v.* = IVec2{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
        };
    }
    const tris = try shared.allocator.alloc([3]IVec2, @as(usize, @intCast(triangle_count)));

    for (tris, 0..) |*tri, i| {
        const ia = triangle_indices[i * 3 + 0];
        const ib = triangle_indices[i * 3 + 1];
        const ic = triangle_indices[i * 3 + 2];
        tri.* = .{
            output_vertices[@as(usize, @intCast(ia))],
            output_vertices[@as(usize, @intCast(ib))],
            output_vertices[@as(usize, @intCast(ic))],
        };
    }
    return tris;
}
