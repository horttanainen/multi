const box2d = @import("box2d.zig");
const std = @import("std");

const config = @import("config.zig");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const allocator = @import("allocator.zig");
const state = @import("state.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const sprite = @import("sprite.zig");
const sensor = @import("sensor.zig");
const time = @import("time.zig");
const renderer = @import("renderer.zig");
const physics = @import("physics.zig");
const input = @import("input.zig");
const camera = @import("camera.zig");
const animation = @import("animation.zig");

const audio = @import("audio.zig");
const delay = @import("delay.zig");
const viewport = @import("viewport.zig");
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
const projectile = @import("projectile.zig");
const particle = @import("particle.zig");
const gibbing = @import("gibbing.zig");
const data = @import("data.zig");
const window = @import("window.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//Small improvements
//TODO: use allyourbase box2d instead of shitty submodule
//TODO: wrap box2d calls so that we do not have to pass worldId
//TODO: make main function deinit explicit instead of the deffered reverse order deinit
//TODO: investigate why aiming is so snappy
//TODO: investigate if it would be simpler to migrate to sdl_audio
//TODO: getptrlocking and getlocking do not make sense. The locking needs to happen on the outside and release after mutations
//TODO: instead of all the silly playerId indexing start using real uids for players and a map.
//TODO: damagePlayersInRadius should use box2d circle collider to check if players are in the radius. It is basically the same as damageTerrainInRadius.
//TODO: refactor sensor stuff into regular entities

//Gun ideas
//TODO: add transparent smoke trail for the rocket
//TODO: add rounds pistol with the glow and spark effect and heavy drop
//TODO: enable ricochets for some slugs
//TODO: make slug glow configurable
//TODO: add green pixel to gun for bullet spawn anchor point

//TODO: rope combo: shoot rocket with rope attached and then shoot hook to attach the rocket to e.g. enemy player
//TODO: chain rocket gun: shoots a rocket with a box2d chain attached to it. Detachhing causes a chain with a hook to fly behind the rocket. Hook can attach to player
//TODO: travel rocket: large slow moving rocket on top which player can jump or attach via rope.
//TODO: mast breaker: shoot two spike balls with a chain between
//TODO: whale harpoon: giant spike with a chain that you can reel in
//TODO: hawking space warp: create a shortlived powerful blackhole which starts to break level around it and pull towards it
//TODO: portal gun
//TODO: Dig2000 for melee and quick digging
//TODO: grenade launcher with different kinds of grenades

//Level ideas:
//TODO: nothing: physics and gun is set so that both players need to shoot down from time to time to levitate and then of course shoot each other
//TODO: breakfloor: all stuff dangle and you can shoot boxes in the ropes to make the platforms fall down
//TODO: e.g. different levels can have different camera distances
//TODO: create a rounds style 1v1 level with single camera

//Quake style:
//TODO: add item.zig that spawns items on the map
//TODO: add weapon item sprites so that weapons can be picked up
//TODO: display weapons name above it
//TODO: weapons could levitate on top of some reverse spawn thingy in pulsating light

//Spawn:
//TODO: add two or more spawn locations to the map
//TODO: spawn should be a levitating teleport thingy
//TODO: spawn should materialize player with some beaming effect

//Fun stuff:
//TODO: display a laughing skull on death
//TODO: buy rounds game and steal their ideas
//TODO: towerfall is game that we can copy ideas from
//TODO: instead of hook the mechanical hand could be shot with a chain/rope
//TODO: niddhog style 1 v 1 or 2 v 2 or 4 deatmatch tournament, level changes after each match
//TODO: we could have different gamemodes: rounds, liero, quake, soldat, towerfall, super meat boy

//Movement
//TODO: character could be able to grab wall by hand
//TODO: add dash to side
//TODO: add sliding
//TODO: add slope sliding
//TODO: try if movement vector should be to the direction of slope character is standing on

//Character
//TODO: Create jumping animation 
//TODO: Create landing animation
//TODO: Create sliding animation
//TODO: Create wall slide animation that is played when player touches wall 

//Items to pick up
//TODO: jetpack
//TODO: short teleport
//TODO: health
//TODO: piercing rocket launcher ammo
//TODO: shrapnel rocket launcher ammo

//Music
//TODO: There should be basic music fitting the deathmatch theme of the game
//TODO: music can be turned off

//Multiplayer:
//TODO: add localhost multiplayer
//TODO: investigate how to sync games when running on different machines
//TODO: add real multiplayer
//TODO: read https://mas-bandwidth.com/what-is-lag/
//TODO: read https://mas-bandwidth.com/choosing-the-right-network-model-for-your-multiplayer-game/
//TODO: read https://gafferongames.com/post/deterministic_lockstep/

//Bugs:
//TODO: Level json creation broke during 0.15 update

pub fn main() !void {
    try window.init();
    time.init();
    try audio.init();
    try gpu.init(try window.getWindow());
    try text.init();
    box2d.initWorld();
    try debug.init();
    try data.init();
    try rope.init();
    try controller.init();
    try keyboard.init();
    try camera.spawn(.{ .x = 0, .y = 0 });
    try gibbing.init();
    try level.next();

    box2d.c.b2World_SetFrictionCallback(box2d.getWorldId(), &friction.callback);

    while (!state.quitGame) {
        time.frameBegin();
        try physics.step();
        try input.handle();

        if (state.editingLevel) {
            levelEditorLoop();
        } else {
            try gameLoop();
        }

        try renderer.render();
        time.frameEnd();
    }

    // Explicit shutdown in reverse init order
    levelEditor.cleanup() catch |err| {
        std.debug.print("Error cleaning up created level folders: {}\n", .{err});
    };
    particle.cleanup();
    level.cleanup();
    gibbing.cleanup();
    gamepad.cleanup();
    keyboard.cleanup();
    controller.cleanup();
    rope.cleanup();
    data.cleanup();
    sprite.deinit();
    delay.cleanup();
    camera.cleanup();
    viewport.cleanup();
    box2d.destroyWorld();
    text.cleanup();
    gpu.cleanup();
    audio.cleanup();
    window.cleanup();
    allocator.deinit();
}

fn levelEditorLoop() void {
    camera.followKeyboard();
}

fn gameLoop() !void {
    if (state.goalReached) {
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
