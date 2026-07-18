const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const box2d = @import("box2d.zig");

const vec = @import("vector.zig");
const IVec2 = vec.IVec2;
const camera = @import("camera.zig");
const viewport = @import("viewport.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const m2Pixel = conv.m2Pixel;
const renderer = @import("renderer.zig");
const player = @import("player.zig");
const projectile = @import("projectile.zig");
const time = @import("time.zig");

var dDraw: ?box2d.c.b2DebugDraw = null;
var autoMissileExplosionNextAtMs: f64 = 0;
const autoMissileExplosionMaximumDamage: f32 = 100;

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

pub fn update() !void {
    if (comptime config.debugAutoMissileExplosionDelayMs == null) return;
    try triggerAutoMissileExplosion();
}

fn triggerAutoMissileExplosion() !void {
    const delayMs = config.debugAutoMissileExplosionDelayMs orelse return;
    if (autoMissileExplosionNextAtMs == 0) {
        autoMissileExplosionNextAtMs = @floatFromInt(delayMs);
    }

    const nowMs = time.now() * 1000.0;
    if (nowMs < autoMissileExplosionNextAtMs) return;
    autoMissileExplosionNextAtMs = nowMs + @as(f64, @floatFromInt(config.respawnDelayMs)) + 100.0;

    const attacker = player.players.get(0) orelse {
        std.log.err("triggerAutoMissileExplosion: attacker player 0 is missing", .{});
        return;
    };
    const victim = player.players.getPtr(1) orelse {
        std.log.err("triggerAutoMissileExplosion: victim player 1 is missing", .{});
        return;
    };
    if (victim.isDead) return;
    if (attacker.weapons.len == 0) {
        std.log.err("triggerAutoMissileExplosion: attacker player 0 has no weapons", .{});
        return;
    }

    const missile = attacker.weapons[0].projectile orelse {
        std.log.err("triggerAutoMissileExplosion: player 0 weapon 0 has no projectile", .{});
        return;
    };
    const explosion = missile.explosion orelse {
        std.log.err("triggerAutoMissileExplosion: missile has no explosion", .{});
        return;
    };

    const victimBodyPosition = vec.fromBox2d(box2d.c.b2Body_GetPosition(victim.bodyId));
    const attackerPosition = vec.add(victimBodyPosition, .{ .x = -5, .y = 0 });
    box2d.c.b2Body_SetTransform(attacker.bodyId, vec.toBox2d(attackerPosition), box2d.c.b2Body_GetRotation(attacker.bodyId));
    box2d.c.b2Body_SetLinearVelocity(attacker.bodyId, box2d.c.b2Vec2_zero);

    const guaranteedGibHealth = autoMissileExplosionMaximumDamage + player.gibHealthThreshold - 1.0;
    if (victim.health > guaranteedGibHealth) {
        const setupDamage = victim.health - guaranteedGibHealth;
        const setupResult = try player.damage(victim.id, setupDamage, attacker.id);
        if (!setupResult.applied or setupResult.fatal) {
            std.log.err("triggerAutoMissileExplosion: failed to prepare victim {d} for gibbing", .{victim.id});
            return;
        }
    }

    const victimCenter = vec.add(victimBodyPosition, player.centerOffset);
    std.log.info("debug.auto_missile_explosion victim={d} delay_ms={d} health={d:.1}", .{ victim.id, delayMs, victim.health });
    try projectile.explodeAt(victimCenter, explosion, attacker.id);
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
            // Use effective viewport size (physical / zoom) so zoomed-out cameras
            // draw debug shapes across the full visible area.
            const effW = @as(f32, @floatFromInt(vp.width)) / renderer.zoom;
            const effH = @as(f32, @floatFromInt(vp.height)) / renderer.zoom;
            const lx: f32 = @as(f32, @floatFromInt(cam.posPx.x)) / conv.met2pix;
            const ly: f32 = @as(f32, @floatFromInt(cam.posPx.y)) / conv.met2pix;
            const ux: f32 = (@as(f32, @floatFromInt(cam.posPx.x)) + effW) / conv.met2pix;
            const uy: f32 = (@as(f32, @floatFromInt(cam.posPx.y)) + effH) / conv.met2pix;
            debugDraw.drawingBounds = .{
                .lowerBound = .{ .x = lx, .y = ly },
                .upperBound = .{ .x = ux, .y = uy },
            };
            debugDraw.useDrawingBounds = true;
        }
        box2d.worldDraw(debugDraw);
    }
}
