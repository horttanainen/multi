const std = @import("std");

const sprite = @import("sprite.zig");
const allocator = @import("allocator.zig").allocator;
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const collision = @import("collision.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");
const runtime = @import("runtime.zig");
const blood = @import("blood.zig");
const time = @import("time.zig");

const GibletSet = struct {
    heads: []u64,
    legs: []u64,
    meat: []u64,
};

const gibletBloodCooldownSeconds: f64 = 0.16;
const gibletBloodMinImpactSpeed: f32 = 1.4;
const gibletBloodMinDamage: f32 = 4.0;
const gibletBloodMaxDamage: f32 = 18.0;
const gibletBloodDamagePerSpeed: f32 = 3.0;

// uncolored template giblets
var templateHeadGiblets: []u64 = &[_]u64{};
var templateLegGiblets: []u64 = &[_]u64{};
var templateMeatGiblets: []u64 = &[_]u64{};

var playerGiblets: std.AutoHashMap(usize, GibletSet) = undefined;
var gibletBloodCooldowns = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, f64).empty;

pub fn init() !void {
    templateHeadGiblets = try fs.loadSpritesFromFolder(
        "giblets/head",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );
    templateLegGiblets = try fs.loadSpritesFromFolder(
        "giblets/leg",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );
    templateMeatGiblets = try fs.loadSpritesFromFolder(
        "giblets/meat",
        .{ .x = 0.2, .y = 0.2 },
        vec.izero,
    );

    playerGiblets = std.AutoHashMap(usize, GibletSet).init(allocator);

    std.debug.print("Loaded giblet templates - heads: {}, legs: {}, meat: {}\n", .{ templateHeadGiblets.len, templateLegGiblets.len, templateMeatGiblets.len });
}

pub fn prepareGibletsForPlayer(playerId: usize, playerColor: sprite.Color) !void {
    var coloredHeads = std.array_list.Managed(u64).init(allocator);
    for (templateHeadGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredHeads.append(colored);
    }

    var coloredLegs = std.array_list.Managed(u64).init(allocator);
    for (templateLegGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredLegs.append(colored);
    }

    var coloredMeat = std.array_list.Managed(u64).init(allocator);
    for (templateMeatGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredMeat.append(colored);
    }

    const gibletSet = GibletSet{
        .heads = try coloredHeads.toOwnedSlice(),
        .legs = try coloredLegs.toOwnedSlice(),
        .meat = try coloredMeat.toOwnedSlice(),
    };

    if (playerGiblets.get(playerId)) |old| {
        for (old.heads) |s| sprite.cleanupLater(s);
        allocator.free(old.heads);
        for (old.legs) |s| sprite.cleanupLater(s);
        allocator.free(old.legs);
        for (old.meat) |s| sprite.cleanupLater(s);
        allocator.free(old.meat);
    }
    try playerGiblets.put(playerId, gibletSet);

    std.debug.print("Pre-colored giblets for player {}: {} heads, {} legs, {} meat\n", .{ playerId, gibletSet.heads.len, gibletSet.legs.len, gibletSet.meat.len });
}

pub fn gib(posM: vec.Vec2, playerId: usize) void {
    const gibletSet = playerGiblets.get(playerId) orelse {
        std.debug.print("Warning: No pre-colored giblets found for player {}\n", .{playerId});
        return;
    };

    if (gibletSet.heads.len > 0) {
        const headCount = runtime.random().intRangeAtMost(u32, 0, 1);
        for (0..headCount) |_| {
            const randomIndex = runtime.random().intRangeAtMost(usize, 0, gibletSet.heads.len - 1);
            spawnGiblet(gibletSet.heads[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }

    if (gibletSet.legs.len > 0) {
        const legCount = runtime.random().intRangeAtMost(u32, 0, 2);
        for (0..legCount) |_| {
            const randomIndex = runtime.random().intRangeAtMost(usize, 0, gibletSet.legs.len - 1);
            spawnGiblet(gibletSet.legs[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }

    if (gibletSet.meat.len > 0) {
        const meatCount = runtime.random().intRangeAtMost(u32, 0, 3);
        for (0..meatCount) |_| {
            const randomIndex = runtime.random().intRangeAtMost(usize, 0, gibletSet.meat.len - 1);
            spawnGiblet(gibletSet.meat[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }
}

fn spawnGiblet(gibletSpriteUuid: u64, posM: vec.Vec2) !void {
    const spriteCopyUuid = try sprite.createCopy(gibletSpriteUuid);

    const variedPosM: vec.Vec2 = .{
        .x = posM.x + runtime.random().float(f32) * 2 - 1,
        .y = posM.y - runtime.random().float(f32) * 2,
    };

    const bodyDef = box2d.createDynamicBodyDef(variedPosM);
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.material.friction = 0.5;
    shapeDef.density = 1.0;
    shapeDef.filter.categoryBits = collision.CATEGORY_GIBLET;
    shapeDef.filter.maskBits = collision.MASK_GIBLET;
    shapeDef.enableHitEvents = true;
    shapeDef.enableContactEvents = true;

    const gibEntity = try entity.createFromImg(spriteCopyUuid, shapeDef, bodyDef, "dynamic");
    try gibletBloodCooldowns.put(allocator, gibEntity.bodyId, 0.0);

    // Apply random impulse to scatter giblets
    const angle = runtime.random().float(f32) * std.math.pi * 2.0;
    const force = 5.0 + runtime.random().float(f32) * 10.0;
    const impulse = box2d.c.b2Vec2{
        .x = std.math.cos(angle) * force,
        .y = std.math.sin(angle) * force,
    };
    box2d.c.b2Body_ApplyLinearImpulseToCenter(gibEntity.bodyId, impulse, true);
}

fn createColoredSprite(gibletSpriteUuid: u64, playerColor: sprite.Color) !u64 {
    const coloredSpriteUuid = try sprite.createMutableCopy(gibletSpriteUuid);
    errdefer sprite.cleanupLater(coloredSpriteUuid);

    const bloodColor = try blood.currentColor();

    try sprite.colorMatchingPixels(coloredSpriteUuid, bloodColor, sprite.isCyan);
    try sprite.colorMatchingPixels(coloredSpriteUuid, playerColor, sprite.isWhite);

    return coloredSpriteUuid;
}

fn cleanupInvalidTrackedGiblets() void {
    var index: usize = 0;
    while (index < gibletBloodCooldowns.count()) {
        const bodyId = gibletBloodCooldowns.keys()[index];
        if (box2d.c.b2Body_IsValid(bodyId)) {
            index += 1;
            continue;
        }

        _ = gibletBloodCooldowns.swapRemove(bodyId);
    }
}

fn shapeCanReceiveGibletBlood(shapeId: box2d.c.b2ShapeId) bool {
    if (!box2d.c.b2Shape_IsValid(shapeId)) {
        return false;
    }

    const filter = box2d.c.b2Shape_GetFilter(shapeId);
    const mask = collision.CATEGORY_TERRAIN | collision.CATEGORY_DYNAMIC | collision.CATEGORY_UNBREAKABLE;
    return (filter.categoryBits & mask) != 0;
}

fn spatterFromGiblet(gibletBodyId: box2d.c.b2BodyId, targetShapeId: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Body_IsValid(gibletBodyId)) {
        return;
    }
    if (!shapeCanReceiveGibletBlood(targetShapeId)) {
        return;
    }

    const nextAllowed = gibletBloodCooldowns.getPtr(gibletBodyId) orelse {
        return;
    };

    const now = time.now();
    if (now < nextAllowed.*) {
        return;
    }

    const velocity = vec.fromBox2d(box2d.c.b2Body_GetLinearVelocity(gibletBodyId));
    const speed = vec.magnitude(velocity);
    if (speed < gibletBloodMinImpactSpeed) {
        return;
    }

    nextAllowed.* = now + gibletBloodCooldownSeconds;
    const pos = vec.fromBox2d(box2d.c.b2Body_GetPosition(gibletBodyId));
    const damage = std.math.clamp((speed - gibletBloodMinImpactSpeed) * gibletBloodDamagePerSpeed, gibletBloodMinDamage, gibletBloodMaxDamage);
    try blood.createParticlesFromImpact(pos, damage, velocity);
}

fn handleGibletContact(shapeIdA: box2d.c.b2ShapeId, shapeIdB: box2d.c.b2ShapeId) !void {
    if (!box2d.c.b2Shape_IsValid(shapeIdA) or !box2d.c.b2Shape_IsValid(shapeIdB)) {
        return;
    }

    const bodyIdA = box2d.c.b2Shape_GetBody(shapeIdA);
    const bodyIdB = box2d.c.b2Shape_GetBody(shapeIdB);
    const aIsGiblet = gibletBloodCooldowns.contains(bodyIdA);
    const bIsGiblet = gibletBloodCooldowns.contains(bodyIdB);

    if (aIsGiblet and !bIsGiblet) {
        try spatterFromGiblet(bodyIdA, shapeIdB);
    }
    if (bIsGiblet and !aIsGiblet) {
        try spatterFromGiblet(bodyIdB, shapeIdA);
    }
}

pub fn checkContacts() !void {
    cleanupInvalidTrackedGiblets();

    const contactEvents = box2d.getContactEvents();
    for (0..@intCast(contactEvents.beginCount)) |i| {
        const event = contactEvents.beginEvents[i];
        try handleGibletContact(event.shapeIdA, event.shapeIdB);
    }

    for (0..@intCast(contactEvents.hitCount)) |i| {
        const event = contactEvents.hitEvents[i];
        try handleGibletContact(event.shapeIdA, event.shapeIdB);
    }
}

pub fn cleanup() void {
    gibletBloodCooldowns.clearAndFree(allocator);

    // Clean up template giblets
    for (templateHeadGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateHeadGiblets);

    for (templateLegGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateLegGiblets);

    for (templateMeatGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    allocator.free(templateMeatGiblets);

    // Clean up all player-specific colored giblets
    var iter = playerGiblets.valueIterator();
    while (iter.next()) |gibletSet| {
        for (gibletSet.heads) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        allocator.free(gibletSet.heads);

        for (gibletSet.legs) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        allocator.free(gibletSet.legs);

        for (gibletSet.meat) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        allocator.free(gibletSet.meat);
    }

    playerGiblets.deinit();
}
