const std = @import("std");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const allocator = @import("allocator.zig").allocator;
const camera = @import("camera.zig");
const level = @import("level.zig");


pub const SerializableParallaxEntity = struct {
    parallaxDistance: f32,
    fog: f32,
    imgPath: []const u8,
    scale: vec.Vec2,
    pos: vec.IVec2,
};

pub const ParallaxEntity = struct {
    parallaxDistance: f32,
    fog: f32,
    scale: vec.Vec2,
    pos: vec.IVec2,
    spriteUuid: u64,
};

var parallaxEntities = std.array_list.Managed(ParallaxEntity).init(allocator);

pub fn draw() !void {
    for (parallaxEntities.items) |parallaxEntity| {
        const parallaxSprite = sprite.getSprite(parallaxEntity.spriteUuid) orelse continue;

        const relativePos = if (level.fixedCamera)
            camera.relativePosition(parallaxEntity.pos)
        else
            camera.parallaxAdjustedRelativePosition(
                parallaxEntity.pos,
                parallaxEntity.parallaxDistance,
            );

        try sprite.drawWithOptions(
            parallaxSprite,
            relativePos,
            0,
            false,
            false,
            parallaxEntity.fog,
            null,
            null,
        );
    }
}

pub fn create(spriteUuid: u64, pos: vec.IVec2, parallaxDistance: f32, scale: vec.Vec2, fog: f32) !void {
    const parallaxEntity = ParallaxEntity{
        .spriteUuid = spriteUuid,
        .parallaxDistance = parallaxDistance,
        .pos = pos,
        .scale = scale,
        .fog = fog,
    };

    try parallaxEntities.append(parallaxEntity);

    std.mem.sort(ParallaxEntity, parallaxEntities.items, {}, sort);
}

fn sort(_: void, a: ParallaxEntity, b: ParallaxEntity) bool {
    return a.parallaxDistance > b.parallaxDistance;
}

pub fn cleanup() void {
    for (parallaxEntities.items) |pEntity| {
        sprite.cleanupLater(pEntity.spriteUuid);
    }
    parallaxEntities.deinit();
    parallaxEntities = std.array_list.Managed(ParallaxEntity).init(allocator);
}

