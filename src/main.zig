const box2d = @import("box2d.zig");
const std = @import("std");
const sdl = @import("sdl.zig");
const runtime = @import("runtime.zig");

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
const music = @import("music.zig");
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
const levelEditor = @import("level_editor.zig");
const lut = @import("lut.zig");
const settings = @import("settings.zig");
const cursor = @import("cursor.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const particle = @import("particle.zig");
const blood = @import("blood.zig");
const perf = @import("perf.zig");
const background_paint = @import("background_paint.zig");
const backgroundConfigMenu = @import("backgroundConfigMenu.zig");
const musicConfigMenu = @import("musicConfigMenu.zig");
const gibbing = @import("gibbing.zig");
const data = @import("data.zig");
const window = @import("window.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//Level editor
//TODO: add option to turn the colliders on so that objects can not be placed on top of each other
//TODO: add option to draw a rectangle which becames an entity in the game with some magenta prefill
//TODO: add option to change texture of entity
//TODO: add option to fill entity with texture tiling
//TODO: add option to fill entity with stretched texture
//TODO: make it possible to stretch existing entities
//TODO: allow for selecting if entity is breakable or not
//TODO: allow for setting the scale of entity
//TODO: allow for copying existing entities
//TODO: allow for creating chain connected objects
//TODO: allow for connecting dynamic objects with a joint (e.g a fellable tree that is connected to ground with a joint)

//Small improvements
//TODO: make blood droplets much smaller and realistic.
//TODO: blood stains should be uneven not perfect circles
//TODO: explosion holes should be uneven not perfect circles
//TODO: explosions should char the hole and terrain surface around them
//TODO: add bones sticking out of giblets
//TODO: find out which giblets can not be made into box2d objects and fix them
//TODO: make settings.zig use data.zig to read the json
//TODO: getptrlocking and getlocking do not make sense. The locking needs to happen on the outside and release after mutations
//TODO: instead of all the silly playerId indexing start using real uids for players and a map.
//TODO: damagePlayersInRadius should use box2d circle collider to check if players are in the radius. It is basically the same as damageTerrainInRadius.

//Gun ideas
//TODO: add rounds pistol with the glow and spark effect and heavy drop
//TODO: enable ricochets for some slugs
//TODO: make slug glow configurable
//TODO: add green pixel to gun for bullet spawn anchor point
//TODO: add transparent smoke trail for the rocket

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
//TODO: level where two balls hang via rope that can be broken via bullet Each players spawn is on the each ball

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
//TODO: music can be turned off
//TODO: should be able to play music from a specified location on fs.

//Multiplayer:
//TODO: add localhost multiplayer
//TODO: investigate how to sync games when running on different machines
//TODO: add real multiplayer
//TODO: read https://mas-bandwidth.com/what-is-lag/
//TODO: read https://mas-bandwidth.com/choosing-the-right-network-model-for-your-multiplayer-game/
//TODO: read https://gafferongames.com/post/deterministic_lockstep/

fn smokeTestTimerCallback(_: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    std.log.info("Ran successfully for 5 seconds", .{});
    return 0;
}

pub fn main(init: std.process.Init) !void {
    runtime.init(init.io);

    try window.init();
    time.init();
    try audio.init();
    try music.init();
    try gpu.init(try window.getWindow());
    background_paint.init();
    try text.init();
    box2d.initWorld();
    try debug.init();
    try data.init();
    try particle.init("particles/circle.png");
    try blood.init();
    try settings.init();
    settings.applyMusic();
    try lut.init();
    settings.apply();
    settings.applyBackgroundPreset();
    try rope.init();
    try controller.init();
    try keyboard.init();
    try camera.spawn(.{ .x = 0, .y = 0 });
    try gibbing.init();
    gpu.saveAtlasCheckpoint();
    try level.next();

    box2d.setFrictionCallback(&friction.callback);
    _ = sdl.addTimer(5000, smokeTestTimerCallback, null);

    while (!state.quitGame) {
        const collectFramePerf = projectile.shouldCollectPerfFrameLog();
        const framePerfStart = if (collectFramePerf) perf.begin(.explosion) else 0;
        const playerDeathFrameStart = perf.beginPlayerDeathFrame();

        time.frameBegin();

        const physicsStart = if (collectFramePerf) perf.begin(.explosion) else 0;
        const playerDeathPhysicsStart = perf.begin(.player_death);
        try physics.step();
        perf.recordPlayerDeathFrameStage(.physics, playerDeathPhysicsStart);
        const physicsUs = perf.elapsedUs(physicsStart);

        const inputStart = if (collectFramePerf) perf.begin(.explosion) else 0;
        const playerDeathInputStart = perf.begin(.player_death);
        try input.handle();
        perf.recordPlayerDeathFrameStage(.input, playerDeathInputStart);
        const inputUs = perf.elapsedUs(inputStart);

        const logicStart = if (collectFramePerf) perf.begin(.explosion) else 0;
        const playerDeathLogicStart = perf.begin(.player_death);
        if (state.editingBackground) {
            backgroundConfigMenu.sync();
        } else if (state.editingLevel) {
            levelEditorLoop();
        } else if (state.editingMusic) {
            musicConfigMenu.sync();
        } else {
            try gameLoop();
        }
        perf.recordPlayerDeathFrameStage(.logic, playerDeathLogicStart);
        const logicUs = perf.elapsedUs(logicStart);

        const renderStart = if (collectFramePerf) perf.begin(.explosion) else 0;
        const playerDeathRenderStart = perf.begin(.player_death);
        try renderer.render();
        perf.recordPlayerDeathFrameStage(.render, playerDeathRenderStart);
        const renderUs = perf.elapsedUs(renderStart);

        time.frameEnd();

        if (projectile.consumePerfFrameLog()) {
            perf.log(
                .explosion,
                "perf.frame total_us={d} physics_us={d} input_us={d} logic_us={d} render_us={d} pending_texture={d} pending_collider={d}",
                .{
                    perf.elapsedUs(framePerfStart),
                    physicsUs,
                    inputUs,
                    logicUs,
                    renderUs,
                    projectile.pendingTerrainTextureUpdateCount(),
                    projectile.pendingTerrainColliderUpdateCount(),
                },
            );
        }

        perf.finishPlayerDeathFrame(playerDeathFrameStart);
    }

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
    lut.cleanup();
    settings.cleanup();
    data.cleanup();
    sprite.deinit();
    delay.cleanup();
    camera.cleanup();
    viewport.cleanup();
    box2d.destroyWorld();
    text.cleanup();
    gpu.cleanup();
    music.cleanup();
    audio.cleanup();
    window.cleanup();
    allocator.deinit();
}

fn levelEditorLoop() void {
    renderer.updateZoom();
    cursor.cameraFollow();
}

fn gameLoop() !void {
    if (state.goalReached) {
        try level.next();
    }

    player.clampAllSpeeds();
    projectile.applyPropulsion();

    const terrainUpdatesStart = perf.begin(.player_death);
    projectile.processTerrainTextureUpdates();
    projectile.processTerrainColliderUpdates();
    perf.recordPlayerDeathGameLoopStage(.terrain_updates, terrainUpdatesStart);

    const ropeStart = perf.begin(.player_death);
    try rope.checkHookContacts();
    rope.applyTension();
    perf.recordPlayerDeathGameLoopStage(.rope, ropeStart);

    const bloodContactsStart = perf.begin(.player_death);
    try particle.checkContacts();
    perf.recordPlayerDeathGameLoopStage(.blood_contacts, bloodContactsStart);

    const bloodTextureStart = perf.begin(.player_death);
    particle.processStainTextureUpdates();
    perf.recordPlayerDeathGameLoopStage(.blood_texture, bloodTextureStart);

    const gibletContactsStart = perf.begin(.player_death);
    try gibbing.checkContacts();
    perf.recordPlayerDeathGameLoopStage(.giblet_contacts, gibletContactsStart);

    const projectileContactsStart = perf.begin(.player_death);
    try projectile.checkContacts();
    perf.recordPlayerDeathGameLoopStage(.projectile_contacts, projectileContactsStart);

    const cleanupStart = perf.begin(.player_death);
    try projectile.cleanupShrapnel();
    try particle.cleanupParticles();
    perf.recordPlayerDeathGameLoopStage(.cleanup, cleanupStart);

    const playerAndSensorStart = perf.begin(.player_death);
    try player.processRespawns();
    perf.recordPlayerDeathGameLoopStage(.player_and_sensor, playerAndSensorStart);

    const animationAndCameraStart = perf.begin(.player_death);
    player.updateAllAnimationStates();
    animation.animate();
    perf.recordPlayerDeathGameLoopStage(.animation_and_camera, animationAndCameraStart);

    const entityCleanupStart = perf.begin(.player_death);
    entity.cleanupEntities();
    sprite.cleanupSprites();
    perf.recordPlayerDeathGameLoopStage(.cleanup, entityCleanupStart);

    const sensorStart = perf.begin(.player_death);
    try player.checkAllSensors();
    try sensor.processSensorEvents();
    perf.recordPlayerDeathGameLoopStage(.player_and_sensor, sensorStart);

    const cameraStart = perf.begin(.player_death);
    renderer.updateZoom();
    camera.followAllPlayers(renderer.zoom);
    perf.recordPlayerDeathGameLoopStage(.animation_and_camera, cameraStart);
}
