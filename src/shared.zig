const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2dnative.zig");
const image = @import("zsdl2_image");

const config = @import("config.zig").config;

const lieroImgSrc = "images/liero.png";
const boxImgSrc = "images/box.png";
const starImgSrc = "images/star.png";
const beanImgSrc = "images/bean.png";
const ballImgSrc = "images/ball.png";
const nickiImgSrc = "images/nicki.png";
const levelImgSrc = "images/level.png";

const SharedResourcesError = error{Uninitialized};

pub const SharedResources = struct {
    worldId: box2d.b2WorldId,
    window: *sdl.Window,
    renderer: *sdl.Renderer,
    boxSurface: *sdl.Surface,
    starSurface: *sdl.Surface,
    beanSurface: *sdl.Surface,
    ballSurface: *sdl.Surface,
    nickiSurface: *sdl.Surface,
    levelSurface: *sdl.Surface,
    lieroSurface: *sdl.Surface,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var quitGame = false;

pub var resources: ?SharedResources = null;

pub fn getResources() !SharedResources {
    if (resources) |r| {
        return r;
    }
    return SharedResourcesError.Uninitialized;
}

pub fn init() !SharedResources {
    try sdl.init(.{ .audio = true, .video = true });

    const window = try sdl.createWindow("My Super Duper Game Window", 0, 0, config.window.width, config.window.height, .{ .opengl = true, .shown = true });

    const renderer = try sdl.createRenderer(window, -1, .{ .accelerated = true, .present_vsync = true });

    const gravity = box2d.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.b2CreateWorld(&worldDef);

    const boxSurface = try image.load(boxImgSrc);
    const starSurface = try image.load(starImgSrc);
    const beanSurface = try image.load(beanImgSrc);
    const ballSurface = try image.load(ballImgSrc);
    const nickiSurface = try image.load(nickiImgSrc);
    const levelSurface = try image.load(levelImgSrc);
    const lieroSurface = try image.load(lieroImgSrc);

    // instantiate shared resources
    const s = SharedResources{ .window = window, .renderer = renderer, .boxSurface = boxSurface, .worldId = worldId, .starSurface = starSurface, .beanSurface = beanSurface, .ballSurface = ballSurface, .nickiSurface = nickiSurface, .levelSurface = levelSurface, .lieroSurface = lieroSurface };

    resources = s;
    return s;
}
