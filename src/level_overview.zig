const std = @import("std");

const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const level = @import("level.zig");
const renderer = @import("renderer.zig");
const sdl = @import("sdl.zig");
const vec = @import("vector.zig");
const window = @import("window.zig");

const maximumPathLength = 1024;

pub const Options = struct {
    enabled: bool = false,
    levelPath: []const u8 = "",
    outputPath: [:0]const u8 = "",
    diagnosticOutputPath: [:0]const u8 = "",
};

pub var options: Options = .{};

var levelPathBuffer: [maximumPathLength]u8 = undefined;
var outputPathBuffer: [maximumPathLength:0]u8 = undefined;
var diagnosticOutputPathBuffer: [maximumPathLength:0]u8 = undefined;

fn optionValue(args: []const []const u8, optionIndex: usize, optionName: []const u8) ![]const u8 {
    if (optionIndex + 1 >= args.len) {
        std.log.err("level_overview.optionValue: option '{s}' requires a value", .{optionName});
        return error.MissingLevelOverviewOptionValue;
    }
    return args[optionIndex + 1];
}

fn copyPath(buffer: []u8, value: []const u8, optionName: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}", .{value}) catch {
        std.log.err("level_overview.copyPath: value for '{s}' is too long", .{optionName});
        return error.LevelOverviewPathTooLong;
    };
}

fn copyPathZ(buffer: [:0]u8, value: []const u8, optionName: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "{s}", .{value}) catch {
        std.log.err("level_overview.copyPathZ: value for '{s}' is too long", .{optionName});
        return error.LevelOverviewPathTooLong;
    };
}

pub fn configure(args: []const []const u8) !void {
    var requestedLevelPath: ?[]const u8 = null;
    var outputPath: ?[]const u8 = null;
    var diagnosticOutputPath: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--level-overview")) {
            requestedLevelPath = try optionValue(args, index, arg);
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--overview-output")) {
            outputPath = try optionValue(args, index, arg);
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--overview-diagnostic-output")) {
            diagnosticOutputPath = try optionValue(args, index, arg);
            index += 2;
            continue;
        }
        index += 1;
    }

    if (requestedLevelPath == null) return;
    if (outputPath == null) {
        std.log.err("level_overview.configure: --overview-output is required", .{});
        return error.MissingLevelOverviewOutputPath;
    }
    if (diagnosticOutputPath == null) {
        std.log.err("level_overview.configure: --overview-diagnostic-output is required", .{});
        return error.MissingLevelOverviewDiagnosticOutputPath;
    }

    options = .{
        .enabled = true,
        .levelPath = try copyPath(&levelPathBuffer, requestedLevelPath.?, "--level-overview"),
        .outputPath = try copyPathZ(&outputPathBuffer, outputPath.?, "--overview-output"),
        .diagnosticOutputPath = try copyPathZ(&diagnosticOutputPathBuffer, diagnosticOutputPath.?, "--overview-diagnostic-output"),
    };
}

pub fn levelPath() ?[]const u8 {
    if (!options.enabled) return null;
    return options.levelPath;
}

fn levelTopLeft() vec.IVec2 {
    return .{
        .x = level.position.x - @divFloor(level.size.x, 2),
        .y = level.position.y - @divFloor(level.size.y, 2),
    };
}

fn captureScale(frame: *sdl.Surface) vec.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(frame.w)) / @as(f32, @floatFromInt(window.width)),
        .y = @as(f32, @floatFromInt(frame.h)) / @as(f32, @floatFromInt(window.height)),
    };
}

fn fillCaptureBackground(destination: *sdl.Surface) !void {
    try sdl.fillSurfaceRect(destination, null, .{ .r = 24, .g = 28, .b = 33, .a = 255 });
}

fn drawGridLine(destination: *sdl.Surface, coordinate: i32, vertical: bool, major: bool) !void {
    const thickness: i32 = if (major) 2 else 1;
    const color = if (major)
        sdl.Color{ .r = 82, .g = 96, .b = 108, .a = 255 }
    else
        sdl.Color{ .r = 48, .g = 58, .b = 67, .a = 255 };
    const rect = if (vertical)
        sdl.Rect{ .x = coordinate, .y = 0, .w = thickness, .h = level.size.y }
    else
        sdl.Rect{ .x = 0, .y = coordinate, .w = level.size.x, .h = thickness };
    try sdl.fillSurfaceRect(destination, &rect, color);
}

fn drawMeterGrid(destination: *sdl.Surface) !void {
    const spacing: i32 = @intFromFloat(@round(conv.met2pix));
    if (spacing <= 0) {
        std.log.err("level_overview.drawMeterGrid: invalid pixels-per-meter value {d}", .{conv.met2pix});
        return error.InvalidLevelOverviewGridSpacing;
    }

    const topLeft = levelTopLeft();
    var worldX = @divFloor(topLeft.x, spacing) * spacing;
    if (worldX < topLeft.x) worldX += spacing;
    while (worldX <= topLeft.x + level.size.x) : (worldX += spacing) {
        const meter = @divFloor(worldX, spacing);
        try drawGridLine(destination, worldX - topLeft.x, true, @mod(meter, 5) == 0);
    }

    var worldY = @divFloor(topLeft.y, spacing) * spacing;
    if (worldY < topLeft.y) worldY += spacing;
    while (worldY <= topLeft.y + level.size.y) : (worldY += spacing) {
        const meter = @divFloor(worldY, spacing);
        try drawGridLine(destination, worldY - topLeft.y, false, @mod(meter, 5) == 0);
    }
}

fn captureTiles(destination: *sdl.Surface, layer: renderer.OverviewLayer) !void {
    renderer.zoom = 1;
    const topLeft = levelTopLeft();

    var destinationY: i32 = 0;
    while (destinationY < level.size.y) : (destinationY += window.height) {
        var destinationX: i32 = 0;
        while (destinationX < level.size.x) : (destinationX += window.width) {
            const requestedCameraX = @min(destinationX, @max(0, level.size.x - window.width));
            const requestedCameraY = @min(destinationY, @max(0, level.size.y - window.height));
            camera.centerOn(.{
                .x = topLeft.x + requestedCameraX + @divFloor(window.width, 2),
                .y = topLeft.y + requestedCameraY + @divFloor(window.height, 2),
            }, renderer.zoom);

            const frame = try renderer.renderOverview(layer);
            defer sdl.destroySurface(frame);
            try sdl.setSurfaceBlendMode(frame, .blend);
            const frameScale = captureScale(frame);
            const activeCamera = camera.getActiveCamera() orelse {
                std.log.err("level_overview.captureTiles: active camera is missing", .{});
                return error.LevelOverviewCameraMissing;
            };

            const sourceWorldX = topLeft.x + destinationX - activeCamera.posPx.x;
            const sourceWorldY = topLeft.y + destinationY - activeCamera.posPx.y;
            const copyWidth = @min(window.width, level.size.x - destinationX);
            const copyHeight = @min(window.height, level.size.y - destinationY);
            const sourceRect = sdl.Rect{
                .x = @intFromFloat(@round(@as(f32, @floatFromInt(sourceWorldX)) * frameScale.x)),
                .y = @intFromFloat(@round(@as(f32, @floatFromInt(sourceWorldY)) * frameScale.y)),
                .w = @intFromFloat(@round(@as(f32, @floatFromInt(copyWidth)) * frameScale.x)),
                .h = @intFromFloat(@round(@as(f32, @floatFromInt(copyHeight)) * frameScale.y)),
            };
            const destinationRect = sdl.Rect{
                .x = destinationX,
                .y = destinationY,
                .w = copyWidth,
                .h = copyHeight,
            };
            try sdl.blitSurfaceScaled(frame, &sourceRect, destination, &destinationRect, .linear);
        }
    }
}

pub fn capture() !void {
    if (!options.enabled) return;
    if (level.size.x <= 0 or level.size.y <= 0) {
        std.log.err("level_overview.capture: invalid level dimensions {d}x{d}", .{ level.size.x, level.size.y });
        return error.InvalidLevelOverviewDimensions;
    }
    if (window.width <= 0 or window.height <= 0) {
        std.log.err("level_overview.capture: invalid window dimensions {d}x{d}", .{ window.width, window.height });
        return error.InvalidLevelOverviewWindowDimensions;
    }

    const overview = try sdl.createSurface(level.size.x, level.size.y, .abgr8888);
    defer sdl.destroySurface(overview);
    try fillCaptureBackground(overview);
    try captureTiles(overview, .entities);
    try sdl.savePng(overview, options.outputPath);

    const diagnostic = try sdl.createSurface(level.size.x, level.size.y, .abgr8888);
    defer sdl.destroySurface(diagnostic);
    try fillCaptureBackground(diagnostic);
    try drawMeterGrid(diagnostic);
    try captureTiles(diagnostic, .entities);
    try captureTiles(diagnostic, .collision);
    try sdl.savePng(diagnostic, options.diagnosticOutputPath);

    std.log.info("level_overview: saved '{s}' and '{s}'", .{ options.outputPath, options.diagnosticOutputPath });
}
