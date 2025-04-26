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

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const conv = @import("conversion.zig");

pub const Sprite = struct { texture: *sdl.Texture, dimM: Vec2 };
pub const Entity = struct { bodyId: box2d.b2BodyId, state: ?State, sprite: Sprite, shapeIds: []box2d.b2ShapeId };

pub var entities: AutoArrayHashMap(box2d.b2BodyId, Entity) = AutoArrayHashMap(box2d.b2BodyId, Entity).init(allocator);

pub fn updateStates() void {
    for (entities.values()) |*e| {
        e.state = box.getState(e.bodyId);
    }
}

pub fn drawAll() !void {
    for (entities.values()) |e| {
        try draw(e);
    }
}

pub fn draw(entity: Entity) !void {
    const resources = try shared.getResources();
    const renderer = resources.renderer;

    const state = getInterpolatedState(entity);
    const pos = camera.relativePosition(conv.m2PixelPos(state.pos.x, state.pos.y, entity.sprite.dimM.x, entity.sprite.dimM.y));

    const rect = sdl.Rect{
        .x = pos.x,
        .y = pos.y,
        .w = conv.m2P(entity.sprite.dimM.x),
        .h = conv.m2P(entity.sprite.dimM.y),
    };
    try sdl.renderCopyEx(renderer, entity.sprite.texture, null, &rect, state.rotAngle * 180.0 / PI, null, sdl.RendererFlip.none);
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
    defer shared.allocator.free(triangles);
    const texture = try sdl.createTextureFromSurface(resources.renderer, img);

    var size: sdl.Point = undefined;
    try sdl.queryTexture(texture, null, null, &size.x, &size.y);
    const dimM = conv.p2m(.{ .x = size.x, .y = size.y });

    const shapeIds = try box.createPolygonShape(bodyId, triangles, .{ .x = size.x, .y = size.y }, shapeDef);

    const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    const entity = Entity{
        .state = null,
        .bodyId = bodyId,
        .sprite = sprite,
        .shapeIds = shapeIds,
    };
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

fn getInterpolatedState(entity: Entity) State {
    const currentState = box.getState(entity.bodyId);

    var interpolatedPosMeter = currentState.pos;
    var interpolatedRotationAngle = currentState.rotAngle;
    if (entity.state) |earlierState| {
        interpolatedPosMeter = box2d.b2Vec2{ .x = @floatCast(time.alpha * currentState.pos.x + (1 - time.alpha) * earlierState.pos.x), .y = @floatCast(time.alpha * currentState.pos.y + (1 - time.alpha) * earlierState.pos.y) };

        interpolatedRotationAngle = @floatCast(time.alpha * currentState.rotAngle + (1 - time.alpha) * earlierState.rotAngle);
    }

    return .{ .pos = interpolatedPosMeter, .rotAngle = interpolatedRotationAngle };
}

pub fn getPosition(entity: Entity) IVec2 {
    const state = getInterpolatedState(entity);
    const pos = conv.m2Pixel(state.pos);
    return pos;
}
