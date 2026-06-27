const std = @import("std");
const vec = @import("vector.zig");

pub const window = .{
    .defaultWidth = 2000,
    .defaultHeight = 1200,
};

pub const debug = false;
pub const debugLog = false;

pub const perf = .{
    .explosion = false,
    .level_editor_static_spawn = false,
};

pub const maxLevelSizeInBytes = 1024 * 1024;
pub const maxAudioSizeInBytes = 10 * 1024 * 1024;

pub const RuntimeAtlasConfig = struct {
    maxQualityZoom: f32,
    oversample: f32,
    downscaleThreshold: f32,
    minTextureEdge: i32,
    maxTextureEdge: i32,
    textureBucket: i32,
};

pub const RuntimeAtlasProfile = enum {
    balanced_downscale,
    preserve_detail,
    aggressive_downscale,
    cap_256,
    cap_512,
    cap_1024,
    cap_2048,
    cap_4096,
};

pub const defaultRuntimeAtlasProfile: RuntimeAtlasProfile = .balanced_downscale;

pub fn runtimeAtlasProfileFromName(name: []const u8) ?RuntimeAtlasProfile {
    return std.meta.stringToEnum(RuntimeAtlasProfile, name);
}

fn runtimeAtlasConfigWithMaxTextureEdge(maxTextureEdge: i32) RuntimeAtlasConfig {
    var profile = runtimeAtlasConfigForProfile(.balanced_downscale);
    profile.maxTextureEdge = maxTextureEdge;
    profile.downscaleThreshold = 1.0;
    return profile;
}

pub fn runtimeAtlasConfigForProfile(profile: RuntimeAtlasProfile) RuntimeAtlasConfig {
    return switch (profile) {
        .balanced_downscale => .{
            .maxQualityZoom = 2.0,
            .oversample = 2.0,
            .downscaleThreshold = 1.25,
            .minTextureEdge = 128,
            .maxTextureEdge = 2048,
            .textureBucket = 64,
        },
        .preserve_detail => .{
            .maxQualityZoom = 2.5,
            .oversample = 2.0,
            .downscaleThreshold = 1.5,
            .minTextureEdge = 256,
            .maxTextureEdge = 4096,
            .textureBucket = 128,
        },
        .aggressive_downscale => .{
            .maxQualityZoom = 1.5,
            .oversample = 1.5,
            .downscaleThreshold = 1.1,
            .minTextureEdge = 64,
            .maxTextureEdge = 1024,
            .textureBucket = 64,
        },
        .cap_256 => runtimeAtlasConfigWithMaxTextureEdge(256),
        .cap_512 => runtimeAtlasConfigWithMaxTextureEdge(512),
        .cap_1024 => runtimeAtlasConfigWithMaxTextureEdge(1024),
        .cap_2048 => runtimeAtlasConfigWithMaxTextureEdge(2048),
        .cap_4096 => runtimeAtlasConfigWithMaxTextureEdge(4096),
    };
}

pub const runtimeAtlas = runtimeAtlasConfigForProfile(defaultRuntimeAtlasProfile);

pub const physics = .{
    .dt = 1.0 / 60.0,
    .subStepCount = 4,
};

pub const aimCircleRadius: f32 = 500;
pub const aimRestingDistance: f32 = 100;
pub const aimCircleOffset: vec.IVec2 = .{ .x = 0, .y = -25 };

pub const runAnimationFps: i32 = 12;

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

pub const sdl = @import("sdl.zig");

pub const menu = .{
    .colorNormal = sdl.Color{ .r = 40, .g = 40, .b = 40, .a = 200 },
    .colorFocused = sdl.Color{ .r = 220, .g = 60, .b = 140, .a = 220 },
    .colorEditing = sdl.Color{ .r = 60, .g = 140, .b = 220, .a = 220 },
    .colorOverlay = sdl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
    .colorSide = sdl.Color{ .r = 20, .g = 20, .b = 20, .a = 140 },
};

pub const lut = .{
    .regenerate_builtin_luts_on_startup = false,
};

pub const levelEditorCursorMovePixels = 10;
pub const levelEditorSnapMoveDelayMs = 150;
pub const levelEditorSteppedSnapMinGranularityMeters: f32 = 1.0;

pub const levelEditorToggleDelayMs: f32 = 1000;
pub const jumpDelayMs = 500;
pub const boxCreateDelayMs = 200;
pub const levelEditorClickDelayMs = 200;
pub const levelEditorScaleRepeatDelayMs = 75;
pub const quitGameDelayMs = 500;
pub const reloadLevelDelayMs = 200;
pub const respawnDelayMs = 2000;
pub const ropeToggleDelayMs = 300;
pub const sprayPaintDelayMs = 2000;

pub const sprayPaintWorldSize: f32 = 5;

pub const CrtParams = struct {
    enabled: bool,
    distortion_strength: f32,
    aberration: f32,
    // zoom > 1 crops into the image to hide black borders from barrel distortion
    zoom: f32,
    virtual_resolution_enabled: bool,
    scanlines_enabled: bool,
    // virtual CRT resolution for scanline/pixelation effect
    resolution: [2]f32,
};

pub const crt = CrtParams{
    .enabled = true,
    .distortion_strength = 0.15,
    .aberration = 0.004,
    .zoom = 1.0,
    .virtual_resolution_enabled = true,
    .scanlines_enabled = true,
    .resolution = .{ 1280.0, 720.0 },
};

pub const crtMenu = CrtParams{
    .enabled = true,
    .distortion_strength = 5.0,
    .aberration = 0.015,
    .zoom = 2.0,
    .virtual_resolution_enabled = true,
    .scanlines_enabled = true,
    .resolution = .{ 640.0, 360.0 },
};

pub const rope = .{
    .hookImpulse = 1.0,
    .hookGravityScale = 1,
    .minLength = 3.0,
    .tensionMultiplier = 7.0,
    .segmentWidth = 4,
};
