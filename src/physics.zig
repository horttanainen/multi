const box2d = @import("box2d.zig");

const config = @import("config.zig");
const time = @import("time.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const camera = @import("camera.zig");
const particle = @import("particle.zig");

pub fn step() !void {
    // Step box2d.c physics world
    while (time.accumulator >= config.physics.dt) {
        entity.updateStates();
        particle.updateStates();
        player.updateAllStates();
        camera.updateState();
        box2d.worldStep(config.physics.dt, config.physics.subStepCount);
        time.accumulator -= config.physics.dt;
    }
    time.alpha = time.accumulator / config.physics.dt;
}
