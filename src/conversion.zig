const std = @import("std");
const box2d = @import("box2d.zig");

const config = @import("config.zig");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

pub fn pixel2M(p: IVec2) Vec2 {
    return Vec2{
        .x = @as(f32, @floatFromInt(p.x)) / config.met2pix,
        .y = @as(f32, @floatFromInt(p.y)) / config.met2pix,
    };
}

pub fn m2Pixel(pos: box2d.c.b2Vec2) IVec2 {
    return .{
        .x = @as(i32, @intFromFloat(pos.x * config.met2pix)),
        .y = @as(i32, @intFromFloat(pos.y * config.met2pix)),
    };
}

pub fn p2m(p: IVec2) box2d.c.b2Vec2 {
    return box2d.c.b2Vec2{
        .x = @as(f32, @floatFromInt(p.x)) / config.met2pix,
        .y = @as(f32, @floatFromInt(p.y)) / config.met2pix,
    };
}
