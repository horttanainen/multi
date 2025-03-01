const sdl = @import("zsdl2");
const box2d = @import("box2d").native;
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

const debug = @import("debug.zig");

const keyDown = @import("control.zig").keyDown;
const mouseButtonDown = @import("control.zig").mouseButtonDown;

const entity = @import("entity.zig");
const Entity = entity.Entity;
const Sprite = entity.Sprite;

//TODO: Create level out of image. May need to use segments as in: https://bhopkins.net/pages/mmphysics/
//TODO: spawn player
//TODO: add rudimentary controls
//TODO: add goal collider
//TODO: spawn new level after entering goal
//TODO: create larger level than window and move camera with player

pub fn main() !void {
    const resources = try init();

    // clean up
    defer sdl.quit();

    defer sdl.destroyWindow(resources.window);
    defer sdl.destroyRenderer(resources.renderer);

    // try entity.createFromImg(.{ .x = 300, .y = 200 }, resources.starTexture, resources.starSurface);
    // try entity.createFromImg(.{ .x = 600, .y = 150 }, resources.beanTexture, resources.beanSurface);
    // try entity.createFromImg(.{ .x = 400, .y = 100 }, resources.ballTexture, resources.ballSurface);
    try entity.createFromImg(.{ .x = 700, .y = 0 }, resources.nickiTexture, resources.nickiSurface);
    try entity.createFromImg(.{ .x = 500, .y = 0 }, resources.nickiTexture, resources.nickiSurface);
    try entity.createFromImg(.{ .x = 400, .y = 0 }, resources.nickiTexture, resources.nickiSurface);
    try entity.createFromImg(.{ .x = 200, .y = 0 }, resources.nickiTexture, resources.nickiSurface);

    // Ground (Static Body)
    var groundDef = box2d.b2DefaultBodyDef();
    groundDef.position = meters(5, 1);
    const groundId = box2d.b2CreateBody(resources.worldId, &groundDef);
    const groundBox = box2d.b2MakeBox(5, 0.5);
    const groundShapeDef = box2d.b2DefaultShapeDef();
    _ = box2d.b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);

    const groundSprite = Sprite{ .texture = resources.boxTexture, .dimM = .{ .x = 10, .y = 1 } };

    const timeStep: f32 = 1.0 / 60.0;
    const subStepCount = 4;
    var running = true;

    var debugDraw = box2d.b2DefaultDebugDraw();
    debugDraw.context = &shared.resources;
    debugDraw.DrawSolidPolygon = &debug.drawSolidPolygon;
    debugDraw.DrawPolygon = &debug.drawPolygon;
    debugDraw.DrawSegment = &debug.drawSegment;
    debugDraw.DrawPoint = &debug.drawPoint;
    debugDraw.drawShapes = true;
    debugDraw.drawAABBs = false;
    debugDraw.drawContacts = true;

    while (running) {
        // Event handling
        var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.EventType.quit => {
                    running = false;
                },
                sdl.EventType.keydown => {
                    running = keyDown(event.key);
                },
                sdl.EventType.mousebuttondown => {
                    try mouseButtonDown(event.button);
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(resources.worldId, timeStep, subStepCount);

        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(resources.renderer);

        // Draw ground
        const gPosMeter = box2d.b2Body_GetPosition(groundId);

        const groundPos = m2PixelPos(gPosMeter.x, gPosMeter.y, groundSprite.dimM.x, groundSprite.dimM.y);
        const groundRect = sdl.Rect{
            .x = groundPos.x,
            .y = groundPos.y,
            .w = m2P(groundSprite.dimM.x),
            .h = m2P(groundSprite.dimM.y),
        };
        try sdl.renderCopyEx(resources.renderer, groundSprite.texture, null, &groundRect, 0, null, sdl.RendererFlip.none);

        for (entity.entities.values()) |e| {
            try entity.draw(e);
        }
        box2d.b2World_Draw(resources.worldId, &debugDraw);

        // Debug
        try sdl.setRenderDrawColor(resources.renderer, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
        try sdl.renderDrawLine(resources.renderer, config.window.width / 2, 0, config.window.width / 2, config.window.height);
        sdl.renderPresent(resources.renderer);
    }
}
