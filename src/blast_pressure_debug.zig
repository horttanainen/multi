const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const blast_pressure = @import("blast_pressure.zig");
const camera = @import("camera.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const gpu = @import("gpu.zig");
const sdl = @import("sdl.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

const DebugCell = struct {
    position: vec.Vec2,
    strength: f32,
    arrival_seconds: f64,
};

const Snapshot = struct {
    cells: []DebugCell,
    cell_count: usize,
    cell_size: f32,
    started_at: f64,
};

var snapshot: ?Snapshot = null;
pub const enabled = config.debugBlastPressure.enabled;

fn clearSnapshot() void {
    if (snapshot == null) return;
    allocator.free(snapshot.?.cells);
    snapshot = null;
}

pub fn capture(field: blast_pressure.Field) !void {
    if (comptime !config.debugBlastPressure.enabled) return;

    clearSnapshot();

    const maximumCellCount = try std.math.mul(usize, field.dimension, field.dimension);
    const cells = try allocator.alloc(DebugCell, maximumCellCount);
    errdefer allocator.free(cells);

    var cellCount: usize = 0;
    for (0..field.dimension) |row| {
        for (0..field.dimension) |column| {
            const columnOffset = @as(isize, @intCast(column)) - @as(isize, @intCast(field.half_extent));
            const rowOffset = @as(isize, @intCast(row)) - @as(isize, @intCast(field.half_extent));
            const position = vec.Vec2{
                .x = field.origin.x + @as(f32, @floatFromInt(columnOffset)) * field.cell_size,
                .y = field.origin.y + @as(f32, @floatFromInt(rowOffset)) * field.cell_size,
            };
            const pressureSample = blast_pressure.sample(field, position) orelse continue;
            cells[cellCount] = .{
                .position = position,
                .strength = pressureSample.strength,
                .arrival_seconds = @as(f64, pressureSample.travel_distance / field.radius) * config.debugBlastPressure.propagationSeconds,
            };
            cellCount += 1;
        }
    }

    snapshot = .{
        .cells = cells,
        .cell_count = cellCount,
        .cell_size = field.cell_size,
        .started_at = time.realNow(),
    };
    time.setSimulationScale(config.debugBlastPressure.slowMotionScale);
}

pub fn update() void {
    if (comptime !config.debugBlastPressure.enabled) return;
    if (snapshot == null) return;

    const elapsed = time.realNow() - snapshot.?.started_at;
    const finishAt = config.debugBlastPressure.propagationSeconds + config.debugBlastPressure.slowMotionSeconds;
    if (elapsed < finishAt) {
        time.setSimulationScale(config.debugBlastPressure.slowMotionScale);
        return;
    }

    clearSnapshot();
    time.setSimulationScale(1);
}

pub fn shouldRunSimulationUpdate(physicsStepCount: usize) bool {
    if (comptime !config.debugBlastPressure.enabled) return true;
    if (snapshot == null) return true;
    return physicsStepCount > 0;
}

fn fadeForCell(elapsed: f64, arrivalSeconds: f64) f32 {
    const age = elapsed - arrivalSeconds;
    const remaining = 1.0 - age / config.debugBlastPressure.slowMotionSeconds;
    return @floatCast(std.math.clamp(remaining, 0, 1));
}

fn cellColor(strength: f32, fade: f32) sdl.Color {
    const clampedStrength = std.math.clamp(strength, 0, 1);
    const alpha = (80.0 + clampedStrength * 175.0) * fade;
    return .{
        .r = 255,
        .g = @intFromFloat(55.0 + clampedStrength * 190.0),
        .b = @intFromFloat(10.0 + clampedStrength * 45.0),
        .a = @intFromFloat(std.math.clamp(alpha, 0, 255)),
    };
}

pub fn draw() !void {
    if (comptime !config.debugBlastPressure.enabled) return;
    if (snapshot == null) return;

    const activeSnapshot = snapshot.?;
    const elapsed = time.realNow() - activeSnapshot.started_at;
    const cellPixels = @max(1, @as(i32, @intFromFloat(@round(activeSnapshot.cell_size * conv.met2pix))));
    const drawSize = @max(1, cellPixels - 1);

    for (activeSnapshot.cells[0..activeSnapshot.cell_count]) |cell| {
        if (elapsed < cell.arrival_seconds) continue;

        const fade = fadeForCell(elapsed, cell.arrival_seconds);
        if (fade <= 0) continue;
        const center = camera.relativePosition(conv.m2Pixel(vec.toBox2d(cell.position)));
        try gpu.setRenderDrawColor(cellColor(cell.strength, fade));
        try gpu.renderFillRect(.{
            .x = center.x - @divFloor(drawSize, 2),
            .y = center.y - @divFloor(drawSize, 2),
            .w = drawSize,
            .h = drawSize,
        });
    }
}

pub fn cleanup() void {
    if (comptime !config.debugBlastPressure.enabled) return;
    clearSnapshot();
    time.setSimulationScale(1);
}
