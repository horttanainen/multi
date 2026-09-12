const box2d = @import("box2d.zig");

const config = @import("config.zig");
const time = @import("time.zig");
const movement = @import("movement.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const camera = @import("camera.zig");
const particle = @import("particle.zig");
const sensor = @import("sensor.zig");
const player_input = @import("player_input.zig");
const control = @import("control.zig");
const character_animation = @import("character_animation.zig");

pub fn step() !usize {
    // Step box2d.c physics world
    var stepCount: usize = 0;
    while (time.accumulator >= config.physics.dt) {
        {
            player_input.beginPhysicsStep();
            defer player_input.endPhysicsStep();

            entity.updateStates();
            particle.updateStates();
            player.updateAllStates();
            control.applyFixedStepPlayerInputs();
            movement.clampAllSpeeds();
            movement.applyAll(config.physics.dt);
            box2d.worldStep(config.physics.dt, config.physics.subStepCount);
            try movement.processSensorEvents();
            try sensor.processSensorEvents();
            character_animation.fixedUpdate(config.physics.dt);
        }
        time.accumulator -= config.physics.dt;
        stepCount += 1;
    }
    time.alpha = time.accumulator / config.physics.dt;
    return stepCount;
}
