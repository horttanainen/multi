const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2d").native;
const image = @import("zsdl2_image");

const config = @import("config.zig").config;

const boxImgSrc = "images/box.png";
const starImgSrc = "images/star.png";
const beanImgSrc = "images/bean.png";
const ballImgSrc = "images/ball.png";
const nickiImgSrc = "images/nicki.png";

pub const SharedResources = struct {
    worldId: box2d.b2WorldId,
    window: *sdl.Window,
    renderer: *sdl.Renderer,
    boxTexture: *sdl.Texture,
    starTexture: *sdl.Texture,
    starSurface: *sdl.Surface,
    beanTexture: *sdl.Texture,
    beanSurface: *sdl.Surface,
    ballTexture: *sdl.Texture,
    ballSurface: *sdl.Surface,
    nickiTexture: *sdl.Texture,
    nickiSurface: *sdl.Surface,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var resources: ?SharedResources = null;

pub fn init() !SharedResources {
    try sdl.init(.{ .audio = true, .video = true });

    const window = try sdl.createWindow("My Super Duper Game Window", 0, 0, config.window.width, config.window.height, .{ .opengl = true, .shown = true });

    const renderer = try sdl.createRenderer(window, -1, .{ .accelerated = true, .present_vsync = true });

    const gravity = box2d.b2Vec2{ .x = 0.0, .y = 10 };
    var worldDef = box2d.b2DefaultWorldDef();
    worldDef.gravity = gravity;
    const worldId = box2d.b2CreateWorld(&worldDef);

    // load box texture
    const boxSurface = try image.load(boxImgSrc);
    const boxTexture = try sdl.createTextureFromSurface(renderer, boxSurface);

    // load star texture
    const starSurface = try image.load(starImgSrc);
    const starTexture = try sdl.createTextureFromSurface(renderer, starSurface);

    // load bean texture
    const beanSurface = try image.load(beanImgSrc);
    const beanTexture = try sdl.createTextureFromSurface(renderer, beanSurface);

    // load ball texture
    const ballSurface = try image.load(ballImgSrc);
    const ballTexture = try sdl.createTextureFromSurface(renderer, ballSurface);

    // load nicki texture
    const nickiSurface = try image.load(nickiImgSrc);
    const nickiTexture = try sdl.createTextureFromSurface(renderer, nickiSurface);

    // instantiate shared resources
    const s = SharedResources{ .window = window, .renderer = renderer, .boxTexture = boxTexture, .worldId = worldId, .starTexture = starTexture, .beanTexture = beanTexture, .ballTexture = ballTexture, .starSurface = starSurface, .beanSurface = beanSurface, .ballSurface = ballSurface, .nickiSurface = nickiSurface, .nickiTexture = nickiTexture };
    resources = s;
    return s;
}
