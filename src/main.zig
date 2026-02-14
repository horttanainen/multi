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
const rope = @import("rope.zig");

const level = @import("level.zig");
const levelEditor = @import("leveleditor.zig");
const entity = @import("entity.zig");
const sprite = @import("sprite.zig");
const projectile = @import("projectile.zig");
const particle = @import("particle.zig");
const gibbing = @import("gibbing.zig");
const window = @import("window.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//TODO: keep score
//TODO: make gun a bit longer
//TODO: make character grab gun with chainsaw grip
//TODO: draw another sprite with arm more extended and use that when pointing downwards
//TODO: change shoulder anchor point when facing other direction. This needs additional anchor point
//TODO: Add anchorpoints to all animations
//TODO: camera should travel with the crosshair

//TODO: getptrlocking and getlocking do not make sense. The locking needs to happen on the outside and release after mutations
//TODO: add transparent smoke trail for the rocket
//TODO: ninja rope attach: can shorten rope to attach without dangling; "clinging"
//TODO: change ninja rope attach point to not be in the crotch

//Gun ideas
//TODO: rope combo: shoot rocket with rope attached and then shoot hook to attach the rocket to e.g. enemy player
//TODO: chain rocket gun: shoots a rocket with a box2d chain attached to it. Detachhing causes a chain with a hook to fly behind the rocket. Hook can attach to player
//TODO: travel rocket: large slow moving rocket on top which player can jump or attach via rope.
//TODO: mast breaker: shoot two spike balls with a chain between
//TODO: whale harpoon: giant spike with a chain that you can reel in
//TODO: hawking space warp: create a shortlived powerful blackhole which starts to break level around it and pull towards it
//TODO: portal gun
//TODO: Dig2000 for melee and quick digging
//TODO: grenade launcher with different kinds of grenades

//TODO: add dash to side

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

pub fn main() !void {
    try window.init();
    defer window.cleanup();

    const resources = try shared.init();
    defer shared.cleanup();

    defer sprite.deinit();

    try rope.init();
    defer rope.cleanup();

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

    try rope.checkHookContacts();
    rope.applyTension();

    try particle.checkContacts();
    try projectile.checkContacts();
    try projectile.cleanupShrapnel();
    try particle.cleanupParticles();

    try player.processRespawns();

    player.updateAllAnimationStates();
    animation.animate();

    entity.cleanupEntities();
    sprite.cleanupSprites();
    try player.checkAllSensors();
    try sensor.checkGoal();

    camera.followAllPlayers();
}
