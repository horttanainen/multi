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
//TODO: make the current level "change" logic use somekind of serialized solution
//TODO: create rudimentary level editor: user can draw window sized level using rocks
//TODO: user can drop images into a folder to use in the editor
//TODO: user can choose to create static objects or dynamic
//TODO: user can save level
//TODO: add option for user to create parallax background from images
//TODO: user can use beams in level editor
//TODO: user can create spawn for player
//TODO: user can create goal for player
//TODO: user can create level that is bigger than screen

//level oriented physics demo game todos:
//TODO: create about 10 different physics and gravity based levels

//Single player game todos:
//TODO: make player feet collider rounded so it does not stick into corners
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

//Bugs:
//TODO: sometimes jumping wont work because of the crappy sensor logic that sometimes misses player returning to ground. We probably should periodically check if player is touching ground to decide if we are back on the ground again.
//TODO: some shapes, such as star.png, crash triangulation. I suspect my version of pavlidis is buggy

pub fn main() !void {
    const resources = try shared.init();
    defer shared.cleanup();

    try camera.spawn(.{ .x = 200, .y = 400 });
    try level.create();
    defer level.cleanup();

    box2d.b2World_SetFrictionCallback(resources.worldId, &frictionCallback);

    while (!shared.quitGame) {
        time.frameBegin();

        try physics.step();

        try input.handle();

        if (shared.editingLevel) {
            levelEditorLoop();
        } else {
            try gameLoop();
        }

        try renderer.render();

        // keep track of time spent per frame
        time.frameEnd();
    }
}

fn levelEditorLoop() void {
    camera.followKeyboard();
}

fn gameLoop() !void {
    if (shared.goalReached) {
        try level.reset();
    }

    player.clampSpeed();

    try player.checkSensors();
    try sensor.checkGoal();

    camera.followPlayer();
}
