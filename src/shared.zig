const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");
const ttf = @import("zsdl_ttf");

const box2d = @import("box2dnative.zig");

const time = @import("time.zig");
const debug = @import("debug.zig");
const config = @import("config.zig");
const entity = @import("entity.zig");
const delay = @import("delay.zig");

const lieroImgSrc = "images/liero.png";
const boxImgSrc = "images/box.png";
const starImgSrc = "images/star.png";
const beanImgSrc = "images/bean.png";
const ballImgSrc = "images/ball.png";
const nickiImgSrc = "images/nicki.png";
const levelImgSrc = "images/level.png";
const level2ImgSrc = "images/level2.png";
const duffImgSrc = "images/duff.png";

const monocraftSrc = "fonts/monocraft.ttf";

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
    level2Surface: *sdl.Surface,
    lieroSurface: *sdl.Surface,
    duffSurface: *sdl.Surface,
    monocraftFont: *ttf.Font,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var quitGame = false;
pub var goalReached = false;
pub var editingLevel = false;

pub var maybeResources: ?SharedResources = null;

pub fn getResources() !SharedResources {
    if (maybeResources) |r| {
        return r;
    }
    return SharedResourcesError.Uninitialized;
}

pub fn init() !SharedResources {
    try sdl.init(.{ .audio = true, .video = true, .timer = true });
    time.init();

    try ttf.init();

    const monocraftFont = try ttf.Font.open(monocraftSrc, 16);

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
    const level2Surface = try image.load(level2ImgSrc);
    const lieroSurface = try image.load(lieroImgSrc);
    const duffSurface = try image.load(duffImgSrc);

    // instantiate shared resources
    const s = SharedResources{
        .window = window,
        .renderer = renderer,
        .boxSurface = boxSurface,
        .worldId = worldId,
        .starSurface = starSurface,
        .beanSurface = beanSurface,
        .ballSurface = ballSurface,
        .nickiSurface = nickiSurface,
        .levelSurface = levelSurface,
        .level2Surface = level2Surface,
        .lieroSurface = lieroSurface,
        .duffSurface = duffSurface,
        .monocraftFont = monocraftFont,
    };

    maybeResources = s;

    try debug.init();

    return s;
}

pub fn cleanup() void {
    delay.cleanup();

    if (maybeResources) |resources| {
        box2d.b2DestroyWorld(resources.worldId);
        ttf.Font.close(resources.monocraftFont);
        sdl.destroyRenderer(resources.renderer);
        sdl.destroyWindow(resources.window);
    }
    ttf.quit();
    sdl.quit();

    const deInitStatus = gpa.deinit();
    if (deInitStatus == .leak) @panic("We are leaking memory");
}
