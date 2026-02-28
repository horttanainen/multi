const std = @import("std");
const sprite = @import("sprite.zig");
const animation = @import("animation.zig");
const shared = @import("shared.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");
const audio = @import("audio.zig");
const projectile = @import("projectile.zig");
const weapon = @import("weapon.zig");

pub const SpriteData = struct {
    path: []const u8,
    scale: f32,
};

pub const AnimationData = struct {
    path: []const u8,
    fps: i32,
    scale: f32,
    offsetX: i32,
    offsetY: i32,
    loop: bool,
    spriteIndex: usize,
    switchDelay: f64,
};

pub const SoundData = struct {
    path: []const u8,
    durationMs: u32,
    volume: f32,
};

pub const ExplosionData = struct {
    sound: []const u8,
    animation: []const u8,
    blastPower: f32,
    blastRadius: f32,
    particleCount: u32,
    particleDensity: f32,
    particleFriction: f32,
    particleRestitution: f32,
    particleRadius: f32,
    particleLinearDamping: f32,
    particleGravityScale: f32,
};

pub const ProjectileData = struct {
    gravityScale: f32,
    density: f32,
    propulsion: f32,
    lateralDamping: f32,
    animation: []const u8,
    propulsionAnimation: ?[]const u8,
    explosion: []const u8,
};

pub const WeaponData = struct {
    sprite: []const u8,
    delay: u32,
    sound: []const u8,
    impulse: f32,
    projectile: []const u8,
};

var spriteDataMap: std.StringHashMapUnmanaged(SpriteData) = .{};
var animationDataMap: std.StringHashMapUnmanaged(AnimationData) = .{};
var soundDataMap: std.StringHashMapUnmanaged(SoundData) = .{};
var explosionDataMap: std.StringHashMapUnmanaged(ExplosionData) = .{};
var projectileDataMap: std.StringHashMapUnmanaged(ProjectileData) = .{};
var weaponDataMap: std.StringHashMapUnmanaged(WeaponData) = .{};

pub fn init() !void {
    try initSprites();
    try initAnimations();
    try initSounds();
    try initExplosions();
    try initProjectiles();
    try initWeapons();
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
        scale: f32 = 1.0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse sprites.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const path = shared.allocator.dupe(u8, entry.path) catch {
            shared.allocator.free(key);
            continue;
        };

        spriteDataMap.put(shared.allocator, key, .{
            .path = path,
            .scale = entry.scale,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(path);
            continue;
        };

        std.debug.print("Parsed sprite data '{s}'\n", .{key});
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
        scale: f32 = 1.0,
        offsetX: i32 = 0,
        offsetY: i32 = 0,
        loop: bool = true,
        spriteIndex: usize = 0,
        switchDelay: f64 = 0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse animations.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const path = shared.allocator.dupe(u8, entry.path) catch {
            shared.allocator.free(key);
            continue;
        };

        animationDataMap.put(shared.allocator, key, .{
            .path = path,
            .fps = entry.fps,
            .scale = entry.scale,
            .offsetX = entry.offsetX,
            .offsetY = entry.offsetY,
            .loop = entry.loop,
            .spriteIndex = entry.spriteIndex,
            .switchDelay = entry.switchDelay,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(path);
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

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse sounds.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const path = shared.allocator.dupe(u8, entry.path) catch {
            shared.allocator.free(key);
            continue;
        };

        soundDataMap.put(shared.allocator, key, .{
            .path = path,
            .durationMs = entry.durationMs,
            .volume = entry.volume,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(path);
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
        sound: []const u8,
        animation: []const u8,
        blastPower: f32 = 100,
        blastRadius: f32 = 2.0,
        particleCount: u32 = 100,
        particleDensity: f32 = 1.5,
        particleFriction: f32 = 0,
        particleRestitution: f32 = 0.99,
        particleRadius: f32 = 0.05,
        particleLinearDamping: f32 = 10,
        particleGravityScale: f32 = 0,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse explosions.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const soundKey = shared.allocator.dupe(u8, entry.sound) catch {
            shared.allocator.free(key);
            continue;
        };
        const animKey = shared.allocator.dupe(u8, entry.animation) catch {
            shared.allocator.free(key);
            shared.allocator.free(soundKey);
            continue;
        };

        explosionDataMap.put(shared.allocator, key, .{
            .sound = soundKey,
            .animation = animKey,
            .blastPower = entry.blastPower,
            .blastRadius = entry.blastRadius,
            .particleCount = entry.particleCount,
            .particleDensity = entry.particleDensity,
            .particleFriction = entry.particleFriction,
            .particleRestitution = entry.particleRestitution,
            .particleRadius = entry.particleRadius,
            .particleLinearDamping = entry.particleLinearDamping,
            .particleGravityScale = entry.particleGravityScale,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(soundKey);
            shared.allocator.free(animKey);
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
        propulsion: f32 = 40,
        lateralDamping: f32 = 10,
        animation: []const u8,
        propulsionAnimation: ?[]const u8 = null,
        explosion: []const u8,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse projectiles.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const animKey = shared.allocator.dupe(u8, entry.animation) catch {
            shared.allocator.free(key);
            continue;
        };
        const explosionKey = shared.allocator.dupe(u8, entry.explosion) catch {
            shared.allocator.free(key);
            shared.allocator.free(animKey);
            continue;
        };
        const propAnimKey = if (entry.propulsionAnimation) |pa|
            shared.allocator.dupe(u8, pa) catch {
                shared.allocator.free(key);
                shared.allocator.free(animKey);
                shared.allocator.free(explosionKey);
                continue;
            }
        else
            null;

        projectileDataMap.put(shared.allocator, key, .{
            .gravityScale = entry.gravityScale,
            .density = entry.density,
            .propulsion = entry.propulsion,
            .lateralDamping = entry.lateralDamping,
            .animation = animKey,
            .propulsionAnimation = propAnimKey,
            .explosion = explosionKey,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(animKey);
            shared.allocator.free(explosionKey);
            if (propAnimKey) |pa| shared.allocator.free(pa);
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

    const Entry = struct {
        key: []const u8,
        sprite: []const u8,
        delay: u32 = 500,
        sound: []const u8,
        impulse: f32 = 10,
        projectile: []const u8,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse weapons.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const spriteKey = shared.allocator.dupe(u8, entry.sprite) catch {
            shared.allocator.free(key);
            continue;
        };
        const soundKey = shared.allocator.dupe(u8, entry.sound) catch {
            shared.allocator.free(key);
            shared.allocator.free(spriteKey);
            continue;
        };
        const projKey = shared.allocator.dupe(u8, entry.projectile) catch {
            shared.allocator.free(key);
            shared.allocator.free(spriteKey);
            shared.allocator.free(soundKey);
            continue;
        };

        weaponDataMap.put(shared.allocator, key, .{
            .sprite = spriteKey,
            .delay = entry.delay,
            .sound = soundKey,
            .impulse = entry.impulse,
            .projectile = projKey,
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(spriteKey);
            shared.allocator.free(soundKey);
            shared.allocator.free(projKey);
            continue;
        };

        std.debug.print("Parsed weapon data '{s}'\n", .{key});
    }
}

pub fn createSpriteFrom(key: []const u8) ?u64 {
    const d = spriteDataMap.get(key) orelse return null;
    return sprite.createFromImg(d.path, .{ .x = d.scale, .y = d.scale }, vec.izero) catch |err| {
        std.debug.print("Warning: Failed to create sprite for '{s}': {}\n", .{ key, err });
        return null;
    };
}

pub fn createAnimationFrom(key: []const u8) !animation.Animation {
    const d = animationDataMap.get(key) orelse return error.AnimationDataNotFound;
    const scale = vec.Vec2{ .x = d.scale, .y = d.scale };
    const offset = vec.IVec2{ .x = d.offsetX, .y = d.offsetY };
    var anim = try animation.load(d.path, d.fps, scale, offset, d.loop, d.spriteIndex);
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

pub fn createExplosionFrom(key: []const u8) !projectile.Explosion {
    const d = explosionDataMap.get(key) orelse return error.ExplosionDataNotFound;
    const sound = createAudioFrom(d.sound) orelse return error.SoundDataNotFound;
    const anim = try createAnimationFrom(d.animation);
    return projectile.Explosion{
        .sound = sound,
        .animation = anim,
        .blastPower = d.blastPower,
        .blastRadius = d.blastRadius,
        .particleCount = d.particleCount,
        .particleDensity = d.particleDensity,
        .particleFriction = d.particleFriction,
        .particleRestitution = d.particleRestitution,
        .particleRadius = d.particleRadius,
        .particleLinearDamping = d.particleLinearDamping,
        .particleGravityScale = d.particleGravityScale,
    };
}

pub fn createProjectileFrom(key: []const u8) !weapon.Projectile {
    const d = projectileDataMap.get(key) orelse return error.ProjectileDataNotFound;
    const anim = try createAnimationFrom(d.animation);
    const explosion = try createExplosionFrom(d.explosion);
    const propAnim = if (d.propulsionAnimation) |paKey|
        try createAnimationFrom(paKey)
    else
        null;
    return weapon.Projectile{
        .gravityScale = d.gravityScale,
        .density = d.density,
        .propulsion = d.propulsion,
        .lateralDamping = d.lateralDamping,
        .animation = anim,
        .explosion = explosion,
        .propulsionAnimation = propAnim,
    };
}

pub fn createWeaponFrom(key: []const u8) !weapon.Weapon {
    const d = weaponDataMap.get(key) orelse return error.WeaponDataNotFound;
    const sound = createAudioFrom(d.sound) orelse return error.SoundDataNotFound;
    const proj = try createProjectileFrom(d.projectile);
    const spriteUuid = createSpriteFrom(d.sprite) orelse 0;
    return weapon.Weapon{
        .name = key,
        .delay = d.delay,
        .sound = sound,
        .impulse = d.impulse,
        .projectile = proj,
        .spriteUuid = spriteUuid,
    };
}

pub fn getAnimationData(key: []const u8) ?AnimationData {
    return animationDataMap.get(key);
}

pub fn getSpriteData(key: []const u8) ?SpriteData {
    return spriteDataMap.get(key);
}

pub fn cleanup() void {
    var spriteIter = spriteDataMap.iterator();
    while (spriteIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    spriteDataMap.deinit(shared.allocator);

    var animIter = animationDataMap.iterator();
    while (animIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    animationDataMap.deinit(shared.allocator);

    var soundIter = soundDataMap.iterator();
    while (soundIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.path);
    }
    soundDataMap.deinit(shared.allocator);

    var explosionIter = explosionDataMap.iterator();
    while (explosionIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.sound);
        shared.allocator.free(entry.value_ptr.animation);
    }
    explosionDataMap.deinit(shared.allocator);

    var projIter = projectileDataMap.iterator();
    while (projIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.animation);
        shared.allocator.free(entry.value_ptr.explosion);
        if (entry.value_ptr.propulsionAnimation) |pa| shared.allocator.free(pa);
    }
    projectileDataMap.deinit(shared.allocator);

    var weaponIter = weaponDataMap.iterator();
    while (weaponIter.next()) |entry| {
        shared.allocator.free(entry.key_ptr.*);
        shared.allocator.free(entry.value_ptr.sprite);
        shared.allocator.free(entry.value_ptr.sound);
        shared.allocator.free(entry.value_ptr.projectile);
    }
    weaponDataMap.deinit(shared.allocator);
}
