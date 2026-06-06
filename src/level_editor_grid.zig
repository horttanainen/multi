const std = @import("std");

const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");

const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const level = @import("level.zig");
const vec = @import("vector.zig");

pub const defaultGranularityMeters: f32 = 1.0;
pub const minGranularityMeters: f32 = 0.1;
pub const maxGranularityMeters: f32 = 20.0;

const maxLinesPerAxis: i32 = 1200;
const gridColor = sdl.Color{ .r = 120, .g = 150, .b = 170, .a = 80 };
const axisColor = sdl.Color{ .r = 220, .g = 220, .b = 220, .a = 135 };

var visible: bool = false;
var granularity_meters: f32 = defaultGranularityMeters;

pub fn isVisible() bool {
    return visible;
}

pub fn toggleVisible() void {
    visible = !visible;
}

pub fn granularityMeters() f32 {
    return granularity_meters;
}

pub fn setGranularityMeters(value: f32) void {
    if (!std.math.isFinite(value)) {
        std.log.warn("level_editor_grid.setGranularityMeters: invalid value {d}, using default", .{value});
        granularity_meters = defaultGranularityMeters;
        return;
    }

    if (value < minGranularityMeters) {
        std.log.warn("level_editor_grid.setGranularityMeters: value {d} below minimum {d}", .{ value, minGranularityMeters });
        granularity_meters = minGranularityMeters;
        return;
    }

    if (value > maxGranularityMeters) {
        std.log.warn("level_editor_grid.setGranularityMeters: value {d} above maximum {d}", .{ value, maxGranularityMeters });
        granularity_meters = maxGranularityMeters;
        return;
    }

    granularity_meters = value;
}

pub fn draw() !void {
    if (!visible) return;

    const base_spacing = spacingPixels();
    if (base_spacing <= 0) {
        std.log.warn("level_editor_grid.draw: invalid spacing {d}", .{base_spacing});
        return;
    }

    const bounds = levelBounds();
    const x_spacing = adjustedSpacing(bounds.maxX - bounds.minX, base_spacing);
    const y_spacing = adjustedSpacing(bounds.maxY - bounds.minY, base_spacing);

    try drawVerticalLines(bounds, x_spacing);
    try drawHorizontalLines(bounds, y_spacing);
}

fn spacingPixels() i32 {
    const pixels = granularity_meters * conv.met2pix;
    if (!std.math.isFinite(pixels)) {
        std.log.warn("level_editor_grid.spacingPixels: invalid pixel spacing {d}", .{pixels});
        return 0;
    }

    return @max(1, @as(i32, @intFromFloat(@round(pixels))));
}

fn levelBounds() vec.IRect {
    const half_width = @divFloor(level.size.x, 2);
    const half_height = @divFloor(level.size.y, 2);
    return .{
        .minX = level.position.x - half_width,
        .minY = level.position.y - half_height,
        .maxX = level.position.x + half_width,
        .maxY = level.position.y + half_height,
    };
}

fn adjustedSpacing(span: i32, base_spacing: i32) i32 {
    var spacing = base_spacing;
    while (lineCount(span, spacing) > maxLinesPerAxis) {
        spacing *= 2;
    }
    return spacing;
}

fn lineCount(span: i32, spacing: i32) i32 {
    if (spacing <= 0) return maxLinesPerAxis + 1;
    return @divFloor(@max(0, span), spacing) + 1;
}

fn firstGridLine(min: i32, spacing: i32) i32 {
    return @divFloor(min, spacing) * spacing;
}

fn drawVerticalLines(bounds: vec.IRect, spacing: i32) !void {
    var x = firstGridLine(bounds.minX, spacing);
    while (x <= bounds.maxX) : (x += spacing) {
        const top = camera.relativePosition(.{ .x = x, .y = bounds.minY });
        const bottom = camera.relativePosition(.{ .x = x, .y = bounds.maxY });
        try gpu.setRenderDrawColor(if (x == 0) axisColor else gridColor);
        try gpu.renderDrawLine(top.x, top.y, bottom.x, bottom.y);
    }
}

fn drawHorizontalLines(bounds: vec.IRect, spacing: i32) !void {
    var y = firstGridLine(bounds.minY, spacing);
    while (y <= bounds.maxY) : (y += spacing) {
        const left = camera.relativePosition(.{ .x = bounds.minX, .y = y });
        const right = camera.relativePosition(.{ .x = bounds.maxX, .y = y });
        try gpu.setRenderDrawColor(if (y == 0) axisColor else gridColor);
        try gpu.renderDrawLine(left.x, left.y, right.x, right.y);
    }
}
