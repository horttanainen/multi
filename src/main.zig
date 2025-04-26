const sdl = @import("zsdl");
const box2d = @import("box2dnative.zig");
const std = @import("std");

const config = @import("config.zig");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const shared = @import("shared.zig");
const SharedResources = @import("shared.zig").SharedResources;
const allocator = @import("shared.zig").allocator;
const sensor = @import("sensor.zig");
const time = @import("time.zig");
const fps = @import("fps.zig");
const renderer = @import("renderer.zig");
const physics = @import("physics.zig");
const input = @import("input.zig");
const camera = @import("camera.zig");

const meters = @import("conversion.zig").meters;
const m2PixelPos = @import("conversion.zig").m2PixelPos;
const m2P = @import("conversion.zig").m2P;

const frictionCallback = @import("friction.zig").frictionCallback;

const debug = @import("debug.zig");

const player = @import("player.zig");

const box = @import("box.zig");
const level = @import("level.zig");
const entity = @import("entity.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//level editor todos:
//TODO: create rudimentary level editor: user can draw window sized level using rocks
//TODO: user can use beams in level editor
//TODO: user can create spawn for player
//TODO: user can create goal for player
//TODO: user can create level that is bigger than screen

//level oriented physics demo game todos:
//TODO: create about 10 different physics and gravity based levels

//Single player game todos:
//TODO: add sliding
//TODO: add sounds
//TODO: add jetpack
//TODO: add liero/worms grappling hook
//TODO: add quake bazooka (investigate box2d bullet)
//TODO: add enemies to shoot

//Multiplayer todos:
//TODO: add splitscreen multiplayer
//TODO: investigate how to sync games when running on different machines
//TODO: add localhost multiplayer
//TODO: add real multiplayer
//TODO: read https://mas-bandwidth.com/what-is-lag/
//TODO: read https://mas-bandwidth.com/choosing-the-right-network-model-for-your-multiplayer-game/
//TODO: read https://gafferongames.com/post/deterministic_lockstep/

//Engine:
//TODO: separate engine code from game logic

//Bugs to fix:
//TODO: center camera on player. Might need bypassing m2PixelPos
//TODO: Clicking does not work relative to camera

pub fn main() !void {
    const resources = try shared.init();
    defer shared.cleanup();

    try level.create();
    defer level.cleanup();

    box2d.b2World_SetFrictionCallback(resources.worldId, &frictionCallback);

    while (!shared.quitGame) {
        time.frameBegin();

        try physics.step();

        try input.handle();

        if (shared.goalReached) {
            try level.reset();
        }

        player.clampSpeed();

        try player.checkSensors();
        try sensor.checkGoal();

        camera.followPlayer();

        try renderer.render();

        // keep track of time spent per frame
        time.frameEnd();
    }
}
