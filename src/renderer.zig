const std = @import("std");
const gpu = @import("gpu.zig");

const background = @import("background.zig");
const camera = @import("camera.zig");
const config = @import("config.zig");
const state = @import("state.zig");
const window = @import("window.zig");
const ui = @import("ui.zig");
const menu = @import("menu.zig");
const debug = @import("debug.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const sensor = @import("sensor.zig");
const cursor = @import("cursor.zig");
const level = @import("level.zig");
const viewport = @import("viewport.zig");
const particle = @import("particle.zig");
const rope = @import("rope.zig");
const weapon = @import("weapon.zig");

const background_paint = @import("background_paint.zig");

const RendererError = error{RendererUninitialized};

pub var zoom: f32 = 1.0;

pub fn updateZoom() void {
    if (!level.fixedCamera) {
        zoom = 1.0;
        return;
    }
    const scaleX = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(level.size.x));
    const scaleY = @as(f32, @floatFromInt(window.height)) / @as(f32, @floatFromInt(level.size.y));
    zoom = @min(scaleX, scaleY);
}

pub fn render() !void {
    gpu.setCrtParams(if (menu.isOpen()) config.crtMenu else config.crt);
    gpu.setLutParams(config.lut);

    // Clear to black then draw the paint-swirl background.
    try gpu.setRenderDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try gpu.renderClear();
    try background_paint.draw();

    if (!menu.isOpen()) {
        if (state.editingLevel) {
            try renderCamera(0);
            try drawLevelBorder();
            try cursor.draw();
        } else {
            for (camera.cameras.keys()) |cameraId| {
                if (viewport.getViewportForCamera(cameraId) == null) continue;
                try renderCamera(cameraId);
            }
        }
    }

    try menu.draw();

    gpu.renderPresent();
}

fn renderCamera(cameraId: usize) !void {
    try camera.setActiveCamera(cameraId);
    gpu.setZoom(zoom);

    try background.draw();
    try sensor.drawAllSensors();
    try player.drawAllWeaponsBehind();
    try player.drawAllLeftHandsBehind();
    try entity.drawAll();
    try player.drawAllWeaponsFront();
    try player.drawAllLeftHandsFront();
    try particle.drawAll();
    try rope.drawRopes();
    try weapon.drawTrails();
    try player.drawAllCrosshairs();

    if (config.debug) {
        try debug.draw();
    }

    try gpu.setRenderDrawColor(.{ .r = 0, .g = 255, .b = 255, .a = 255 });

    try ui.drawMode();
    try ui.drawFps();
    try ui.drawPlayerHealth();
    try ui.drawPlayerLocationsOnViewportBorder();
    try ui.drawScoreboard();
}

fn drawLevelBorder() !void {
    const hw = @divFloor(level.size.x, 2);
    const hh = @divFloor(level.size.y, 2);
    const tl = camera.relativePosition(.{ .x = level.position.x - hw, .y = level.position.y - hh });
    try gpu.setRenderDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 200 });
    try gpu.renderDrawRect(.{ .x = tl.x, .y = tl.y, .w = level.size.x, .h = level.size.y });
}

fn drawHorizontalLine(height: i32) !void {
    const xAxisStart = camera.relativePosition(.{ .x = 0, .y = height });
    const xAxisEnd = camera.relativePosition(.{ .x = window.width, .y = height });
    try gpu.renderDrawLine(xAxisStart.x, xAxisStart.y, xAxisEnd.x, xAxisEnd.y);
}

fn drawVerticalLine(height: i32) !void {
    const yAxisStart = camera.relativePosition(.{ .x = height, .y = window.height });
    const yAxisEnd = camera.relativePosition(.{ .x = height, .y = 0 });
    try gpu.renderDrawLine(yAxisStart.x, yAxisStart.y, yAxisEnd.x, yAxisEnd.y);
}
