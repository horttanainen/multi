const std = @import("std");

pub const window = .{
    .width = 800,
    .height = 800,
};

pub const maxLevelSizeInBytes = 1024 * 1024;

pub const met2pix = 80;

pub const goalMaterialId = 420;
pub const spawnMaterialId = 69;

pub const physics = .{
    .dt = 1.0 / 60.0,
    .subStepCount = 4,
};

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
pub const levelEditorClickDelayMs = 200;
pub const quitGameDelayMs = 500;
pub const reloadLevelDelayMs = 200;
