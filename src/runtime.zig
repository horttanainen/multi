const std = @import("std");

var current_io: std.Io = undefined;
var random_source: std.Random.IoSource = undefined;
var initialized = false;

pub fn init(io_value: std.Io) void {
    current_io = io_value;
    random_source = .{ .io = io_value };
    initialized = true;
}

pub fn io() std.Io {
    if (!initialized) {
        std.log.err("runtime.io: used before runtime.init", .{});
        @panic("runtime I/O not initialized");
    }

    return current_io;
}

pub fn random() std.Random {
    _ = io();
    return random_source.interface();
}
