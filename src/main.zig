const sdl2 = @cImport({
    @cInclude("SDL2/SDL.h");
});
const box2d = @import("box2d").native;
const assert = @import("std").debug.assert;

pub fn main() !void {
    if (sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO) != 0) {
        sdl2.SDL_Log("Unable to initialize SDL: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer sdl2.SDL_Quit();

    const window = sdl2.SDL_CreateWindow("My Super Duper Game Window", sdl2.SDL_WINDOWPOS_UNDEFINED, sdl2.SDL_WINDOWPOS_UNDEFINED, 800, 600, sdl2.SDL_WINDOW_OPENGL | sdl2.SDL_WINDOW_SHOWN) orelse
        {
        sdl2.SDL_Log("Unable to create window: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl2.SDL_DestroyWindow(window);

    const renderer = sdl2.SDL_CreateRenderer(window, -1, sdl2.SDL_RENDERER_ACCELERATED | sdl2.SDL_RENDERER_PRESENTVSYNC) orelse {
        sdl2.SDL_Log("Unable to create renderer: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl2.SDL_DestroyRenderer(renderer);

    const level_bmp = @embedFile("level.bmp");
    const rw = sdl2.SDL_RWFromConstMem(level_bmp, level_bmp.len) orelse {
        sdl2.SDL_Log("Unable to get RWFromConstMem: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer assert(sdl2.SDL_RWclose(rw) == 0);

    const zig_surface = sdl2.SDL_LoadBMP_RW(rw, 0) orelse {
        sdl2.SDL_Log("Unable to load bmp: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl2.SDL_FreeSurface(zig_surface);

    const zig_texture = sdl2.SDL_CreateTextureFromSurface(renderer, zig_surface) orelse {
        sdl2.SDL_Log("Unable to create texture from surface: %s", sdl2.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl2.SDL_DestroyTexture(zig_texture);

    // Initialize Box2D World
    const gravity = box2d.b2Vec2{ .x = 0.0, .y = 9.8 };
    var worldDef = box2d.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.b2CreateWorld(&worldDef);

    // Ground (Static Body)
    var groundDef = box2d.b2DefaultBodyDef();
    groundDef.position = wCoordToBox2d(0.0, 550.0);
    const groundId = box2d.b2CreateBody(worldId, &groundDef);
    const groundBox = box2d.b2MakeBox(wLengthToBox2d(800.0), wLengthToBox2d(50.0));
    const groundShapeDef = box2d.b2DefaultShapeDef();
    _ = box2d.b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);

    // Falling Box (Dynamic Body)
    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_dynamicBody;
    bodyDef.position = wCoordToBox2d(400, 0.0);
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    const dynamicBox = box2d.b2MakeBox(wLengthToBox2d(50.0), wLengthToBox2d(50.0));
    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.density = 1.0;
    shapeDef.friction = 0.3;
    _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const timeStep: f32 = 1.0 / 60.0;
    const subStepCount = 4;
    var running = true;

    while (running) {
        // Event handling
        var event: sdl2.SDL_Event = undefined;
        while (sdl2.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl2.SDL_QUIT => {
                    running = false;
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(worldId, timeStep, subStepCount);

        // Render
        _ = sdl2.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255); // Black background
        _ = sdl2.SDL_RenderClear(renderer);

        const groundPositionBox2d = box2d.b2Body_GetPosition(groundId);
        const groundPositionW = box2dCoordToW(groundPositionBox2d);

        // Draw ground
        _ = sdl2.SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255); // Green ground
        var groundRect = sdl2.SDL_Rect{
            .x = groundPositionW.x,
            .y = groundPositionW.y,
            .w = 800,
            .h = 50,
        };
        _ = sdl2.SDL_RenderFillRect(renderer, &groundRect);

        const boxPositionBox2d = box2d.b2Body_GetPosition(bodyId);
        const boxPositionW = box2dCoordToW(boxPositionBox2d);

        _ = sdl2.SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255); // Red box
        var boxRect = sdl2.SDL_Rect{
            .x = boxPositionW.x,
            .y = boxPositionW.y,
            .w = 50.0,
            .h = 50.0,
        };
        _ = sdl2.SDL_RenderFillRect(renderer, &boxRect);

        sdl2.SDL_RenderPresent(renderer);
    }
}

const pixelScale = 50.0;
fn wCoordToBox2d(x: f32, y: f32) box2d.b2Vec2 {
    return box2d.b2Vec2{ .x = wLengthToBox2d(x), .y = wLengthToBox2d(y) };
}
fn wLengthToBox2d(x: f32) f32 {
    return x / pixelScale;
}

const Point = struct {
    x: i32,
    y: i32,
};
fn box2dCoordToW(coord: box2d.b2Vec2) Point {
    return .{ .x = @as(i32, @intFromFloat(coord.x * pixelScale)), .y = @as(i32, @intFromFloat(coord.y * pixelScale)) };
}
