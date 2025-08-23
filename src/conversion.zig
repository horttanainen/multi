const std = @import("std");
const box2d = @import("box2d.zig");

const config = @import("config.zig");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

pub fn m2PixelPos(x: f32, y: f32, w: f32, h: f32) IVec2 {
    return IVec2{
        .x = @as(i32, @intFromFloat(((w / 2.0) + x) * config.met2pix - config.met2pix * w)),
        .y = @as(i32, @intFromFloat(((h / 2.0) + y) * config.met2pix - config.met2pix * h)),
    };
}

pub fn pixel2MPos(px: i32, py: i32, w: f32, h: f32) Vec2 {
    const met2pix = config.met2pix;
    return Vec2{
        .x = (@as(f32, @floatFromInt(px)) / met2pix) - (w / 2.0 - w),
        .y = (@as(f32, @floatFromInt(py)) / met2pix) - (h / 2.0 - h),
    };
}

pub fn p2m(p: IVec2) box2d.c.b2Vec2 {
    return box2d.c.b2Vec2{
        .x = @as(f32, @floatFromInt(p.x)) / config.met2pix,
        .y = @as(f32, @floatFromInt(p.y)) / config.met2pix,
    };
}

pub fn m2Pixel(
    coord: box2d.c.b2Vec2,
) IVec2 {
    return .{ .x = @as(i32, @intFromFloat(coord.x * config.met2pix)), .y = @as(i32, @intFromFloat(coord.y * config.met2pix)) };
}
