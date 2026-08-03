const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const camera = @import("camera.zig");
const conv = @import("conversion.zig");
const runtime = @import("runtime.zig");
const sprite = @import("sprite.zig");
const tex = @import("texture.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");
const visual_particle = @import("visual_particle.zig");

pub const Id = u64;

pub const Preset = struct {
    flash_duration_ms: u32,
    flash_start_radius: f32,
    flash_end_radius: f32,
    flash_max_alpha: u8,
    flash_color: sprite.Color,
    ember_count: u32,
    ember_min_speed: f32,
    ember_max_speed: f32,
    ember_min_lifetime_ms: u32,
    ember_max_lifetime_ms: u32,
    ember_min_diameter: f32,
    ember_max_diameter: f32,
    ember_end_diameter_scale: f32,
    ember_drag: f32,
    ember_gravity: f32,
    ember_surface_bias: f32,
    ember_start_color: sprite.Color,
    ember_end_color: sprite.Color,
    smoke_count: u32,
    smoke_min_radius: f32,
    smoke_max_radius: f32,
    smoke_min_delay_ms: u32,
    smoke_max_delay_ms: u32,
    smoke_fade_in_ms: u32,
    smoke_min_speed: f32,
    smoke_max_speed: f32,
    smoke_min_lifetime_ms: u32,
    smoke_max_lifetime_ms: u32,
    smoke_min_diameter: f32,
    smoke_max_diameter: f32,
    smoke_end_diameter_scale: f32,
    smoke_drag: f32,
    smoke_upward_acceleration: f32,
    smoke_outward_bias: f32,
    smoke_upward_bias: f32,
    smoke_max_alpha: u8,
    smoke_start_color: sprite.Color,
    smoke_end_color: sprite.Color,
};

pub const Capture = struct {
    impact_position: vec.Vec2,
    pressure_source_position: vec.Vec2,
    blast_radius: f32,
    pressure_radius: f32,
};

pub const Event = struct {
    preset_id: Id,
    impact_position: vec.Vec2,
    pressure_source_position: vec.Vec2,
    blast_radius: f32,
    pressure_radius: f32,
    started_at: f64,
    seed: u64,
};

pub var presets = std.AutoArrayHashMapUnmanaged(Id, Preset).empty;
pub var events = std.ArrayListUnmanaged(Event).empty;
var presetNames = std.AutoArrayHashMapUnmanaged(Id, []const u8).empty;
var circleSpriteUuid: ?u64 = null;
var flashSpriteUuid: ?u64 = null;
var smokeSpriteUuid: ?u64 = null;

const Random = struct {
    state: u64,
};

var visualRandom = Random{ .state = 1 };

const maximumSmokeParticlesPerExplosion: usize = 64;

fn idFromName(name: []const u8) Id {
    return std.hash.Wyhash.hash(0, name);
}

fn validateEmberPreset(name: []const u8, preset: Preset) !void {
    if (preset.ember_count == 0) return;
    if (!std.math.isFinite(preset.ember_min_speed) or !std.math.isFinite(preset.ember_max_speed) or
        preset.ember_min_speed < 0 or preset.ember_max_speed < preset.ember_min_speed)
    {
        std.log.err("explosion_visual.validateEmberPreset: preset '{s}' has invalid ember speeds", .{name});
        return error.InvalidExplosionVisualEmberSpeed;
    }
    if (preset.ember_min_lifetime_ms == 0 or preset.ember_max_lifetime_ms < preset.ember_min_lifetime_ms) {
        std.log.err("explosion_visual.validateEmberPreset: preset '{s}' has invalid ember lifetimes", .{name});
        return error.InvalidExplosionVisualEmberLifetime;
    }
    if (!std.math.isFinite(preset.ember_min_diameter) or !std.math.isFinite(preset.ember_max_diameter) or
        preset.ember_min_diameter <= 0 or preset.ember_max_diameter < preset.ember_min_diameter or
        !std.math.isFinite(preset.ember_end_diameter_scale) or preset.ember_end_diameter_scale <= 0)
    {
        std.log.err("explosion_visual.validateEmberPreset: preset '{s}' has invalid ember diameters", .{name});
        return error.InvalidExplosionVisualEmberDiameter;
    }
    if (!std.math.isFinite(preset.ember_drag) or preset.ember_drag < 0 or
        !std.math.isFinite(preset.ember_gravity) or
        !std.math.isFinite(preset.ember_surface_bias) or preset.ember_surface_bias < 0)
    {
        std.log.err("explosion_visual.validateEmberPreset: preset '{s}' has invalid ember motion", .{name});
        return error.InvalidExplosionVisualEmberMotion;
    }
}

fn validateSmokePreset(name: []const u8, preset: Preset) !void {
    if (preset.smoke_count == 0) return;
    if (@as(usize, preset.smoke_count) > maximumSmokeParticlesPerExplosion) {
        std.log.err(
            "explosion_visual.validateSmokePreset: preset '{s}' has {d} smoke particles, maximum is {d}",
            .{ name, preset.smoke_count, maximumSmokeParticlesPerExplosion },
        );
        return error.TooManyExplosionVisualSmokeParticles;
    }
    if (!std.math.isFinite(preset.smoke_min_radius) or !std.math.isFinite(preset.smoke_max_radius) or
        preset.smoke_min_radius < 0 or preset.smoke_max_radius < preset.smoke_min_radius)
    {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke radii", .{name});
        return error.InvalidExplosionVisualSmokeRadius;
    }
    if (preset.smoke_max_delay_ms < preset.smoke_min_delay_ms or preset.smoke_fade_in_ms >= preset.smoke_min_lifetime_ms) {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke timing", .{name});
        return error.InvalidExplosionVisualSmokeTiming;
    }
    if (!std.math.isFinite(preset.smoke_min_speed) or !std.math.isFinite(preset.smoke_max_speed) or
        preset.smoke_min_speed < 0 or preset.smoke_max_speed < preset.smoke_min_speed)
    {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke speeds", .{name});
        return error.InvalidExplosionVisualSmokeSpeed;
    }
    if (preset.smoke_min_lifetime_ms == 0 or preset.smoke_max_lifetime_ms < preset.smoke_min_lifetime_ms) {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke lifetimes", .{name});
        return error.InvalidExplosionVisualSmokeLifetime;
    }
    if (!std.math.isFinite(preset.smoke_min_diameter) or !std.math.isFinite(preset.smoke_max_diameter) or
        preset.smoke_min_diameter <= 0 or preset.smoke_max_diameter < preset.smoke_min_diameter or
        !std.math.isFinite(preset.smoke_end_diameter_scale) or preset.smoke_end_diameter_scale <= 0)
    {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke diameters", .{name});
        return error.InvalidExplosionVisualSmokeDiameter;
    }
    if (!std.math.isFinite(preset.smoke_drag) or preset.smoke_drag < 0 or
        !std.math.isFinite(preset.smoke_upward_acceleration) or preset.smoke_upward_acceleration < 0 or
        !std.math.isFinite(preset.smoke_outward_bias) or preset.smoke_outward_bias < 0 or
        !std.math.isFinite(preset.smoke_upward_bias) or preset.smoke_upward_bias < 0)
    {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has invalid smoke motion", .{name});
        return error.InvalidExplosionVisualSmokeMotion;
    }
    if (preset.smoke_max_alpha == 0) {
        std.log.err("explosion_visual.validateSmokePreset: preset '{s}' has no smoke opacity", .{name});
        return error.InvalidExplosionVisualSmokeOpacity;
    }
}

fn validatePreset(name: []const u8, preset: Preset) !void {
    if (preset.flash_duration_ms == 0) {
        std.log.err("explosion_visual.validatePreset: preset '{s}' has no flash duration", .{name});
        return error.InvalidExplosionVisualDuration;
    }
    if (!std.math.isFinite(preset.flash_start_radius) or !std.math.isFinite(preset.flash_end_radius) or
        preset.flash_start_radius <= 0 or preset.flash_end_radius < preset.flash_start_radius)
    {
        std.log.err("explosion_visual.validatePreset: preset '{s}' has invalid flash radii", .{name});
        return error.InvalidExplosionVisualRadius;
    }
    if (preset.flash_max_alpha == 0) {
        std.log.err("explosion_visual.validatePreset: preset '{s}' has no flash opacity", .{name});
        return error.InvalidExplosionVisualOpacity;
    }

    try validateEmberPreset(name, preset);
    try validateSmokePreset(name, preset);
}

pub fn init(sourcePresets: std.StringHashMapUnmanaged(Preset)) !void {
    errdefer cleanup();

    visualRandom.state = runtime.random().int(u64);
    if (visualRandom.state == 0) {
        std.log.warn("explosion_visual.init: random source returned zero, using fallback visual seed", .{});
        visualRandom.state = 0x9e3779b97f4a7c15;
    }

    circleSpriteUuid = try sprite.createFromImg("particles/circle.png", .{ .x = 1, .y = 1 }, vec.izero);
    flashSpriteUuid = try sprite.createFromImg("particles/explosion-flash.png", .{ .x = 1, .y = 1 }, vec.izero);
    smokeSpriteUuid = try sprite.createFromImg("particles/smoke-puff.png", .{ .x = 1, .y = 1 }, vec.izero);

    var iterator = sourcePresets.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const preset = entry.value_ptr.*;
        try validatePreset(name, preset);

        const id = idFromName(name);
        if (presets.contains(id)) {
            const existingName = presetNames.get(id) orelse "unknown";
            std.log.err("explosion_visual.init: preset ID collision between '{s}' and '{s}'", .{ existingName, name });
            return error.ExplosionVisualPresetIdCollision;
        }

        try presets.put(allocator, id, preset);
        try presetNames.put(allocator, id, name);
    }
}

pub fn idForName(name: []const u8) ?Id {
    const id = idFromName(name);
    if (!presets.contains(id)) return null;

    const registeredName = presetNames.get(id) orelse {
        std.log.err("explosion_visual.idForName: preset {d} has no registered name", .{id});
        return null;
    };
    if (std.mem.eql(u8, registeredName, name)) return id;

    std.log.err("explosion_visual.idForName: preset ID collision for '{s}'", .{name});
    return null;
}

fn positionIsFinite(position: vec.Vec2) bool {
    return std.math.isFinite(position.x) and std.math.isFinite(position.y);
}

fn randomNext(random: *Random) u64 {
    var value = random.state;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    random.state = value;
    return value;
}

fn randomFloat(random: *Random) f32 {
    const bits: u24 = @truncate(randomNext(random) >> 40);
    return @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(std.math.maxInt(u24)));
}

fn randomRange(random: *Random, minimum: f32, maximum: f32) f32 {
    return minimum + (maximum - minimum) * randomFloat(random);
}

fn randomRangeU32(random: *Random, minimum: u32, maximum: u32) u32 {
    if (minimum == maximum) return minimum;
    const range: u64 = @as(u64, maximum) - minimum + 1;
    return minimum + @as(u32, @intCast(randomNext(random) % range));
}

fn normalizedOrZero(value: vec.Vec2) vec.Vec2 {
    const magnitude = vec.magnitude(value);
    if (magnitude <= 0.0001) return vec.zero;
    return vec.mul(value, 1.0 / magnitude);
}

fn randomForEffect(event: Event, salt: u64) Random {
    const state = event.seed ^ event.preset_id ^ salt;
    if (state != 0) return .{ .state = state };

    std.log.warn("explosion_visual.randomForEffect: mixed visual seed was zero, using fallback", .{});
    return .{ .state = salt };
}

fn emitEmbers(event: Event, preset: Preset) !void {
    if (preset.ember_count == 0) return;
    const spriteUuid = circleSpriteUuid orelse {
        std.log.err("explosion_visual.emitEmbers: circle sprite is not initialized", .{});
        return error.ExplosionVisualNotInitialized;
    };

    var random = randomForEffect(event, 0x9e3779b97f4a7c15);

    const surfaceDirection = normalizedOrZero(vec.subtract(event.pressure_source_position, event.impact_position));
    var index: u32 = 0;
    while (index < preset.ember_count) : (index += 1) {
        const angle = randomRange(&random, 0, std.math.tau);
        const radialDirection = vec.Vec2{ .x = @cos(angle), .y = @sin(angle) };
        var direction = normalizedOrZero(vec.add(radialDirection, vec.mul(surfaceDirection, preset.ember_surface_bias)));
        if (vec.equals(direction, vec.zero)) direction = radialDirection;

        const speed = randomRange(&random, preset.ember_min_speed, preset.ember_max_speed);
        const diameter = randomRange(&random, preset.ember_min_diameter, preset.ember_max_diameter);
        const positionOffset = randomRange(&random, 0, @min(event.blast_radius, 0.08));
        try visual_particle.spawn(.{
            .sprite_uuid = spriteUuid,
            .position = vec.add(event.impact_position, vec.mul(direction, positionOffset)),
            .velocity = vec.mul(direction, speed),
            .gravity = .{ .x = 0, .y = preset.ember_gravity },
            .drag = preset.ember_drag,
            .start_diameter = diameter,
            .end_diameter = diameter * preset.ember_end_diameter_scale,
            .start_color = preset.ember_start_color,
            .end_color = preset.ember_end_color,
            .start_alpha = 255,
            .end_alpha = 0,
            .lifetime_ms = randomRangeU32(&random, preset.ember_min_lifetime_ms, preset.ember_max_lifetime_ms),
            .blend_mode = .additive,
        });
    }
}

fn emitSmoke(event: Event, preset: Preset) !void {
    if (preset.smoke_count == 0) return;
    const spriteUuid = smokeSpriteUuid orelse {
        std.log.err("explosion_visual.emitSmoke: smoke sprite is not initialized", .{});
        return error.ExplosionVisualNotInitialized;
    };

    var random = randomForEffect(event, 0xd1b54a32d192ed03);
    const upwardDirection = vec.Vec2{ .x = 0, .y = -1 };
    var index: u32 = 0;
    while (index < preset.smoke_count) : (index += 1) {
        const angle = randomRange(&random, 0, std.math.tau);
        const radialDirection = vec.Vec2{ .x = @cos(angle), .y = @sin(angle) };
        const radius = randomRange(&random, preset.smoke_min_radius, preset.smoke_max_radius);
        const smokePosition = vec.add(event.impact_position, vec.mul(radialDirection, radius));
        const horizontalJitter = vec.Vec2{ .x = randomRange(&random, -0.25, 0.25), .y = 0 };
        const biasedDirection = vec.add(
            horizontalJitter,
            vec.add(
                vec.mul(radialDirection, preset.smoke_outward_bias),
                vec.mul(upwardDirection, preset.smoke_upward_bias),
            ),
        );
        var direction = normalizedOrZero(biasedDirection);
        if (vec.equals(direction, vec.zero)) direction = upwardDirection;

        const diameter = randomRange(&random, preset.smoke_min_diameter, preset.smoke_max_diameter);
        try visual_particle.spawn(.{
            .sprite_uuid = spriteUuid,
            .position = smokePosition,
            .velocity = vec.mul(direction, randomRange(&random, preset.smoke_min_speed, preset.smoke_max_speed)),
            .gravity = .{ .x = 0, .y = -preset.smoke_upward_acceleration },
            .drag = preset.smoke_drag,
            .start_diameter = diameter,
            .end_diameter = diameter * preset.smoke_end_diameter_scale,
            .start_color = preset.smoke_start_color,
            .end_color = preset.smoke_end_color,
            .start_alpha = preset.smoke_max_alpha,
            .end_alpha = 0,
            .delay_ms = randomRangeU32(&random, preset.smoke_min_delay_ms, preset.smoke_max_delay_ms),
            .fade_in_ms = preset.smoke_fade_in_ms,
            .lifetime_ms = randomRangeU32(&random, preset.smoke_min_lifetime_ms, preset.smoke_max_lifetime_ms),
            .angle = randomRange(&random, 0, std.math.tau),
            .angular_velocity = randomRange(&random, -1.2, 1.2),
            .blend_mode = .alpha,
        });
    }
}

pub fn capture(presetId: Id, captureData: Capture) !void {
    const preset = presets.get(presetId) orelse {
        std.log.err("explosion_visual.capture: preset {d} is missing", .{presetId});
        return error.ExplosionVisualPresetNotFound;
    };
    if (!positionIsFinite(captureData.impact_position) or !positionIsFinite(captureData.pressure_source_position)) {
        std.log.err("explosion_visual.capture: explosion positions must be finite", .{});
        return error.InvalidExplosionVisualPosition;
    }
    if (!std.math.isFinite(captureData.blast_radius) or captureData.blast_radius < 0 or
        !std.math.isFinite(captureData.pressure_radius) or captureData.pressure_radius <= 0)
    {
        std.log.err("explosion_visual.capture: explosion radii are invalid", .{});
        return error.InvalidExplosionVisualRadius;
    }

    const event = Event{
        .preset_id = presetId,
        .impact_position = captureData.impact_position,
        .pressure_source_position = captureData.pressure_source_position,
        .blast_radius = captureData.blast_radius,
        .pressure_radius = captureData.pressure_radius,
        .started_at = time.realNow(),
        .seed = randomNext(&visualRandom),
    };
    try events.append(allocator, event);

    emitSmoke(event, preset) catch |err| {
        std.log.warn("explosion_visual.capture: failed to emit smoke for preset {d}: {}", .{ presetId, err });
    };
    emitEmbers(event, preset) catch |err| {
        std.log.warn("explosion_visual.capture: failed to emit embers for preset {d}: {}", .{ presetId, err });
    };
}

pub fn update() void {
    const now = time.realNow();
    var index: usize = 0;
    while (index < events.items.len) {
        const event = events.items[index];
        const preset = presets.get(event.preset_id) orelse {
            std.log.err("explosion_visual.update: preset {d} is missing", .{event.preset_id});
            _ = events.swapRemove(index);
            continue;
        };
        const lifetimeSeconds = @as(f64, @floatFromInt(preset.flash_duration_ms)) / 1000.0;
        if (now - event.started_at < lifetimeSeconds) {
            index += 1;
            continue;
        }
        _ = events.swapRemove(index);
    }
}

fn flashProgress(event: Event, preset: Preset, now: f64) f32 {
    const durationSeconds = @as(f64, @floatFromInt(preset.flash_duration_ms)) / 1000.0;
    const elapsed = now - event.started_at;
    return @floatCast(std.math.clamp(elapsed / durationSeconds, 0, 1));
}

fn drawFlash(flashSprite: sprite.Sprite, event: Event, preset: Preset, now: f64) !void {
    const progress = flashProgress(event, preset, now);
    if (progress >= 1) return;

    const remaining = 1.0 - progress;
    const easedProgress = 1.0 - remaining * remaining;
    const radius = preset.flash_start_radius +
        (preset.flash_end_radius - preset.flash_start_radius) * easedProgress;
    const diameterPixels = radius * 2.0 * conv.met2pix;
    const spriteScale = diameterPixels / @as(f32, @floatFromInt(flashSprite.surface.w));
    const fadeProgress = std.math.clamp((progress - 0.3) / 0.7, 0, 1);
    const alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(preset.flash_max_alpha)) * (1.0 - fadeProgress));
    if (alpha == 0) return;

    try tex.setTextureAlphaMod(flashSprite.texture, alpha);
    const center = camera.relativePosition(conv.m2Pixel(vec.toBox2d(event.impact_position)));
    const scale = vec.Vec2{ .x = spriteScale, .y = spriteScale };
    try sprite.drawWithScale(flashSprite, center, 0, scale, preset.flash_color);
}

pub fn draw() !void {
    if (events.items.len == 0) return;
    const spriteUuid = flashSpriteUuid orelse {
        std.log.err("explosion_visual.draw: flash sprite is not initialized", .{});
        return error.ExplosionVisualNotInitialized;
    };
    const flashSprite = sprite.getSprite(spriteUuid) orelse {
        std.log.err("explosion_visual.draw: flash sprite {d} is missing", .{spriteUuid});
        return error.SpriteNotFound;
    };

    const previousBlendMode = flashSprite.texture.blend_mode;
    const previousColor = flashSprite.texture.color_mod;
    try tex.setTextureBlendMode(flashSprite.texture, .add);
    defer {
        tex.setTextureBlendMode(flashSprite.texture, previousBlendMode) catch |err| {
            std.log.err("explosion_visual.draw: failed to restore flash blend mode: {}", .{err});
        };
        tex.setTextureColorMod(flashSprite.texture, previousColor.r, previousColor.g, previousColor.b) catch |err| {
            std.log.err("explosion_visual.draw: failed to restore flash color: {}", .{err});
        };
        tex.setTextureAlphaMod(flashSprite.texture, previousColor.a) catch |err| {
            std.log.err("explosion_visual.draw: failed to restore flash opacity: {}", .{err});
        };
    }

    const now = time.realNow();
    for (events.items) |event| {
        const preset = presets.get(event.preset_id) orelse {
            std.log.err("explosion_visual.draw: preset {d} is missing", .{event.preset_id});
            continue;
        };
        try drawFlash(flashSprite, event, preset, now);
    }
}

pub fn cleanup() void {
    events.clearAndFree(allocator);
    presets.clearAndFree(allocator);
    presetNames.clearAndFree(allocator);
    visualRandom.state = 1;
    circleSpriteUuid = null;
    flashSpriteUuid = null;
    smokeSpriteUuid = null;
}
