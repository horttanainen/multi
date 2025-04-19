const std = @import("std");
const sdl = @import("zsdl");

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

    try fps.draw();

    sdl.renderPresent(renderer);
}
