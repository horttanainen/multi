const sdl = @import("zsdl");
const box2d = @import("box2d.zig");
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
const animation = @import("animation.zig");

const frictionCallback = @import("friction.zig").frictionCallback;

const debug = @import("debug.zig");

const player = @import("player.zig");

const level = @import("level.zig");
const levelEditor = @import("leveleditor.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//Single player game todos:
//TODO: add random rotation to explosion animation
//TODO: make explosion break level
//TODO: allow explosion to break objects
//TODO: split projectile into pieces
//TODO: add walking animation
//TODO: add stupid enemy that only stands still and can be killed
//TODO: make killing of enemy very gibby and bloody
//TODO: support controller
//TODO: add crouch
//TODO: add sliding
//TODO: add slope sliding
//TODO: add sounds
//TODO: add jetpack
//TODO: add liero/worms grappling hook
//TODO: add enemies to shoot

//level editor todos:
//TODO: Pressing r in level editor reloads the level from latest version
//TODO: pressing ctrl z in level editor loads the previous version of the json.
//TODO: pressing ctrl r in level editor loads the next version of the json.
//TODO: user can move entities
//TODO: user can drop images into a folder to use in the editor
//TODO: user can choose to create static objects or dynamic
//TODO: pause time when entering level editor
//TODO: add option for user to create parallax background from images
//TODO: user can create spawn for player
//TODO: user can create goal for player
//TODO: user can create level that is bigger than screen

//level oriented physics demo game todos:
//TODO: create about 10 different physics and gravity based levels
//TODO: create levels with enemies


//Multiplayer todos:
//TODO: add splitscreen multiplayer
//TODO: investigate how to sync games when running on different machines
//TODO: add localhost multiplayer
//TODO: add real multiplayer
//TODO: instagib mode
//TODO: read https://mas-bandwidth.com/what-is-lag/
//TODO: read https://mas-bandwidth.com/choosing-the-right-network-model-for-your-multiplayer-game/
//TODO: read https://gafferongames.com/post/deterministic_lockstep/

// game idea: niddhog style 1 v 1 or 2 v 2 or 4 deatmatch. 
// winner is decided based on the tournament
// level changes upon 5 deaths
// main weapon is the cannon

//Engine:
//TODO: separate engine code from game logic

//Bugs:
//TODO: Level json creation broke during 0.15 update

pub fn main() !void {
    const resources = try shared.init();
    defer shared.cleanup();

    try camera.spawn(.{ .x = 0, .y = 0 });
    try level.next();
    defer level.cleanup();
    defer levelEditor.cleanup() catch |err| {
        std.debug.print("Error cleaning up created level folders: {}\n", .{err});
    };

    box2d.c.b2World_SetFrictionCallback(resources.worldId, &frictionCallback);

    while (!shared.quitGame) {
        time.frameBegin();

        try physics.step();

        try input.handle();

        if (shared.editingLevel) {
            levelEditorLoop();
        } else {
            try gameLoop();
        }

        player.animate();

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
        try level.next();
    }

    player.clampSpeed();

    try projectile.checkContacts();
    try projectile.cleanupShrapnel();
    animation.animate();
    entity.cleanupEntities();
    try player.checkSensors();
    try sensor.checkGoal();

    camera.followPlayer();
}
