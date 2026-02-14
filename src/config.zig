const std = @import("std");
const vec = @import("vector.zig");

pub const window = .{
    .defaultWidth = 2000,
    .defaultHeight = 1200,
};

pub const debug = false;
pub const debugLog = false;

pub const maxLevelSizeInBytes = 1024 * 1024;
pub const maxAudioSizeInBytes = 10 * 1024 * 1024;

pub const met2pix = 80;

pub const physics = .{
    .dt = 1.0 / 60.0,
    .subStepCount = 4,
};

pub const cannonFireSoundDurationMs = 10000;
pub const cannonHitSoundDurationMs = 10000;

pub const aimCircleRadius: f32 = 500;
pub const aimRestingDistance: f32 = 100;
pub const aimCircleOffset: vec.IVec2 = .{ .x = 0, .y = -25 };

pub const Player = struct {
    restingFriction: f32,
    movementFriction: f32,
    sidewaysMovementForce: f32,
    jumpImpulse: f32,
    maxAirJumps: i32,
    maxMovementSpeed: f32,
    materialOffset: i32,
};

pub const player: Player = .{
    .restingFriction = 100,
    .movementFriction = 0.1,
    .sidewaysMovementForce = 5,
    .jumpImpulse = 1.7,
    .maxAirJumps = 1,
    .maxMovementSpeed = 6,
    .materialOffset = 600,
};

pub const BloodParticle = struct {
    particlesPerDamage: f32,
    maxParticles: u32,
    minSpeedVariation: f32,
    maxSpeedVariation: f32,
    minScale: f32,
    maxScale: f32,
    minStainRadius: f32,
    maxStainRadius: f32,

    lifetimeMs: u32,
    colorR: u8,
    colorG: u8,
    colorB: u8,

    linearDamping: f32,
    gravityScale: f32,
    density: f32,
    friction: f32,
    restitution: f32,
    boxSize: f32,
    groupIndex: i32,
};

pub const bloodParticle: BloodParticle = .{
    .particlesPerDamage = 0.5,
    .maxParticles = 30,
    .minSpeedVariation = 5,
    .maxSpeedVariation = 10,
    .minScale = 0.1,
    .maxScale = 1.0,
    .minStainRadius = 0.0,
    .maxStainRadius = 0.5,

    .lifetimeMs = 5000,
    .colorR = 138,
    .colorG = 3,
    .colorB = 3,

    .linearDamping = 1.0,
    .gravityScale = 1.0,
    .density = 1.0,
    .friction = 0.5,
    .restitution = 0.3,
    .boxSize = 0.1,
    .groupIndex = -3, // Don't collide with each other
};

pub const levelEditorCameraMovementForce = 10;

pub const levelEditorToggleDelayMs: f32 = 1000;
pub const jumpDelayMs = 500;
pub const boxCreateDelayMs = 200;
pub const shootDelayMs = 500;
pub const levelEditorClickDelayMs = 200;
pub const quitGameDelayMs = 500;
pub const reloadLevelDelayMs = 200;
pub const respawnDelayMs = 2000;
pub const ropeToggleDelayMs = 300;

pub const rocketLateralDamping: f32 = 10;

pub const rope = .{
    .hookImpulse = 1.0,
    .hookGravityScale = 1,
    .minLength = 3.0,
    .tensionMultiplier = 7.0,
    .segmentWidth = 4,
};
