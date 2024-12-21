const sdl = @import("zsdl2");
const image = @import("zsdl2_image");
const box2d = @import("box2d").native;
const assert = @import("std").debug.assert;
const print = @import("std").debug.print;
const PI = @import("std").math.pi;

const boxImgSrc = "images/box.png";

pub fn main() !void {
    try sdl.init(.{ .audio = true, .video = true });
    defer sdl.quit();

    const window = try sdl.createWindow("My Super Duper Game Window", 0, 0, 800, 600, .{ .opengl = true, .shown = true });
    defer sdl.destroyWindow(window);

    const renderer = try sdl.createRenderer(window, -1, .{ .accelerated = true, .present_vsync = true });
    defer sdl.destroyRenderer(renderer);

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

    const boxSurface = try image.load(boxImgSrc);

    print("surface width: {} height: {}\n", .{ boxSurface.w, boxSurface.h });

    const boxTexture = try sdl.createTextureFromSurface(renderer, boxSurface);
    defer sdl.destroyTexture(boxTexture);

    var width: i32 = 0;
    var height: i32 = 0;
    try sdl.queryTexture(boxTexture, null, null, &width, &height);
    print("texture width: {} height: {}\n", .{ width, height });

    var bodyDef = box2d.b2DefaultBodyDef();
    bodyDef.type = box2d.b2_dynamicBody;
    bodyDef.position = wCoordToBox2d(400, 0.0);
    const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
    box2d.b2Body_SetAngularVelocity(bodyId, 1.0);
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
        var event: sdl.Event = .{ .type = sdl.EventType.firstevent };
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.EventType.quit => {
                    running = false;
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(worldId, timeStep, subStepCount);

        try sdl.renderClear(renderer);

        const groundPositionBox2d = box2d.b2Body_GetPosition(groundId);
        const groundPositionW = box2dCoordToW(groundPositionBox2d);

        // Draw ground
        try sdl.setRenderDrawColor(renderer, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
        const groundRect = sdl.Rect{
            .x = groundPositionW.x,
            .y = groundPositionW.y,
            .w = 800,
            .h = 50,
        };
        try sdl.renderFillRect(renderer, groundRect);

        const boxPositionBox2d = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);
        const boxPositionW = box2dCoordToW(boxPositionBox2d);
        print("box2d: \t{d} \t{d} \t{d}\n", .{ boxPositionBox2d.x, boxPositionBox2d.y, rotationAngle * 180.0 / PI });
        // print("w: {d} {d} {d}\n", .{ boxPositionW.x, boxPositionW.y, rotationAngle * 180.0 / PI });
        print("ground: \t{d} \t{d} \t{d}\n", .{ groundPositionBox2d.x, groundPositionBox2d.y, rotationAngle * 180.0 / PI });

        try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });

        const boxRect = sdl.Rect{
            .x = boxPositionW.x,
            .y = boxPositionW.y,
            .w = 50,
            .h = 50,
        };
        // platform.x = ((SCALED_WIDTH / 2.0f) + x_plat) * MET2PIX - platform.w / 2;
        // platform.y = ((SCALED_HEIGHT / 2.0f) + y_plat) * MET2PIX - platform.h / 2;

        try sdl.renderCopyEx(renderer, boxTexture, null, &boxRect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);

        sdl.renderPresent(renderer);
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
fn box2dLengthToW(x: i32) i32 {
    return x * @as(i32, pixelScale);
}
