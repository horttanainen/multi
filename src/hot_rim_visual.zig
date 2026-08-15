const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const gpu = @import("gpu.zig");
const sdl = @import("sdl.zig");
const surface_cutout = @import("surface_cutout.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

const Event = struct {
    bodyId: box2d.c.b2BodyId,
    quads: []surface_cutout.HotRimQuad,
    startedAt: f64,
    durationSeconds: f64,
};

const glowExpansionPixels: f32 = 1.5;
const glowAlphaScale: f32 = 0.1;

var events: std.ArrayListUnmanaged(Event) = .empty;

pub fn capture(bodyId: box2d.c.b2BodyId, quads: []surface_cutout.HotRimQuad, durationMs: u32) !void {
    try events.append(allocator, .{
        .bodyId = bodyId,
        .quads = quads,
        .startedAt = time.realNow(),
        .durationSeconds = @as(f64, @floatFromInt(durationMs)) / 1000.0,
    });
}

fn removeEvent(index: usize) void {
    allocator.free(events.items[index].quads);
    _ = events.swapRemove(index);
}

pub fn update() void {
    const now = time.realNow();
    var index: usize = 0;
    while (index < events.items.len) {
        const event = events.items[index];
        if (!box2d.c.b2Body_IsValid(event.bodyId) or now - event.startedAt >= event.durationSeconds) {
            removeEvent(index);
            continue;
        }
        index += 1;
    }
}

fn lerpByte(start: u8, end: u8, amount: f32) u8 {
    const startFloat: f32 = @floatFromInt(start);
    const endFloat: f32 = @floatFromInt(end);
    return @intFromFloat(@round(startFloat + (endFloat - startFloat) * amount));
}

fn lerpColor(start: sdl.Color, end: sdl.Color, amount: f32) sdl.Color {
    return .{
        .r = lerpByte(start.r, end.r, amount),
        .g = lerpByte(start.g, end.g, amount),
        .b = lerpByte(start.b, end.b, amount),
        .a = lerpByte(start.a, end.a, amount),
    };
}

fn colorBetween(progress: f32, startAt: f32, endAt: f32, start: sdl.Color, end: sdl.Color) sdl.Color {
    const amount = (progress - startAt) / (endAt - startAt);
    return lerpColor(start, end, std.math.clamp(amount, 0, 1));
}

fn rimColor(progress: f32) sdl.Color {
    const whiteHot = sdl.Color{ .r = 255, .g = 250, .b = 220, .a = 255 };
    const amber = sdl.Color{ .r = 255, .g = 205, .b = 55, .a = 250 };
    const orange = sdl.Color{ .r = 255, .g = 105, .b = 20, .a = 235 };
    const red = sdl.Color{ .r = 205, .g = 28, .b = 8, .a = 205 };
    const charredBlack = sdl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (progress < 0.08) return colorBetween(progress, 0, 0.08, whiteHot, amber);
    if (progress < 0.38) return colorBetween(progress, 0.08, 0.38, amber, orange);
    if (progress < 0.58) return colorBetween(progress, 0.38, 0.58, orange, red);

    const coolingProgress = (progress - 0.58) / (1.0 - 0.58);
    const smoothedCooling = coolingProgress * coolingProgress * (3.0 - 2.0 * coolingProgress);
    return lerpColor(red, charredBlack, smoothedCooling);
}

fn expandedQuad(quad: surface_cutout.HotRimQuad, expansion: f32) surface_cutout.HotRimQuad {
    const horizontal = vec.subtract(quad.corners[1], quad.corners[0]);
    const vertical = vec.subtract(quad.corners[3], quad.corners[0]);
    const horizontalDirection = vec.mul(horizontal, 1.0 / vec.magnitude(horizontal));
    const verticalDirection = vec.mul(vertical, 1.0 / vec.magnitude(vertical));
    const horizontalExpansion = vec.mul(horizontalDirection, expansion);
    const verticalExpansion = vec.mul(verticalDirection, expansion);
    return .{ .corners = .{
        vec.subtract(vec.subtract(quad.corners[0], horizontalExpansion), verticalExpansion),
        vec.add(vec.subtract(quad.corners[1], verticalExpansion), horizontalExpansion),
        vec.add(vec.add(quad.corners[2], horizontalExpansion), verticalExpansion),
        vec.add(vec.subtract(quad.corners[3], horizontalExpansion), verticalExpansion),
    } };
}

fn screenQuad(quad: surface_cutout.HotRimQuad) [4][2]f32 {
    var points: [4][2]f32 = undefined;
    for (quad.corners, 0..) |corner, index| {
        const screen = camera.relativePosition(conv.m2Pixel(vec.toBox2d(corner)));
        points[index] = .{ @floatFromInt(screen.x), @floatFromInt(screen.y) };
    }
    return points;
}

fn drawQuads(quads: []const surface_cutout.HotRimQuad, color: sdl.Color, expansion: f32) !void {
    if (color.a == 0) return;
    try gpu.setRenderDrawColor(color);
    for (quads) |quad| {
        const drawnQuad = if (expansion > 0) expandedQuad(quad, expansion) else quad;
        try gpu.renderFillQuad(screenQuad(drawnQuad));
    }
}

pub fn draw() !void {
    if (events.items.len == 0) return;

    const now = time.realNow();
    for (events.items) |event| {
        const progress: f32 = @floatCast(std.math.clamp((now - event.startedAt) / event.durationSeconds, 0, 1));
        const color = rimColor(progress);
        const glowColor = sdl.Color{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * glowAlphaScale),
        };
        try drawQuads(event.quads, glowColor, glowExpansionPixels / conv.met2pix);
        try drawQuads(event.quads, color, 0);
    }
}

pub fn cleanup() void {
    for (events.items) |event| allocator.free(event.quads);
    events.clearAndFree(allocator);
}
