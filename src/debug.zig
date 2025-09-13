const std = @import("std");
const sdl = @import("zsdl");
const box2d = @import("box2d.zig");

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const shared = @import("shared.zig");
const camera = @import("camera.zig");
const SharedResources = @import("shared.zig").SharedResources;
const m2Pixel = @import("conversion.zig").m2Pixel;

var dDraw: ?box2d.c.b2DebugDraw = null;
pub fn init() !void {
    var debugDraw = box2d.c.b2DefaultDebugDraw();
    debugDraw.context = &shared.maybeResources;
    debugDraw.DrawSolidPolygon = &drawSolidPolygon;
    debugDraw.DrawPolygon = &drawPolygon;
    debugDraw.DrawSegment = &drawSegment;
    debugDraw.DrawPoint = &drawPoint;
    debugDraw.DrawSolidCircle = &drawSolidCircle;
    debugDraw.drawShapes = true;
    debugDraw.drawAABBs = false;
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
    // Retrieve our shared resources from the context pointer.
    const res: *SharedResources = @alignCast(@ptrCast(context));

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    sdl.setRenderDrawColor(res.renderer, .{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("Error setting draw color\n", .{});
        return;
    };

    if (vertexCount == 0) return;

    const rot = transform.q;
    // The transform's position, converted to pixel coordinates.

    // Draw each edge of the polygon.
    for (0..@intCast(vertexCount)) |i| {
        // Rotate and translate the current vertex.
        const v_current: box2d.c.b2Vec2 = vertices[i];
        const rotated_current: box2d.c.b2Vec2 = b2Mul(rot, v_current);
        const world_current: box2d.c.b2Vec2 = box2d.c.b2Vec2{
            .x = transform.p.x + rotated_current.x,
            .y = transform.p.y + rotated_current.y,
        };
        const current: IVec2 = camera.relativePosition(m2Pixel(world_current));

        // Do the same for the next vertex (with wrap-around)
        const v_next: box2d.c.b2Vec2 = vertices[(i + 1) % @as(usize, @intCast(vertexCount))];
        const rotated_next: box2d.c.b2Vec2 = b2Mul(rot, v_next);
        const world_next: box2d.c.b2Vec2 = box2d.c.b2Vec2{
            .x = transform.p.x + rotated_next.x,
            .y = transform.p.y + rotated_next.y,
        };
        const next: IVec2 = camera.relativePosition(m2Pixel(world_next));

        sdl.renderDrawLine(res.renderer, current.x, current.y, next.x, next.y) catch {
            std.debug.print("Error drawing line\n", .{});
            return;
        };
    }
}

pub fn drawPolygon(vertices: [*c]const box2d.c.b2Vec2, vertexCount: c_int, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    const res: *SharedResources = @alignCast(@ptrCast(context));

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    sdl.setRenderDrawColor(res.renderer, .{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    if (vertexCount == 0) return;

    // Draw lines connecting the vertices (wrap-around at the end)
    for (0..@intCast(vertexCount)) |i| {
        const current: IVec2 = camera.relativePosition(m2Pixel(vertices[i]));
        const next: IVec2 = camera.relativePosition(m2Pixel(vertices[(i + 1) % @as(usize, @intCast(vertexCount))]));
        sdl.renderDrawLine(res.renderer, current.x, current.y, next.x, next.y) catch {
            std.debug.print("encountered error in debugDrawPolygon when trying to renderDrawLine\n", .{});
            return;
        };
    }
}

pub fn drawSegment(p1: box2d.c.b2Vec2, p2: box2d.c.b2Vec2, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    const res: *SharedResources = @alignCast(@ptrCast(context));

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    sdl.setRenderDrawColor(res.renderer, .{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    const current: IVec2 = camera.relativePosition(m2Pixel(p1));
    const next: IVec2 = camera.relativePosition(m2Pixel(p2));

    sdl.renderDrawLine(res.renderer, current.x, current.y, next.x, next.y) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to renderDrawLine\n", .{});
        return;
    };
}

pub fn drawPoint(p1: box2d.c.b2Vec2, size: f32, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    const res: *SharedResources = @alignCast(@ptrCast(context));

    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    sdl.setRenderDrawColor(res.renderer, .{ .r = r, .g = g, .b = b, .a = 255 }) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to setRenderDrawColor\n", .{});
        return;
    };

    const current: IVec2 = camera.relativePosition(m2Pixel(p1));

    const rect = sdl.Rect{ .x = current.x, .y = current.y, .w = @intFromFloat(size), .h = @intFromFloat(size) };

    sdl.renderFillRect(res.renderer, rect) catch {
        std.debug.print("encountered error in debugDrawPolygon when trying to renderFillRect\n", .{});
        return;
    };
}

pub fn drawSolidCircle(transform: box2d.c.b2Transform, radius: f32, color: box2d.c.b2HexColor, context: ?*anyopaque) callconv(.c) void {
    const half = radius;
    const verts = [_]box2d.c.b2Vec2{
        .{ .x = -half, .y = -half },
        .{ .x =  half, .y = -half },
        .{ .x =  half, .y =  half },
        .{ .x = -half, .y =  half },
    };

    drawSolidPolygon(transform, &verts, verts.len, radius, color, context);
}

pub fn draw() !void {
    const resources = try shared.getResources();

    if (dDraw) |*debugDraw| {
        box2d.c.b2World_Draw(resources.worldId, debugDraw);
    }
}
