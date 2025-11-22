const std = @import("std");

pub const window = .{
    .width = 2000,
    .height = 1200,
};

pub const debug = false;

pub const maxLevelSizeInBytes = 1024 * 1024;
pub const maxAudioSizeInBytes = 10 * 1024 * 1024;

pub const met2pix = 80;

// Collision categories (bit flags)
pub const CATEGORY_TERRAIN: u64 = 1 << 0;      // 0x01
pub const CATEGORY_PLAYER: u64 = 1 << 1;       // 0x02
pub const CATEGORY_PROJECTILE: u64 = 1 << 2;   // 0x04
pub const CATEGORY_SENSOR: u64 = 1 << 3;       // 0x08
pub const CATEGORY_DYNAMIC: u64 = 1 << 4;      // 0x10
pub const CATEGORY_UNBREAKABLE: u64 = 1 << 5;  // 0x20

pub const physics = .{
    .dt = 1.0 / 60.0,
    .subStepCount = 4,
};

pub const cannonImpulse = 10;
pub const cannonFireSoundDurationMs = 10000;
pub const cannonHitSoundDurationMs = 10000;

pub const Player = struct {
    materialId: i32,
    restingFriction: f32,
    movementFriction: f32,
    sidewaysMovementForce: f32,
    jumpImpulse: f32,
    maxAirJumps: i32,
    maxMovementSpeed: f32,
};

pub const player: Player = .{
    .materialId = 666,
    .restingFriction = 100,
    .movementFriction = 0.1,
    .sidewaysMovementForce = 5,
    .jumpImpulse = 1.7,
    .maxAirJumps = 1,
    .maxMovementSpeed = 6,
};

pub const levelEditorCameraMovementForce = 10;

pub const levelEditorToggleDelayMs: f32 = 1000;
pub const jumpDelayMs = 500;
pub const boxCreateDelayMs = 200;
pub const shootDelayMs = 500;
pub const levelEditorClickDelayMs = 200;
pub const quitGameDelayMs = 500;
pub const reloadLevelDelayMs = 200;
