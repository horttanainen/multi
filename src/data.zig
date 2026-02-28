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
    sound: ?[]const u8,
    animation: ?[]const u8,
    blastPower: f32,
    blastRadius: f32,
    particleCount: u32,
    particleDensity: f32,
    particleFriction: f32,
    particleRestitution: f32,
    particleRadius: f32,
    particleLinearDamping: f32,
    particleGravityScale: f32,
    damagePlayers: bool,
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

pub const PelletData = struct {
    gravityScale: f32,
    density: f32,
    friction: f32,
    radius: f32,
    spriteScale: f32,
    count: u32,
    spreadAngle: f32,
    spawnRadius: f32,
    explosion: []const u8,
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
        sound: ?[]const u8 = null,
        animation: ?[]const u8 = null,
        blastPower: f32 = 0,
        blastRadius: f32 = 2.0,
        particleCount: u32 = 0,
        particleDensity: f32 = 1.5,
        particleFriction: f32 = 0,
        particleRestitution: f32 = 0.99,
        particleRadius: f32 = 0.05,
        particleLinearDamping: f32 = 10,
        particleGravityScale: f32 = 0,
        damagePlayers: bool = true,
    };

    const parsed = std.json.parseFromSlice([]const Entry, shared.allocator, jsonData, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("Warning: Failed to parse explosions.json: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const key = shared.allocator.dupe(u8, entry.key) catch continue;
        const soundKey = if (entry.sound) |s|
            shared.allocator.dupe(u8, s) catch {
                shared.allocator.free(key);
                continue;
            }
        else
            null;
        const animKey = if (entry.animation) |a|
            shared.allocator.dupe(u8, a) catch {
                shared.allocator.free(key);
                if (soundKey) |sk| shared.allocator.free(sk);
                continue;
            }
        else
            null;

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
            .damagePlayers = entry.damagePlayers,
        }) catch {
            shared.allocator.free(key);
            if (soundKey) |sk| shared.allocator.free(sk);
            if (animKey) |ak| shared.allocator.free(ak);
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

    const PelletEntry = struct {
        gravityScale: f32 = 0.5,
        density: f32 = 2.0,
        friction: f32 = 0.3,
        radius: f32 = 0.05,
        spriteScale: f32 = 0.3,
        count: u32 = 1,
        spreadAngle: f32 = 0,
        spawnRadius: f32 = 0.15,
        explosion: []const u8,
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
        const projKey = if (entry.projectile) |p|
            shared.allocator.dupe(u8, p) catch {
                shared.allocator.free(key);
                shared.allocator.free(spriteKey);
                shared.allocator.free(soundKey);
                continue;
            }
        else
            null;
        const pelletData: ?PelletData = if (entry.pellet) |pel|
            .{
                .gravityScale = pel.gravityScale,
                .density = pel.density,
                .friction = pel.friction,
                .radius = pel.radius,
                .spriteScale = pel.spriteScale,
                .count = pel.count,
                .spreadAngle = pel.spreadAngle,
                .spawnRadius = pel.spawnRadius,
                .color = pel.color,
                .explosion = shared.allocator.dupe(u8, pel.explosion) catch {
                    shared.allocator.free(key);
                    shared.allocator.free(spriteKey);
                    shared.allocator.free(soundKey);
                    if (projKey) |pk| shared.allocator.free(pk);
                    continue;
                },
            }
        else
            null;
        const explosionKey = if (entry.explosion) |e|
            shared.allocator.dupe(u8, e) catch {
                shared.allocator.free(key);
                shared.allocator.free(spriteKey);
                shared.allocator.free(soundKey);
                if (projKey) |pk| shared.allocator.free(pk);
                if (pelletData) |pd| shared.allocator.free(pd.explosion);
                continue;
            }
        else
            null;

        weaponDataMap.put(shared.allocator, key, .{
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
        }) catch {
            shared.allocator.free(key);
            shared.allocator.free(spriteKey);
            shared.allocator.free(soundKey);
            if (projKey) |pk| shared.allocator.free(pk);
            if (pelletData) |pd| shared.allocator.free(pd.explosion);
            if (explosionKey) |ek| shared.allocator.free(ek);
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
    const sound = if (d.sound) |sk| createAudioFrom(sk) else null;
    const anim = if (d.animation) |ak| try createAnimationFrom(ak) else null;
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
        .damagePlayers = d.damagePlayers,
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
            .spriteScale = pelData.spriteScale,
            .count = pelData.count,
            .spreadAngle = pelData.spreadAngle,
            .spawnRadius = pelData.spawnRadius,
            .explosion = try createExplosionFrom(pelData.explosion),
            .color = pelData.color,
        }
    else
        null;
    const hitscanExp = if (d.explosion) |eKey|
        try createExplosionFrom(eKey)
    else
        null;
    const spriteUuid = createSpriteFrom(d.sprite) orelse 0;
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
        if (entry.value_ptr.sound) |s| shared.allocator.free(s);
        if (entry.value_ptr.animation) |a| shared.allocator.free(a);
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
        if (entry.value_ptr.projectile) |p| shared.allocator.free(p);
        if (entry.value_ptr.pellet) |pel| shared.allocator.free(pel.explosion);
        if (entry.value_ptr.explosion) |e| shared.allocator.free(e);
    }
    weaponDataMap.deinit(shared.allocator);
}
