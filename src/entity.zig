const std = @import("std");
const sdl = @import("zsdl");
const box2d = @import("box2dnative.zig");

const AutoArrayHashMap = std.AutoArrayHashMap;

const camera = @import("camera.zig");
const time = @import("time.zig");
const polygon = @import("polygon.zig");
const box = @import("box.zig");
const State = box.State;

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const vec = @import("vector.zig");

const conv = @import("conversion.zig");

pub const Sprite = struct {
    texture: *sdl.Texture,
    dimM: vec.Vec2,
};
pub const Entity = struct {
    bodyId: box2d.b2BodyId,
    state: ?State,
    sprite: Sprite,
    highlighted: bool,
    shapeIds: []box2d.b2ShapeId,
};

pub var entities: AutoArrayHashMap(
    box2d.b2BodyId,
    Entity,
) = AutoArrayHashMap(box2d.b2BodyId, Entity).init(allocator);

pub fn updateStates() void {
    for (entities.values()) |*e| {
        e.state = box.getState(e.bodyId);
    }
}

pub fn drawAll() !void {
    for (entities.values()) |*e| {
        try draw(e);
    }
}

pub fn draw(entity: *Entity) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    const currentState = box.getState(entity.bodyId);
    const state = box.getInterpolatedState(entity.state, currentState);

    const pos = camera.relativePosition(conv.m2PixelPos(state.pos.x, state.pos.y, entity.sprite.dimM.x, entity.sprite.dimM.y));

    const rect = sdl.Rect{
        .x = pos.x,
        .y = pos.y,
        .w = conv.m2P(entity.sprite.dimM.x),
        .h = conv.m2P(entity.sprite.dimM.y),
    };

    try sdl.setTextureColorMod(entity.sprite.texture, 255, 255, 255);
    if (entity.highlighted) {
        try sdl.setTextureColorMod(entity.sprite.texture, 100, 100, 100);
    }
    try sdl.renderCopyEx(renderer, entity.sprite.texture, null, &rect, state.rotAngle * 180.0 / PI, null, sdl.RendererFlip.none);
}

pub fn createFromImg(img: *sdl.Surface, shapeDef: box2d.b2ShapeDef, bodyDef: box2d.b2BodyDef) !void {
    const bodyId = try box.createBody(bodyDef);
    const entity = try createEntityForBody(bodyId, img, shapeDef);
    try entities.put(bodyId, entity);
}

pub fn createEntityForBody(bodyId: box2d.b2BodyId, img: *sdl.Surface, shapeDef: box2d.b2ShapeDef) !Entity {
    const resources = try shared.getResources();
    const triangles = try polygon.triangulate(img);
    defer shared.allocator.free(triangles);
    const texture = try sdl.createTextureFromSurface(resources.renderer, img);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = conv.p2m(.{ .x = size.x, .y = size.y });

    const shapeIds = try box.createPolygonShape(bodyId, triangles, .{ .x = size.x, .y = size.y }, shapeDef);

    const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    const entity = Entity{ .state = null, .bodyId = bodyId, .sprite = sprite, .shapeIds = shapeIds, .highlighted = false };
    return entity;
}

pub fn cleanup() void {
    for (entities.values()) |entity| {
        box2d.b2DestroyBody(entity.bodyId);
        shared.allocator.free(entity.shapeIds);
    }
    entities.deinit();
    entities = AutoArrayHashMap(box2d.b2BodyId, Entity).init(allocator);
}

pub fn getPosition(entity: Entity) vec.IVec2 {
    const currentState = box.getState(entity.bodyId);
    const state = box.getInterpolatedState(entity.state, currentState);
    const pos = conv.m2Pixel(state.pos);
    return pos;
}

pub fn getEntity(bodyId: box2d.b2BodyId) ?*Entity {
    return entities.getPtr(bodyId);
}
