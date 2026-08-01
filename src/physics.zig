const box2d = @import("box2d.zig");

const config = @import("config.zig");
const time = @import("time.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const camera = @import("camera.zig");
const particle = @import("particle.zig");

pub fn step() !usize {
    // Step box2d.c physics world
    var stepCount: usize = 0;
    while (time.accumulator >= config.physics.dt) {
        entity.updateStates();
        particle.updateStates();
        player.updateAllStates();
        box2d.worldStep(config.physics.dt, config.physics.subStepCount);
        time.accumulator -= config.physics.dt;
        stepCount += 1;
    }
    time.alpha = time.accumulator / config.physics.dt;
    return stepCount;
}
