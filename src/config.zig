const std = @import("std");

pub const Config = struct { window: struct { width: i32, height: i32 }, met2pix: i32, player: struct { materialId: i32, restingFriction: f32, movementFriction: f32, sidewaysMovementForce: f32, jumpImpulse: f32, maxAirJumps: i32, maxMovementSpeed: f32 } };

pub const config: Config = .{ .window = .{ .width = 800, .height = 800 }, .met2pix = 80, .player = .{ .materialId = 666, .restingFriction = 100, .movementFriction = 0.1, .sidewaysMovementForce = 5, .jumpImpulse = 1.5, .maxAirJumps = 1, .maxMovementSpeed = 6 } };
