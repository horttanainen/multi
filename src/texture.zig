const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const atlas = @import("atlas.zig");
const c = sdl.c;
const Atlas = atlas.Atlas;
const ATLAS_SIZE = atlas.ATLAS_SIZE;

const PendingTextureUpload = struct {
    transfer_buf: *c.SDL_GPUTransferBuffer,
    fence: *c.SDL_GPUFence,
};

var pendingTextureUploads: std.ArrayListUnmanaged(PendingTextureUpload) = .empty;

pub const TextureBacking = enum {
    immutable_atlas,
    mutable_atlas,
    standalone,
};

pub const Texture = struct {
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: i32,
    height: i32,
    backing: TextureBacking = .immutable_atlas,
    atlas_generation: u64 = 0,
    owns_atlas_region: bool = true,
    standalone_gpu_texture: ?*c.SDL_GPUTexture = null,
    color_mod: sdl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    blend_mode: sdl.BlendMode = .blend,
};

pub fn isAtlasTexture(texture: *const Texture) bool {
    return texture.backing != .standalone;
}

pub fn isImmutableAtlasTexture(texture: *const Texture) bool {
    return texture.backing == .immutable_atlas;
}

fn atlasForTexture(texture: *const Texture) ?*Atlas {
    switch (texture.backing) {
        .immutable_atlas => return gpu.getAtlas(),
        .mutable_atlas => return gpu.getMutableAtlas(),
        .standalone => return null,
    }
}

pub fn gpuTexture(texture: *const Texture) *c.SDL_GPUTexture {
    const tex_atlas = atlasForTexture(texture);
    if (tex_atlas == null) {
        return texture.standalone_gpu_texture.?;
    }
    return tex_atlas.?.gpu_texture;
}

fn createGpuTexture(device: *c.SDL_GPUDevice, w: u32, h: u32) !*c.SDL_GPUTexture {
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
    return c.SDL_CreateGPUTexture(device, &tex_info) orelse return error.CreateGPUTextureFailed;
}

/// Add a surface to the texture atlas. Returns an atlas-backed Texture.
pub fn addToAtlas(surface: *sdl.Surface) !*Texture {
    const device = gpu.getDevice();
    const tex_atlas = gpu.getAtlas();
    const allocator = gpu.getAllocator();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);

    const region = try tex_atlas.allocate(w, h);

    const texture = try allocator.create(Texture);
    texture.* = .{
        .atlas_x = region.x,
        .atlas_y = region.y,
        .width = @intCast(w),
        .height = @intCast(h),
        .backing = .immutable_atlas,
        .atlas_generation = tex_atlas.generation,
    };

    uploadToAtlasRegion(device, tex_atlas, rgba_surface, region.x, region.y, w, h);
    return texture;
}

/// Create a standalone GPU texture (not in atlas). Used for ephemeral textures like text.
pub fn createStandaloneTexture(surface: *sdl.Surface) !*Texture {
    const device = gpu.getDevice();
    const allocator = gpu.getAllocator();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);

    const gpu_texture = try createGpuTexture(device, w, h);

    const texture = try allocator.create(Texture);
    texture.* = .{
        .width = @intCast(w),
        .height = @intCast(h),
        .backing = .standalone,
        .standalone_gpu_texture = gpu_texture,
    };

    uploadTextureImmediate(device, gpu_texture, rgba_surface);
    return texture;
}

pub fn createMutableTexture(surface: *sdl.Surface) !*Texture {
    const device = gpu.getDevice();
    const allocator = gpu.getAllocator();
    const tex_atlas = gpu.getMutableAtlas();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);
    const region = tex_atlas.allocate(w, h) catch |err| {
        if (err != error.AtlasFull) {
            std.log.warn("createMutableTexture: mutable atlas allocation failed with {}", .{err});
            return err;
        }

        std.log.warn("createMutableTexture: mutable atlas full, using standalone texture", .{});
        return createStandaloneTexture(surface);
    };

    const texture = try allocator.create(Texture);
    texture.* = .{
        .atlas_x = region.x,
        .atlas_y = region.y,
        .width = @intCast(w),
        .height = @intCast(h),
        .backing = .mutable_atlas,
        .atlas_generation = tex_atlas.generation,
    };

    uploadToAtlasRegion(device, tex_atlas, rgba_surface, region.x, region.y, w, h);
    return texture;
}

pub fn destroyTexture(texture: *Texture) void {
    if (texture.backing == .standalone) {
        if (texture.standalone_gpu_texture) |gpu_tex| {
            gpu.queueTextureDestroy(gpu_tex);
        }
    } else if (texture.backing == .mutable_atlas and texture.owns_atlas_region) {
        const tex_atlas = gpu.getMutableAtlas();
        if (texture.atlas_generation != tex_atlas.generation) {
            gpu.getAllocator().destroy(texture);
            return;
        }

        tex_atlas.freeRegion(
            texture.atlas_x,
            texture.atlas_y,
            @intCast(texture.width),
            @intCast(texture.height),
        );
    }
    gpu.getAllocator().destroy(texture);
}

fn releasePendingUpload(device: *c.SDL_GPUDevice, upload: PendingTextureUpload) void {
    c.SDL_ReleaseGPUFence(device, upload.fence);
    c.SDL_ReleaseGPUTransferBuffer(device, upload.transfer_buf);
}

fn cleanupPendingUploads(device: *c.SDL_GPUDevice, wait: bool) void {
    var i: usize = 0;
    while (i < pendingTextureUploads.items.len) {
        const upload = pendingTextureUploads.items[i];

        if (wait) {
            var fence = upload.fence;
            _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&fence), 1);
        } else if (!c.SDL_QueryGPUFence(device, upload.fence)) {
            i += 1;
            continue;
        }

        releasePendingUpload(device, upload);
        _ = pendingTextureUploads.swapRemove(i);
    }
}

pub fn cleanupCompletedUploads() void {
    cleanupPendingUploads(gpu.getDevice(), false);
}

pub fn flushPendingUploads() void {
    cleanupPendingUploads(gpu.getDevice(), true);
    pendingTextureUploads.deinit(gpu.getAllocator());
}

fn submitUploadAndTrackBuffer(device: *c.SDL_GPUDevice, cmd: *c.SDL_GPUCommandBuffer, transfer_buf: *c.SDL_GPUTransferBuffer) void {
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
        std.log.warn("submitUploadAndTrackBuffer: failed to submit texture upload command buffer", .{});
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };

    pendingTextureUploads.append(gpu.getAllocator(), .{
        .transfer_buf = transfer_buf,
        .fence = fence,
    }) catch |err| {
        std.log.warn("submitUploadAndTrackBuffer: failed to track texture upload with {}", .{err});
        var fenceToWait = fence;
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&fenceToWait), 1);
        c.SDL_ReleaseGPUFence(device, fence);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    };

    cleanupPendingUploads(device, false);
}

/// Create a new Texture wrapper that shares the same atlas region.
pub fn cloneTexture(source: *Texture) !*Texture {
    if (source.backing != .immutable_atlas) {
        std.log.warn("cloneTexture: refusing to share non-immutable texture backing", .{});
        return error.CannotCloneMutableTexture;
    }

    const texture = try gpu.getAllocator().create(Texture);
    texture.* = .{
        .atlas_x = source.atlas_x,
        .atlas_y = source.atlas_y,
        .width = source.width,
        .height = source.height,
        .backing = .immutable_atlas,
        .atlas_generation = source.atlas_generation,
        .owns_atlas_region = false,
        .color_mod = source.color_mod,
        .blend_mode = source.blend_mode,
    };
    return texture;
}

fn moveTextureToStandalone(texture: *Texture, rgba_surface: *sdl.Surface) !void {
    const device = gpu.getDevice();

    const w: u32 = @intCast(texture.width);
    const h: u32 = @intCast(texture.height);
    const gpu_texture = try createGpuTexture(device, w, h);
    errdefer c.SDL_ReleaseGPUTexture(device, gpu_texture);

    texture.atlas_x = 0;
    texture.atlas_y = 0;
    texture.backing = .standalone;
    texture.atlas_generation = 0;
    texture.owns_atlas_region = true;
    texture.standalone_gpu_texture = gpu_texture;

    uploadTextureImmediate(device, gpu_texture, rgba_surface);
}

pub fn ensureMutableTexture(texture: *Texture, surface: *sdl.Surface) !void {
    if (texture.backing == .mutable_atlas or texture.backing == .standalone) {
        return;
    }

    const device = gpu.getDevice();
    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(texture.width);
    const h: u32 = @intCast(texture.height);
    const tex_atlas = gpu.getMutableAtlas();
    const region = tex_atlas.allocate(w, h) catch |err| {
        if (err != error.AtlasFull) {
            std.log.warn("ensureMutableTexture: mutable atlas allocation failed with {}", .{err});
            return err;
        }

        std.log.warn("ensureMutableTexture: mutable atlas full, using standalone texture", .{});
        try moveTextureToStandalone(texture, rgba_surface);
        return;
    };

    texture.atlas_x = region.x;
    texture.atlas_y = region.y;
    texture.backing = .mutable_atlas;
    texture.atlas_generation = tex_atlas.generation;
    texture.owns_atlas_region = true;
    texture.standalone_gpu_texture = null;

    uploadToAtlasRegion(device, tex_atlas, rgba_surface, region.x, region.y, w, h);
}

/// Compatibility wrapper for older copy-on-write call sites.
pub fn reallocateAtlasRegion(texture: *Texture, surface: *sdl.Surface) !void {
    try ensureMutableTexture(texture, surface);
}

/// Reset atlas packer state (call on level reload to reclaim all atlas space).
pub fn resetAtlas() void {
    gpu.getAtlas().init();
    gpu.getMutableAtlas().init();
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

    const tex_atlas = atlasForTexture(texture);
    if (tex_atlas == null) {
        uploadTextureImmediate(device, texture.standalone_gpu_texture.?, rgba_surface);
        return;
    }

    uploadToAtlasRegion(device, tex_atlas.?, rgba_surface, texture.atlas_x, texture.atlas_y, @intCast(texture.width), @intCast(texture.height));
}

pub fn reuploadTextureRegion(texture: *Texture, surface: *sdl.Surface, rect: sdl.Rect) !void {
    if (rect.w <= 0 or rect.h <= 0) {
        return;
    }

    if (surface.format == c.SDL_PIXELFORMAT_BGRA32) {
        uploadTextureRegionFromBgraSurface(texture, surface, rect);
        return;
    }

    const device = gpu.getDevice();

    const sub_surface = c.SDL_CreateSurface(rect.w, rect.h, surface.format);
    if (sub_surface == null) return error.CreateSurfaceFailed;
    defer c.SDL_DestroySurface(sub_surface);

    const src_rect = c.SDL_Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    const dst_rect = c.SDL_Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
    if (!c.SDL_BlitSurface(surface, &src_rect, sub_surface, &dst_rect)) {
        return error.BlitSurfaceFailed;
    }

    const rgba_surface = c.SDL_ConvertSurface(sub_surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const tex_atlas = atlasForTexture(texture);
    if (tex_atlas != null) {
        const dstX: u32 = texture.atlas_x + @as(u32, @intCast(rect.x));
        const dstY: u32 = texture.atlas_y + @as(u32, @intCast(rect.y));
        uploadToAtlasRegion(device, tex_atlas.?, rgba_surface, dstX, dstY, @intCast(rect.w), @intCast(rect.h));
        return;
    }

    uploadTextureRegionImmediate(device, texture.standalone_gpu_texture.?, rgba_surface, @intCast(rect.x), @intCast(rect.y));
}

fn uploadTextureRegionFromBgraSurface(texture: *Texture, surface: *sdl.Surface, rect: sdl.Rect) void {
    const device = gpu.getDevice();
    const w: u32 = @intCast(rect.w);
    const h: u32 = @intCast(rect.h);
    const data_size: u32 = w * h * 4;

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
    const sourcePixels: [*]const u8 = @ptrCast(surface.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);
        return;
    });
    const sourcePitch: usize = @intCast(surface.pitch);
    const dst: [*]u8 = @ptrCast(mapped);

    const rectX: usize = @intCast(rect.x);
    const rectY: usize = @intCast(rect.y);
    const width: usize = @intCast(w);
    const height: usize = @intCast(h);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const sourceRow = (rectY + y) * sourcePitch + rectX * 4;
        const dstRow = y * width * 4;

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const srcIndex = sourceRow + x * 4;
            const dstIndex = dstRow + x * 4;
            dst[dstIndex + 0] = sourcePixels[srcIndex + 2];
            dst[dstIndex + 1] = sourcePixels[srcIndex + 1];
            dst[dstIndex + 2] = sourcePixels[srcIndex + 0];
            dst[dstIndex + 3] = sourcePixels[srcIndex + 3];
        }
    }
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
        .pixels_per_row = w,
        .rows_per_layer = h,
    };
    const dst_region = c.SDL_GPUTextureRegion{
        .texture = gpuTexture(texture),
        .mip_level = 0,
        .layer = 0,
        .x = if (isAtlasTexture(texture)) texture.atlas_x + @as(u32, @intCast(rect.x)) else @intCast(rect.x),
        .y = if (isAtlasTexture(texture)) texture.atlas_y + @as(u32, @intCast(rect.y)) else @intCast(rect.y),
        .z = 0,
        .w = w,
        .h = h,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &dst_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    submitUploadAndTrackBuffer(device, cmd, transfer_buf);
}

/// Upload surface pixel data to a sub-region of the atlas texture.
fn uploadToAtlasRegion(device: *c.SDL_GPUDevice, tex_atlas: *Atlas, rgba_surface: *sdl.Surface, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
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
        .texture = tex_atlas.gpu_texture,
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
    submitUploadAndTrackBuffer(device, cmd, transfer_buf);
}

fn uploadTextureRegionImmediate(device: *c.SDL_GPUDevice, gpu_texture: *c.SDL_GPUTexture, rgba_surface: *sdl.Surface, dst_x: u32, dst_y: u32) void {
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
        .x = dst_x,
        .y = dst_y,
        .z = 0,
        .w = w,
        .h = h,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &dst_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    submitUploadAndTrackBuffer(device, cmd, transfer_buf);
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
    submitUploadAndTrackBuffer(device, cmd, transfer_buf);
}

pub fn saveAtlasToDisk(path: [*:0]const u8) void {
    const device = gpu.getDevice();
    const tex_atlas = gpu.getAtlas();

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
        .texture = tex_atlas.gpu_texture,
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
