const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2d").native;

const polygon = @import("polygon.zig");
const box = @import("box.zig");
const shared = @import("shared.zig");

const m2P = @import("conversion.zig").m2P;
const p2m = @import("conversion.zig").p2m;
const m2PixelPos = @import("conversion.zig").m2PixelPos;

const IVec2 = @import("vector.zig").IVec2;
const Sprite = @import("entity.zig").Sprite;
const Entity = @import("entity.zig").Entity;

var maybeLevel: ?Entity = null;

const LevelError = error{Uninitialized};

pub fn createFromImg(position: IVec2, img: *sdl.Surface) !void {
    const resources = try shared.getResources();

    const texture = try sdl.createTextureFromSurface(resources.renderer, img);

    const triangles = try polygon.triangulate(img);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = p2m(.{ .x = size.x, .y = size.y });

    const bodyId = try box.createStaticBody(position);
    try box.createPolygonShape(bodyId, triangles, .{ .x = size.x, .y = size.y });

    const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    maybeLevel = Entity{ .bodyId = bodyId, .sprite = sprite };
}

pub fn getLevel() !Entity {
    if (maybeLevel) |level| {
        return level;
    }
    return LevelError.Uninitialized;
}

pub fn draw() !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;
    const level = try getLevel();

    const bodyId = level.bodyId;
    const sprite = level.sprite;
    const posMeter = box2d.b2Body_GetPosition(bodyId);

    const pos = m2PixelPos(posMeter.x, posMeter.y, sprite.dimM.x, sprite.dimM.y);
    const rect = sdl.Rect{
        .x = pos.x,
        .y = pos.y,
        .w = m2P(sprite.dimM.x),
        .h = m2P(sprite.dimM.y),
    };
    try sdl.renderCopy(renderer, sprite.texture, null, &rect);
}
