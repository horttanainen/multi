const box2d = @import("box2d.zig");
const data = @import("data.zig");
const sprite = @import("sprite.zig");
const conv = @import("conversion.zig");
const camera = @import("camera.zig");
const vec = @import("vector.zig");
const level = @import("level.zig");
const config = @import("config.zig");

var bodyId: box2d.c.b2BodyId = undefined;
var bodyCreated: bool = false;
var prevState: ?box2d.State = null;
var crosshairUuid: ?u64 = null;

var pendingKey: ?[]const u8 = null;
var pendingUuid: ?u64 = null;
var pendingImgPath: ?[]const u8 = null;
var pendingScale: vec.Vec2 = .{ .x = 1, .y = 1 };

pub fn create() !void {
    if (bodyCreated) return;
    const bodyDef = box2d.createDynamicBodyDef(.{ .x = 0, .y = 0 });
    bodyId = try box2d.createBody(bodyDef);
    box2d.c.b2Body_SetGravityScale(bodyId, 0);
    box2d.c.b2Body_SetLinearDamping(bodyId, 2);
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.isSensor = true;
    const polygon = box2d.c.b2MakeSquare(0.5);
    _ = box2d.c.b2CreatePolygonShape(bodyId, &shapeDef, &polygon);
    bodyCreated = true;
}

pub fn destroy() void {
    if (bodyCreated) {
        box2d.c.b2DestroyBody(bodyId);
        bodyCreated = false;
    }
    if (crosshairUuid) |uuid| {
        sprite.cleanupLater(uuid);
        crosshairUuid = null;
    }
}

// Called on initial level editor entry: refresh sprite and reset cursor to level center.
pub fn initSprite() void {
    if (crosshairUuid) |old| sprite.cleanupLater(old);
    crosshairUuid = data.createSpriteFrom("crosshair");

    if (bodyCreated) {
        const centerM = conv.p2m(level.position);
        const rot = box2d.c.b2MakeRot(0.0);
        box2d.c.b2Body_SetTransform(bodyId, centerM, rot);
        box2d.c.b2Body_SetLinearVelocity(bodyId, .{ .x = 0, .y = 0 });
    }
}

// Called after editor reloads: refreshes sprites without moving the cursor.
pub fn refreshSprite() void {
    if (crosshairUuid) |old| sprite.cleanupLater(old);
    crosshairUuid = data.createSpriteFrom("crosshair");

    // Re-create pending sprite so its texture reference stays valid after atlas repack.
    if (pendingKey) |key| {
        if (pendingUuid) |old| sprite.cleanupLater(old);
        pendingUuid = data.createSpriteFrom(key);
        if (data.getSpriteData(key)) |d| {
            pendingImgPath = d.path;
            pendingScale = .{ .x = d.scale, .y = d.scale };
        }
    }
}

pub fn updateState() void {
    if (bodyCreated) prevState = box2d.getState(bodyId);
}

pub fn cameraFollow() void {
    if (!bodyCreated) return;
    const currentState = box2d.getState(bodyId);
    const state = box2d.getInterpolatedState(prevState, currentState);
    camera.centerOn(conv.m2Pixel(state.pos));
}

pub fn attachSprite(key: []const u8) void {
    detachSprite();
    const d = data.getSpriteData(key) orelse return;
    pendingUuid = data.createSpriteFrom(key);
    pendingKey = key;
    pendingImgPath = d.path;
    pendingScale = .{ .x = d.scale, .y = d.scale };
}

pub fn detachSprite() void {
    if (pendingUuid) |uuid| sprite.cleanupLater(uuid);
    pendingUuid = null;
    pendingKey = null;
    pendingImgPath = null;
}

pub fn hasPendingSprite() bool {
    return pendingKey != null;
}

pub fn getPendingImgPath() ?[]const u8 {
    return pendingImgPath;
}

pub fn getPendingScale() vec.Vec2 {
    return pendingScale;
}

pub fn getWorldPos() vec.IVec2 {
    if (!bodyCreated) return .{ .x = 0, .y = 0 };
    const currentState = box2d.getState(bodyId);
    const state = box2d.getInterpolatedState(prevState, currentState);
    return conv.m2Pixel(state.pos);
}

pub fn moveLeft() void {
    applyForce(.{ .x = -config.levelEditorCameraMovementForce, .y = 0 });
}
pub fn moveRight() void {
    applyForce(.{ .x = config.levelEditorCameraMovementForce, .y = 0 });
}
pub fn moveUp() void {
    applyForce(.{ .x = 0, .y = -config.levelEditorCameraMovementForce });
}
pub fn moveDown() void {
    applyForce(.{ .x = 0, .y = config.levelEditorCameraMovementForce });
}

fn applyForce(f: box2d.c.b2Vec2) void {
    if (bodyCreated) box2d.c.b2Body_ApplyForceToCenter(bodyId, f, true);
}

pub fn draw() !void {
    if (!bodyCreated) return;
    const currentState = box2d.getState(bodyId);
    const state = box2d.getInterpolatedState(prevState, currentState);
    const screenPos = camera.relativePosition(conv.m2Pixel(state.pos));

    if (pendingUuid) |uuid| {
        const s = sprite.getSprite(uuid) orelse return;
        try sprite.drawWithOptions(s, screenPos, 0, false, false, 0, null, null);
    } else {
        const uuid = crosshairUuid orelse return;
        const s = sprite.getSprite(uuid) orelse return;
        try sprite.drawWithOptions(s, screenPos, 0, false, false, 0, null, null);
    }
}
