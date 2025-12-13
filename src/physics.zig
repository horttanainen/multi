const box2d = @import("box2d.zig");

const shared = @import("shared.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const camera = @import("camera.zig");

pub fn step() !void {
    const resources = try shared.getResources();
    // Step box2d.c physics world
    while (time.accumulator >= config.physics.dt) {
        entity.updateStates();
        player.updateAllStates();
        camera.updateState();
        box2d.c.b2World_Step(resources.worldId, config.physics.dt, config.physics.subStepCount);
        time.accumulator -= config.physics.dt;
    }
    time.alpha = time.accumulator / config.physics.dt;
}
