const box2d = @import("box2d").native;
const sdl = @import("zsdl2");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const box = @import("box.zig");

const p2m = @import("conversion.zig").p2m;

const IVec2 = @import("vector.zig").IVec2;

pub const Player = struct {
    entity: entity.Entity,
};

pub var player: ?Player = null;

pub fn spawn(position: IVec2) !void {
    const resources = try shared.getResources();
    const texture = try sdl.createTextureFromSurface(resources.renderer, resources.lieroSurface);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = p2m(.{ .x = size.x, .y = size.y });

    const bodyId = try box.createNonRotatingDynamicBody(position);

    const dynamicBox = box2d.b2MakeBox(0.1, 0.33);
    var shapeDef = box2d.b2DefaultShapeDef();
    shapeDef.density = 1.0;
    shapeDef.friction = 0.3;
    _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);

    const sprite = entity.Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    player = Player{ .entity = entity.Entity{ .bodyId = bodyId, .sprite = sprite } };
}
