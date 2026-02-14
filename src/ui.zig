const std = @import("std");
const sdl = @import("zsdl");

const shared = @import("shared.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const text = @import("text.zig");
const viewport = @import("viewport.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const box2d = @import("box2d.zig");
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const vec = @import("vector.zig");
const controller = @import("controller.zig");

pub fn drawMode() !void {
    const mode = if (shared.editingLevel) "LEVEL EDITOR" else "PLAY";

    const vp = viewport.activeViewport;

    const xPos = @divFloor(vp.width, 2);
    try text.writeAt(mode, .{ .x = xPos, .y = 2 });
}

pub fn drawFps() !void {
    var fpsTextBuf: [100]u8 = undefined;

    const fps = time.calculateFps();

    const vp = viewport.activeViewport;

    const fpsText = try std.fmt.bufPrintZ(&fpsTextBuf, "FPS: {d}", .{fps});
    const xPos = vp.width - 90;
    try text.writeAt(fpsText, .{ .x = xPos, .y = 2 });
}

pub fn drawPlayerHealth() !void {
    for (player.players.values()) |*p| {
        const maybeEntity = entity.getEntity(p.bodyId);
        if (maybeEntity) |ent| {
            const currentState = box2d.getState(p.bodyId);
            const state = box2d.getInterpolatedState(ent.state, currentState);
            const playerPos = camera.relativePosition(conv.m2Pixel(state.pos));

            var buf: [32]u8 = undefined;
            const healthText = std.fmt.bufPrintZ(&buf, "{d}", .{@as(i32, @intFromFloat(p.health))}) catch return;

            const textPos = vec.IVec2{
                .x = playerPos.x,
                .y = playerPos.y + 70,
            };

            try text.writeAt(healthText, textPos);
        }
    }
}

pub fn drawPlayerLocationsOnViewportBorder() !void {
    const resources = try shared.getResources();

    for (player.players.values()) |*p| {
        const activeCamera = camera.getActiveCamera() orelse continue;
        const vpPlayerId = activeCamera.playerId;
        if (p.id == vpPlayerId) {
            continue;
        }

        if (p.isDead) {
            continue;
        }

        const ent = entity.getEntity(p.bodyId) orelse continue;

        const currentState = box2d.getState(p.bodyId);
        const state = box2d.getInterpolatedState(ent.state, currentState);
        const enemyPos = camera.relativePosition(conv.m2Pixel(state.pos));

        const enemyController = controller.controllers.get(p.id) orelse continue;
        const enemyColor = enemyController.color;

        const vp = viewport.activeViewport;
        const margin: i32 = 4;

        // Skip if enemy is inside the viewport
        if (enemyPos.x >= margin and enemyPos.x <= vp.width - margin and
            enemyPos.y >= margin and enemyPos.y <= vp.height - margin)
        {
            continue;
        }

        // Cast ray from viewport center toward enemy position
        const cx: f32 = @as(f32, @floatFromInt(vp.width)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(vp.height)) / 2.0;
        const dx: f32 = @as(f32, @floatFromInt(enemyPos.x)) - cx;
        const dy: f32 = @as(f32, @floatFromInt(enemyPos.y)) - cy;

        if (dx == 0 and dy == 0) continue;

        // Find the smallest positive t where the ray hits a viewport edge
        const halfW = cx - @as(f32, @floatFromInt(margin));
        const halfH = cy - @as(f32, @floatFromInt(margin));

        var t: f32 = std.math.floatMax(f32);
        if (dx != 0) {
            const tRight = halfW / @abs(dx);
            const tLeft = halfW / @abs(dx);
            t = @min(t, if (dx > 0) tRight else tLeft);
        }
        if (dy != 0) {
            const tBottom = halfH / @abs(dy);
            const tTop = halfH / @abs(dy);
            t = @min(t, if (dy > 0) tBottom else tTop);
        }

        const ix: i32 = @intFromFloat(cx + dx * t);
        const iy: i32 = @intFromFloat(cy + dy * t);

        const indicatorSize: i32 = 8;
        const rect = sdl.Rect{
            .x = ix - @divFloor(indicatorSize, 2),
            .y = iy - @divFloor(indicatorSize, 2),
            .w = indicatorSize,
            .h = indicatorSize,
        };

        try sdl.setRenderDrawColor(resources.renderer, .{ .r = enemyColor.r, .g = enemyColor.g, .b = enemyColor.b, .a = 255 });
        try sdl.renderFillRect(resources.renderer, rect);
    }
}
