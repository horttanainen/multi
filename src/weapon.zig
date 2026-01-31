const std = @import("std");
const audio = @import("audio.zig");
const delay = @import("delay.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const animation = @import("animation.zig");
const shared = @import("shared.zig");

pub const Projectile = struct {
    gravityScale: f32,
    propulsion: f32,
    animation: animation.Animation,
    explosion: projectile.Explosion,
    propulsionAnimation: ?animation.Animation = null,
};

pub const Weapon = struct {
    name: [:0]const u8,
    scale: vec.Vec2,
    delay: u32,
    sound: audio.Audio,
    impulse: f32,
    projectile: Projectile,
};

pub fn shoot(weapon: Weapon, position: vec.IVec2, direction: vec.Vec2) !void {
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    shapeDef.enableHitEvents = true;
    shapeDef.filter.categoryBits = collision.CATEGORY_PROJECTILE;
    shapeDef.filter.maskBits = collision.MASK_PROJECTILE;

    const animCopy = try animation.copyAnimation(weapon.projectile.animation);

    // Use first frame of animation as the sprite
    const firstFrameUuid = animCopy.frames[0];
    const firstFrame = sprite.getSprite(firstFrameUuid) orelse return error.SpriteNotFound;
    const pos = conv.pixel2MPos(position.x, position.y, firstFrame.sizeM.x, firstFrame.sizeM.y);
    var bodyDef = box2d.createDynamicBodyDef(pos);
    bodyDef.isBullet = true;

    const angle = std.math.atan2(-direction.y, direction.x);
    bodyDef.rotation = box2d.c.b2MakeRot(angle + std.math.pi * 0.5);

    const projectileEntity = try entity.createFromImg(firstFrameUuid, shapeDef, bodyDef, "projectile");

    box2d.c.b2Body_SetGravityScale(projectileEntity.bodyId, weapon.projectile.gravityScale);

    const impulse = vec.mul(vec.normalize(.{
        .x = direction.x,
        .y = -direction.y,
    }), weapon.impulse);

    box2d.c.b2Body_ApplyLinearImpulseToCenter(projectileEntity.bodyId, vec.toBox2d(impulse), true);

    const propulsionVector = vec.mul(vec.normalize(.{
        .x = direction.x,
        .y = -direction.y,
    }), weapon.projectile.propulsion);

    try projectile.create(projectileEntity.bodyId, weapon.projectile.explosion);
    try projectile.registerPropulsion(projectileEntity.bodyId, propulsionVector);

    var animations = std.StringHashMap(animation.Animation).init(shared.allocator);
    try animations.put("main", animCopy);

    if (weapon.projectile.propulsionAnimation) |propAnim| {
        const propAnimCopy = try animation.copyAnimation(propAnim);

        try entity.addSprite(projectileEntity.bodyId, propAnimCopy.frames[0]);

        try animations.put("propulsion", propAnimCopy);
    }

    try animation.registerAnimationSet(projectileEntity.bodyId, animations, "main", true);

    try audio.playFor(weapon.sound);
}
