const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2dnative.zig");

const AutoArrayHashMap = std.AutoArrayHashMap;

const polygon = @import("polygon.zig");
const box = @import("box.zig");

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const m2PixelPos = @import("conversion.zig").m2PixelPos;
const p2m = @import("conversion.zig").p2m;
const m2P = @import("conversion.zig").m2P;

pub const Sprite = struct { texture: *sdl.Texture, dimM: Vec2 };
pub const Entity = struct { bodyId: box2d.b2BodyId, sprite: Sprite, shapeIds: []box2d.b2ShapeId };

pub var entities: AutoArrayHashMap(box2d.b2BodyId, Entity) = AutoArrayHashMap(box2d.b2BodyId, Entity).init(allocator);

pub fn draw(entity: Entity) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    const bodyId = entity.bodyId;
    const sprite = entity.sprite;
    const posMeter = box2d.b2Body_GetPosition(bodyId);
    const rotation = box2d.b2Body_GetRotation(bodyId);
    const rotationAngle = box2d.b2Rot_GetAngle(rotation);

    const pos = m2PixelPos(posMeter.x, posMeter.y, sprite.dimM.x, sprite.dimM.y);
    const rect = sdl.Rect{
        .x = pos.x,
        .y = pos.y,
        .w = m2P(sprite.dimM.x),
        .h = m2P(sprite.dimM.y),
    };
    try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
}

pub fn createStaticFromImg(position: IVec2, img: *sdl.Surface, shapeDef: box2d.ShapeDef) !void {
    const bodyId = try box.createStaticBody(position);
    const entity = try createEntityForBody(bodyId, img, shapeDef);
    try entities.put(bodyId, entity);
}

pub fn createFromImg(position: IVec2, img: *sdl.Surface, shapeDef: box2d.b2ShapeDef) !void {
    const bodyId = try box.createDynamicBody(position);
    const entity = try createEntityForBody(bodyId, img, shapeDef);
    try entities.put(bodyId, entity);
}

pub fn createEntityForBody(bodyId: box2d.b2BodyId, img: *sdl.Surface, shapeDef: box2d.b2ShapeDef) !Entity {
    const resources = try shared.getResources();
    const triangles = try polygon.triangulate(img);
    const texture = try sdl.createTextureFromSurface(resources.renderer, img);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = p2m(.{ .x = size.x, .y = size.y });

    const shapeIds = try box.createPolygonShape(bodyId, triangles, .{ .x = size.x, .y = size.y }, shapeDef);

    const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    const entity = Entity{ .bodyId = bodyId, .sprite = sprite, .shapeIds = shapeIds };
    return entity;
}
