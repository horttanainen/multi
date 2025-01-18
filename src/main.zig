const sdl = @import("zsdl2");
const image = @import("zsdl2_image");
const box2d = @import("box2d").native;
const assert = @import("std").debug.assert;
const print = @import("std").debug.print;
const std = @import("std");

const PI = std.math.pi;
const ArrayList = std.ArrayList;

const boxImgSrc = "images/box.png";

const Config = struct {
    window: struct { width: i32, height: i32 },
    met2pix: i32,
};

const c: Config = .{ .window = .{ .width = 800, .height = 800 }, .met2pix = 80 };

const Sprite = struct { texture: *sdl.Texture, dim: struct {
    w: f32,
    h: f32,
} };

const Point = struct {
    x: i32,
    y: i32,
};

const Object = struct {
    bodyId: box2d.b2BodyId,
    sprite: Sprite,
};

const SharedResources = struct {
    worldId: box2d.b2WorldId,
    renderer: *sdl.Renderer,
    boxTexture: *sdl.Texture,
};

var sharedResources: ?SharedResources = null;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var objects: ArrayList(Object) = ArrayList(Object).init(allocator);

fn createCube(position: Point) void {
    if (sharedResources) |shared| {
        const worldId = shared.worldId;
        const boxTexture = shared.boxTexture;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
        const dynamicBox = box2d.b2MakeBox(0.5, 0.5);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
        const sprite = Sprite{ .texture = boxTexture, .dim = .{ .w = 1, .h = 1 } };

        const object = Object{ .bodyId = bodyId, .sprite = sprite };
        objects.append(object) catch {};
    }
}

fn drawObject(object: Object) !void {
    if (sharedResources) |shared| {
        const renderer = shared.renderer;

        const bodyId = object.bodyId;
        const sprite = object.sprite;
        const boxPosMeter = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);

        const pos = m2PixelPos(boxPosMeter.x, boxPosMeter.y, sprite.dim.w, sprite.dim.h);
        const rect = sdl.Rect{
            .x = pos.x,
            .y = pos.y,
            .w = m2P(sprite.dim.w),
            .h = m2P(sprite.dim.h),
        };
        try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
    }
}

pub fn main() !void {
    try sdl.init(.{ .audio = true, .video = true });
    defer sdl.quit();

    const window = try sdl.createWindow("My Super Duper Game Window", 0, 0, c.window.width, c.window.height, .{ .opengl = true, .shown = true });
    defer sdl.destroyWindow(window);

    const renderer = try sdl.createRenderer(window, -1, .{ .accelerated = true, .present_vsync = true });
    defer sdl.destroyRenderer(renderer);

    // Initialize Box2D World
    const gravity = box2d.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.b2CreateWorld(&worldDef);

    // load box texture
    const boxSurface = try image.load(boxImgSrc);
    const boxTexture = try sdl.createTextureFromSurface(renderer, boxSurface);
    defer sdl.destroyTexture(boxTexture);

    // instantiate shared resources
    sharedResources = SharedResources{ .renderer = renderer, .boxTexture = boxTexture, .worldId = worldId };

    // Ground (Static Body)
    var groundDef = box2d.b2DefaultBodyDef();
    groundDef.position = meters(5, 1);
    const groundId = box2d.b2CreateBody(worldId, &groundDef);
    const groundBox = box2d.b2MakeBox(5, 0.5);
    const groundShapeDef = box2d.b2DefaultShapeDef();
    _ = box2d.b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);

    const groundSprite = Sprite{ .texture = boxTexture, .dim = .{ .w = 10, .h = 1 } };

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
                sdl.EventType.mousebuttondown => {
                    mouseButtonDown(event.button);
                },
                else => {},
            }
        }

        // Step Box2D physics world
        box2d.b2World_Step(worldId, timeStep, subStepCount);

        try sdl.setRenderDrawColor(renderer, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        try sdl.renderClear(renderer);

        // Draw ground
        const gPosMeter = box2d.b2Body_GetPosition(groundId);

        const groundPos = m2PixelPos(gPosMeter.x, gPosMeter.y, groundSprite.dim.w, groundSprite.dim.h);
        const groundRect = sdl.Rect{
            .x = groundPos.x,
            .y = groundPos.y,
            .w = m2P(groundSprite.dim.w),
            .h = m2P(groundSprite.dim.h),
        };
        try sdl.renderCopyEx(renderer, groundSprite.texture, null, &groundRect, 0, null, sdl.RendererFlip.none);

        for (objects.items) |object| {
            try drawObject(object);
        }

        // Debug
        try sdl.setRenderDrawColor(renderer, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
        try sdl.renderDrawLine(renderer, c.window.width / 2, 0, c.window.width / 2, c.window.height);
        sdl.renderPresent(renderer);
    }
}

fn mouseButtonDown(event: sdl.MouseButtonEvent) void {
    print("Click!!", .{});
    createCube(.{ .x = event.x, .y = event.y });
}

fn m2PixelPos(x: f32, y: f32, w: f32, h: f32) Point {
    return Point{
        .x = @as(i32, @intFromFloat(((w / 2.0) + x) * c.met2pix - c.met2pix * w)),
        .y = @as(i32, @intFromFloat(((h / 2.0) + y) * c.met2pix - c.met2pix * h / 2.0)),
    };
}

fn p2m(p: Point) box2d.b2Vec2 {
    return box2d.b2Vec2{ .x = @as(f32, @floatFromInt(p.x)) / c.met2pix, .y = @as(f32, @floatFromInt(p.y)) / c.met2pix };
}

fn meters(x: f32, y: f32) box2d.b2Vec2 {
    return box2d.b2Vec2{ .x = x, .y = (c.window.height / c.met2pix) - y };
}

fn m2Pixel(
    coord: box2d.b2Vec2,
) Point {
    return .{ .x = @as(i32, @intFromFloat(coord.x * c.met2pix)), .y = @as(i32, @intFromFloat(coord.y * c.met2pix)) };
}
fn m2P(x: f32) i32 {
    return @as(i32, @intFromFloat(x * c.met2pix));
}
