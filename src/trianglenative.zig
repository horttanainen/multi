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
pub extern fn triangulate(flags: [*:0]const u8, in_: *triangulateio, out: *triangulateio, vorout: ?*triangulateio) void;
pub extern fn trifree(ptr: ?*anyopaque) void;
