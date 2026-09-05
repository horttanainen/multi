const std = @import("std");
const sprite = @import("sprite.zig");
const surface_cutout = @import("surface_cutout.zig");
const animation = @import("animation.zig");
const allocator = @import("allocator.zig").allocator;
const vec = @import("vector.zig");
const fs = @import("fs.zig");
const audio = @import("audio.zig");
const explosion_visual = @import("explosion_visual.zig");
const projectile = @import("projectile.zig");
const weapon = @import("weapon.zig");
const config = @import("config.zig");

pub const SpriteData = struct {
    path: []const u8,
    heightMeters: f32,
    atlasProfile: config.RuntimeAtlasProfile,
    markers: sprite.MarkerExtraction,
};

pub const GibletGroup = enum {
    head,
    leg,
    meat,
};

pub const GibletData = struct {
    group: GibletGroup,
    path: []const u8,
    heightMeters: f32,
};

pub const AnimationData = struct {
    path: []const u8,
    fps: i32,
    heightMeters: f32,
    offsetMeters: vec.Vec2,
    loop: bool,
    spriteIndex: usize,
    switchDelay: f64,
    markers: sprite.MarkerExtraction,
};

pub const SoundData = struct {
    path: []const u8,
    durationMs: u32,
    volume: f32,
};

pub const ExplosionData = struct {
    sound: ?[]const u8,
    visual: ?[]const u8,
    maximumDamage: f32,
    maximumPlayerVelocityChange: f32,
    maximumObjectImpulse: f32,
    blastRadius: f32,
    pressureRadius: f32,
    cutoutIrregularity: f32,
    cutoutCharWidth: f32,
    cutoutCharStrength: f32,
    cutoutHotRimWidth: f32,
    cutoutHotRimDurationMs: u32,
    damagePlayers: bool,
};

pub const ProjectileData = struct {
    gravityScale: f32,
    density: f32,
    launchSpeed: f32,
    linearDamping: f32,
    propulsion: f32,
    lateralDamping: f32,
    animation: []const u8,
    propulsionAnimation: ?[]const u8,
    explosion: ?[]const u8,
    impactBehavior: projectile.ImpactBehavior,
    flightRotation: projectile.FlightRotation,
    stickDepth: f32,
};

pub const PelletData = struct {
    gravityScale: f32,
    density: f32,
    friction: f32,
    radius: f32,
    spriteDiameterMeters: f32,
    count: u32,
    spreadAngle: f32,
    spawnRadius: f32,
    explosion: ?[]const u8,
    color: sprite.Color,
};

pub const WeaponData = struct {
    sprite: []const u8,
    delay: u32,
    sound: []const u8,
    impulse: f32,
    projectile: ?[]const u8,
    pellet: ?PelletData,
    explosion: ?[]const u8,
    range: f32,
    trailDurationMs: u32,
    trailColor: sprite.Color,
    directDamage: f32,
    penetration: projectile.PenetrationMode,
};

pub const ParticleStainData = struct {
    minRadius: f32,
    maxRadius: f32,
    color: sprite.Color,
};

pub const ParticleDirection = enum {
    radial,
    upward_bias,
};

pub const ParticleData = struct {
    particlesPerUnit: f32,
    maxParticles: u32,
    minSpeedVariation: f32,
    maxSpeedVariation: f32,
    minScale: f32,
    maxScale: f32,
    defaultDirection: ParticleDirection,

    lifetimeMs: u32,
    color: sprite.Color,
    stain: ?ParticleStainData,

    linearDamping: f32,
    gravityScale: f32,
    density: f32,
    friction: f32,
    restitution: f32,
    groupIndex: i32,
};

pub const MovementMechanism = enum {
    liero,
    towerfall,
};

pub const MovementGroundingMode = enum {
    foot_contact,
    body_contact,
    ground_sweep,
    none,
};

pub const MovementControlData = struct {
    lateralForce: f32,
    maxLateralSpeed: f32,
};

pub const MovementBodyMotionData = struct {
    maxLinearSpeed: ?f32 = null,
    linearDamping: f32,
    gravityScale: f32,
};

pub const MovementSurfaceResponseData = struct {
    movingFriction: f32,
    restingFriction: f32,
};

pub const MovementJumpData = struct {
    impulse: f32,
    maxAirJumps: u32,
    cooldownMs: u32,
    coyoteTimeMs: u32 = 0,
    bufferTimeMs: u32 = 0,
};

pub const MovementGroundingData = struct {
    mode: MovementGroundingMode,
    probeHalfWidth: f32,
    probeHalfHeight: f32,
    probeOffset: vec.Vec2,
    sweepDistance: f32 = 0,
    maxSlopeAngleDegrees: f32 = 60,
};

pub const LieroMovementData = struct {
    control: MovementControlData,
    bodyMotion: MovementBodyMotionData,
    surfaceResponse: MovementSurfaceResponseData,
    jump: MovementJumpData,
};

pub const TowerfallControlData = struct {
    maxRunSpeed: f32,
    groundAcceleration: f32,
    groundReversalAcceleration: f32,
    groundDeceleration: f32,
    airAcceleration: f32,
    airDeceleration: f32,
    gravity: f32,
    maxFallSpeed: f32,
    fastFallAcceleration: f32,
    fastFallSpeed: f32,
    excessFallSpeedDeceleration: f32,
};

pub const TowerfallJumpData = struct {
    speed: f32,
    heldGravity: f32,
    coyoteTimeMs: u32,
    bufferTimeMs: u32,
};

pub const TowerfallWallSlideData = struct {
    acceleration: f32,
    maxFallSpeed: f32,
};

pub const TowerfallWallJumpData = struct {
    horizontalSpeed: f32,
    forcedMovementSteps: u32,
};

pub const TowerfallMovementData = struct {
    control: TowerfallControlData,
    bodyMotion: MovementBodyMotionData,
    surfaceResponse: MovementSurfaceResponseData,
    jump: TowerfallJumpData,
    wallSlide: TowerfallWallSlideData,
    wallJump: TowerfallWallJumpData,
};

pub const MovementData = struct {
    mechanism: MovementMechanism,
    aimGuideLengthMeters: f32 = 0.5,
    liero: ?LieroMovementData = null,
    towerfall: ?TowerfallMovementData = null,
    grounding: MovementGroundingData,
};

pub fn loadMovementData(path: []const u8) !MovementData {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile(path, &jsonBuf) catch |err| {
        std.log.warn("data.loadMovementData: failed to read '{s}': {}", .{ path, err });
        return err;
    };

    const parsed = std.json.parseFromSlice(MovementData, allocator, jsonData, .{}) catch |err| {
        std.log.warn("data.loadMovementData: failed to parse '{s}': {}", .{ path, err });
        return err;
    };
    defer parsed.deinit();

    return parsed.value;
}

pub var spriteDataMap: std.StringHashMapUnmanaged(SpriteData) = .{};
pub var gibletData: []GibletData = &.{};
var animationDataMap: std.StringHashMapUnmanaged(AnimationData) = .{};
var soundDataMap: std.StringHashMapUnmanaged(SoundData) = .{};
var explosionDataMap: std.StringHashMapUnmanaged(ExplosionData) = .{};
var projectileDataMap: std.StringHashMapUnmanaged(ProjectileData) = .{};
var weaponDataMap: std.StringHashMapUnmanaged(WeaponData) = .{};
pub var particleDataMap: std.StringHashMapUnmanaged(ParticleData) = .{};
pub var explosionVisualDataMap: std.StringHashMapUnmanaged(explosion_visual.Preset) = .{};

pub fn init() !void {
    try initSprites();
    try initGiblets();
    try initParticles();
    try initAnimations();
    try initSounds();
    try initExplosionVisuals();
    try initExplosions();
    try initProjectiles();
    try initWeapons();
}

fn initGiblets() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("giblets.json", &jsonBuf) catch |err| {
        std.log.err("data.initGiblets: failed to read giblets.json: {}", .{err});
        return err;
    };

    const Entry = struct {
        group: GibletGroup,
        path: []const u8,
        heightMeters: f32,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.log.err("data.initGiblets: failed to parse giblets.json: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    var entries = std.array_list.Managed(GibletData).init(allocator);
    defer entries.deinit();
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
    }

    for (parsed.value) |entry| {
        const path = try allocator.dupe(u8, entry.path);
        entries.append(.{
            .group = entry.group,
            .path = path,
            .heightMeters = entry.heightMeters,
        }) catch |err| {
            allocator.free(path);
            return err;
        };
    }

    gibletData = try entries.toOwnedSlice();
}

fn initExplosionVisuals() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("explosion_visuals.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read explosion_visuals.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        pressureWaveDurationMs: u32,
        pressureWaveTrailDurationMs: u32,
        pressureWaveDistortionPixels: f32,
        screenShakeDurationMs: u32,
        screenShakeMaxOffsetPixels: f32,
        flashDurationMs: u32,
        flashStartRadius: f32,
        flashEndRadius: f32,
        flashMaxAlpha: u8,
        flashColor: sprite.Color,
        emberCount: u32,
        emberMinSpeed: f32,
        emberMaxSpeed: f32,
        emberMinLifetimeMs: u32,
        emberMaxLifetimeMs: u32,
        emberMinDiameter: f32,
        emberMaxDiameter: f32,
        emberEndDiameterScale: f32,
        emberDrag: f32,
        emberGravity: f32,
        emberSurfaceBias: f32,
        emberStartColor: sprite.Color,
        emberEndColor: sprite.Color,
        smokeCount: u32,
        smokeMinRadius: f32,
        smokeMaxRadius: f32,
        smokeMinDelayMs: u32,
        smokeMaxDelayMs: u32,
        smokeFadeInMs: u32,
        smokeMinSpeed: f32,
        smokeMaxSpeed: f32,
        smokeMinLifetimeMs: u32,
        smokeMaxLifetimeMs: u32,
        smokeMinDiameter: f32,
        smokeMaxDiameter: f32,
        smokeEndDiameterScale: f32,
        smokeDrag: f32,
        smokeUpwardAcceleration: f32,
        smokeOutwardBias: f32,
        smokeUpwardBias: f32,
        smokeMaxAlpha: u8,
        smokeStartColor: sprite.Color,
        smokeEndColor: sprite.Color,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse explosion_visuals.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = allocator.dupe(u8, entry.key) catch continue;
        explosionVisualDataMap.put(allocator, key, .{
            .pressure_wave_duration_ms = entry.pressureWaveDurationMs,
            .pressure_wave_trail_duration_ms = entry.pressureWaveTrailDurationMs,
            .pressure_wave_distortion_pixels = entry.pressureWaveDistortionPixels,
            .screen_shake_duration_ms = entry.screenShakeDurationMs,
            .screen_shake_max_offset_pixels = entry.screenShakeMaxOffsetPixels,
            .flash_duration_ms = entry.flashDurationMs,
            .flash_start_radius = entry.flashStartRadius,
            .flash_end_radius = entry.flashEndRadius,
            .flash_max_alpha = entry.flashMaxAlpha,
            .flash_color = entry.flashColor,
            .ember_count = entry.emberCount,
            .ember_min_speed = entry.emberMinSpeed,
            .ember_max_speed = entry.emberMaxSpeed,
            .ember_min_lifetime_ms = entry.emberMinLifetimeMs,
            .ember_max_lifetime_ms = entry.emberMaxLifetimeMs,
            .ember_min_diameter = entry.emberMinDiameter,
            .ember_max_diameter = entry.emberMaxDiameter,
            .ember_end_diameter_scale = entry.emberEndDiameterScale,
            .ember_drag = entry.emberDrag,
            .ember_gravity = entry.emberGravity,
            .ember_surface_bias = entry.emberSurfaceBias,
            .ember_start_color = entry.emberStartColor,
            .ember_end_color = entry.emberEndColor,
            .smoke_count = entry.smokeCount,
            .smoke_min_radius = entry.smokeMinRadius,
            .smoke_max_radius = entry.smokeMaxRadius,
            .smoke_min_delay_ms = entry.smokeMinDelayMs,
            .smoke_max_delay_ms = entry.smokeMaxDelayMs,
            .smoke_fade_in_ms = entry.smokeFadeInMs,
            .smoke_min_speed = entry.smokeMinSpeed,
            .smoke_max_speed = entry.smokeMaxSpeed,
            .smoke_min_lifetime_ms = entry.smokeMinLifetimeMs,
            .smoke_max_lifetime_ms = entry.smokeMaxLifetimeMs,
            .smoke_min_diameter = entry.smokeMinDiameter,
            .smoke_max_diameter = entry.smokeMaxDiameter,
            .smoke_end_diameter_scale = entry.smokeEndDiameterScale,
            .smoke_drag = entry.smokeDrag,
            .smoke_upward_acceleration = entry.smokeUpwardAcceleration,
            .smoke_outward_bias = entry.smokeOutwardBias,
            .smoke_upward_bias = entry.smokeUpwardBias,
            .smoke_max_alpha = entry.smokeMaxAlpha,
            .smoke_start_color = entry.smokeStartColor,
            .smoke_end_color = entry.smokeEndColor,
        }) catch {
            allocator.free(key);
            continue;
        };
        std.debug.print("Parsed explosion visual data '{s}'\n", .{key});
    }
}

fn initSprites() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("sprites.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read sprites.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        path: []const u8,
        heightMeters: f32,
        atlasProfile: ?[]const u8 = null,
        markers: sprite.MarkerExtraction = .{},
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse sprites.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = allocator.dupe(u8, entry.key) catch continue;
        const path = allocator.dupe(u8, entry.path) catch {
            allocator.free(key);
            continue;
        };

        spriteDataMap.put(allocator, key, .{
            .path = path,
            .heightMeters = entry.heightMeters,
            .atlasProfile = runtimeAtlasProfileForSpriteEntry(entry.key, entry.atlasProfile),
            .markers = entry.markers,
        }) catch {
            allocator.free(key);
            allocator.free(path);
            continue;
        };

        std.debug.print("Parsed sprite data '{s}'\n", .{key});
    }
}

fn runtimeAtlasProfileForSpriteEntry(key: []const u8, profileName: ?[]const u8) config.RuntimeAtlasProfile {
    if (profileName == null) return config.defaultRuntimeAtlasProfile;

    const name = profileName.?;
    const profile = config.runtimeAtlasProfileFromName(name) orelse {
        std.log.warn("runtimeAtlasProfileForSpriteEntry: sprite '{s}' has unknown atlasProfile '{s}', using default", .{ key, name });
        return config.defaultRuntimeAtlasProfile;
    };
    return profile;
}

fn initParticles() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("particles.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read particles.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        particlesPerUnit: f32,
        maxParticles: u32,
        minSpeedVariation: f32,
        maxSpeedVariation: f32,
        minScale: f32,
        maxScale: f32,
        defaultDirection: ParticleDirection = .radial,
        lifetimeMs: u32,
        color: sprite.Color,
        stain: ?ParticleStainData = null,
        linearDamping: f32,
        gravityScale: f32,
        density: f32,
        friction: f32,
        restitution: f32,
        groupIndex: i32,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse particles.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = allocator.dupe(u8, entry.key) catch continue;

        particleDataMap.put(allocator, key, .{
            .particlesPerUnit = entry.particlesPerUnit,
            .maxParticles = entry.maxParticles,
            .minSpeedVariation = entry.minSpeedVariation,
            .maxSpeedVariation = entry.maxSpeedVariation,
            .minScale = entry.minScale,
            .maxScale = entry.maxScale,
            .defaultDirection = entry.defaultDirection,
            .lifetimeMs = entry.lifetimeMs,
            .color = entry.color,
            .stain = entry.stain,
            .linearDamping = entry.linearDamping,
            .gravityScale = entry.gravityScale,
            .density = entry.density,
            .friction = entry.friction,
            .restitution = entry.restitution,
            .groupIndex = entry.groupIndex,
        }) catch {
            allocator.free(key);
            continue;
        };

        std.debug.print("Parsed particle data '{s}'\n", .{key});
    }
}

fn initAnimations() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("animations.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read animations.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        path: []const u8,
        fps: i32 = 8,
        heightMeters: f32,
        offsetMeters: vec.Vec2 = vec.zero,
        loop: bool = true,
        spriteIndex: usize = 0,
        switchDelay: f64 = 0,
        markers: sprite.MarkerExtraction = .{},
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse animations.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = allocator.dupe(u8, entry.key) catch continue;
        const path = allocator.dupe(u8, entry.path) catch {
            allocator.free(key);
            continue;
        };

        animationDataMap.put(allocator, key, .{
            .path = path,
            .fps = entry.fps,
            .heightMeters = entry.heightMeters,
            .offsetMeters = entry.offsetMeters,
            .loop = entry.loop,
            .spriteIndex = entry.spriteIndex,
            .switchDelay = entry.switchDelay,
            .markers = entry.markers,
        }) catch {
            allocator.free(key);
            allocator.free(path);
            continue;
        };

        std.debug.print("Parsed animation data '{s}'\n", .{key});
    }
}

fn initSounds() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("sounds.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read sounds.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        path: []const u8,
        durationMs: u32 = 10000,
        volume: f32 = 1.0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse sounds.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = allocator.dupe(u8, entry.key) catch continue;
        const path = allocator.dupe(u8, entry.path) catch {
            allocator.free(key);
            continue;
        };

        soundDataMap.put(allocator, key, .{
            .path = path,
            .durationMs = entry.durationMs,
            .volume = entry.volume,
        }) catch {
            allocator.free(key);
            allocator.free(path);
            continue;
        };

        std.debug.print("Parsed sound data '{s}'\n", .{key});
    }
}

fn initExplosions() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("explosions.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read explosions.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        sound: ?[]const u8 = null,
        visual: ?[]const u8 = null,
        maximumDamage: f32 = 0,
        maximumPlayerVelocityChange: f32 = 0,
        maximumObjectImpulse: f32 = 0,
        blastRadius: f32 = 2.0,
        pressureRadius: ?f32 = null,
        cutoutIrregularity: f32 = 0.16,
        cutoutCharWidth: f32 = 0.12,
        cutoutCharStrength: f32 = 0.75,
        cutoutHotRimWidth: f32 = 0.06,
        cutoutHotRimDurationMs: u32 = 600,
        damagePlayers: bool = true,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse explosions.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        if (!std.math.isFinite(entry.cutoutIrregularity) or
            entry.cutoutIrregularity < 0 or
            entry.cutoutIrregularity > surface_cutout.maximumIrregularity)
        {
            std.log.err(
                "initExplosions: explosion '{s}' has invalid cutout irregularity {d}; expected 0 to {d}",
                .{ entry.key, entry.cutoutIrregularity, surface_cutout.maximumIrregularity },
            );
            continue;
        }
        if (!std.math.isFinite(entry.cutoutCharWidth) or entry.cutoutCharWidth < 0 or
            !std.math.isFinite(entry.cutoutCharStrength) or
            entry.cutoutCharStrength < 0 or entry.cutoutCharStrength > 1)
        {
            std.log.err("initExplosions: explosion '{s}' has invalid cutout charring", .{entry.key});
            continue;
        }
        if (!std.math.isFinite(entry.cutoutHotRimWidth) or entry.cutoutHotRimWidth < 0) {
            std.log.err("initExplosions: explosion '{s}' has invalid hot-rim width", .{entry.key});
            continue;
        }

        const key = allocator.dupe(u8, entry.key) catch continue;
        const soundKey = if (entry.sound) |s|
            allocator.dupe(u8, s) catch {
                allocator.free(key);
                continue;
            }
        else
            null;
        const visualKey = if (entry.visual) |visual|
            allocator.dupe(u8, visual) catch {
                allocator.free(key);
                if (soundKey) |sound| allocator.free(sound);
                continue;
            }
        else
            null;
        explosionDataMap.put(allocator, key, .{
            .sound = soundKey,
            .visual = visualKey,
            .maximumDamage = entry.maximumDamage,
            .maximumPlayerVelocityChange = entry.maximumPlayerVelocityChange,
            .maximumObjectImpulse = entry.maximumObjectImpulse,
            .blastRadius = entry.blastRadius,
            .pressureRadius = entry.pressureRadius orelse entry.blastRadius,
            .cutoutIrregularity = entry.cutoutIrregularity,
            .cutoutCharWidth = entry.cutoutCharWidth,
            .cutoutCharStrength = entry.cutoutCharStrength,
            .cutoutHotRimWidth = entry.cutoutHotRimWidth,
            .cutoutHotRimDurationMs = entry.cutoutHotRimDurationMs,
            .damagePlayers = entry.damagePlayers,
        }) catch {
            allocator.free(key);
            if (soundKey) |sk| allocator.free(sk);
            if (visualKey) |visual| allocator.free(visual);
            continue;
        };

        std.debug.print("Parsed explosion data '{s}'\n", .{key});
    }
}

fn initProjectiles() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("projectiles.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read projectiles.json: {}\n", .{err});
        return;
    };

    const Entry = struct {
        key: []const u8,
        gravityScale: f32 = 0.2,
        density: f32 = 10,
        launchSpeed: f32 = 0,
        linearDamping: f32 = 0,
        propulsion: f32 = 40,
        lateralDamping: f32 = 10,
        animation: []const u8,
        propulsionAnimation: ?[]const u8 = null,
        explosion: ?[]const u8 = null,
        impactBehavior: []const u8 = "destroy",
        flightRotation: []const u8 = "fixed",
        stickDepth: f32 = 0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse projectiles.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const impactBehavior = std.meta.stringToEnum(projectile.ImpactBehavior, entry.impactBehavior) orelse {
            std.log.warn("initProjectiles: projectile '{s}' has invalid impact behavior '{s}'", .{ entry.key, entry.impactBehavior });
            continue;
        };
        const flightRotation = std.meta.stringToEnum(projectile.FlightRotation, entry.flightRotation) orelse {
            std.log.warn("initProjectiles: projectile '{s}' has invalid flight rotation '{s}'", .{ entry.key, entry.flightRotation });
            continue;
        };
        const key = allocator.dupe(u8, entry.key) catch continue;
        const animKey = allocator.dupe(u8, entry.animation) catch {
            allocator.free(key);
            continue;
        };
        const explosionKey = if (entry.explosion) |explosion|
            allocator.dupe(u8, explosion) catch {
                allocator.free(key);
                allocator.free(animKey);
                continue;
            }
        else
            null;
        const propAnimKey = if (entry.propulsionAnimation) |pa|
            allocator.dupe(u8, pa) catch {
                allocator.free(key);
                allocator.free(animKey);
                if (explosionKey) |explosion| allocator.free(explosion);
                continue;
            }
        else
            null;

        projectileDataMap.put(allocator, key, .{
            .gravityScale = entry.gravityScale,
            .density = entry.density,
            .launchSpeed = entry.launchSpeed,
            .linearDamping = entry.linearDamping,
            .propulsion = entry.propulsion,
            .lateralDamping = entry.lateralDamping,
            .animation = animKey,
            .propulsionAnimation = propAnimKey,
            .explosion = explosionKey,
            .impactBehavior = impactBehavior,
            .flightRotation = flightRotation,
            .stickDepth = entry.stickDepth,
        }) catch {
            allocator.free(key);
            allocator.free(animKey);
            if (explosionKey) |explosion| allocator.free(explosion);
            if (propAnimKey) |pa| allocator.free(pa);
            continue;
        };

        std.debug.print("Parsed projectile data '{s}'\n", .{key});
    }
}

fn initWeapons() !void {
    var jsonBuf: [16384]u8 = undefined;
    const jsonData = fs.readFile("weapons.json", &jsonBuf) catch |err| {
        std.debug.print("Warning: Could not read weapons.json: {}\n", .{err});
        return;
    };

    const PelletEntry = struct {
        gravityScale: f32 = 0.5,
        density: f32 = 2.0,
        friction: f32 = 0.3,
        radius: f32 = 0.05,
        spriteDiameterMeters: f32 = 0.12,
        count: u32 = 1,
        spreadAngle: f32 = 0,
        spawnRadius: f32 = 0.15,
        explosion: ?[]const u8 = null,
        color: sprite.Color = .{ .r = 255, .g = 255, .b = 255 },
    };

    const Entry = struct {
        key: []const u8,
        sprite: []const u8,
        delay: u32 = 500,
        sound: []const u8,
        impulse: f32 = 10,
        projectile: ?[]const u8 = null,
        pellet: ?PelletEntry = null,
        explosion: ?[]const u8 = null,
        range: f32 = 50,
        trailDurationMs: u32 = 0,
        trailColor: sprite.Color = .{ .r = 255, .g = 255, .b = 255 },
        directDamage: f32 = 0,
        penetration: []const u8 = "non_penetrating",
    };

    const parsed = std.json.parseFromSlice([]const Entry, allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse weapons.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const penetration = std.meta.stringToEnum(projectile.PenetrationMode, entry.penetration) orelse {
            std.log.warn("initWeapons: weapon '{s}' has invalid penetration mode '{s}'", .{ entry.key, entry.penetration });
            continue;
        };
        const key = allocator.dupe(u8, entry.key) catch continue;
        const spriteKey = allocator.dupe(u8, entry.sprite) catch {
            allocator.free(key);
            continue;
        };
        const soundKey = allocator.dupe(u8, entry.sound) catch {
            allocator.free(key);
            allocator.free(spriteKey);
            continue;
        };
        const projKey = if (entry.projectile) |p|
            allocator.dupe(u8, p) catch {
                allocator.free(key);
                allocator.free(spriteKey);
                allocator.free(soundKey);
                continue;
            }
        else
            null;
        const pelletData: ?PelletData = if (entry.pellet) |pel| blk: {
            const pelletExplosionKey = if (pel.explosion) |explosion|
                allocator.dupe(u8, explosion) catch {
                    allocator.free(key);
                    allocator.free(spriteKey);
                    allocator.free(soundKey);
                    if (projKey) |pk| allocator.free(pk);
                    continue;
                }
            else
                null;
            break :blk .{
                .gravityScale = pel.gravityScale,
                .density = pel.density,
                .friction = pel.friction,
                .radius = pel.radius,
                .spriteDiameterMeters = pel.spriteDiameterMeters,
                .count = pel.count,
                .spreadAngle = pel.spreadAngle,
                .spawnRadius = pel.spawnRadius,
                .color = pel.color,
                .explosion = pelletExplosionKey,
            };
        } else null;
        const explosionKey = if (entry.explosion) |e|
            allocator.dupe(u8, e) catch {
                allocator.free(key);
                allocator.free(spriteKey);
                allocator.free(soundKey);
                if (projKey) |pk| allocator.free(pk);
                if (pelletData) |pd| {
                    if (pd.explosion) |explosion| allocator.free(explosion);
                }
                continue;
            }
        else
            null;

        weaponDataMap.put(allocator, key, .{
            .sprite = spriteKey,
            .delay = entry.delay,
            .sound = soundKey,
            .impulse = entry.impulse,
            .projectile = projKey,
            .pellet = pelletData,
            .explosion = explosionKey,
            .range = entry.range,
            .trailDurationMs = entry.trailDurationMs,
            .trailColor = entry.trailColor,
            .directDamage = entry.directDamage,
            .penetration = penetration,
        }) catch {
            allocator.free(key);
            allocator.free(spriteKey);
            allocator.free(soundKey);
            if (projKey) |pk| allocator.free(pk);
            if (pelletData) |pd| {
                if (pd.explosion) |explosion| allocator.free(explosion);
            }
            if (explosionKey) |ek| allocator.free(ek);
            continue;
        };

        std.debug.print("Parsed weapon data '{s}'\n", .{key});
    }
}

pub fn createSpriteFrom(key: []const u8) ?u64 {
    return createSpriteFromWithBacking(key, .immutable);
}

pub fn createSpriteFromWithBacking(key: []const u8, backing: sprite.Backing) ?u64 {
    const d = spriteDataMap.get(key) orelse return null;
    return sprite.createFromImgWorldHeightWithBacking(d.path, d.heightMeters, vec.zero, backing, d.atlasProfile, d.markers) catch |err| {
        std.debug.print("Warning: Failed to create sprite for '{s}': {}\n", .{ key, err });
        return null;
    };
}

pub fn createAnimationFrom(key: []const u8) !animation.Animation {
    return createAnimationFromWithBacking(key, .immutable);
}

pub fn createAnimationFromWithBacking(key: []const u8, backing: sprite.Backing) !animation.Animation {
    const d = animationDataMap.get(key) orelse return error.AnimationDataNotFound;
    var anim = try animation.loadWorldHeightWithBacking(d.path, d.fps, d.heightMeters, d.offsetMeters, d.loop, d.spriteIndex, backing, d.markers);
    anim.switchDelay = d.switchDelay;
    return anim;
}

pub fn createAudioFrom(key: []const u8) ?audio.Audio {
    const d = soundDataMap.get(key) orelse return null;
    return audio.Audio{
        .file = d.path,
        .durationMs = d.durationMs,
        .volume = d.volume,
    };
}

fn explosionVisualIdForName(name: ?[]const u8) !?explosion_visual.Id {
    if (name == null) return null;
    const visualName = name.?;
    const visualId = explosion_visual.idForName(visualName) orelse {
        std.log.err("explosionVisualIdForName: explosion visual preset '{s}' is missing", .{visualName});
        return error.ExplosionVisualPresetNotFound;
    };
    return visualId;
}

pub fn createExplosionFrom(key: []const u8) !projectile.Explosion {
    const d = explosionDataMap.get(key) orelse return error.ExplosionDataNotFound;
    const sound = if (d.sound) |sk| createAudioFrom(sk) else null;
    const visual = try explosionVisualIdForName(d.visual);
    return projectile.Explosion{
        .sound = sound,
        .visual = visual,
        .maximumDamage = d.maximumDamage,
        .maximumPlayerVelocityChange = d.maximumPlayerVelocityChange,
        .maximumObjectImpulse = d.maximumObjectImpulse,
        .blastRadius = d.blastRadius,
        .pressureRadius = d.pressureRadius,
        .cutoutIrregularity = d.cutoutIrregularity,
        .cutoutCharWidth = d.cutoutCharWidth,
        .cutoutCharStrength = d.cutoutCharStrength,
        .cutoutHotRimWidth = d.cutoutHotRimWidth,
        .cutoutHotRimDurationMs = d.cutoutHotRimDurationMs,
        .cutoutSeedSalt = std.hash.Wyhash.hash(0, key),
        .damagePlayers = d.damagePlayers,
    };
}

pub fn createProjectileFrom(key: []const u8) !weapon.Projectile {
    const d = projectileDataMap.get(key) orelse return error.ProjectileDataNotFound;
    const anim = try createAnimationFrom(d.animation);
    const explosion = if (d.explosion) |explosionKey|
        try createExplosionFrom(explosionKey)
    else
        null;
    const propAnim = if (d.propulsionAnimation) |paKey|
        try createAnimationFrom(paKey)
    else
        null;
    const proj = weapon.Projectile{
        .gravityScale = d.gravityScale,
        .density = d.density,
        .launchSpeed = d.launchSpeed,
        .linearDamping = d.linearDamping,
        .propulsion = d.propulsion,
        .lateralDamping = d.lateralDamping,
        .animation = anim,
        .explosion = explosion,
        .propulsionAnimation = propAnim,
        .impactBehavior = d.impactBehavior,
        .flightRotation = d.flightRotation,
        .stickDepth = d.stickDepth,
    };
    try weapon.warmProjectileCollider(proj);
    return proj;
}

pub fn createWeaponFrom(key: []const u8) !weapon.Weapon {
    return createWeaponFromWithSpriteBacking(key, .immutable);
}

pub fn createWeaponFromWithSpriteBacking(key: []const u8, spriteBacking: sprite.Backing) !weapon.Weapon {
    const d = weaponDataMap.get(key) orelse return error.WeaponDataNotFound;
    const sound = createAudioFrom(d.sound) orelse return error.SoundDataNotFound;
    const proj = if (d.projectile) |projKey|
        try createProjectileFrom(projKey)
    else
        null;
    const pel: ?weapon.Pellet = if (d.pellet) |pelData|
        .{
            .gravityScale = pelData.gravityScale,
            .density = pelData.density,
            .friction = pelData.friction,
            .radius = pelData.radius,
            .spriteDiameterMeters = pelData.spriteDiameterMeters,
            .count = pelData.count,
            .spreadAngle = pelData.spreadAngle,
            .spawnRadius = pelData.spawnRadius,
            .explosion = if (pelData.explosion) |explosionKey|
                try createExplosionFrom(explosionKey)
            else
                null,
            .color = pelData.color,
        }
    else
        null;
    const hitscanExp = if (d.explosion) |eKey|
        try createExplosionFrom(eKey)
    else
        null;
    const spriteUuid = createSpriteFromWithBacking(d.sprite, spriteBacking) orelse 0;
    return weapon.Weapon{
        .name = key,
        .delay = d.delay,
        .sound = sound,
        .impulse = d.impulse,
        .projectile = proj,
        .pellet = pel,
        .spriteUuid = spriteUuid,
        .hitscanExplosion = hitscanExp,
        .range = d.range,
        .trailDurationMs = d.trailDurationMs,
        .trailColor = d.trailColor,
        .directDamage = d.directDamage,
        .penetration = d.penetration,
    };
}

pub fn getAnimationData(key: []const u8) ?AnimationData {
    return animationDataMap.get(key);
}

pub fn getSpriteData(key: []const u8) ?SpriteData {
    return spriteDataMap.get(key);
}

pub fn createGibletSprite(giblet: GibletData) !u64 {
    return sprite.createFromImgWorldHeightWithBacking(
        giblet.path,
        giblet.heightMeters,
        vec.zero,
        .immutable,
        config.defaultRuntimeAtlasProfile,
        .{},
    );
}

pub fn getParticleData(key: []const u8) ?ParticleData {
    return particleDataMap.get(key);
}

pub fn cleanup() void {
    var spriteIter = spriteDataMap.iterator();
    while (spriteIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.path);
    }
    spriteDataMap.deinit(allocator);

    for (gibletData) |giblet| allocator.free(giblet.path);
    allocator.free(gibletData);
    gibletData = &.{};

    var particleIter = particleDataMap.iterator();
    while (particleIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    particleDataMap.deinit(allocator);

    var animIter = animationDataMap.iterator();
    while (animIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.path);
    }
    animationDataMap.deinit(allocator);

    var soundIter = soundDataMap.iterator();
    while (soundIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.path);
    }
    soundDataMap.deinit(allocator);

    var explosionIter = explosionDataMap.iterator();
    while (explosionIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.sound) |s| allocator.free(s);
        if (entry.value_ptr.visual) |visual| allocator.free(visual);
    }
    explosionDataMap.deinit(allocator);

    var explosionVisualIter = explosionVisualDataMap.iterator();
    while (explosionVisualIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    explosionVisualDataMap.deinit(allocator);

    var projIter = projectileDataMap.iterator();
    while (projIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.animation);
        if (entry.value_ptr.explosion) |explosion| allocator.free(explosion);
        if (entry.value_ptr.propulsionAnimation) |pa| allocator.free(pa);
    }
    projectileDataMap.deinit(allocator);

    var weaponIter = weaponDataMap.iterator();
    while (weaponIter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.sprite);
        allocator.free(entry.value_ptr.sound);
        if (entry.value_ptr.projectile) |p| allocator.free(p);
        if (entry.value_ptr.pellet) |pel| {
            if (pel.explosion) |explosion| allocator.free(explosion);
        }
        if (entry.value_ptr.explosion) |e| allocator.free(e);
    }
    weaponDataMap.deinit(allocator);
}
