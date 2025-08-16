const std = @import("std");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const shared = @import("shared.zig");
const camera = @import("camera.zig");

pub const SerializableParallaxEntity = struct {
    parallaxDistance: i32,
    imgPath: []const u8,
    scale: vec.Vec2,
    pos: vec.IVec2,
};

pub const ParallaxEntity = struct {
    parallaxDistance: i32,
    scale: vec.Vec2,
    pos: vec.IVec2,
    sprite: sprite.Sprite,
};

var parallaxEntities = std.ArrayList(ParallaxEntity).init(shared.allocator);

pub fn draw() !void {
    for (parallaxEntities.items) |parallaxEntity| {
        const relativePos = camera.parallaxAdjustedRelativePosition(
            parallaxEntity.pos,
            parallaxEntity.parallaxDistance,
        );

        try sprite.drawWithOptions(
            parallaxEntity.sprite,
            relativePos,
            0,
            false,
            false,
        );
    }
}

pub fn create(s: sprite.Sprite, pos: vec.IVec2, parallaxDistance: i32, scale: vec.Vec2) !void {
    const parallaxEntity = ParallaxEntity{
        .sprite = s,
        .parallaxDistance = parallaxDistance,
        .pos = pos,
        .scale = scale,
    };

    try parallaxEntities.append(parallaxEntity);

    std.mem.sort(ParallaxEntity, parallaxEntities.items, {}, sort);
}

fn sort(_: void, a: ParallaxEntity, b: ParallaxEntity) bool {
    return a.parallaxDistance > b.parallaxDistance;
}

pub fn cleanup() void {
    for (parallaxEntities.items) |pEntity| {
        sprite.cleanup(pEntity.sprite);
    }
    parallaxEntities.deinit();
    parallaxEntities = std.ArrayList(ParallaxEntity).init(shared.allocator);
}
