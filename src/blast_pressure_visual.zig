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

const propagationSeconds: f64 = 0.2;
const cellFadeSeconds: f64 = 0.12;

const Cell = struct {
    position: vec.Vec2,
    strength: f32,
    arrival_fraction: f64,
};

const Wave = struct {
    cells: []Cell,
    cell_count: usize,
    cell_size: f32,
    started_at: f64,
};

var waves: std.ArrayListUnmanaged(Wave) = .empty;

fn activePropagationSeconds() f64 {
    if (comptime config.debugBlastPressure.enabled) {
        return config.debugBlastPressure.propagationSeconds;
    }
    return propagationSeconds;
}

fn activeFadeSeconds() f64 {
    if (comptime config.debugBlastPressure.enabled) {
        return config.debugBlastPressure.slowMotionSeconds;
    }
    return cellFadeSeconds;
}

fn freeWave(wave: Wave) void {
    allocator.free(wave.cells);
}

pub fn capture(field: blast_pressure.Field) !void {
    const maximumCellCount = try std.math.mul(usize, field.dimension, field.dimension);
    const cells = try allocator.alloc(Cell, maximumCellCount);
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
                .arrival_fraction = pressureSample.travel_distance / field.radius,
            };
            cellCount += 1;
        }
    }

    try waves.append(allocator, .{
        .cells = cells,
        .cell_count = cellCount,
        .cell_size = field.cell_size,
        .started_at = time.realNow(),
    });

    if (comptime config.debugBlastPressure.enabled) {
        time.setSimulationScale(config.debugBlastPressure.slowMotionScale);
    }
}

pub fn update() void {
    const now = time.realNow();
    const lifetime = activePropagationSeconds() + activeFadeSeconds();
    var index: usize = 0;
    while (index < waves.items.len) {
        if (now - waves.items[index].started_at < lifetime) {
            index += 1;
            continue;
        }

        freeWave(waves.items[index]);
        _ = waves.swapRemove(index);
    }

    if (comptime config.debugBlastPressure.enabled) {
        const scale: f64 = if (waves.items.len > 0) config.debugBlastPressure.slowMotionScale else 1;
        time.setSimulationScale(scale);
    }
}

pub fn shouldRunSimulationUpdate(physicsStepCount: usize) bool {
    if (comptime !config.debugBlastPressure.enabled) return true;
    if (waves.items.len == 0) return true;
    return physicsStepCount > 0;
}

fn fadeForCell(elapsed: f64, arrivalFraction: f64) f32 {
    const arrivalTime = arrivalFraction * activePropagationSeconds();
    const cellAge = elapsed - arrivalTime;
    if (cellAge <= 0) return 1;
    const remaining = 1.0 - cellAge / activeFadeSeconds();
    return @floatCast(std.math.clamp(remaining, 0, 1));
}

fn cellColor(strength: f32, fade: f32) sdl.Color {
    const clampedStrength = std.math.clamp(strength, 0, 1);
    const clampedFade = std.math.clamp(fade, 0, 1);
    const alpha = clampedStrength * 255.0 * clampedFade;
    return .{
        .r = 210,
        .g = 125,
        .b = 70,
        .a = @intFromFloat(std.math.clamp(alpha, 0, 255)),
    };
}

fn drawWave(wave: Wave, now: f64) !void {
    const elapsed = now - wave.started_at;
    const revealFraction = std.math.clamp(elapsed / activePropagationSeconds(), 0, 1);
    const cellPixels = @max(1, @as(i32, @intFromFloat(@round(wave.cell_size * conv.met2pix))));

    for (wave.cells[0..wave.cell_count]) |cell| {
        if (cell.arrival_fraction > revealFraction) continue;
        const fade = fadeForCell(elapsed, cell.arrival_fraction);
        if (fade <= 0) continue;

        const center = camera.relativePosition(conv.m2Pixel(vec.toBox2d(cell.position)));
        try gpu.setRenderDrawColor(cellColor(cell.strength, fade));
        try gpu.renderFillRect(.{
            .x = center.x - @divFloor(cellPixels, 2),
            .y = center.y - @divFloor(cellPixels, 2),
            .w = cellPixels,
            .h = cellPixels,
        });
    }
}

pub fn draw() !void {
    if (waves.items.len == 0) return;

    const previousBlendMode = try gpu.getRenderDrawBlendMode();
    try gpu.setRenderDrawBlendMode(.blend);
    defer gpu.setRenderDrawBlendMode(previousBlendMode) catch |err| {
        std.log.err("blast_pressure_visual.draw: failed to restore render blend mode: {}", .{err});
    };

    const now = time.realNow();
    for (waves.items) |wave| {
        try drawWave(wave, now);
    }
}

pub fn cleanup() void {
    for (waves.items) |wave| {
        freeWave(wave);
    }
    waves.clearAndFree(allocator);

    if (comptime config.debugBlastPressure.enabled) {
        time.setSimulationScale(1);
    }
}
