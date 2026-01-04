const std = @import("std");
const sdl = @import("zsdl");

const sprite = @import("sprite.zig");
const shared = @import("shared.zig");
const box2d = @import("box2d.zig");
const entity = @import("entity.zig");
const config = @import("config.zig");
const vec = @import("vector.zig");

const GibletType = enum {
    head,
    leg,
    meat,
};

const GibletSprite = struct {
    sprites: []sprite.Sprite,
    gibletType: GibletType,
};

var headGiblets: []sprite.Sprite = &[_]sprite.Sprite{};
var legGiblets: []sprite.Sprite = &[_]sprite.Sprite{};
var meatGiblets: []sprite.Sprite = &[_]sprite.Sprite{};

fn loadGibletsFromFolder(folderPath: []const u8, baseScale: f32) ![]sprite.Sprite {
    var dir = std.fs.cwd().openDir(folderPath, .{}) catch |err| {
        std.debug.print("Warning: Could not open giblet folder {s}: {}\n", .{ folderPath, err });
        return &[_]sprite.Sprite{};
    };
    defer dir.close();

    var images = std.array_list.Managed([]const u8).init(shared.allocator);
    defer {
        for (images.items) |imageName| {
            shared.allocator.free(imageName);
        }
        images.deinit();
    }

    var dirIterator = dir.iterate();
    while (try dirIterator.next()) |dirContent| {
        if (dirContent.kind == std.fs.File.Kind.file) {
            // Skip .DS_Store files
            if (!std.mem.eql(u8, dirContent.name, ".DS_Store")) {
                const name = try shared.allocator.dupe(u8, dirContent.name);
                try images.append(name);
            }
        }
    }

    if (images.items.len == 0) {
        std.debug.print("Warning: No giblets found in {s}\n", .{folderPath});
        return &[_]sprite.Sprite{};
    }

    // Sort for consistent loading
    std.mem.sort([]const u8, images.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var sprites = std.array_list.Managed(sprite.Sprite).init(shared.allocator);
    for (images.items) |imageName| {
        var pathBuf: [256]u8 = undefined;
        const imagePath = try std.fmt.bufPrint(&pathBuf, "{s}/{s}", .{ folderPath, imageName });

        const s = try sprite.createFromImg(imagePath, .{ .x = baseScale, .y = baseScale }, vec.izero);
        try sprites.append(s);
    }

    return sprites.toOwnedSlice();
}

pub fn init() !void {
    headGiblets = try loadGibletsFromFolder("giblets/head", 0.3);
    legGiblets = try loadGibletsFromFolder("giblets/leg", 0.3);
    meatGiblets = try loadGibletsFromFolder("giblets/meat", 0.3);

    std.debug.print("Loaded giblets - heads: {}, legs: {}, meat: {}\n", .{ headGiblets.len, legGiblets.len, meatGiblets.len });
}

fn replaceColorsOnSprite(s: sprite.Sprite, playerColor: sprite.Color, bloodColor: sprite.Color) !void {
    const surface = s.surface;

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

            if (bytesPerPixel == 4) {
                const alpha = pixels[pixelIndex + 3];
                // Only process non-transparent pixels
                if (alpha > 0) {
                    const b = pixels[pixelIndex + 0];
                    const g = pixels[pixelIndex + 1];
                    const r = pixels[pixelIndex + 2];

                    // Check if pixel is white (all channels near 255)
                    if (r > 150 and g > 150 and b > 150) {
                        pixels[pixelIndex + 0] = playerColor.b;
                        pixels[pixelIndex + 1] = playerColor.g;
                        pixels[pixelIndex + 2] = playerColor.r;
                    }
                    // Check if pixel is cyan (low red, higher green and blue)
                    // This catches both bright cyan (0,170,172) and dark cyan (43,111,118)
                    else if (r < 150 and b > 100) {
                        pixels[pixelIndex + 0] = bloodColor.b;
                        pixels[pixelIndex + 1] = bloodColor.g;
                        pixels[pixelIndex + 2] = bloodColor.r;
                    }
                }
            }
        }
    }
}

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

fn spawnGiblet(gibletSprite: sprite.Sprite, posM: vec.Vec2, playerColor: sprite.Color) !void {
    // Create a copy of the sprite for this giblet
    const resources = try shared.getResources();

    // Create a new surface as a copy
    const format: u32 = if (gibletSprite.surface.format) |fmt| @intFromEnum(fmt.*) else 373694468; // fallback to RGBA8888
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

    // Copy pixels from original to new surface
    try sdl.blitSurface(gibletSprite.surface, null, copiedSurface, null);

    // Apply color replacement to the copied surface
    const bloodColor = sprite.Color{ .r = config.bloodParticle.colorR, .g = config.bloodParticle.colorG, .b = config.bloodParticle.colorB };
    const tempSprite = sprite.Sprite{
        .surface = copiedSurface,
        .texture = undefined, // Will be created below
        .imgPath = gibletSprite.imgPath,
        .scale = gibletSprite.scale,
        .sizeM = gibletSprite.sizeM,
        .sizeP = gibletSprite.sizeP,
        .offset = gibletSprite.offset,
    };

    try replaceColorsOnSprite(tempSprite, playerColor, bloodColor);

    // Create texture from modified surface
    const texture = try sdl.createTextureFromSurface(resources.renderer, copiedSurface);

    const coloredSprite = sprite.Sprite{
        .surface = copiedSurface,
        .texture = texture,
        .imgPath = gibletSprite.imgPath,
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

    const gibEntity = try entity.createFromImg(coloredSprite, shapeDef, bodyDef, "dynamic");

    // Apply random impulse to scatter giblets
    const angle = std.crypto.random.float(f32) * std.math.pi * 2.0;
    const force = 5.0 + std.crypto.random.float(f32) * 10.0;
    const impulse = box2d.c.b2Vec2{
        .x = std.math.cos(angle) * force,
        .y = std.math.sin(angle) * force,
    };
    box2d.c.b2Body_ApplyLinearImpulseToCenter(gibEntity.bodyId, impulse, true);
}

pub fn gib(posM: vec.Vec2, playerColor: sprite.Color) !void {
    // Spawn 0-1 head giblets
    if (headGiblets.len > 0) {
        const headCount = std.crypto.random.intRangeAtMost(u32, 0, 1);
        for (0..headCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, headGiblets.len - 1);
            try spawnGiblet(headGiblets[randomIndex], posM, playerColor);
        }
    }

    // Spawn 0-2 leg giblets
    if (legGiblets.len > 0) {
        const legCount = std.crypto.random.intRangeAtMost(u32, 0, 2);
        for (0..legCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, legGiblets.len - 1);
            try spawnGiblet(legGiblets[randomIndex], posM, playerColor);
        }
    }

    // Spawn 0-3 meat giblets
    if (meatGiblets.len > 0) {
        const meatCount = std.crypto.random.intRangeAtMost(u32, 0, 3);
        for (0..meatCount) |_| {
            const randomIndex = std.crypto.random.intRangeAtMost(usize, 0, meatGiblets.len - 1);
            try spawnGiblet(meatGiblets[randomIndex], posM, playerColor);
        }
    }
}

pub fn cleanup() void {
    for (headGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(headGiblets);

    for (legGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(legGiblets);

    for (meatGiblets) |s| {
        sprite.cleanup(s);
    }
    shared.allocator.free(meatGiblets);
}
