const std = @import("std");
const sdl = @import("zsdl");

const background = @import("background.zig");
const camera = @import("camera.zig");
const config = @import("config.zig");
const shared = @import("shared.zig");
const window = @import("window.zig");
const ui = @import("ui.zig");
const debug = @import("debug.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const sensor = @import("sensor.zig");
const level = @import("level.zig");
const viewport = @import("viewport.zig");
const particle = @import("particle.zig");
const rope = @import("rope.zig");

const RendererError = error{RendererUninitialized};

pub fn render() !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    // Clear entire window once
    try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try sdl.renderClear(renderer);

    for (camera.cameras.keys()) |cameraId| {
        try renderCamera(cameraId);
    }

    sdl.renderPresent(renderer);
}

fn renderCamera(cameraId: usize) !void {
    const resources = try shared.getResources();

    try camera.setActiveCamera(cameraId);

    try background.draw();
    try sensor.drawGoal();
    try player.drawAllWeaponsBehind();
    try player.drawAllLeftHandsBehind();
    try entity.drawAll();
    try player.drawAllWeaponsFront();
    try player.drawAllLeftHandsFront();
    try particle.drawAll();
    try rope.drawRopes();
    try player.drawAllCrosshairs();

    if (config.debug) {
        try debug.draw();
    }

    try sdl.setRenderDrawColor(resources.renderer, .{ .r = 0, .g = 255, .b = 255, .a = 255 });

    try ui.drawMode();
    try ui.drawFps();
    try ui.drawPlayerHealth();
    try ui.drawPlayerLocationsOnViewportBorder();
    try ui.drawScoreboard();
}

fn drawHorizontalLine(height: i32) !void {
    const resources = try shared.getResources();
    const xAxisStart = camera.relativePosition(.{ .x = 0, .y = height });
    const xAxisEnd = camera.relativePosition(.{ .x = window.width, .y = height });
    try sdl.renderDrawLine(resources.renderer, xAxisStart.x, xAxisStart.y, xAxisEnd.x, xAxisEnd.y);
}

fn drawVerticalLine(height: i32) !void {
    const resources = try shared.getResources();
    const yAxisStart = camera.relativePosition(.{ .x = height, .y = window.height });
    const yAxisEnd = camera.relativePosition(.{ .x = height, .y = 0 });
    try sdl.renderDrawLine(resources.renderer, yAxisStart.x, yAxisStart.y, yAxisEnd.x, yAxisEnd.y);
}
