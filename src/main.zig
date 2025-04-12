const sdl = @import("zsdl");
const box2d = @import("box2dnative.zig");
const std = @import("std");

const config = @import("config.zig");
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const init = @import("shared.zig").init;
const shared = @import("shared.zig");
const SharedResources = @import("shared.zig").SharedResources;
const allocator = @import("shared.zig").allocator;
const sensor = @import("sensor.zig");
const time = @import("time.zig");
const fps = @import("fps.zig");

const meters = @import("conversion.zig").meters;
const m2PixelPos = @import("conversion.zig").m2PixelPos;
const m2P = @import("conversion.zig").m2P;

const frictionCallback = @import("friction.zig").frictionCallback;

const debug = @import("debug.zig");

const control = @import("control.zig");

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
//TODO: spawn new level after entering goal
//TODO: create larger level than window and move camera with player
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

pub fn main() !void {
    const resources = try init();

    // clean up
    defer sdl.quit();

    defer sdl.destroyWindow(resources.window);
    defer sdl.destroyRenderer(resources.renderer);

    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    try level.createFromImg(.{ .x = 400, .y = 400 }, resources.levelSurface, shapeDef);

    try player.spawn(.{ .x = 200, .y = 400 });

    try sensor.createGoalSensorFromImg(.{ .x = 700, .y = 550 }, resources.duffSurface);

    box2d.b2World_SetFrictionCallback(resources.worldId, &frictionCallback);

    while (!shared.quitGame and !shared.goalReached) {
        time.frameBegin();
        // const deltaS = @divFloor((currentTime - lastTime), freqMs) * 1000.0;

        // Step Box2D physics world
        while (time.accumulator >= config.physics.dt) {
            box.updateStates();
            box2d.b2World_Step(resources.worldId, config.physics.dt, config.physics.subStepCount);
            time.accumulator -= config.physics.dt;
        }
        time.alpha = time.accumulator / config.physics.dt;

        // Event handling
        var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.EventType.quit => {
                    shared.quitGame = true;
                },
                sdl.EventType.mousebuttondown => {
                    try control.mouseButtonDown(event.button);
                },
                else => {},
            }
        }

        control.handleKeyboardInput();

        player.clampSpeed();

        try player.checkSensors();
        try sensor.checkGoal();

        //draw
        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(resources.renderer);

        try level.draw();
        if (sensor.maybeGoalSensor) |goalSensor| {
            try entity.draw(goalSensor);
        }
        for (entity.entities.values()) |e| {
            try entity.draw(e);
        }
        if (player.player) |p| {
            try entity.draw(p.entity);
        }
        try debug.draw();

        try fps.show();

        sdl.renderPresent(resources.renderer);

        // keep track of time spend per frame
        time.frameEnd();
    }
}
