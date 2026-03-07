const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const box2d = @import("box2d.zig");

const IVec2 = @import("vector.zig").IVec2;
const camera = @import("camera.zig");
const viewport = @import("viewport.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const m2Pixel = conv.m2Pixel;

var dDraw: ?box2d.c.b2DebugDraw = null;
pub fn init() !void {
    var debugDraw = box2d.c.b2DefaultDebugDraw();
    debugDraw.context = null;
    debugDraw.DrawSolidPolygonFcn = &drawSolidPolygon;
    debugDraw.DrawPolygonFcn = &drawPolygon;
    debugDraw.DrawSegmentFcn = &drawSegment;
    debugDraw.DrawPointFcn = &drawPoint;
    debugDraw.DrawSolidCircleFcn = &drawSolidCircle;
    debugDraw.drawShapes = true;
    debugDraw.drawBounds = false;
    debugDraw.drawContacts = true;
    debugDraw.drawFrictionImpulses = false;
    dDraw = debugDraw;
}

fn b2Mul(rot: box2d.c.b2Rot, v: box2d.c.b2Vec2) box2d.c.b2Vec2 {
    return box2d.c.b2Vec2{
        .x = rot.c * v.x - rot.s * v.y,
        .y = rot.s * v.x + rot.c * v.y,
    };
}

pub fn drawSolidPolygon(transform: box2d.c.b2Transform, vertices: [*c]const box2d.c.b2Vec2, vertexCount: c_int, radius: f32, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    _ = radius;
    _ = context;

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    gpu.setRenderDrawColor(.{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("Error setting draw color\n", .{});
        return;
    };

    if (vertexCount == 0) return;

    const rot = transform.q;

    for (0..@intCast(vertexCount)) |i| {
        const v_current: box2d.c.b2Vec2 = vertices[i];
        const rotated_current: box2d.c.b2Vec2 = b2Mul(rot, v_current);
        const world_current: box2d.c.b2Vec2 = box2d.c.b2Vec2{
            .x = transform.p.x + rotated_current.x,
            .y = transform.p.y + rotated_current.y,
        };
        const current: IVec2 = camera.relativePosition(m2Pixel(world_current));

        const v_next: box2d.c.b2Vec2 = vertices[(i + 1) % @as(usize, @intCast(vertexCount))];
        const rotated_next: box2d.c.b2Vec2 = b2Mul(rot, v_next);
        const world_next: box2d.c.b2Vec2 = box2d.c.b2Vec2{
            .x = transform.p.x + rotated_next.x,
            .y = transform.p.y + rotated_next.y,
        };
        const next: IVec2 = camera.relativePosition(m2Pixel(world_next));

        gpu.renderDrawLine(current.x, current.y, next.x, next.y) catch {
            std.debug.print("Error drawing line\n", .{});
            return;
        };
    }
}

pub fn drawPolygon(vertices: [*c]const box2d.c.b2Vec2, vertexCount: c_int, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    _ = context;

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    gpu.setRenderDrawColor(.{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    if (vertexCount == 0) return;

    for (0..@intCast(vertexCount)) |i| {
        const current: IVec2 = camera.relativePosition(m2Pixel(vertices[i]));
        const next: IVec2 = camera.relativePosition(m2Pixel(vertices[(i + 1) % @as(usize, @intCast(vertexCount))]));
        gpu.renderDrawLine(current.x, current.y, next.x, next.y) catch {
            std.debug.print("encountered error in debugDrawPolygon when trying to renderDrawLine\n", .{});
            return;
        };
    }
}

pub fn drawSegment(p1: box2d.c.b2Vec2, p2: box2d.c.b2Vec2, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    _ = context;

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    gpu.setRenderDrawColor(.{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    const current: IVec2 = camera.relativePosition(m2Pixel(p1));
    const next: IVec2 = camera.relativePosition(m2Pixel(p2));

    gpu.renderDrawLine(current.x, current.y, next.x, next.y) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to renderDrawLine\n", .{});
        return;
    };
}

pub fn drawPoint(p1: box2d.c.b2Vec2, size: f32, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    _ = context;

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    gpu.setRenderDrawColor(.{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    const current: IVec2 = camera.relativePosition(m2Pixel(p1));

    const rect = sdl.Rect{ .x = current.x, .y = current.y, .w = @intFromFloat(size), .h = @intFromFloat(size) };

    gpu.renderFillRect(rect) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to renderFillRect\n", .{});
        return;
    };
}

pub fn drawSolidCircle(transform: box2d.c.b2Transform, radius: f32, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    const half = radius;
    const verts = [_]box2d.c.b2Vec2{
        .{ .x = -half, .y = -half },
        .{ .x = half, .y = -half },
        .{ .x = half, .y = half },
        .{ .x = -half, .y = half },
    };

    drawSolidPolygon(transform, &verts, verts.len, radius, color, context);
}

pub fn draw() !void {
    if (dDraw) |*debugDraw| {
        if (camera.getActiveCamera()) |cam| {
            const vp = viewport.activeViewport;
            const lx: f32 = @as(f32, @floatFromInt(cam.posPx.x)) / conv.met2pix;
            const ly: f32 = @as(f32, @floatFromInt(cam.posPx.y)) / conv.met2pix;
            const ux: f32 = @as(f32, @floatFromInt(cam.posPx.x + vp.width)) / conv.met2pix;
            const uy: f32 = @as(f32, @floatFromInt(cam.posPx.y + vp.height)) / conv.met2pix;
            debugDraw.drawingBounds = .{
                .lowerBound = .{ .x = lx, .y = ly },
                .upperBound = .{ .x = ux, .y = uy },
            };
            debugDraw.useDrawingBounds = true;
        }
        box2d.worldDraw(debugDraw);
    }
}
