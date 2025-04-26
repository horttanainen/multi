const std = @import("std");
const sdl = @import("zsdl");

const camera = @import("camera.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const fps = @import("fps.zig");
const debug = @import("debug.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const sensor = @import("sensor.zig");
const level = @import("level.zig");

const RendererError = error{RendererUninitialized};

pub fn render() !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    //draw
    try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try sdl.renderClear(renderer);

    try level.draw();
    try sensor.drawGoal();
    try entity.drawAll();
    try player.draw();
    try debug.draw();

    try sdl.setRenderDrawColor(renderer, .{ .r = 0, .g = 255, .b = 255, .a = 255 });

    for (0..9) |y| {
        try drawHorizontalLine(@as(i32, @intCast(y)) * 100);
        try drawVerticalLine(@as(i32, @intCast(y)) * 100);
    }

    try fps.draw();

    sdl.renderPresent(renderer);
}

fn drawHorizontalLine(height: i32) !void {
    const resources = try shared.getResources();
    const xAxisStart = camera.relativePosition(.{ .x = 0, .y = height });
    const xAxisEnd = camera.relativePosition(.{ .x = config.window.width, .y = height });
    try sdl.renderDrawLine(resources.renderer, xAxisStart.x, xAxisStart.y, xAxisEnd.x, xAxisEnd.y);
}

fn drawVerticalLine(height: i32) !void {
    const resources = try shared.getResources();
    const yAxisStart = camera.relativePosition(.{ .x = height, .y = config.window.height });
    const yAxisEnd = camera.relativePosition(.{ .x = height, .y = 0 });
    try sdl.renderDrawLine(resources.renderer, yAxisStart.x, yAxisStart.y, yAxisEnd.x, yAxisEnd.y);
}
