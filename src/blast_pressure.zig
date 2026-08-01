const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const collision = @import("collision.zig");
const vec = @import("vector.zig");

const CellState = enum {
    unknown,
    open,
    blocked,
};

const Cell = struct {
    travel_distance: f32 = std.math.inf(f32),
    strength: f32 = 0,
    transmission: f32 = 0,
    wave_source_index: ?usize = null,
    state: CellState = .unknown,
    settled: bool = false,
};

pub const Field = struct {
    origin: vec.Vec2,
    radius: f32,
    cell_size: f32,
    half_extent: usize,
    dimension: usize,
    center_index: usize,
    cells: []Cell,
};

const QueueEntry = struct {
    cell_index: usize,
    travel_distance: f32,
    strength: f32,
};

pub const Sample = struct {
    direction: vec.Vec2,
    strength: f32,
};

const Neighbor = struct {
    column_offset: isize,
    row_offset: isize,
    distance_scale: f32,
};

const gridCellSize: f32 = 0.2;
const maximumGridCells: usize = 65536;
const diffractionTransmission: f32 = 0.45;
const diagonalDistance: f32 = 1.41421356237;
const neighbors = [_]Neighbor{
    .{ .column_offset = -1, .row_offset = 0, .distance_scale = 1 },
    .{ .column_offset = 1, .row_offset = 0, .distance_scale = 1 },
    .{ .column_offset = 0, .row_offset = -1, .distance_scale = 1 },
    .{ .column_offset = 0, .row_offset = 1, .distance_scale = 1 },
    .{ .column_offset = -1, .row_offset = -1, .distance_scale = diagonalDistance },
    .{ .column_offset = 1, .row_offset = -1, .distance_scale = diagonalDistance },
    .{ .column_offset = -1, .row_offset = 1, .distance_scale = diagonalDistance },
    .{ .column_offset = 1, .row_offset = 1, .distance_scale = diagonalDistance },
};

fn normalizedOrZero(value: vec.Vec2) vec.Vec2 {
    const length = vec.magnitude(value);
    if (length <= 0.001) return .{ .x = 0, .y = 0 };
    return .{
        .x = value.x / length,
        .y = value.y / length,
    };
}

fn normalizedOrUp(value: vec.Vec2) vec.Vec2 {
    const normalized = normalizedOrZero(value);
    if (vec.magnitude(normalized) >= 0.001) return normalized;
    return .{ .x = 0, .y = -1 };
}

fn falloff(distance: f32, radius: f32) f32 {
    if (radius <= 0) {
        std.log.err("blast_pressure.falloff: radius must be positive", .{});
        return 0;
    }
    return std.math.clamp(1.0 - distance / radius, 0.0, 1.0);
}

fn queueOrder(_: void, a: QueueEntry, b: QueueEntry) std.math.Order {
    const strengthOrder = std.math.order(b.strength, a.strength);
    if (strengthOrder != .eq) return strengthOrder;
    const distanceOrder = std.math.order(a.travel_distance, b.travel_distance);
    if (distanceOrder != .eq) return distanceOrder;
    return std.math.order(a.cell_index, b.cell_index);
}

fn cellIndex(field: Field, column: isize, row: isize) ?usize {
    if (column < 0 or row < 0) return null;
    const columnIndex: usize = @intCast(column);
    const rowIndex: usize = @intCast(row);
    if (columnIndex >= field.dimension or rowIndex >= field.dimension) return null;
    return rowIndex * field.dimension + columnIndex;
}

fn cellCoordinates(field: Field, index: usize) struct { column: isize, row: isize } {
    return .{
        .column = @intCast(index % field.dimension),
        .row = @intCast(index / field.dimension),
    };
}

fn cellPosition(field: Field, index: usize) vec.Vec2 {
    const coordinates = cellCoordinates(field, index);
    const halfExtent: isize = @intCast(field.half_extent);
    return .{
        .x = field.origin.x + @as(f32, @floatFromInt(coordinates.column - halfExtent)) * field.cell_size,
        .y = field.origin.y + @as(f32, @floatFromInt(coordinates.row - halfExtent)) * field.cell_size,
    };
}

const BlockerRasterContext = struct {
    field: *Field,
};

fn clampedGridCoordinate(field: Field, worldCoordinate: f32, originCoordinate: f32, roundUp: bool) usize {
    const offset = (worldCoordinate - originCoordinate) / field.cell_size;
    const gridCoordinate = offset + @as(f32, @floatFromInt(field.half_extent));
    const rounded = if (roundUp) @ceil(gridCoordinate) else @floor(gridCoordinate);
    const maximum: f32 = @floatFromInt(field.dimension - 1);
    return @intFromFloat(std.math.clamp(rounded, 0, maximum));
}

fn rasterizeBlocker(shapeId: box2d.c.b2ShapeId, rawContext: ?*anyopaque) callconv(.c) bool {
    if (rawContext == null) {
        std.log.err("blast_pressure.rasterizeBlocker: overlap query context is missing", .{});
        return false;
    }
    const context: *BlockerRasterContext = @ptrCast(@alignCast(rawContext.?));
    const field = context.field;
    const probeRadius = field.cell_size * 0.32;
    const shapeAabb = box2d.c.b2Shape_GetAABB(shapeId);
    const minimumColumn = clampedGridCoordinate(field.*, shapeAabb.lowerBound.x - probeRadius, field.origin.x, false);
    const maximumColumn = clampedGridCoordinate(field.*, shapeAabb.upperBound.x + probeRadius, field.origin.x, true);
    const minimumRow = clampedGridCoordinate(field.*, shapeAabb.lowerBound.y - probeRadius, field.origin.y, false);
    const maximumRow = clampedGridCoordinate(field.*, shapeAabb.upperBound.y + probeRadius, field.origin.y, true);
    const probeRadiusSquared = probeRadius * probeRadius;

    for (minimumRow..maximumRow + 1) |row| {
        for (minimumColumn..maximumColumn + 1) |column| {
            const index = row * field.dimension + column;
            const position = cellPosition(field.*, index);
            const closestPoint = vec.fromBox2d(box2d.c.b2Shape_GetClosestPoint(shapeId, vec.toBox2d(position)));
            const separation = vec.subtract(position, closestPoint);
            if (vec.dot(separation, separation) > probeRadiusSquared) continue;
            field.cells[index].state = .blocked;
        }
    }
    return true;
}

fn rasterizeBlockers(field: *Field) void {
    const probeRadius = field.cell_size * 0.32;
    const gridExtent = @as(f32, @floatFromInt(field.half_extent)) * field.cell_size + probeRadius;
    const bounds = box2d.c.b2AABB{
        .lowerBound = vec.toBox2d(.{ .x = field.origin.x - gridExtent, .y = field.origin.y - gridExtent }),
        .upperBound = vec.toBox2d(.{ .x = field.origin.x + gridExtent, .y = field.origin.y + gridExtent }),
    };
    var filter = box2d.c.b2DefaultQueryFilter();
    filter.categoryBits = collision.MASK_EXPLOSION_PRESSURE_BLOCKER;
    filter.maskBits = collision.MASK_EXPLOSION_PRESSURE_BLOCKER;
    var context = BlockerRasterContext{ .field = field };
    box2d.overlapAABB(bounds, filter, rasterizeBlocker, &context);

    for (field.cells) |*cell| {
        if (cell.state == .unknown) cell.state = .open;
    }
    field.cells[field.center_index].state = .open;
}

fn cellIsBlocked(field: *Field, index: usize) bool {
    if (index == field.center_index) return false;
    return field.cells[index].state == .blocked;
}

fn diagonalMoveIsBlocked(
    field: *Field,
    column: isize,
    row: isize,
    neighbor: Neighbor,
) bool {
    if (neighbor.column_offset == 0 or neighbor.row_offset == 0) return false;

    const horizontalIndex = cellIndex(field.*, column + neighbor.column_offset, row) orelse {
        std.log.err("blast_pressure.diagonalMoveIsBlocked: horizontal neighbor is outside pressure grid", .{});
        return true;
    };
    const verticalIndex = cellIndex(field.*, column, row + neighbor.row_offset) orelse {
        std.log.err("blast_pressure.diagonalMoveIsBlocked: vertical neighbor is outside pressure grid", .{});
        return true;
    };
    return cellIsBlocked(field, horizontalIndex) or cellIsBlocked(field, verticalIndex);
}

fn cellsHaveLineOfSight(field: *Field, startIndex: usize, endIndex: usize) bool {
    const start = cellCoordinates(field.*, startIndex);
    const end = cellCoordinates(field.*, endIndex);
    const columnDistance = if (end.column >= start.column) end.column - start.column else start.column - end.column;
    const rowDistance = if (end.row >= start.row) end.row - start.row else start.row - end.row;
    const columnStep: isize = if (start.column < end.column) 1 else if (start.column > end.column) -1 else 0;
    const rowStep: isize = if (start.row < end.row) 1 else if (start.row > end.row) -1 else 0;
    const negativeRowDistance = -rowDistance;
    var errorValue = columnDistance + negativeRowDistance;
    var column = start.column;
    var row = start.row;

    while (true) {
        if (column != start.column or row != start.row) {
            const index = cellIndex(field.*, column, row) orelse {
                std.log.err("blast_pressure.cellsHaveLineOfSight: traversed outside pressure grid", .{});
                return false;
            };
            if (cellIsBlocked(field, index)) return false;
        }
        if (column == end.column and row == end.row) return true;

        const previousColumn = column;
        const previousRow = row;
        const twiceError = errorValue * 2;
        if (twiceError >= negativeRowDistance) {
            errorValue += negativeRowDistance;
            column += columnStep;
        }
        if (twiceError <= columnDistance) {
            errorValue += columnDistance;
            row += rowStep;
        }

        if (column == previousColumn or row == previousRow) continue;
        const horizontalIndex = cellIndex(field.*, column, previousRow) orelse {
            std.log.err("blast_pressure.cellsHaveLineOfSight: horizontal diagonal cell is outside pressure grid", .{});
            return false;
        };
        const verticalIndex = cellIndex(field.*, previousColumn, row) orelse {
            std.log.err("blast_pressure.cellsHaveLineOfSight: vertical diagonal cell is outside pressure grid", .{});
            return false;
        };
        if (cellIsBlocked(field, horizontalIndex) or cellIsBlocked(field, verticalIndex)) return false;
    }
}

pub fn build(origin: vec.Vec2, radius: f32) !Field {
    if (!std.math.isFinite(radius) or radius <= 0) {
        std.log.err("blast_pressure.build: radius must be finite and positive", .{});
        return error.InvalidExplosionRadius;
    }

    const halfExtentFloat = @ceil(radius / gridCellSize);
    if (halfExtentFloat > @as(f32, @floatFromInt(maximumGridCells))) {
        std.log.err("blast_pressure.build: radius {d} is too large", .{radius});
        return error.ExplosionPressureFieldTooLarge;
    }
    const halfExtent: usize = @intFromFloat(halfExtentFloat);
    const dimension = try std.math.add(usize, try std.math.mul(usize, halfExtent, 2), 1);
    const cellCount = try std.math.mul(usize, dimension, dimension);
    if (cellCount > maximumGridCells) {
        std.log.err("blast_pressure.build: pressure grid needs {d} cells, maximum is {d}", .{ cellCount, maximumGridCells });
        return error.ExplosionPressureFieldTooLarge;
    }

    const cells = try allocator.alloc(Cell, cellCount);
    errdefer allocator.free(cells);
    for (cells) |*cell| {
        cell.* = .{};
    }

    const centerIndex = halfExtent * dimension + halfExtent;
    var field = Field{
        .origin = origin,
        .radius = radius,
        .cell_size = gridCellSize,
        .half_extent = halfExtent,
        .dimension = dimension,
        .center_index = centerIndex,
        .cells = cells,
    };
    rasterizeBlockers(&field);
    field.cells[centerIndex].travel_distance = 0;
    field.cells[centerIndex].strength = 1;
    field.cells[centerIndex].transmission = 1;
    field.cells[centerIndex].wave_source_index = centerIndex;

    var queue: std.PriorityQueue(QueueEntry, void, queueOrder) = .empty;
    defer queue.deinit(allocator);
    try queue.push(allocator, .{ .cell_index = centerIndex, .travel_distance = 0, .strength = 1 });

    while (queue.pop()) |entry| {
        const currentCell = &field.cells[entry.cell_index];
        if (currentCell.settled) continue;
        if (entry.strength < currentCell.strength) continue;
        currentCell.settled = true;

        const coordinates = cellCoordinates(field, entry.cell_index);
        for (neighbors) |neighbor| {
            const neighborIndex = cellIndex(
                field,
                coordinates.column + neighbor.column_offset,
                coordinates.row + neighbor.row_offset,
            ) orelse continue;
            const candidateDistance = currentCell.travel_distance + field.cell_size * neighbor.distance_scale;
            if (candidateDistance > field.radius) continue;
            if (cellIsBlocked(&field, neighborIndex)) continue;
            if (diagonalMoveIsBlocked(&field, coordinates.column, coordinates.row, neighbor)) continue;

            const currentWaveSourceIndex = currentCell.wave_source_index orelse {
                std.log.err("blast_pressure.build: settled cell {d} has no wave source", .{entry.cell_index});
                continue;
            };
            var candidateTransmission = currentCell.transmission;
            var candidateWaveSourceIndex = currentWaveSourceIndex;
            if (!cellsHaveLineOfSight(&field, currentWaveSourceIndex, neighborIndex)) {
                candidateTransmission *= diffractionTransmission;
                candidateWaveSourceIndex = entry.cell_index;
            }
            const candidateStrength = falloff(candidateDistance, field.radius) * candidateTransmission;
            if (candidateStrength <= 0) continue;

            const neighborCell = &field.cells[neighborIndex];
            if (candidateStrength < neighborCell.strength) continue;
            if (candidateStrength == neighborCell.strength and candidateDistance >= neighborCell.travel_distance) continue;
            neighborCell.travel_distance = candidateDistance;
            neighborCell.strength = candidateStrength;
            neighborCell.transmission = candidateTransmission;
            neighborCell.wave_source_index = candidateWaveSourceIndex;
            try queue.push(allocator, .{
                .cell_index = neighborIndex,
                .travel_distance = candidateDistance,
                .strength = candidateStrength,
            });
        }
    }

    return field;
}

pub fn deinit(field: *Field) void {
    allocator.free(field.cells);
    field.* = undefined;
}

fn cellIndexAtPoint(field: Field, point: vec.Vec2) ?usize {
    const columnOffsetFloat = @round((point.x - field.origin.x) / field.cell_size);
    const rowOffsetFloat = @round((point.y - field.origin.y) / field.cell_size);
    const halfExtentFloat: f32 = @floatFromInt(field.half_extent);
    if (@abs(columnOffsetFloat) > halfExtentFloat or @abs(rowOffsetFloat) > halfExtentFloat) return null;

    const halfExtent: isize = @intCast(field.half_extent);
    const column = @as(isize, @intFromFloat(columnOffsetFloat)) + halfExtent;
    const row = @as(isize, @intFromFloat(rowOffsetFloat)) + halfExtent;
    return cellIndex(field, column, row);
}

pub fn sample(field: Field, point: vec.Vec2) ?Sample {
    const cellIndexValue = cellIndexAtPoint(field, point) orelse return null;
    const cell = field.cells[cellIndexValue];
    if (!cell.settled or cell.state == .blocked) return null;

    if (cell.strength <= 0) return null;

    const waveSourceIndex = cell.wave_source_index orelse {
        std.log.err("blast_pressure.sample: settled cell {d} has no wave source", .{cellIndexValue});
        return null;
    };
    const waveSourcePosition = cellPosition(field, waveSourceIndex);
    const samplePosition = if (waveSourceIndex == field.center_index) point else cellPosition(field, cellIndexValue);
    const direction = normalizedOrUp(vec.subtract(samplePosition, waveSourcePosition));
    return .{
        .direction = direction,
        .strength = cell.strength,
    };
}
