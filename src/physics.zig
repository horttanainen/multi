const character_hair = @import("character_hair.zig");
const box2d = @import("box2d.zig");

const config = @import("config.zig");
const time = @import("time.zig");
const movement = @import("movement.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const particle = @import("particle.zig");
const sensor = @import("sensor.zig");
const player_input = @import("player_input.zig");
const control = @import("control.zig");
const character_animation = @import("character_animation.zig");
const projectile = @import("projectile.zig");
const rope = @import("rope.zig");
const gibbing = @import("gibbing.zig");
const pool = @import("pool.zig");
const perf = @import("perf.zig");

fn processContacts() !void {
    // Box2D replaces these events on the next step, including catch-up steps
    // within this rendered frame. Surface painting/uploads stay deferred.
    const ropeStart = perf.begin(.player_death);
    try rope.checkHookContacts();
    perf.recordPlayerDeathGameLoopStage(.rope, ropeStart);

    const bloodStart = perf.begin(.player_death);
    try particle.checkContacts();
    perf.recordPlayerDeathGameLoopStage(.blood_contacts, bloodStart);

    const gibletStart = perf.begin(.player_death);
    try gibbing.checkContacts();
    perf.recordPlayerDeathGameLoopStage(.giblet_contacts, gibletStart);

    const projectileStart = perf.begin(.player_death);
    try projectile.checkContacts();
    pool.processQueuedReleases();
    perf.recordPlayerDeathGameLoopStage(.projectile_contacts, projectileStart);
}

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
            // Shooting can destroy or recycle a target during this fixed step.
            projectile.updateAttachments();
            box2d.worldStep(config.physics.dt, config.physics.subStepCount);
            try movement.resolveGroundMovement();
            try movement.processSensorEvents();
            try sensor.processSensorEvents();
            character_animation.fixedUpdate(config.physics.dt);
            try processContacts();
            character_hair.fixedUpdate(config.physics.dt);
        }
        time.accumulator -= config.physics.dt;
        stepCount += 1;
    }
    time.alpha = time.accumulator / config.physics.dt;
    return stepCount;
}
