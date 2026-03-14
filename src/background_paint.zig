// Generates a static full-screen paint-swirl background texture at startup.
// Algorithm adapted from Balatro's background shader (originally by localthunk).
const std = @import("std");
const sdl = @import("sdl.zig");
const tex = @import("texture.zig");
const gpu = @import("gpu.zig");
const window = @import("window.zig");
const alloc = @import("allocator.zig").allocator;
const c = sdl.c;

var maybe_texture: ?*tex.Texture = null;

pub fn init() !void {
    const sw: f32 = @floatFromInt(window.width);
    const sh: f32 = @floatFromInt(window.height);
    const screen_len: f32 = @sqrt(sw * sw + sh * sh);

    // Random parameters — different every run.
    const rng = std.crypto.random;
    const pixel_filter: f32 = 150.0 + rng.float(f32) * 250.0; // 150–400: controls pixelation
    const spin_rotation: f32 = rng.float(f32) * std.math.tau;
    const offset = [2]f32{ (rng.float(f32) - 0.5) * 0.3, (rng.float(f32) - 0.5) * 0.3 };
    const contrast: f32 = 1.5 + rng.float(f32) * 1.5; // 1.5–3.0
    const spin_amount: f32 = 0.2 + rng.float(f32) * 0.4; // 0.2–0.6

    // Palette: base hue + analogous + near-opposite for depth.
    const base_hue: f32 = rng.float(f32);
    const hue_step: f32 = 0.08 + rng.float(f32) * 0.15;
    const sat: f32 = 0.55 + rng.float(f32) * 0.3;
    const val: f32 = 0.40 + rng.float(f32) * 0.35;
    const c1 = hsvToRgb(base_hue, sat, val);
    const c2 = hsvToRgb(@mod(base_hue + hue_step, 1.0), sat, val);
    const c3 = hsvToRgb(@mod(base_hue + 0.45 + rng.float(f32) * 0.15, 1.0), sat * 0.85, val * 1.15);

    // Generate a small texture: one texel per pixelation block.
    const pixel_size: f32 = screen_len / pixel_filter;
    const tex_w: i32 = @intFromFloat(@ceil(sw / pixel_size));
    const tex_h: i32 = @intFromFloat(@ceil(sh / pixel_size));

    const pixel_buf = try alloc.alloc(u8, @intCast(tex_w * tex_h * 4));
    defer alloc.free(pixel_buf);

    for (0..@intCast(tex_h)) |ty| {
        for (0..@intCast(tex_w)) |tx| {
            const rgb = computePixel(
                tx, ty, pixel_size, sw, sh, screen_len,
                spin_rotation, offset, contrast, spin_amount,
                c1, c2, c3,
            );
            const base = (ty * @as(usize, @intCast(tex_w)) + tx) * 4;
            // ABGR8888 on little-endian: memory order is R, G, B, A.
            pixel_buf[base + 0] = @intFromFloat(@min(255.0, rgb[0] * 255.0));
            pixel_buf[base + 1] = @intFromFloat(@min(255.0, rgb[1] * 255.0));
            pixel_buf[base + 2] = @intFromFloat(@min(255.0, rgb[2] * 255.0));
            pixel_buf[base + 3] = 255;
        }
    }

    const surface = c.SDL_CreateSurfaceFrom(
        tex_w, tex_h,
        c.SDL_PIXELFORMAT_ABGR8888,
        pixel_buf.ptr,
        tex_w * 4,
    );
    if (surface == null) return error.CreateSurfaceFailed;
    defer c.SDL_DestroySurface(surface);

    maybe_texture = try tex.createStandaloneTexture(surface);
    std.log.info("background_paint: generated {d}x{d} texture (pixel_filter={d:.0})", .{ tex_w, tex_h, pixel_filter });
}

pub fn draw() !void {
    const t = maybe_texture orelse {
        std.log.warn("background_paint.draw: texture not initialised", .{});
        return;
    };
    const dst = sdl.Rect{ .x = 0, .y = 0, .w = window.width, .h = window.height };
    try gpu.renderCopy(t, null, &dst);
}

pub fn cleanup() void {
    if (maybe_texture) |t| {
        tex.destroyTexture(t);
        maybe_texture = null;
    }
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn computePixel(
    tx: usize, ty: usize,
    pixel_size: f32,
    sw: f32, sh: f32, screen_len: f32,
    spin_rotation: f32,
    offset: [2]f32,
    contrast: f32,
    spin_amount: f32,
    c1: [3]f32, c2: [3]f32, c3: [3]f32,
) [3]f32 {
    // Map texel back to the floored screen coordinate it represents.
    const px: f32 = @as(f32, @floatFromInt(tx)) * pixel_size;
    const py: f32 = @as(f32, @floatFromInt(ty)) * pixel_size;

    // UV in [-0.5, 0.5]-ish range, centred on screen.
    var uvx: f32 = (px - 0.5 * sw) / screen_len - offset[0];
    var uvy: f32 = (py - 0.5 * sh) / screen_len - offset[1];
    const uv_len: f32 = @sqrt(uvx * uvx + uvy * uvy);

    // Centre swirl — spin_rotation picks a static pose.
    const swirl_speed: f32 = spin_rotation * 0.2 + 302.2;
    const new_angle: f32 = std.math.atan2(uvy, uvx) + swirl_speed
        - 20.0 * (spin_amount * uv_len + (1.0 - spin_amount));
    uvx = uv_len * @cos(new_angle);
    uvy = uv_len * @sin(new_angle);

    // Paint distortion (5-iteration loop from the original shader, TIME=0).
    uvx *= 30.0;
    uvy *= 30.0;
    var uv2x: f32 = uvx + uvy;
    var uv2y: f32 = uvx + uvy;
    for (0..5) |_| {
        const s: f32 = @sin(@max(uvx, uvy));
        uv2x += s + uvx;
        uv2y += s + uvy;
        uvx += 0.5 * @cos(5.1123314 + 0.353 * uv2y);
        uvy += 0.5 * @sin(uv2x);
        const sub: f32 = @cos(uvx + uvy) - @sin(uvx * 0.711 - uvy);
        uvx -= sub;
        uvy -= sub;
    }

    // Map paint result to three-colour blend weights.
    const contrast_mod: f32 = 0.25 * contrast + 0.5 * spin_amount + 1.2;
    const paint_res: f32 = @min(2.0, @max(0.0, @sqrt(uvx * uvx + uvy * uvy) * 0.035 * contrast_mod));
    const c1p: f32 = @max(0.0, 1.0 - contrast_mod * @abs(1.0 - paint_res));
    const c2p: f32 = @max(0.0, 1.0 - contrast_mod * @abs(paint_res));
    const c3p: f32 = 1.0 - @min(1.0, c1p + c2p);

    const inv: f32 = 0.3 / contrast;
    const r: f32 = @max(0.0, inv * c1[0] + (1.0 - inv) * (c1[0] * c1p + c2[0] * c2p + c3[0] * c3p));
    const g: f32 = @max(0.0, inv * c1[1] + (1.0 - inv) * (c1[1] * c1p + c2[1] * c2p + c3[1] * c3p));
    const b: f32 = @max(0.0, inv * c1[2] + (1.0 - inv) * (c1[2] * c1p + c2[2] * c2p + c3[2] * c3p));
    return .{ r, g, b };
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const i: u32 = @intFromFloat(@mod(@floor(h * 6.0), 6.0));
    const f: f32 = h * 6.0 - @floor(h * 6.0);
    const p: f32 = v * (1.0 - s);
    const q: f32 = v * (1.0 - f * s);
    const t: f32 = v * (1.0 - (1.0 - f) * s);
    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}
