const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");
const box2d = @import("box2dnative.zig");

const polygon = @import("polygon.zig");
const box = @import("box.zig");
const shared = @import("shared.zig");
const player = @import("player.zig");
const sensor = @import("sensor.zig");
const camera = @import("camera.zig");

const m2P = @import("conversion.zig").m2P;
const p2m = @import("conversion.zig").p2m;
const m2PixelPos = @import("conversion.zig").m2PixelPos;

const IVec2 = @import("vector.zig").IVec2;
const entity = @import("entity.zig");
const Sprite = entity.Sprite;
const Entity = entity.Entity;

var levelNumber: usize = 0;

pub const position: IVec2 = .{
    .x = 400,
    .y = 400,
};
pub var size: IVec2 = .{
    .x = 100,
    .y = 100,
};

const LevelError = error{
    Uninitialized,
};

// pub fn draw() !void {
//     const resources = try shared.getResources();
//     const renderer = resources.renderer;
//     const level = try getLevel();

//     const bodyId = level.bodyId;
//     const sprite = level.sprite;
//     const posMeter = box2d.b2Body_GetPosition(bodyId);

//     const pos = camera.relativePosition(m2PixelPos(posMeter.x, posMeter.y, sprite.dimM.x, sprite.dimM.y));
//     const rect = sdl.Rect{
//         .x = pos.x,
//         .y = pos.y,
//         .w = m2P(sprite.dimM.x),
//         .h = m2P(sprite.dimM.y),
//     };
//     try sdl.renderCopy(renderer, sprite.texture, null, &rect);
// }

pub const SerializableEntity = struct {
    dynamic: bool,
    friction: f32,
    imgPath: [:0]const u8,
    pos: IVec2,
};

pub const Level = struct {
    size: IVec2,
    entities: [2]SerializableEntity,
    spawn: IVec2,
    goal: SerializableEntity,
};

const levels = [_]Level{
    Level{
        .size = IVec2{ .x = 1680, .y = 1680 },
        .entities = [2]SerializableEntity{
            .{
                .dynamic = false,
                .friction = 0.5,
                .imgPath = "images/level.png",
                .pos = IVec2{
                    .x = 400,
                    .y = 400,
                },
            },
            .{
                .dynamic = true,
                .friction = 0.5,
                .imgPath = "images/bean.png",
                .pos = IVec2{
                    .x = 400,
                    .y = 400,
                },
            },
        },
        .spawn = IVec2{
            .x = 250,
            .y = 450,
        },
        .goal = SerializableEntity{
            .dynamic = false,
            .friction = 0,
            .imgPath = "images/duff.png",
            .pos = IVec2{
                .x = 700,
                .y = 550,
            },
        },
    },
    Level{
        .size = IVec2{ .x = 840, .y = 840 },
        .entities = [_]SerializableEntity{
            .{
                .dynamic = false,
                .friction = 0.5,
                .imgPath = "images/level2.png",
                .pos = IVec2{
                    .x = 400,
                    .y = 400,
                },
            },
            .{
                .dynamic = true,
                .friction = 0.5,
                .imgPath = "images/bean.png",
                .pos = IVec2{
                    .x = 400,
                    .y = 400,
                },
            },
        },
        .spawn = IVec2{
            .x = 600,
            .y = 50,
        },
        .goal = SerializableEntity{
            .dynamic = false,
            .friction = 0,
            .imgPath = "images/duff.png",
            .pos = IVec2{
                .x = 100,
                .y = 250,
            },
        },
    },
};

pub fn create() !void {
    const levelToDeserialize = levels[levelNumber];

    for (levelToDeserialize.entities) |e| {
        const surface = try image.load(e.imgPath);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.friction = e.friction;

        const bodyDef = if (e.dynamic) box.createDynamicBodyDef(e.pos) else box.createStaticBodyDef(e.pos);

        try entity.createFromImg(surface, shapeDef, bodyDef);
    }

    try player.spawn(levelToDeserialize.spawn);

    const goalSurface = try image.load(levelToDeserialize.goal.imgPath);
    try sensor.createGoalSensorFromImg(levelToDeserialize.goal.pos, goalSurface);

    levelNumber = @mod(levelNumber + 1, levels.len);
    size = levelToDeserialize.size;
}

pub fn cleanup() void {
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
}

pub fn reset() !void {
    shared.goalReached = false;
    player.cleanup();
    sensor.cleanup();
    entity.cleanup();
    try create();
}
