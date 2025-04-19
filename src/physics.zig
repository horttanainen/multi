const box2d = @import("box2dnative.zig");

const shared = @import("shared.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");

pub fn step() !void {
    const resources = try shared.getResources();
    // Step Box2D physics world
    while (time.accumulator >= config.physics.dt) {
        entity.updateStates();
        player.updateState();
        box2d.b2World_Step(resources.worldId, config.physics.dt, config.physics.subStepCount);
        time.accumulator -= config.physics.dt;
    }
    time.alpha = time.accumulator / config.physics.dt;
}
