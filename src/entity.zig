const std = @import("std");
const sdl = @import("zsdl2");
const box2d = @import("box2d").native;

const AutoArrayHashMap = std.AutoArrayHashMap;

const polygon = @import("polygon.zig");

const PI = std.math.pi;

const shared = @import("shared.zig");
const allocator = @import("shared.zig").allocator;

const Vec2 = @import("vector.zig").Vec2;
const IVec2 = @import("vector.zig").IVec2;

const m2PixelPos = @import("conversion.zig").m2PixelPos;
const p2m = @import("conversion.zig").p2m;
const m2P = @import("conversion.zig").m2P;

pub const Sprite = struct { texture: *sdl.Texture, dimM: Vec2 };
pub const Entity = struct {
    bodyId: box2d.b2BodyId,
    sprite: Sprite,
};

pub var entities: AutoArrayHashMap(box2d.b2BodyId, Entity) = AutoArrayHashMap(box2d.b2BodyId, Entity).init(allocator);

pub fn draw(entity: Entity) !void {
    if (shared.resources) |resources| {
        const renderer = resources.renderer;

        const bodyId = entity.bodyId;
        const sprite = entity.sprite;
        const boxPosMeter = box2d.b2Body_GetPosition(bodyId);
        const boxRotation = box2d.b2Body_GetRotation(bodyId);
        const rotationAngle = box2d.b2Rot_GetAngle(boxRotation);

        const pos = m2PixelPos(boxPosMeter.x, boxPosMeter.y, sprite.dimM.x, sprite.dimM.y);
        const rect = sdl.Rect{
            .x = pos.x,
            .y = pos.y,
            .w = m2P(sprite.dimM.x),
            .h = m2P(sprite.dimM.y),
        };
        try sdl.renderCopyEx(renderer, sprite.texture, null, &rect, rotationAngle * 180.0 / PI, null, sdl.RendererFlip.none);
    }
}

pub fn createBox(position: IVec2) !void {
    if (shared.resources) |resources| {
        const worldId = resources.worldId;
        const boxTexture = resources.boxTexture;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);
        const dynamicBox = box2d.b2MakeBox(0.5, 0.5);
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &dynamicBox);
        const sprite = Sprite{ .texture = boxTexture, .dimM = .{ .x = 1, .y = 1 } };

        const entity = Entity{ .bodyId = bodyId, .sprite = sprite };
        try entities.put(bodyId, entity);
    }
}

pub fn createFromImg(position: IVec2, texture: *sdl.Texture, img: *sdl.Surface) !void {
    const triangles = try polygon.triangulate(img);

    try createShape(position, texture, triangles);
}

fn createShape(position: IVec2, texture: *sdl.Texture, triangles: [][3]IVec2) !void {
    if (shared.resources) |resources| {
        const worldId = resources.worldId;

        var bodyDef = box2d.b2DefaultBodyDef();
        bodyDef.type = box2d.b2_dynamicBody;
        bodyDef.position = p2m(position);
        const bodyId = box2d.b2CreateBody(worldId, &bodyDef);

        var size: sdl.Point = undefined;
        try sdl.queryTexture(texture, null, null, &size.x, &size.y);
        const dimM = p2m(.{ .x = size.x, .y = size.y });
        createBox2DMultiPolygon(bodyId, triangles, .{ .x = size.x, .y = size.y });

        const sprite = Sprite{ .texture = texture, .dimM = .{ .x = dimM.x, .y = dimM.y } };

        const entity = Entity{ .bodyId = bodyId, .sprite = sprite };
        try entities.put(bodyId, entity);
    }
}

fn createBox2DMultiPolygon(bodyId: box2d.b2BodyId, triangles: [][3]IVec2, dimP: IVec2) void {
    // For each triangle, create a polygon fixture on the body.
    for (triangles) |tri| {
        var triangle: [3]IVec2 = undefined;
        triangle[0] = .{ .x = tri[0].x - @divFloor(dimP.x, 2), .y = tri[0].y - @divFloor(dimP.y, 2) };
        triangle[1] = .{ .x = tri[1].x - @divFloor(dimP.x, 2), .y = tri[1].y - @divFloor(dimP.y, 2) };
        triangle[2] = .{ .x = tri[2].x - @divFloor(dimP.x, 2), .y = tri[2].y - @divFloor(dimP.y, 2) };

        // Convert the triangle's vertices from IVec2 (pixel space)
        // to box2d.b2Vec2 (meter space) using the provided conversion.
        var verts: [3]box2d.b2Vec2 = undefined;
        verts[0] = p2m(triangle[0]);
        verts[1] = p2m(triangle[1]);
        verts[2] = p2m(triangle[2]);

        // Create a default shape definition.
        var shapeDef = box2d.b2DefaultShapeDef();
        shapeDef.density = 1.0;
        shapeDef.friction = 0.3;
        // (You may adjust properties like density, friction, or restitution as needed.)

        const hull = box2d.b2ComputeHull(&verts[0], 3);

        const poly: box2d.b2Polygon = box2d.b2MakePolygon(&hull, 0.01);

        // Create a polygon shape (fixture) on the body using the triangle vertices.
        // The b2CreatePolygonShape function expects a pointer to an array of b2Vec2
        // and the number of vertices is inferred by the fixture or shape definition.
        _ = box2d.b2CreatePolygonShape(bodyId, &shapeDef, &poly);
    }
}
