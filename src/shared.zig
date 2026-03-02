const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");

const box2d = @import("box2d.zig");

const time = @import("time.zig");
const debug = @import("debug.zig");
const window = @import("window.zig");
const entity = @import("entity.zig");
const delay = @import("delay.zig");
const audio = @import("audio.zig");
const camera = @import("camera.zig");
const viewport = @import("viewport.zig");

pub const crosshairImgSrc = "images/crosshair.png";
pub const lieroImgSrc = "images/liero.png";
pub const boxImgSrc = "images/box.png";
pub const cannonBallmgSrc = "images/cannonball.png";
pub const nickiImgSrc = "images/nicki.png";
pub const starImgSrc = "images/star.png";

const monocraftSrc = "fonts/monocraft.ttf";

const SharedResourcesError = error{Uninitialized};

pub const SharedResources = struct {
    worldId: box2d.c.b2WorldId,
    renderer: *gpu.Renderer,
    monocraftFont: *sdl.Font,
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
    time.init();
    try audio.init();

    try sdl.ttf.init();

    const monocraftFont = try sdl.ttf.openFont(monocraftSrc, 24);

    const sdlWindow = try window.getWindow();
    const renderer = try gpu.createRenderer(sdlWindow);

    const gravity = box2d.c.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.c.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.c.b2CreateWorld(&worldDef);

    // instantiate shared resources
    const s = SharedResources{
        .renderer = renderer,
        .worldId = worldId,
        .monocraftFont = monocraftFont,
    };

    maybeResources = s;

    try debug.init();

    return s;
}

pub fn cleanup() void {
    delay.cleanup();
    audio.cleanup();
    camera.cleanup();
    viewport.cleanup();

    if (maybeResources) |resources| {
        box2d.c.b2DestroyWorld(resources.worldId);
        sdl.ttf.closeFont(resources.monocraftFont);
        gpu.destroyRenderer(resources.renderer);
    }
    sdl.ttf.quit();

    const deInitStatus = gpa.deinit();
    if (deInitStatus == .leak) @panic("We are leaking memory");
}
