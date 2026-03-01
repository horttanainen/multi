const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const atlas_mod = @import("atlas.zig");
const c = sdl.c;
const Atlas = atlas_mod.Atlas;
const ATLAS_SIZE = atlas_mod.ATLAS_SIZE;

pub const Texture = struct {
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: i32,
    height: i32,
    is_atlas: bool = true,
    owns_atlas_region: bool = true,
    standalone_gpu_texture: ?*c.SDL_GPUTexture = null,
    color_mod: sdl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    blend_mode: sdl.BlendMode = .blend,

    pub fn gpuTexture(self: *const Texture) *c.SDL_GPUTexture {
        if (self.is_atlas) {
            return gpu.getAtlas().gpu_texture;
        }
        return self.standalone_gpu_texture.?;
    }
};

/// Add a surface to the texture atlas. Returns an atlas-backed Texture.
pub fn addToAtlas(renderer: *gpu.Renderer, surface: *sdl.Surface) !*Texture {
    _ = renderer;
    const device = gpu.getDevice();
    const atlas = gpu.getAtlas();
    const allocator = gpu.getAllocator();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);

    const region = try atlas.allocate(w, h);

    const texture = try allocator.create(Texture);
    texture.* = .{
        .atlas_x = region.x,
        .atlas_y = region.y,
        .width = @intCast(w),
        .height = @intCast(h),
        .is_atlas = true,
    };

    uploadToAtlasRegion(device, atlas, rgba_surface, region.x, region.y, w, h);
    return texture;
}

/// Create a standalone GPU texture (not in atlas). Used for ephemeral textures like text.
pub fn createStandaloneTexture(renderer: *gpu.Renderer, surface: *sdl.Surface) !*Texture {
    _ = renderer;
    const device = gpu.getDevice();
    const allocator = gpu.getAllocator();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);

    const tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const gpu_texture = c.SDL_CreateGPUTexture(device, &tex_info) orelse return error.CreateGPUTextureFailed;

    const texture = try allocator.create(Texture);
    texture.* = .{
        .width = @intCast(w),
        .height = @intCast(h),
        .is_atlas = false,
        .standalone_gpu_texture = gpu_texture,
    };

    uploadTextureImmediate(device, gpu_texture, rgba_surface);
    return texture;
}

pub fn destroyTexture(texture: *Texture) void {
    if (!texture.is_atlas) {
        // Standalone texture: release GPU texture
        if (texture.standalone_gpu_texture) |gpu_tex| {
            gpu.queueTextureDestroy(gpu_tex);
        }
    }
    // Atlas textures: just free the wrapper, atlas region is leaked (reclaimed on level reload)
    gpu.getAllocator().destroy(texture);
}

/// Create a new Texture wrapper that shares the same atlas region.
pub fn cloneTexture(source: *Texture) !*Texture {
    const texture = try gpu.getAllocator().create(Texture);
    texture.* = .{
        .atlas_x = source.atlas_x,
        .atlas_y = source.atlas_y,
        .width = source.width,
        .height = source.height,
        .is_atlas = source.is_atlas,
        .owns_atlas_region = false,
        .standalone_gpu_texture = source.standalone_gpu_texture,
        .color_mod = source.color_mod,
        .blend_mode = source.blend_mode,
    };
    return texture;
}

/// Allocate a new private atlas region for a texture and upload surface data there.
/// Used for copy-on-write when a texture shares its atlas region with the cache.
pub fn reallocateAtlasRegion(texture: *Texture, surface: *sdl.Surface) !void {
    const device = gpu.getDevice();
    const atlas = gpu.getAtlas();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(texture.width);
    const h: u32 = @intCast(texture.height);

    const region = try atlas.allocate(w, h);
    texture.atlas_x = region.x;
    texture.atlas_y = region.y;
    texture.owns_atlas_region = true;

    uploadToAtlasRegion(device, atlas, rgba_surface, region.x, region.y, w, h);
}

/// Reset atlas packer state (call on level reload to reclaim all atlas space).
pub fn resetAtlas() void {
    gpu.getAtlas().init();
}

pub fn queryTexture(texture: *Texture, w: *i32, h: *i32) !void {
    w.* = texture.width;
    h.* = texture.height;
}

pub fn setTextureColorMod(texture: *Texture, r: u8, g: u8, b: u8) !void {
    texture.color_mod.r = r;
    texture.color_mod.g = g;
    texture.color_mod.b = b;
}

pub fn setTextureAlphaMod(texture: *Texture, a: u8) !void {
    texture.color_mod.a = a;
}

pub fn setTextureBlendMode(texture: *Texture, mode: sdl.BlendMode) !void {
    texture.blend_mode = mode;
}

/// Re-upload a texture from its associated surface (for terrain destruction, blood stains).
/// For atlas textures, uploads to the atlas sub-region. For standalone, uploads to the GPU texture.
pub fn reuploadTexture(texture: *Texture, surface: *sdl.Surface) !void {
    const device = gpu.getDevice();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    if (texture.is_atlas) {
        uploadToAtlasRegion(device, gpu.getAtlas(), rgba_surface, texture.atlas_x, texture.atlas_y, @intCast(texture.width), @intCast(texture.height));
    } else {
        uploadTextureImmediate(device, texture.standalone_gpu_texture.?, rgba_surface);
    }
}

/// Upload surface pixel data to a sub-region of the atlas texture.
fn uploadToAtlasRegion(device: *c.SDL_GPUDevice, atlas: *Atlas, rgba_surface: *sdl.Surface, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
    const pitch: u32 = @intCast(rgba_surface.*.pitch);
    const data_size: u32 = pitch * h;

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    };
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse return;

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };
    const pixels: [*]const u8 = @ptrCast(rgba_surface.*.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    });
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], pixels[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };

    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = pitch / 4,
        .rows_per_layer = h,
    };
    const dst_region = c.SDL_GPUTextureRegion{
        .texture = atlas.gpu_texture,
        .mip_level = 0,
        .layer = 0,
        .x = dst_x,
        .y = dst_y,
        .z = 0,
        .w = w,
        .h = h,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &dst_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(device, f);
    }
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
}

/// Upload surface pixel data to a standalone GPU texture (full replacement).
fn uploadTextureImmediate(device: *c.SDL_GPUDevice, gpu_texture: *c.SDL_GPUTexture, rgba_surface: *sdl.Surface) void {
    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);
    const pitch: u32 = @intCast(rgba_surface.*.pitch);
    const data_size: u32 = pitch * h;

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    };
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse return;

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };
    const pixels: [*]const u8 = @ptrCast(rgba_surface.*.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    });
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], pixels[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };

    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = pitch / 4,
        .rows_per_layer = h,
    };
    const dst_region = c.SDL_GPUTextureRegion{
        .texture = gpu_texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = w,
        .h = h,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &dst_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(device, f);
    }
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
}

pub fn saveAtlasToDisk(path: [*:0]const u8) void {
    const device = gpu.getDevice();
    const atlas = gpu.getAtlas();

    const bpp: u32 = 4;
    const data_size: u32 = ATLAS_SIZE * ATLAS_SIZE * bpp;

    // Create download transfer buffer
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = data_size,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create download transfer buffer\n", .{});
        return;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);

    // Download atlas texture via copy pass
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        std.debug.print("Failed to acquire command buffer for atlas dump\n", .{});
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        std.debug.print("Failed to begin copy pass for atlas dump\n", .{});
        return;
    };

    const src_region = c.SDL_GPUTextureRegion{
        .texture = atlas.gpu_texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = ATLAS_SIZE,
        .h = ATLAS_SIZE,
        .d = 1,
    };
    const dst_transfer = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = ATLAS_SIZE,
        .rows_per_layer = ATLAS_SIZE,
    };
    c.SDL_DownloadFromGPUTexture(copy_pass, &src_region, &dst_transfer);
    c.SDL_EndGPUCopyPass(copy_pass);

    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(device, f);
    }

    // Map and create surface from downloaded data
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse {
        std.debug.print("Failed to map transfer buffer for atlas dump\n", .{});
        return;
    };

    // Create surface from pixel data (ABGR8888 matches R8G8B8A8_UNORM on little-endian)
    const surface = c.SDL_CreateSurfaceFrom(
        @as(i32, @intCast(ATLAS_SIZE)),
        @as(i32, @intCast(ATLAS_SIZE)),
        c.SDL_PIXELFORMAT_ABGR8888,
        @ptrCast(mapped),
        @as(i32, @intCast(ATLAS_SIZE * bpp)),
    );
    if (surface == null) {
        std.debug.print("Failed to create surface for atlas dump\n", .{});
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);
        return;
    }

    if (c.IMG_SavePNG(surface, path)) {
        std.debug.print("Atlas saved to {s}\n", .{path});
    } else {
        std.debug.print("Failed to save atlas: {s}\n", .{c.SDL_GetError()});
    }

    c.SDL_DestroySurface(surface);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);
}
