const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const blast_pressure = @import("blast_pressure.zig");
const camera = @import("camera.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const gpu = @import("gpu.zig");
const perf = @import("perf.zig");
const sdl = @import("sdl.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

pub const Capture = struct {
    propagation_duration_ms: u32,
    trail_duration_ms: u32,
    distortion_pixels: f32,
};

const cellRiseSeconds: f64 = 0.012;

const DrawMetrics = struct {
    active_elements: usize = 0,
    draw_vertices: usize = 0,
};

const Cell = struct {
    position: vec.Vec2,
    direction: vec.Vec2,
    strength: f32,
    arrival_fraction: f64,
};

const Wave = struct {
    field_id: gpu.PressureFieldId,
    field_origin: vec.Vec2,
    half_extent: usize,
    debug_cells: []Cell,
    debug_cell_count: usize,
    cell_size: f32,
    started_at: f64,
    propagation_seconds: f64,
    trail_duration_seconds: f64,
    distortion_pixels: f32,
};

var waves: std.ArrayListUnmanaged(Wave) = .empty;

fn activePropagationSeconds(wave: Wave) f64 {
    if (comptime config.debugBlastPressure.enabled) {
        return config.debugBlastPressure.propagationSeconds;
    }
    return wave.propagation_seconds;
}

fn activeTrailDurationSeconds(wave: Wave) f64 {
    if (comptime config.debugBlastPressure.enabled) {
        return config.debugBlastPressure.slowMotionSeconds;
    }
    return wave.trail_duration_seconds;
}

fn freeWave(wave: Wave) void {
    gpu.destroyPressureField(wave.field_id);
    if (comptime config.debugBlastPressure.enabled) {
        allocator.free(wave.debug_cells);
    }
}

pub fn capture(field: blast_pressure.Field, captureData: Capture) !void {
    const maximumCellCount = try std.math.mul(usize, field.dimension, field.dimension);
    const texels = try allocator.alloc(gpu.PressureFieldTexel, maximumCellCount);
    defer allocator.free(texels);

    var debugCells: []Cell = &.{};
    if (comptime config.debugBlastPressure.enabled) {
        debugCells = try allocator.alloc(Cell, maximumCellCount);
    }
    errdefer if (comptime config.debugBlastPressure.enabled) allocator.free(debugCells);

    var cellCount: usize = 0;
    for (0..field.dimension) |row| {
        for (0..field.dimension) |column| {
            const texelIndex = row * field.dimension + column;
            const columnOffset = @as(isize, @intCast(column)) - @as(isize, @intCast(field.half_extent));
            const rowOffset = @as(isize, @intCast(row)) - @as(isize, @intCast(field.half_extent));
            const position = vec.Vec2{
                .x = field.origin.x + @as(f32, @floatFromInt(columnOffset)) * field.cell_size,
                .y = field.origin.y + @as(f32, @floatFromInt(rowOffset)) * field.cell_size,
            };
            const pressureSample = blast_pressure.sample(field, position);
            if (pressureSample == null) {
                texels[texelIndex] = .{
                    .pressure_x = 0,
                    .pressure_y = 0,
                    .arrival_pressure = 0,
                    .strength = 0,
                };
                continue;
            }

            const sample = pressureSample.?;
            const direction = if (sample.travel_distance > 0) sample.direction else vec.zero;
            const arrivalFraction = sample.travel_distance / field.radius;
            texels[texelIndex] = .{
                .pressure_x = @floatCast(direction.x * sample.strength),
                .pressure_y = @floatCast(direction.y * sample.strength),
                .arrival_pressure = @floatCast(arrivalFraction * sample.strength),
                .strength = @floatCast(sample.strength),
            };

            if (comptime config.debugBlastPressure.enabled) {
                debugCells[cellCount] = .{
                    .position = position,
                    .direction = direction,
                    .strength = sample.strength,
                    .arrival_fraction = arrivalFraction,
                };
            }
            cellCount += 1;
        }
    }

    const fieldId = try gpu.createPressureField(@intCast(field.dimension), texels);
    errdefer gpu.destroyPressureField(fieldId);

    try waves.append(allocator, .{
        .field_id = fieldId,
        .field_origin = field.origin,
        .half_extent = field.half_extent,
        .debug_cells = debugCells,
        .debug_cell_count = cellCount,
        .cell_size = field.cell_size,
        .started_at = time.realNow(),
        .propagation_seconds = @as(f64, @floatFromInt(captureData.propagation_duration_ms)) / 1000.0,
        .trail_duration_seconds = @as(f64, @floatFromInt(captureData.trail_duration_ms)) / 1000.0,
        .distortion_pixels = captureData.distortion_pixels,
    });

    perf.log(
        .explosion,
        "perf.pressure_capture dimension={d} field_cells={d} reachable_cells={d} texture_bytes={d}",
        .{ field.dimension, maximumCellCount, cellCount, maximumCellCount * @sizeOf(gpu.PressureFieldTexel) },
    );

    if (comptime config.debugBlastPressure.enabled) {
        time.setSimulationScale(config.debugBlastPressure.slowMotionScale);
    }
}

pub fn update() void {
    const now = time.realNow();
    var index: usize = 0;
    while (index < waves.items.len) {
        const lifetime = activePropagationSeconds(waves.items[index]) + activeTrailDurationSeconds(waves.items[index]);
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

fn smoothStep(progress: f64) f64 {
    const clamped = std.math.clamp(progress, 0, 1);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

fn fadeForCell(wave: Wave, elapsed: f64, arrivalFraction: f64) f32 {
    const arrivalTime = arrivalFraction * activePropagationSeconds(wave);
    const cellAge = elapsed - arrivalTime;
    if (cellAge <= 0) return 0;

    const lifetime = activeTrailDurationSeconds(wave);
    const riseDuration = @min(cellRiseSeconds, lifetime * 0.25);
    const attack = smoothStep(cellAge / riseDuration);
    const decay = 1.0 - smoothStep((cellAge - riseDuration) / (lifetime - riseDuration));
    return @floatCast(attack * decay);
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

fn drawWave(wave: Wave, now: f64, metrics: *DrawMetrics) !void {
    const elapsed = now - wave.started_at;
    if (comptime config.debugBlastPressure.enabled) {
        const revealFraction = std.math.clamp(elapsed / activePropagationSeconds(wave), 0, 1);
        const cellPixels = @max(1, @as(i32, @intFromFloat(@round(wave.cell_size * conv.met2pix))));
        for (wave.debug_cells[0..wave.debug_cell_count]) |cell| {
            if (cell.arrival_fraction > revealFraction) continue;
            const fade = fadeForCell(wave, elapsed, cell.arrival_fraction);
            if (fade <= 0) continue;

            if (comptime perf.configured(.explosion)) {
                metrics.active_elements += 1;
                metrics.draw_vertices += 6;
            }
            const center = camera.relativePosition(conv.m2Pixel(vec.toBox2d(cell.position)));
            try gpu.setRenderDrawColor(cellColor(cell.strength, fade));
            try gpu.renderFillRect(.{
                .x = center.x - @divFloor(cellPixels, 2),
                .y = center.y - @divFloor(cellPixels, 2),
                .w = cellPixels,
                .h = cellPixels,
            });
        }
        return;
    }

    const halfExtent: f32 = @floatFromInt(wave.half_extent);
    const edgeOffset = (halfExtent + 0.5) * wave.cell_size;
    const fieldTopLeft = vec.Vec2{
        .x = wave.field_origin.x - edgeOffset,
        .y = wave.field_origin.y - edgeOffset,
    };
    const screenTopLeft = camera.relativePosition(conv.m2Pixel(vec.toBox2d(fieldTopLeft)));
    const fieldDimension: f32 = @floatFromInt(wave.half_extent * 2 + 1);
    const fieldSizePixels = fieldDimension * wave.cell_size * conv.met2pix;
    const lifetime = activeTrailDurationSeconds(wave);

    gpu.renderPressureField(.{
        .field_id = wave.field_id,
        .rectangle_origin = .{ @floatFromInt(screenTopLeft.x), @floatFromInt(screenTopLeft.y) },
        .rectangle_size = .{ fieldSizePixels, fieldSizePixels },
        .elapsed_seconds = @floatCast(elapsed),
        .propagation_seconds = @floatCast(activePropagationSeconds(wave)),
        .trail_duration_seconds = @floatCast(lifetime),
        .rise_seconds = @floatCast(@min(cellRiseSeconds, lifetime * 0.25)),
        .displacement_pixels = wave.distortion_pixels,
    });
    if (comptime perf.configured(.explosion)) {
        metrics.active_elements += 1;
        metrics.draw_vertices += 6;
    }
}

pub fn draw() !void {
    if (waves.items.len == 0) return;

    const drawStart = perf.begin(.explosion);
    var metrics = DrawMetrics{};

    const previousBlendMode = try gpu.getRenderDrawBlendMode();
    try gpu.setRenderDrawBlendMode(.blend);
    defer gpu.setRenderDrawBlendMode(previousBlendMode) catch |err| {
        std.log.err("blast_pressure_visual.draw: failed to restore render blend mode: {}", .{err});
    };

    const now = time.realNow();
    for (waves.items) |wave| {
        try drawWave(wave, now, &metrics);
    }

    if (comptime config.debugBlastPressure.enabled) {
        perf.log(
            .explosion,
            "perf.pressure_visual waves={d} active_cells={d} vertices={d} draw_us={d}",
            .{ waves.items.len, metrics.active_elements, metrics.draw_vertices, perf.elapsedUs(drawStart) },
        );
    } else {
        perf.log(
            .explosion,
            "perf.pressure_visual waves={d} field_quads={d} static_vertices={d} uploaded_vertices=0 draw_us={d}",
            .{ waves.items.len, metrics.active_elements, metrics.draw_vertices, perf.elapsedUs(drawStart) },
        );
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
