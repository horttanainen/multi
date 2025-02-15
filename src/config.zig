const std = @import("std");

pub const Config = struct {
    window: struct { width: i32, height: i32 },
    met2pix: i32,
};

pub const config: Config = .{
    .window = .{ .width = 800, .height = 800 },
    .met2pix = 80,
};
