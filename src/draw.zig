const std = @import("std");
const box2d = @import("box2d").native;
const sdl = @import("zsdl2");

const m2PixelPos = @import("conversion.zig").m2PixelPos;
const m2P = @import("conversion.zig").m2P;

const Object = @import("object.zig").Object;

const shared = @import("shared.zig");

const PI = std.math.pi;

pub fn drawObject(object: Object) !void {
    if (shared.resources) |resources| {
        const renderer = resources.renderer;

        const bodyId = object.bodyId;
        const sprite = object.sprite;
        const boxPosMeter = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);

        const pos = m2PixelPos(boxPosMeter.x, boxPosMeter.y, sprite.dimM.x, sprite.dimM.y);
        const rect = sdl.Rect{
            .x = pos.x,
            .y = pos.y,
            .w = m2P(sprite.dimM.x),
            .h = m2P(sprite.dimM.y),
        };
        try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
    }
}
