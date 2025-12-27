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
            const playerPos = camera.relativePosition(
                conv.m2PixelPos(
                    state.pos.x,
                    state.pos.y,
                    0.4,
                    0.4,
                ),
            );

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
