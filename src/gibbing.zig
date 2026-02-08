const std = @import("std");

const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");

const GibletSet = struct {
    heads: []u64,
    legs: []u64,
    meat: []u64,
};

// uncolored template giblets
var templateHeadGiblets: []u64 = &[_]u64{};
var templateLegGiblets: []u64 = &[_]u64{};
var templateMeatGiblets: []u64 = &[_]u64{};

var playerGiblets: std.AutoHashMap(usize, GibletSet) = undefined;

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

    playerGiblets = std.AutoHashMap(usize, GibletSet).init(shared.allocator);

    std.debug.print("Loaded giblet templates - heads: {}, legs: {}, meat: {}\n", .{ templateHeadGiblets.len, templateLegGiblets.len, templateMeatGiblets.len });
}

pub fn prepareGibletsForPlayer(playerId: usize, playerColor: sprite.Color) !void {
    var coloredHeads = std.array_list.Managed(u64).init(shared.allocator);
    for (templateHeadGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredHeads.append(colored);
    }

    var coloredLegs = std.array_list.Managed(u64).init(shared.allocator);
    for (templateLegGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredLegs.append(colored);
    }

    var coloredMeat = std.array_list.Managed(u64).init(shared.allocator);
    for (templateMeatGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredMeat.append(colored);
    }

    const gibletSet = GibletSet{
        .heads = try coloredHeads.toOwnedSlice(),
        .legs = try coloredLegs.toOwnedSlice(),
        .meat = try coloredMeat.toOwnedSlice(),
    };

    try playerGiblets.put(playerId, gibletSet);

    std.debug.print("Pre-colored giblets for player {}: {} heads, {} legs, {} meat\n", .{ playerId, gibletSet.heads.len, gibletSet.legs.len, gibletSet.meat.len });
}

pub fn gib(posM: vec.Vec2, playerId: usize) void {
    const gibletSet = playerGiblets.get(playerId) orelse {
        std.debug.print("Warning: No pre-colored giblets found for player {}\n", .{playerId});
        return;
    };

    if (gibletSet.heads.len > 0) {
        const headCount = std.crypto.random.intRangeAtMost(u32, 0, 1);
        for (0..headCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, gibletSet.heads.len - 1);
            spawnGiblet(gibletSet.heads[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }

    if (gibletSet.legs.len > 0) {
        const legCount = std.crypto.random.intRangeAtMost(u32, 0, 2);
        for (0..legCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, gibletSet.legs.len - 1);
            spawnGiblet(gibletSet.legs[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }

    if (gibletSet.meat.len > 0) {
        const meatCount = std.crypto.random.intRangeAtMost(u32, 0, 3);
        for (0..meatCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, gibletSet.meat.len - 1);
            spawnGiblet(gibletSet.meat[randomIndex], posM) catch |err| {
                std.debug.print("Failed to spawnGiblet: {}\n", .{err});
            };
        }
    }
}

fn spawnGiblet(gibletSpriteUuid: u64, posM: vec.Vec2) !void {
    const spriteCopyUuid = try sprite.createCopy(gibletSpriteUuid);

    const variedPosM: vec.Vec2 = .{
        .x = posM.x + std.crypto.random.float(f32) * 2 - 1,
        .y = posM.y - std.crypto.random.float(f32) * 2,
    };

    const bodyDef = box2d.createDynamicBodyDef(variedPosM);
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    shapeDef.density = 1.0;
    shapeDef.filter.categoryBits = collision.CATEGORY_GIBLET;
    shapeDef.filter.maskBits = collision.MASK_GIBLET;

    const gibEntity = try entity.createFromImg(spriteCopyUuid, shapeDef, bodyDef, "dynamic");

    // Apply random impulse to scatter giblets
    const angle = std.crypto.random.float(f32) * std.math.pi * 2.0;
    const force = 5.0 + std.crypto.random.float(f32) * 10.0;
    const impulse = box2d.c.b2Vec2{
        .x = std.math.cos(angle) * force,
        .y = std.math.sin(angle) * force,
    };
    box2d.c.b2Body_ApplyLinearImpulseToCenter(gibEntity.bodyId, impulse, true);
}

fn createColoredSprite(gibletSpriteUuid: u64, playerColor: sprite.Color) !u64 {
    const coloredSpriteUuid = try sprite.createCopy(gibletSpriteUuid);
    errdefer sprite.cleanupLater(coloredSpriteUuid);

    const bloodColor = sprite.Color{ .r = config.bloodParticle.colorR, .g = config.bloodParticle.colorG, .b = config.bloodParticle.colorB };

    try sprite.colorMatchingPixels(coloredSpriteUuid, bloodColor, sprite.isCyan);
    try sprite.colorMatchingPixels(coloredSpriteUuid, playerColor, sprite.isWhite);

    return coloredSpriteUuid;
}

pub fn cleanup() void {
    // Clean up template giblets
    for (templateHeadGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    shared.allocator.free(templateHeadGiblets);

    for (templateLegGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    shared.allocator.free(templateLegGiblets);

    for (templateMeatGiblets) |spriteUuid| {
        sprite.cleanupLater(spriteUuid);
    }
    shared.allocator.free(templateMeatGiblets);

    // Clean up all player-specific colored giblets
    var iter = playerGiblets.valueIterator();
    while (iter.next()) |gibletSet| {
        for (gibletSet.heads) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        shared.allocator.free(gibletSet.heads);

        for (gibletSet.legs) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        shared.allocator.free(gibletSet.legs);

        for (gibletSet.meat) |spriteUuid| {
            sprite.cleanupLater(spriteUuid);
        }
        shared.allocator.free(gibletSet.meat);
    }

    playerGiblets.deinit();
}
