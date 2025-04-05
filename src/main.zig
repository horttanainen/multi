const sdl = @import("zsdl2");
const box2d = @import("box2dnative.zig");
const std = @import("std");

const config = @import("config.zig").config;
const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;
const init = @import("shared.zig").init;
const shared = @import("shared.zig");
const SharedResources = @import("shared.zig").SharedResources;
const allocator = @import("shared.zig").allocator;

const meters = @import("conversion.zig").meters;
const m2PixelPos = @import("conversion.zig").m2PixelPos;
const m2P = @import("conversion.zig").m2P;

const frictionCallback = @import("friction.zig").frictionCallback;

const debug = @import("debug.zig");

const control = @import("control.zig");

const player = @import("player.zig");

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
//TODO: add goal collider
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

    const timeStep: f32 = 1.0 / 60.0;
    const subStepCount = 4;

    var debugDraw = box2d.b2DefaultDebugDraw();
    debugDraw.context = &shared.resources;
    debugDraw.DrawSolidPolygon = &debug.drawSolidPolygon;
    debugDraw.DrawPolygon = &debug.drawPolygon;
    debugDraw.DrawSegment = &debug.drawSegment;
    debugDraw.DrawPoint = &debug.drawPoint;
    debugDraw.drawShapes = true;
    debugDraw.drawAABBs = false;
    debugDraw.drawContacts = true;
    debugDraw.drawFrictionImpulses = true;

    box2d.b2World_SetFrictionCallback(resources.worldId, &frictionCallback);

    while (!shared.quitGame) {
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

        // Step Box2D physics world
        box2d.b2World_Step(resources.worldId, timeStep, subStepCount);
        player.clampSpeed();

        try player.checkSensors();

        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(resources.renderer);

        try level.draw();
        for (entity.entities.values()) |e| {
            try entity.draw(e);
        }
        if (player.player) |p| {
            try entity.draw(p.entity);
        }
        box2d.b2World_Draw(resources.worldId, &debugDraw);

        // Debug
        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 255, .g = 0, .b = 255, .a = 255 });
        try sdl.renderDrawLine(resources.renderer, config.window.width / 2, 0, config.window.width / 2, config.window.height);
        try sdl.renderDrawLine(resources.renderer, 0, config.window.height - (config.window.height / 10), config.window.width, config.window.height - (config.window.height / 10));
        sdl.renderPresent(resources.renderer);
    }
}
