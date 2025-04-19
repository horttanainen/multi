const std = @import("std");
const sdl = @import("zsdl");
const box2d = @import("box2dnative.zig");

const polygon = @import("polygon.zig");
const box = @import("box.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const sensor = @import("sensor.zig");

const m2P = @import("conversion.zig").m2P;
const p2m = @import("conversion.zig").p2m;
const m2PixelPos = @import("conversion.zig").m2PixelPos;

const IVec2 = @import("vector.zig").IVec2;
const entity = @import("entity.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var maybeLevel: ?Entity = null;
var levelNumber: i32 = 0;

const LevelError = error{Uninitialized};

pub fn createFromImg(position: IVec2, img: *sdl.Surface, shapeDef: box2d.b2ShapeDef) !void {
    const bodyId = try box.createStaticBody(position);
    maybeLevel = try entity.createEntityForBody(bodyId, img, shapeDef);
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

pub fn create() !void {
    const evenLevel = @mod(levelNumber, 2);

    const resources = try shared.getResources();

    const levelSurface = if (evenLevel == 0) resources.levelSurface else resources.level2Surface;

    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    try createFromImg(.{ .x = 400, .y = 400 }, levelSurface, shapeDef);

    try entity.createFromImg(.{ .x = 400, .y = 400 }, resources.beanSurface, shapeDef);

    try player.spawn(.{ .x = 200, .y = 400 });

    if (evenLevel == 0) {
        try sensor.createGoalSensorFromImg(.{ .x = 700, .y = 550 }, resources.duffSurface);
    } else {
        try sensor.createGoalSensorFromImg(.{ .x = 100, .y = 300 }, resources.duffSurface);
    }

    levelNumber += 1;
}

pub fn cleanup() void {
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
    if (maybeLevel) |level| {
        shared.allocator.free(level.shapeIds);
    }
    maybeLevel = null;
}

pub fn reset() !void {
    shared.goalReached = false;
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
    if (maybeLevel) |level| {
        box2d.b2DestroyBody(level.bodyId);
        shared.allocator.free(level.shapeIds);
    }
    try create();
}
