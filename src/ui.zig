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
const score = @import("score.zig");

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

    const activeCamera = camera.getActiveCamera() orelse return;
    const vpPlayerId = activeCamera.playerId;

    // Get the viewing player's screen position to use as ray origin
    const vpPlayer = player.players.getPtr(vpPlayerId) orelse return;
    const vpEnt = entity.getEntity(vpPlayer.bodyId) orelse return;
    const vpCurrentState = box2d.getState(vpPlayer.bodyId);
    const vpState = box2d.getInterpolatedState(vpEnt.state, vpCurrentState);
    const vpScreenPos = camera.relativePosition(conv.m2Pixel(vpState.pos));
    const ox: f32 = @floatFromInt(vpScreenPos.x);
    const oy: f32 = @floatFromInt(vpScreenPos.y);

    for (player.players.values()) |*p| {
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
        const marginF: f32 = @floatFromInt(margin);
        const vpW: f32 = @floatFromInt(vp.width);
        const vpH: f32 = @floatFromInt(vp.height);

        // Skip if enemy is inside the viewport
        if (enemyPos.x >= margin and enemyPos.x <= vp.width - margin and
            enemyPos.y >= margin and enemyPos.y <= vp.height - margin)
        {
            continue;
        }

        // Cast ray from viewing player's screen position toward enemy
        const ex: f32 = @floatFromInt(enemyPos.x);
        const ey: f32 = @floatFromInt(enemyPos.y);
        const dx: f32 = ex - ox;
        const dy: f32 = ey - oy;

        if (dx == 0 and dy == 0) continue;

        // Find smallest positive t where ray from (ox,oy) in direction (dx,dy) hits a viewport edge
        var t: f32 = std.math.floatMax(f32);
        if (dx != 0) {
            const tEdge = if (dx > 0) (vpW - marginF - ox) / dx else (marginF - ox) / dx;
            if (tEdge > 0) t = @min(t, tEdge);
        }
        if (dy != 0) {
            const tEdge = if (dy > 0) (vpH - marginF - oy) / dy else (marginF - oy) / dy;
            if (tEdge > 0) t = @min(t, tEdge);
        }

        const ix: i32 = @intFromFloat(std.math.clamp(ox + dx * t, marginF, vpW - marginF));
        const iy: i32 = @intFromFloat(std.math.clamp(oy + dy * t, marginF, vpH - marginF));

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

pub fn drawScoreboard() !void {
    const vp = viewport.activeViewport;

    const activeCamera = camera.getActiveCamera() orelse return;
    const playerId = activeCamera.playerId;
    const s = score.getScore(playerId) orelse return;

    const totalScore = s.kills - s.suicides;

    var buf: [64]u8 = undefined;
    const scoreText = std.fmt.bufPrintZ(&buf, "Score: {d} - Kills: {d} - Suicides: {d} - Deaths: {d}", .{ totalScore, s.kills, s.suicides, s.deaths }) catch return;
    try text.writeAt(scoreText, .{ .x = @divFloor(vp.width, 2) - 250, .y = vp.height - 20 });
}
