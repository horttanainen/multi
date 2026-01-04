const std = @import("std");
const sdl = @import("zsdl");

const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const config = @import("config.zig");
const vec = @import("vector.zig");
const fs = @import("fs.zig");

// SDL_CreateRGBSurfaceWithFormat is not exposed by zsdl, so we declare it here
const SDL_CreateRGBSurfaceWithFormat = @extern(*const fn (
    flags: c_int,
    width: c_int,
    height: c_int,
    depth: c_int,
    format: u32,
) callconv(.c) ?*sdl.Surface, .{ .name = "SDL_CreateRGBSurfaceWithFormat" });

// SDL_LockSurface/SDL_UnlockSurface are not exposed by zsdl
const SDL_LockSurface = @extern(*const fn (surface: *sdl.Surface) callconv(.c) c_int, .{ .name = "SDL_LockSurface" });
const SDL_UnlockSurface = @extern(*const fn (surface: *sdl.Surface) callconv(.c) void, .{ .name = "SDL_UnlockSurface" });

const GibletSet = struct {
    heads: []sprite.Sprite,
    legs: []sprite.Sprite,
    meat: []sprite.Sprite,
};

// uncolored template giblets
var templateHeadGiblets: []sprite.Sprite = &[_]sprite.Sprite{};
var templateLegGiblets: []sprite.Sprite = &[_]sprite.Sprite{};
var templateMeatGiblets: []sprite.Sprite = &[_]sprite.Sprite{};

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
    var coloredHeads = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
    for (templateHeadGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredHeads.append(colored);
    }

    var coloredLegs = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
    for (templateLegGiblets) |templateGiblet| {
        const colored = try createColoredSprite(templateGiblet, playerColor);
        try coloredLegs.append(colored);
    }

    var coloredMeat = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
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

fn spawnGiblet(gibletSprite: sprite.Sprite, posM: vec.Vec2) !void {
    const imgPathCopy = try shared.allocator.dupe(u8, gibletSprite.imgPath);
    errdefer shared.allocator.free(imgPathCopy);

    const spriteCopy = sprite.Sprite{
        .surface = gibletSprite.surface,
        .texture = gibletSprite.texture,
        .imgPath = imgPathCopy,
        .scale = gibletSprite.scale,
        .sizeM = gibletSprite.sizeM,
        .sizeP = gibletSprite.sizeP,
        .offset = gibletSprite.offset,
    };

    // Create dynamic body at position
    const bodyDef = box2d.createDynamicBodyDef(posM);
    var shapeDef = box2d.c.b2DefaultShapeDef();
    shapeDef.friction = 0.5;
    shapeDef.density = 1.0;
    shapeDef.filter.categoryBits = config.CATEGORY_DYNAMIC;
    shapeDef.filter.maskBits = config.CATEGORY_TERRAIN | config.CATEGORY_PLAYER | config.CATEGORY_PROJECTILE | config.CATEGORY_BLOOD | config.CATEGORY_DYNAMIC | config.CATEGORY_SENSOR | config.CATEGORY_UNBREAKABLE;

    const gibEntity = try entity.createFromImg(spriteCopy, shapeDef, bodyDef, "dynamic");

    // Apply random impulse to scatter giblets
    const angle = std.crypto.random.float(f32) * std.math.pi * 2.0;
    const force = 5.0 + std.crypto.random.float(f32) * 10.0;
    const impulse = box2d.c.b2Vec2{
        .x = std.math.cos(angle) * force,
        .y = std.math.sin(angle) * force,
    };
    box2d.c.b2Body_ApplyLinearImpulseToCenter(gibEntity.bodyId, impulse, true);
}

fn createColoredSprite(gibletSprite: sprite.Sprite, playerColor: sprite.Color) !sprite.Sprite {
    const resources = try shared.getResources();

    const format: u32 = if (gibletSprite.surface.format) |fmt| @intFromEnum(fmt.*) else 373694468; // RGBA8888
    const copiedSurface = SDL_CreateRGBSurfaceWithFormat(
        0,
        gibletSprite.surface.w,
        gibletSprite.surface.h,
        32,
        format,
    ) orelse {
        std.debug.print("Failed to create surface copy\n", .{});
        return error.SurfaceCopyFailed;
    };
    try sdl.blitSurface(gibletSprite.surface, null, copiedSurface, null);

    const bloodColor = sprite.Color{ .r = config.bloodParticle.colorR, .g = config.bloodParticle.colorG, .b = config.bloodParticle.colorB };

    try replaceColorsOnSurface(copiedSurface, playerColor, bloodColor);

    const texture = try sdl.createTextureFromSurface(resources.renderer, copiedSurface);

    const imgPathCopy = try shared.allocator.dupe(u8, gibletSprite.imgPath);

    return sprite.Sprite{
        .surface = copiedSurface,
        .texture = texture,
        .imgPath = imgPathCopy,
        .scale = gibletSprite.scale,
        .sizeM = gibletSprite.sizeM,
        .sizeP = gibletSprite.sizeP,
        .offset = gibletSprite.offset,
    };
}


fn replaceColorsOnSurface(surface: *sdl.Surface, playerColor: sprite.Color, bloodColor: sprite.Color) !void {
    // Lock surface for pixel access
    if (SDL_LockSurface(surface) != 0) {
        return error.SDLLockSurfaceFailed;
    }
    defer SDL_UnlockSurface(surface);

    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const bytesPerPixel: usize = 4; // RGBA format
    const width: usize = @intCast(surface.w);
    const height: usize = @intCast(surface.h);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixelIndex = (y * width + x) * bytesPerPixel;

            if (bytesPerPixel != 4) {
                std.debug.print("Could not color sprite. Wrong number of bytes per pixel: {}", .{bytesPerPixel});
                return;
            }
            const alpha = pixels[pixelIndex + 3];
            if (alpha <= 0) {
                continue;
            }
            const b = pixels[pixelIndex + 0];
            const g = pixels[pixelIndex + 1];
            const r = pixels[pixelIndex + 2];

            // white pixels become players color 
            if (r > 150 and g > 150 and b > 150) {
                pixels[pixelIndex + 0] = playerColor.b;
                pixels[pixelIndex + 1] = playerColor.g;
                pixels[pixelIndex + 2] = playerColor.r;
            }
            // Cyan pixels become blood color
            else if (r < 150 and b > 100) {
                pixels[pixelIndex + 0] = bloodColor.b;
                pixels[pixelIndex + 1] = bloodColor.g;
                pixels[pixelIndex + 2] = bloodColor.r;
            }
        }
    }
}


pub fn cleanup() void {
    // Clean up template giblets
    for (templateHeadGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(templateHeadGiblets);

    for (templateLegGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(templateLegGiblets);

    for (templateMeatGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(templateMeatGiblets);

    // Clean up all player-specific colored giblets
    var iter = playerGiblets.valueIterator();
    while (iter.next()) |gibletSet| {
        for (gibletSet.heads) |s| {
            sprite.cleanup(s);
        }
        shared.allocator.free(gibletSet.heads);

        for (gibletSet.legs) |s| {
            sprite.cleanup(s);
        }
        shared.allocator.free(gibletSet.legs);

        for (gibletSet.meat) |s| {
            sprite.cleanup(s);
        }
        shared.allocator.free(gibletSet.meat);
    }

    playerGiblets.deinit();
}
