const audio = @import("audio.zig");
const delay = @import("delay.zig");
const sprite = @import("sprite.zig");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");
const conv = @import("conversion.zig");
const entity = @import("entity.zig");
const projectile = @import("projectile.zig");
const config = @import("config.zig");

pub const Weapon = struct {
    name: [:0]const u8,
    projectileImgSrc: []const u8,
    scale: vec.Vec2,
    delay: u32,
    sound: audio.Audio,
    impulse: f32,
    explosion: ?projectile.Explosion,
};

pub fn shoot(weapon: Weapon, position: vec.IVec2, direction: vec.Vec2) !void {
    if (!delay.check(weapon.name)) {
        var shapeDef = box2d.c.b2DefaultShapeDef();
        shapeDef.friction = 0.5;
        shapeDef.enableHitEvents = true;
        shapeDef.filter.categoryBits = config.CATEGORY_PROJECTILE;
        shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_PLAYER | config.CATEGORY_DYNAMIC;

        const s = try sprite.createFromImg(
            weapon.projectileImgSrc,
            weapon.scale,
            vec.izero,
        );
        const pos = conv.pixel2MPos(position.x, position.y, s.sizeM.x, s.sizeM.y);
        var bodyDef = box2d.createDynamicBodyDef(pos);
        bodyDef.isBullet = true;
        const projectileEntity = try entity.createFromImg(s, shapeDef, bodyDef, "dynamic");

        const impulse = vec.mul(vec.normalize(.{
            .x = direction.x,
            .y = -direction.y,
        }), weapon.impulse);

        box2d.c.b2Body_ApplyLinearImpulseToCenter(projectileEntity.bodyId, vec.toBox2d(impulse), true);

        try projectile.create(projectileEntity.bodyId, weapon.explosion);

        try audio.playFor(weapon.sound);
        delay.action(weapon.name, weapon.delay);
    }
}
