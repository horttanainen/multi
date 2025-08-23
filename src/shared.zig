const std = @import("std");
const sdl = @import("zsdl");
const image = @import("zsdl_image");
const ttf = @import("zsdl_ttf");

const box2d = @import("box2d.zig");

const time = @import("time.zig");
const debug = @import("debug.zig");
const config = @import("config.zig");
const entity = @import("entity.zig");
const delay = @import("delay.zig");
const audio = @import("audio.zig");

pub const crosshairImgSrc = "images/crosshair.png";
pub const lieroImgSrc = "images/liero.png";
pub const boxImgSrc = "images/box.png";
pub const cannonBallmgSrc = "images/cannonball.png";
pub const nickiImgSrc = "images/nicki.png";
pub const starImgSrc = "images/star.png";
const duffImgSrc = "images/duff.png";

const monocraftSrc = "fonts/monocraft.ttf";

const SharedResourcesError = error{Uninitialized};

pub const SharedResources = struct {
    worldId: box2d.c.b2WorldId,
    window: *sdl.Window,
    renderer: *sdl.Renderer,
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
    try audio.init();

    try ttf.init();

    const monocraftFont = try ttf.Font.open(monocraftSrc, 16);

    const window = try sdl.createWindow("My Super Duper Game Window", 2000, 0, config.window.width, config.window.height, .{ .opengl = true, .shown = true });

    const renderer = try sdl.createRenderer(window, null, .{ .accelerated = true, .present_vsync = true });

    const gravity = box2d.c.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.c.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.c.b2CreateWorld(&worldDef);

    const duffSurface = try image.load(duffImgSrc);

    // instantiate shared resources
    const s = SharedResources{
        .window = window,
        .renderer = renderer,
        .worldId = worldId,
        .duffSurface = duffSurface,
        .monocraftFont = monocraftFont,
    };

    maybeResources = s;

    try debug.init();

    return s;
}

pub fn cleanup() void {
    delay.cleanup();
    audio.cleanup();

    if (maybeResources) |resources| {
        box2d.c.b2DestroyWorld(resources.worldId);
        ttf.Font.close(resources.monocraftFont);
        sdl.destroyRenderer(resources.renderer);
        sdl.destroyWindow(resources.window);
    }
    ttf.quit();
    sdl.quit();

    const deInitStatus = gpa.deinit();
    if (deInitStatus == .leak) @panic("We are leaking memory");
}
