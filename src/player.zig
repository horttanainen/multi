const std = @import("std");
const box2d = @import("box2dnative.zig");
const sdl = @import("zsdl2");

const entity = @import("entity.zig");
const shared = @import("shared.zig");
const box = @import("box.zig");

const config = @import("config.zig").config;

const p2m = @import("conversion.zig").p2m;

const IVec2 = @import("vector.zig").IVec2;

pub const Player = struct {
    entity: entity.Entity,
    bodyShapeId: box2d.b2ShapeId,
};

pub var player: ?Player = null;
pub var isMoving: bool = false;

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
    shapeDef.friction = config.player.movementFriction;
    const shapeId = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
    box2d.b2Shape_SetMaterial(shapeId, config.player.materialId);

    const sprite = entity.Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

    player = Player{ .entity = entity.Entity{ .bodyId = bodyId, .sprite = sprite }, .bodyShapeId = shapeId };
}

pub fn jump() void {
    if (player) |p| {
        if (inAir()) {
            return;
        }
        box2d.b2Body_ApplyLinearImpulseToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = 0, .y = -config.player.jumpImpulse }, true);
    }
}

pub fn inAir() bool {
    return false;
}

pub fn brake() void {
    isMoving = false;
}

pub fn moveLeft() void {
    isMoving = true;
    if (player) |p| {
        box2d.b2Body_ApplyForceToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = -config.player.sidewaysMovementForce, .y = 0 }, true);
    }
}

pub fn moveRight() void {
    isMoving = true;
    if (player) |p| {
        box2d.b2Body_ApplyForceToCenter(p.entity.bodyId, box2d.b2Vec2{ .x = config.player.sidewaysMovementForce, .y = 0 }, true);
    }
}
pub fn clampSpeed() void {
    if (player) |p| {
        var velocity = box2d.b2Body_GetLinearVelocity(p.entity.bodyId);
        if (velocity.x > config.player.maxMovementSpeed) {
            velocity.x = config.player.maxMovementSpeed;
            box2d.b2Body_SetLinearVelocity(p.entity.bodyId, velocity);
        } else if (velocity.x < -config.player.maxMovementSpeed) {
            velocity.x = -config.player.maxMovementSpeed;
            box2d.b2Body_SetLinearVelocity(p.entity.bodyId, velocity);
        }
    }
}
