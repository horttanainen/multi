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

const friction = @import("friction.zig");

const debug = @import("debug.zig");

const player = @import("player.zig");
const controller = @import("controller.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");

const level = @import("level.zig");
const levelEditor = @import("leveleditor.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const particle = @import("particle.zig");
const gibbing = @import("gibbing.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//TODO: character remains running after initial movement
//TODO: add ninja rope
//TODO: add dash to side
//TODO: allow resizing the window and start the game with the players monitor size in mind
//TODO: getptrlocking and getlocking do not make sense. The locking needs to happen on the outside and release after mutations
//TODO: add transparent smoke trail for the rocket
//TODO: does it make sense to refactor sprite out of entity and refer to sprites with bodyIds?
//TODO: if so we could get rid of animation spriteindex and just store the pointer to the sprite

//TODO: instead of all the silly playerId indexing start using real uids for players and a map.
//TODO: damagePlayersInRadius should use box2d circle collider to check if players are in the radius. It is basically the same as damageTerrainInRadius.

//extras:
//TODO: refactor sensor stuff into regular entities

//Look and feel
//TODO: Create jumping animation 
//TODO: Create landing animation
//TODO: Create sliding animation
//TODO: Create wall slide animation that is played when player touches wall 

//Controls
//TODO: add sliding
//TODO: add slope sliding
//TODO: try if movement vector should be to the direction of slope character is standing on

//Items to pick up
//TODO: jetpack
//TODO: liero/worms grappling hook
//TODO: short teleport
//TODO: health
//TODO: piercing rocket launcher ammo
//TODO: shrapnel rocket launcher ammo
//TODO: mine bazooka ammo

//Music
//TODO: There should be basic music fitting the deathmatch theme of the game
//TODO: music can be turned off

//level editor:
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

//E2E demo:
//TODO: 3 levels. Each level has some physics puzzle
//TODO: There is Main menu: start game, settings, level editor, exit game
//TODO: Music plays in the background
//TODO: end credits

//Multiplayer:
//TODO: add localhost multiplayer
//TODO: investigate how to sync games when running on different machines
//TODO: add real multiplayer
//TODO: read https://mas-bandwidth.com/what-is-lag/
//TODO: read https://mas-bandwidth.com/choosing-the-right-network-model-for-your-multiplayer-game/
//TODO: read https://gafferongames.com/post/deterministic_lockstep/

//Game content:
//TODO: niddhog style 1 v 1 or 2 v 2 or 4 deatmatch tournament, level changes after each match

//Bugs:
//TODO: Level json creation broke during 0.15 update
//TODO: reapply physics to recreated objects that have been broken

pub fn main() !void {
    const resources = try shared.init();
    defer shared.cleanup();

    try controller.init();
    defer controller.cleanup();

    try keyboard.init();
    defer keyboard.cleanup();

    defer gamepad.cleanup();

    try camera.spawn(.{ .x = 0, .y = 0 });
    try gibbing.init();
    defer gibbing.cleanup();
    try level.next();
    defer level.cleanup();
    defer particle.cleanup();
    defer levelEditor.cleanup() catch |err| {
        std.debug.print("Error cleaning up created level folders: {}\n", .{err});
    };

    box2d.c.b2World_SetFrictionCallback(resources.worldId, &friction.callback);

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
        try level.next();
    }

    player.clampAllSpeeds();
    projectile.applyPropulsion();

    try particle.checkContacts();
    try projectile.checkContacts();
    try projectile.cleanupShrapnel();
    try particle.cleanupParticles();

    try player.processRespawns();

    player.updateAllAnimationStates();
    animation.animate();

    entity.cleanupEntities();
    try player.checkAllSensors();
    try sensor.checkGoal();

    camera.followAllPlayers();
}
