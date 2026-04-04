// GPU batch renderer using SDL_GPU
// Extracted from sdl.zig - handles pipelines, shaders, vertex types, batch recording, draw calls, frame management
const std = @import("std");
const sdl = @import("sdl.zig");
const atlas = @import("atlas.zig");
const texture = @import("texture.zig");
const config = @import("config.zig");
const c = sdl.c;

var crt_params: config.CrtParams = config.crt;
pub const LutParams = struct {
    strength: f32,
};
var lut_params: LutParams = .{ .strength = 1.0 };

pub fn setCrtParams(params: config.CrtParams) void {
    crt_params = params;
}

pub fn setLutParams(params: LutParams) void {
    lut_params = params;
}

// Camera zoom: values < 1.0 zoom out (show more of the world). Recorded as a batch
// command so it interleaves correctly with draw calls during playback.
pub fn setZoom(z: f32) void {
    const g = getGpu();

    // Finalize current batch before zoom change so the draw record
    // appears before this set_zoom in the playback sequence.
    finalizeBatch(g);

    if (g.batch_count >= MAX_BATCH_RECORDS) return;
    g.batch_records[g.batch_count] = .{ .set_zoom = .{ .zoom = z } };
    g.batch_count += 1;
}

pub fn drawPaintBackground(uniforms: PaintUniforms) void {
    const g = getGpu();
    finalizeBatch(g);
    if (g.batch_count >= MAX_BATCH_RECORDS) return;
    g.batch_records[g.batch_count] = .{ .draw_paint_background = .{ .uniforms = uniforms } };
    g.batch_count += 1;
}

pub const Texture = texture.Texture;

// ============================================================
// Vertex types for batch renderer
// ============================================================

const PackedColor = packed struct { r: u8, g: u8, b: u8, a: u8 };

const SpriteVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: PackedColor,
};

const ColorVertex = extern struct {
    x: f32,
    y: f32,
    color: PackedColor,
};

const ViewportUniforms = extern struct {
    viewport_size: [2]f32,
};

const FullscreenVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

const CrtUniforms = extern struct {
    resolution: [2]f32,
    distortion_strength: f32,
    aberration: f32,
    zoom: f32,
};

const LutUniforms = extern struct {
    strength: f32,
};

pub const PaintUniforms = extern struct {
    resolution: [2]f32,
    spin_rotation: f32,
    spin_speed: f32,
    offset: [2]f32,
    contrast: f32,
    spin_amount: f32,
    pixel_filter: f32,
    time: f32,
    colour_1: [3]f32,
    _pad1: f32 = 0,
    colour_2: [3]f32,
    _pad2: f32 = 0,
    colour_3: [3]f32,
    _pad3: f32 = 0,
    swirl_type: f32 = 0,
    noise_type: f32 = 0,
    color_mode: f32 = 0,
    noise_scale: f32 = 1.0,
    noise_octaves: f32 = 5.0,
    offset_z: f32 = 1.0,
    color_intensity: f32 = 1.0,
    swirl_segments: f32 = 6.0,
    swirl_count: f32 = 1.0,
    swirl_center_1: [2]f32 = .{ 0.0, 0.0 },
    swirl_center_2: [2]f32 = .{ 0.25, 0.0 },
    swirl_center_3: [2]f32 = .{ -0.25, 0.2 },
    swirl_center_4: [2]f32 = .{ 0.0, -0.25 },
    noise_speed: f32 = 0.5,
    noise_amplitude: f32 = 1.0,
    color_speed: f32 = 0.0,
    swirl_falloff: f32 = 5.0,
    audio_loudness: f32 = 0.0,
    audio_loudness_att: f32 = 0.0,
    audio_bass: f32 = 0.0,
    audio_bass_att: f32 = 0.0,
    audio_texture: f32 = 0.0,
    audio_texture_att: f32 = 0.0,
    audio_accent: f32 = 0.0,
    audio_accent_att: f32 = 0.0,
    audio_onset: f32 = 0.0,
    bass_mode: f32 = 3.0,
    bass_strength: f32 = 0.45,
    texture_mode: f32 = 5.0,
    texture_strength: f32 = 0.4,
    accent_mode: f32 = 8.0,
    accent_strength: f32 = 0.28,
    loudness_mode: f32 = 8.0,
    loudness_strength: f32 = 0.22,
    onset_mode: f32 = 10.0,
    onset_strength: f32 = 0.24,
    _pad5: [1]f32 = .{0},
};

// ============================================================
// GPU Batch Renderer State (deferred rendering)
// ============================================================

const MAX_SPRITE_VERTICES = 64 * 1024; // 64K vertices = ~10K sprites
const MAX_COLOR_VERTICES = 64 * 1024;
const MAX_BATCH_RECORDS = 8192;
const MAX_PENDING_DESTROYS = 256;

const PipelineType = enum {
    sprite_alpha,
    sprite_additive,
    colored_triangles,
    colored_lines,
};

const BatchMode = enum { none, sprite, color };

const BatchRecord = union(enum) {
    draw_sprites: struct {
        pipeline: PipelineType,
        texture: *c.SDL_GPUTexture,
        vertex_offset: u32,
        vertex_count: u32,
    },
    draw_colored: struct {
        pipeline: PipelineType,
        vertex_offset: u32,
        vertex_count: u32,
    },
    set_viewport: struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    set_zoom: struct {
        zoom: f32,
    },
    draw_paint_background: struct {
        uniforms: PaintUniforms,
    },
};

const GpuState = struct {
    device: *c.SDL_GPUDevice,
    window: *sdl.Window,

    // Texture atlas
    atlas: atlas.Atlas,

    // Pipelines
    sprite_alpha_pipeline: *c.SDL_GPUGraphicsPipeline,
    sprite_additive_pipeline: *c.SDL_GPUGraphicsPipeline,
    colored_triangles_pipeline: *c.SDL_GPUGraphicsPipeline,
    colored_lines_pipeline: *c.SDL_GPUGraphicsPipeline,

    // CRT post-processing
    crt_enabled: bool = true,
    offscreen_texture: *c.SDL_GPUTexture,
    offscreen_w: u32,
    offscreen_h: u32,
    crt_pipeline: *c.SDL_GPUGraphicsPipeline,
    fullscreen_quad_buffer: *c.SDL_GPUBuffer,
    crt_sampler: *c.SDL_GPUSampler,

    // Paint background
    paint_pipeline: *c.SDL_GPUGraphicsPipeline,

    // LUT color grading
    lut_enabled: bool = true,
    lut_pipeline: *c.SDL_GPUGraphicsPipeline,
    lut_texture: *c.SDL_GPUTexture,
    offscreen_texture_b: *c.SDL_GPUTexture,

    // Sampler
    sampler: *c.SDL_GPUSampler,

    // Pre-allocated GPU vertex buffers
    sprite_gpu_buffer: *c.SDL_GPUBuffer,
    color_gpu_buffer: *c.SDL_GPUBuffer,

    // Pre-allocated transfer buffers (reused each frame)
    sprite_transfer_buffer: *c.SDL_GPUTransferBuffer,
    color_transfer_buffer: *c.SDL_GPUTransferBuffer,

    // Per-frame state
    cmd_buf: ?*c.SDL_GPUCommandBuffer = null,
    swapchain_texture: ?*c.SDL_GPUTexture = null,
    swapchain_w: f32 = 0,
    swapchain_h: f32 = 0,

    // CPU-side vertex arrays
    sprite_vertices: [MAX_SPRITE_VERTICES]SpriteVertex = undefined,
    sprite_vertex_count: u32 = 0,
    color_vertices: [MAX_COLOR_VERTICES]ColorVertex = undefined,
    color_vertex_count: u32 = 0,

    // Deferred batch records
    batch_records: [MAX_BATCH_RECORDS]BatchRecord = undefined,
    batch_count: u32 = 0,

    // Current batch tracking
    batch_mode: BatchMode = .none,
    current_pipeline: ?PipelineType = null,
    current_texture: ?*c.SDL_GPUTexture = null,
    sprite_batch_start: u32 = 0,
    color_batch_start: u32 = 0,

    // Deferred texture destruction
    pending_destroys: [MAX_PENDING_DESTROYS]*c.SDL_GPUTexture = undefined,
    pending_destroy_count: u32 = 0,

    // Current viewport/state
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    draw_color: sdl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    clear_color: sdl.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    draw_blend_mode: sdl.BlendMode = .blend,
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
};

/// Opaque GPU device handle - game code passes this around as "renderer"
pub const Renderer = GpuState;

var gpu: ?*GpuState = null;

fn getGpu() *GpuState {
    return gpu.?;
}

// ============================================================
// Accessors for texture/atlas modules
// ============================================================

pub fn getDevice() *c.SDL_GPUDevice {
    return getGpu().device;
}

pub fn getAtlas() *atlas.Atlas {
    return &getGpu().atlas;
}

pub fn saveAtlasCheckpoint() void {
    getGpu().atlas.saveCheckpoint();
}

pub fn resetAtlasToCheckpoint() void {
    getGpu().atlas.restoreCheckpoint();
}

pub fn getAllocator() std.mem.Allocator {
    return mem_allocator;
}

pub fn queueTextureDestroy(gpu_tex: *c.SDL_GPUTexture) void {
    if (gpu) |g| {
        if (g.pending_destroy_count < MAX_PENDING_DESTROYS) {
            g.pending_destroys[g.pending_destroy_count] = gpu_tex;
            g.pending_destroy_count += 1;
        } else {
            c.SDL_ReleaseGPUTexture(g.device, gpu_tex);
        }
    }
}

// ============================================================
// Shader loading helpers
// ============================================================

const sprite_vert_msl = @embedFile("shaders/sprite.metal");
const sprite_frag_msl = @embedFile("shaders/sprite.metal");
const colored_vert_msl = @embedFile("shaders/colored.metal");
const colored_frag_msl = @embedFile("shaders/colored.metal");
const crt_msl = @embedFile("shaders/crt.metal");
const lut_msl = @embedFile("shaders/lut.metal");
const paint_msl = @embedFile("shaders/background_paint.metal");

fn createShader(
    device: *c.SDL_GPUDevice,
    code: [*]const u8,
    code_size: usize,
    entrypoint: [*:0]const u8,
    stage: c.SDL_GPUShaderStage,
    num_samplers: u32,
    num_uniform_buffers: u32,
) !*c.SDL_GPUShader {
    const create_info = c.SDL_GPUShaderCreateInfo{
        .code_size = code_size,
        .code = code,
        .entrypoint = entrypoint,
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    };
    return c.SDL_CreateGPUShader(device, &create_info) orelse return error.CreateShaderFailed;
}

// ============================================================
// Pipeline creation
// ============================================================

const MAX_VERTEX_ATTRS = 4;

const VertexLayout = struct {
    pitch: u32,
    attrs: []const c.SDL_GPUVertexAttribute,
};

const PipelineConfig = struct {
    // Shader source (same file for both vert and frag)
    shader_code: []const u8,
    vert_entry: [*:0]const u8,
    frag_entry: [*:0]const u8,

    // Shader resource counts
    vert_samplers: u32 = 0,
    vert_uniforms: u32 = 0,
    frag_samplers: u32 = 0,
    frag_uniforms: u32 = 0,

    // Vertex layout
    vertex_layout: VertexLayout,

    // Rendering config
    primitive_type: c.SDL_GPUPrimitiveType = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
    blend_state: c.SDL_GPUColorTargetBlendState = no_blend,

    const no_blend = c.SDL_GPUColorTargetBlendState{
        .enable_blend = false,
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = 0xF,
        .enable_color_write_mask = true,
        .padding1 = 0,
        .padding2 = 0,
    };
};

fn createPipeline(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    pipeline_config: PipelineConfig,
) !*c.SDL_GPUGraphicsPipeline {
    const vert_shader = try createShader(
        device,
        pipeline_config.shader_code.ptr,
        pipeline_config.shader_code.len,
        pipeline_config.vert_entry,
        c.SDL_GPU_SHADERSTAGE_VERTEX,
        pipeline_config.vert_samplers,
        pipeline_config.vert_uniforms,
    );
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = try createShader(
        device,
        pipeline_config.shader_code.ptr,
        pipeline_config.shader_code.len,
        pipeline_config.frag_entry,
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        pipeline_config.frag_samplers,
        pipeline_config.frag_uniforms,
    );
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const vertex_buffer_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{
            .slot = 0,
            .pitch = pipeline_config.vertex_layout.pitch,
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
    };

    const color_target = [_]c.SDL_GPUColorTargetDescription{
        .{
            .format = swapchain_format,
            .blend_state = pipeline_config.blend_state,
        },
    };

    const pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = vertex_buffer_desc.len,
            .vertex_attributes = pipeline_config.vertex_layout.attrs.ptr,
            .num_vertex_attributes = @intCast(pipeline_config.vertex_layout.attrs.len),
        },
        .primitive_type = pipeline_config.primitive_type,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = std.mem.zeroes(c.SDL_GPUDepthStencilState),
        .target_info = .{
            .color_target_descriptions = &color_target,
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            .has_depth_stencil_target = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    };

    return c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse return error.CreatePipelineFailed;
}

// Pre-defined vertex layouts
const sprite_vertex_layout = VertexLayout{
    .pitch = @sizeOf(SpriteVertex),
    .attrs = &[_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(SpriteVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(SpriteVertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(SpriteVertex, "color") },
    },
};

const color_vertex_layout = VertexLayout{
    .pitch = @sizeOf(ColorVertex),
    .attrs = &[_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(ColorVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(ColorVertex, "color") },
    },
};

const fullscreen_vertex_layout = VertexLayout{
    .pitch = @sizeOf(FullscreenVertex),
    .attrs = &[_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(FullscreenVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(FullscreenVertex, "u") },
    },
};

fn createOffscreenTexture(device: *c.SDL_GPUDevice, w: u32, h: u32, swapchain_format: c.SDL_GPUTextureFormat) !*c.SDL_GPUTexture {
    const tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = swapchain_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    return c.SDL_CreateGPUTexture(device, &tex_info) orelse return error.CreateGPUTextureFailed;
}

fn uploadFullscreenQuad(device: *c.SDL_GPUDevice, buffer: *c.SDL_GPUBuffer) void {
    // Fullscreen quad: two triangles covering NDC [-1,1] with UV [0,1]
    const vertices = [6]FullscreenVertex{
        .{ .x = -1, .y = 1, .u = 0, .v = 0 }, // top-left
        .{ .x = 1, .y = 1, .u = 1, .v = 0 }, // top-right
        .{ .x = 1, .y = -1, .u = 1, .v = 1 }, // bottom-right
        .{ .x = -1, .y = 1, .u = 0, .v = 0 }, // top-left
        .{ .x = 1, .y = -1, .u = 1, .v = 1 }, // bottom-right
        .{ .x = -1, .y = -1, .u = 0, .v = 1 }, // bottom-left
    };

    const data_size = @sizeOf(@TypeOf(vertices));
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse return;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse return;
    const dst: [*]u8 = @ptrCast(mapped);
    const src: [*]const u8 = @ptrCast(&vertices);
    @memcpy(dst[0..data_size], src[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return;
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer_buf,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = buffer,
        .offset = 0,
        .size = data_size,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(device, f);
    }
}

// ============================================================
// Renderer (GPU Device)
// ============================================================

var gpu_state_storage: GpuState = undefined;
var mem_allocator: std.mem.Allocator = undefined;

pub fn init(win: *sdl.Window) !void {
    try createRenderer(win);
}

pub fn cleanup() void {
    destroyRenderer();
}

pub fn createRenderer(window: *sdl.Window) !void {
    mem_allocator = std.heap.c_allocator;

    const device = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_MSL,
        true,
        null,
    ) orelse return error.CreateGPUDeviceFailed;

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.ClaimWindowFailed;

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);

    // Alpha blend state
    const alpha_blend = c.SDL_GPUColorTargetBlendState{
        .enable_blend = true,
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = 0xF,
        .enable_color_write_mask = true,
        .padding1 = 0,
        .padding2 = 0,
    };

    // Additive blend state
    const additive_blend = c.SDL_GPUColorTargetBlendState{
        .enable_blend = true,
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = 0xF,
        .enable_color_write_mask = true,
        .padding1 = 0,
        .padding2 = 0,
    };

    // Create 4 pipelines
    const sprite_alpha = try createPipeline(device, swapchain_format, .{
        .shader_code = sprite_vert_msl,
        .vert_entry = "sprite_vert",
        .frag_entry = "sprite_frag",
        .vert_uniforms = 1,
        .frag_samplers = 1,
        .vertex_layout = sprite_vertex_layout,
        .blend_state = alpha_blend,
    });
    const sprite_additive = try createPipeline(device, swapchain_format, .{
        .shader_code = sprite_vert_msl,
        .vert_entry = "sprite_vert",
        .frag_entry = "sprite_frag",
        .vert_uniforms = 1,
        .frag_samplers = 1,
        .vertex_layout = sprite_vertex_layout,
        .blend_state = additive_blend,
    });
    const colored_triangles = try createPipeline(device, swapchain_format, .{
        .shader_code = colored_vert_msl,
        .vert_entry = "colored_vert",
        .frag_entry = "colored_frag",
        .vert_uniforms = 1,
        .vertex_layout = color_vertex_layout,
        .blend_state = alpha_blend,
    });
    const colored_lines = try createPipeline(device, swapchain_format, .{
        .shader_code = colored_vert_msl,
        .vert_entry = "colored_vert",
        .frag_entry = "colored_frag",
        .vert_uniforms = 1,
        .vertex_layout = color_vertex_layout,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_LINELIST,
        .blend_state = alpha_blend,
    });

    // Create sampler (nearest-neighbor for pixel art)
    const sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0,
        .max_lod = 0,
        .enable_anisotropy = false,
        .enable_compare = false,
        .padding1 = 0,
        .padding2 = 0,
        .props = 0,
    };
    const gpu_sampler = c.SDL_CreateGPUSampler(device, &sampler_info) orelse return error.CreateSamplerFailed;

    // Pre-allocate GPU vertex buffers
    const sprite_vb = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = MAX_SPRITE_VERTICES * @sizeOf(SpriteVertex),
        .props = 0,
    }) orelse return error.CreateBufferFailed;

    const color_vb = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = MAX_COLOR_VERTICES * @sizeOf(ColorVertex),
        .props = 0,
    }) orelse return error.CreateBufferFailed;

    // Pre-allocate transfer buffers (reused each frame)
    const sprite_tb = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = MAX_SPRITE_VERTICES * @sizeOf(SpriteVertex),
        .props = 0,
    }) orelse return error.CreateBufferFailed;

    const color_tb = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = MAX_COLOR_VERTICES * @sizeOf(ColorVertex),
        .props = 0,
    }) orelse return error.CreateBufferFailed;

    // CRT pipeline
    const crt_pipe = try createPipeline(device, swapchain_format, .{
        .shader_code = crt_msl,
        .vert_entry = "crt_vert",
        .frag_entry = "crt_frag",
        .frag_samplers = 1,
        .frag_uniforms = 1,
        .vertex_layout = fullscreen_vertex_layout,
    });

    // Paint background pipeline (no samplers - purely procedural)
    const paint_pipe = try createPipeline(device, swapchain_format, .{
        .shader_code = paint_msl,
        .vert_entry = "paint_vert",
        .frag_entry = "paint_frag",
        .frag_uniforms = 1,
        .vertex_layout = fullscreen_vertex_layout,
    });

    // Linear sampler for CRT post-processing
    const crt_sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0,
        .max_lod = 0,
        .enable_anisotropy = false,
        .enable_compare = false,
        .padding1 = 0,
        .padding2 = 0,
        .props = 0,
    };
    const crt_samp = c.SDL_CreateGPUSampler(device, &crt_sampler_info) orelse return error.CreateSamplerFailed;

    // Fullscreen quad vertex buffer
    const quad_buffer = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = 6 * @sizeOf(FullscreenVertex),
        .props = 0,
    }) orelse return error.CreateBufferFailed;
    uploadFullscreenQuad(device, quad_buffer);

    // LUT pipeline
    const lut_pipe = try createPipeline(device, swapchain_format, .{
        .shader_code = lut_msl,
        .vert_entry = "lut_vert",
        .frag_entry = "lut_frag",
        .frag_samplers = 2,
        .frag_uniforms = 1,
        .vertex_layout = fullscreen_vertex_layout,
    });

    // Offscreen texture for scene rendering (initial size from window)
    var init_w: c_int = 0;
    var init_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &init_w, &init_h);
    const ow: u32 = if (init_w > 0) @intCast(init_w) else 640;
    const oh: u32 = if (init_h > 0) @intCast(init_h) else 480;
    const offscreen_tex = try createOffscreenTexture(device, ow, oh, swapchain_format);
    const offscreen_tex_b = try createOffscreenTexture(device, ow, oh, swapchain_format);

    // Generate and upload identity LUT (32x32x32 stored as 1024x32 RGBA)
    const lut_tex = try createIdentityLut(device);

    // Create atlas GPU texture
    const atlas_tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = atlas.ATLAS_SIZE,
        .height = atlas.ATLAS_SIZE,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const atlas_gpu_texture = c.SDL_CreateGPUTexture(device, &atlas_tex_info) orelse return error.CreateGPUTextureFailed;

    gpu_state_storage = .{
        .device = device,
        .window = window,
        .atlas = blk: {
            var a = atlas.Atlas{ .gpu_texture = atlas_gpu_texture };
            a.init();
            break :blk a;
        },
        .sprite_alpha_pipeline = sprite_alpha,
        .sprite_additive_pipeline = sprite_additive,
        .colored_triangles_pipeline = colored_triangles,
        .colored_lines_pipeline = colored_lines,
        .offscreen_texture = offscreen_tex,
        .offscreen_w = ow,
        .offscreen_h = oh,
        .paint_pipeline = paint_pipe,
        .crt_pipeline = crt_pipe,
        .fullscreen_quad_buffer = quad_buffer,
        .crt_sampler = crt_samp,
        .lut_pipeline = lut_pipe,
        .lut_texture = lut_tex,
        .offscreen_texture_b = offscreen_tex_b,
        .sampler = gpu_sampler,
        .sprite_gpu_buffer = sprite_vb,
        .color_gpu_buffer = color_vb,
        .sprite_transfer_buffer = sprite_tb,
        .color_transfer_buffer = color_tb,
        .swapchain_format = swapchain_format,
    };

    gpu = &gpu_state_storage;
}

pub fn destroyRenderer() void {
    if (gpu) |g| {
        c.SDL_ReleaseGPUTexture(g.device, g.offscreen_texture);
        c.SDL_ReleaseGPUTexture(g.device, g.offscreen_texture_b);
        c.SDL_ReleaseGPUTexture(g.device, g.lut_texture);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.paint_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.crt_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.lut_pipeline);
        c.SDL_ReleaseGPUBuffer(g.device, g.fullscreen_quad_buffer);
        c.SDL_ReleaseGPUSampler(g.device, g.crt_sampler);
        c.SDL_ReleaseGPUTexture(g.device, g.atlas.gpu_texture);
        c.SDL_ReleaseGPUTransferBuffer(g.device, g.sprite_transfer_buffer);
        c.SDL_ReleaseGPUTransferBuffer(g.device, g.color_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(g.device, g.sprite_gpu_buffer);
        c.SDL_ReleaseGPUBuffer(g.device, g.color_gpu_buffer);
        c.SDL_ReleaseGPUSampler(g.device, g.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.sprite_alpha_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.sprite_additive_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.colored_triangles_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(g.device, g.colored_lines_pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(g.device, g.window);
        c.SDL_DestroyGPUDevice(g.device);
        gpu = null;
    }
}

// ============================================================
// Draw color / blend mode state
// ============================================================

pub fn setRenderDrawColor(color: sdl.Color) !void {
    const g = getGpu();
    g.draw_color = color;
}

pub fn setRenderDrawBlendMode(mode: sdl.BlendMode) !void {
    const g = getGpu();
    g.draw_blend_mode = mode;
}

pub fn getRenderDrawBlendMode() !sdl.BlendMode {
    const g = getGpu();
    return g.draw_blend_mode;
}

// ============================================================
// Deferred batch recording
// ============================================================

fn finalizeBatch(g: *GpuState) void {
    switch (g.batch_mode) {
        .sprite => {
            const count = g.sprite_vertex_count - g.sprite_batch_start;
            if (count > 0 and g.batch_count < MAX_BATCH_RECORDS) {
                g.batch_records[g.batch_count] = .{ .draw_sprites = .{
                    .pipeline = g.current_pipeline orelse .sprite_alpha,
                    .texture = g.current_texture.?,
                    .vertex_offset = g.sprite_batch_start,
                    .vertex_count = count,
                } };
                g.batch_count += 1;
            }
        },
        .color => {
            const count = g.color_vertex_count - g.color_batch_start;
            if (count > 0 and g.batch_count < MAX_BATCH_RECORDS) {
                g.batch_records[g.batch_count] = .{ .draw_colored = .{
                    .pipeline = g.current_pipeline orelse .colored_triangles,
                    .vertex_offset = g.color_batch_start,
                    .vertex_count = count,
                } };
                g.batch_count += 1;
            }
        },
        .none => {},
    }
    g.batch_mode = .none;
}

fn ensureSpritePipeline(g: *GpuState, pipeline_type: PipelineType, gpu_texture: *c.SDL_GPUTexture) void {
    if (g.batch_mode != .sprite or g.current_pipeline != pipeline_type or g.current_texture != gpu_texture) {
        finalizeBatch(g);
        g.batch_mode = .sprite;
        g.current_pipeline = pipeline_type;
        g.current_texture = gpu_texture;
        g.sprite_batch_start = g.sprite_vertex_count;
    }
}

fn ensureColorPipeline(g: *GpuState, pipeline_type: PipelineType) void {
    if (g.batch_mode != .color or g.current_pipeline != pipeline_type) {
        finalizeBatch(g);
        g.batch_mode = .color;
        g.current_pipeline = pipeline_type;
        g.current_texture = null;
        g.color_batch_start = g.color_vertex_count;
    }
}

fn setGpuViewport(pass: *c.SDL_GPURenderPass, vp_x: f32, vp_y: f32, vp_w: f32, vp_h: f32) void {
    const vp = c.SDL_GPUViewport{
        .x = vp_x,
        .y = vp_y,
        .w = vp_w,
        .h = vp_h,
        .min_depth = 0,
        .max_depth = 1,
    };
    c.SDL_SetGPUViewport(pass, &vp);

    const scissor = c.SDL_Rect{
        .x = @intFromFloat(vp_x),
        .y = @intFromFloat(vp_y),
        .w = @intFromFloat(vp_w),
        .h = @intFromFloat(vp_h),
    };
    c.SDL_SetGPUScissor(pass, &scissor);
}

// ============================================================
// Frame management
// ============================================================

pub fn renderClear() !void {
    const g = getGpu();

    // Store clear color
    g.clear_color = g.draw_color;

    // Acquire command buffer
    g.cmd_buf = c.SDL_AcquireGPUCommandBuffer(g.device) orelse return error.AcquireCommandBufferFailed;

    // Acquire swapchain texture
    var sw_w: u32 = 0;
    var sw_h: u32 = 0;
    var swapchain_tex: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(g.cmd_buf.?, g.window, &swapchain_tex, &sw_w, &sw_h)) {
        return error.AcquireSwapchainFailed;
    }
    g.swapchain_texture = swapchain_tex;

    if (swapchain_tex == null) return error.SwapchainTextureNull;

    // Save swapchain dimensions for renderPresent initial viewport
    g.swapchain_w = @floatFromInt(sw_w);
    g.swapchain_h = @floatFromInt(sw_h);

    // Recreate offscreen textures if window was resized (needed for post-processing)
    if ((g.crt_enabled or g.lut_enabled) and (sw_w != g.offscreen_w or sw_h != g.offscreen_h)) {
        c.SDL_ReleaseGPUTexture(g.device, g.offscreen_texture);
        c.SDL_ReleaseGPUTexture(g.device, g.offscreen_texture_b);
        g.offscreen_texture = createOffscreenTexture(g.device, sw_w, sw_h, g.swapchain_format) catch return error.AcquireSwapchainFailed;
        g.offscreen_texture_b = createOffscreenTexture(g.device, sw_w, sw_h, g.swapchain_format) catch return error.AcquireSwapchainFailed;
        g.offscreen_w = sw_w;
        g.offscreen_h = sw_h;
    }

    // Set default viewport to full window
    g.viewport_x = 0;
    g.viewport_y = 0;
    g.viewport_w = g.swapchain_w;
    g.viewport_h = g.swapchain_h;

    // Reset batch state (no render pass started yet - deferred to renderPresent)
    g.sprite_vertex_count = 0;
    g.color_vertex_count = 0;
    g.batch_count = 0;
    g.batch_mode = .none;
    g.current_pipeline = null;
    g.current_texture = null;
    g.sprite_batch_start = 0;
    g.color_batch_start = 0;
}

pub fn renderPresent() void {
    const g = getGpu();
    finalizeBatch(g);

    const cmd = g.cmd_buf orelse return;
    const swapchain_tex = g.swapchain_texture orelse return;

    uploadVertexData(g, cmd);

    if (g.lut_enabled and g.crt_enabled) {
        renderScene(g, cmd, g.offscreen_texture);
        applyLutEffect(g, cmd, g.offscreen_texture, g.offscreen_texture_b);
        applyCrtEffect(g, cmd, g.offscreen_texture_b, swapchain_tex);
    } else if (g.lut_enabled) {
        renderScene(g, cmd, g.offscreen_texture);
        applyLutEffect(g, cmd, g.offscreen_texture, swapchain_tex);
    } else if (g.crt_enabled) {
        renderScene(g, cmd, g.offscreen_texture);
        applyCrtEffect(g, cmd, g.offscreen_texture, swapchain_tex);
    } else {
        renderScene(g, cmd, swapchain_tex);
    }

    submitFrame(g, cmd);
}

fn uploadVertexData(g: *GpuState, cmd: *c.SDL_GPUCommandBuffer) void {
    if (g.sprite_vertex_count == 0 and g.color_vertex_count == 0) return;

    if (g.sprite_vertex_count > 0) {
        if (c.SDL_MapGPUTransferBuffer(g.device, g.sprite_transfer_buffer, true)) |mapped| {
            const sprite_data_size = g.sprite_vertex_count * @sizeOf(SpriteVertex);
            const src_bytes: [*]const u8 = @ptrCast(&g.sprite_vertices);
            const dst_bytes: [*]u8 = @ptrCast(mapped);
            @memcpy(dst_bytes[0..sprite_data_size], src_bytes[0..sprite_data_size]);
            c.SDL_UnmapGPUTransferBuffer(g.device, g.sprite_transfer_buffer);
        }
    }

    if (g.color_vertex_count > 0) {
        if (c.SDL_MapGPUTransferBuffer(g.device, g.color_transfer_buffer, true)) |mapped| {
            const color_data_size = g.color_vertex_count * @sizeOf(ColorVertex);
            const src_bytes: [*]const u8 = @ptrCast(&g.color_vertices);
            const dst_bytes: [*]u8 = @ptrCast(mapped);
            @memcpy(dst_bytes[0..color_data_size], src_bytes[0..color_data_size]);
            c.SDL_UnmapGPUTransferBuffer(g.device, g.color_transfer_buffer);
        }
    }

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    if (copy_pass) |cp| {
        if (g.sprite_vertex_count > 0) {
            c.SDL_UploadToGPUBuffer(cp, &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = g.sprite_transfer_buffer,
                .offset = 0,
            }, &c.SDL_GPUBufferRegion{
                .buffer = g.sprite_gpu_buffer,
                .offset = 0,
                .size = g.sprite_vertex_count * @sizeOf(SpriteVertex),
            }, false);
        }

        if (g.color_vertex_count > 0) {
            c.SDL_UploadToGPUBuffer(cp, &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = g.color_transfer_buffer,
                .offset = 0,
            }, &c.SDL_GPUBufferRegion{
                .buffer = g.color_gpu_buffer,
                .offset = 0,
                .size = g.color_vertex_count * @sizeOf(ColorVertex),
            }, false);
        }

        c.SDL_EndGPUCopyPass(cp);
    }
}

fn renderScene(g: *GpuState, cmd: *c.SDL_GPUCommandBuffer, target_texture: *c.SDL_GPUTexture) void {
    const cc = g.clear_color;
    const color_target = c.SDL_GPUColorTargetInfo{
        .texture = target_texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{
            .r = @as(f32, @floatFromInt(cc.r)) / 255.0,
            .g = @as(f32, @floatFromInt(cc.g)) / 255.0,
            .b = @as(f32, @floatFromInt(cc.b)) / 255.0,
            .a = @as(f32, @floatFromInt(cc.a)) / 255.0,
        },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };
    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
    if (render_pass == null) return;
    const rp = render_pass.?;

    setGpuViewport(rp, 0, 0, g.swapchain_w, g.swapchain_h);

    var current_vp_w: f32 = g.swapchain_w;
    var current_vp_h: f32 = g.swapchain_h;
    var current_zoom: f32 = 1.0;
    var last_pipeline: ?PipelineType = null;
    var last_texture: ?*c.SDL_GPUTexture = null;
    var uniforms_dirty: bool = true;
    var i: u32 = 0;
    while (i < g.batch_count) : (i += 1) {
        switch (g.batch_records[i]) {
            .set_viewport => |vp| {
                setGpuViewport(rp, vp.x, vp.y, vp.w, vp.h);
                current_vp_w = vp.w;
                current_vp_h = vp.h;
                uniforms_dirty = true;
            },
            .set_zoom => |z| {
                current_zoom = z.zoom;
                uniforms_dirty = true;
            },
            .draw_sprites => |batch| {
                if (last_pipeline != batch.pipeline) {
                    const pipeline = switch (batch.pipeline) {
                        .sprite_alpha => g.sprite_alpha_pipeline,
                        .sprite_additive => g.sprite_additive_pipeline,
                        else => g.sprite_alpha_pipeline,
                    };
                    c.SDL_BindGPUGraphicsPipeline(rp, pipeline);
                    last_pipeline = batch.pipeline;
                    uniforms_dirty = true;
                }

                if (uniforms_dirty) {
                    const uniforms = ViewportUniforms{ .viewport_size = .{ current_vp_w / current_zoom, current_vp_h / current_zoom } };
                    c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(ViewportUniforms));
                    uniforms_dirty = false;
                }

                const binding = c.SDL_GPUBufferBinding{
                    .buffer = g.sprite_gpu_buffer,
                    .offset = batch.vertex_offset * @sizeOf(SpriteVertex),
                };
                c.SDL_BindGPUVertexBuffers(rp, 0, &binding, 1);

                if (last_texture != batch.texture) {
                    const sampler_binding = c.SDL_GPUTextureSamplerBinding{
                        .texture = batch.texture,
                        .sampler = g.sampler,
                    };
                    c.SDL_BindGPUFragmentSamplers(rp, 0, &sampler_binding, 1);
                    last_texture = batch.texture;
                }

                c.SDL_DrawGPUPrimitives(rp, batch.vertex_count, 1, 0, 0);
            },
            .draw_paint_background => |paint| {
                c.SDL_BindGPUGraphicsPipeline(rp, g.paint_pipeline);
                const quad_binding = c.SDL_GPUBufferBinding{
                    .buffer = g.fullscreen_quad_buffer,
                    .offset = 0,
                };
                c.SDL_BindGPUVertexBuffers(rp, 0, &quad_binding, 1);
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &paint.uniforms, @sizeOf(PaintUniforms));
                c.SDL_DrawGPUPrimitives(rp, 6, 1, 0, 0);
                last_pipeline = null;
                last_texture = null;
                uniforms_dirty = true;
            },
            .draw_colored => |batch| {
                if (last_pipeline != batch.pipeline) {
                    const pipeline = switch (batch.pipeline) {
                        .colored_triangles => g.colored_triangles_pipeline,
                        .colored_lines => g.colored_lines_pipeline,
                        else => g.colored_triangles_pipeline,
                    };
                    c.SDL_BindGPUGraphicsPipeline(rp, pipeline);
                    last_pipeline = batch.pipeline;
                    last_texture = null;
                    uniforms_dirty = true;
                }

                if (uniforms_dirty) {
                    const uniforms = ViewportUniforms{ .viewport_size = .{ current_vp_w / current_zoom, current_vp_h / current_zoom } };
                    c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(ViewportUniforms));
                    uniforms_dirty = false;
                }

                const binding = c.SDL_GPUBufferBinding{
                    .buffer = g.color_gpu_buffer,
                    .offset = batch.vertex_offset * @sizeOf(ColorVertex),
                };
                c.SDL_BindGPUVertexBuffers(rp, 0, &binding, 1);

                c.SDL_DrawGPUPrimitives(rp, batch.vertex_count, 1, 0, 0);
            },
        }
    }

    c.SDL_EndGPURenderPass(rp);
}

fn applyCrtEffect(g: *GpuState, cmd: *c.SDL_GPUCommandBuffer, input_texture: *c.SDL_GPUTexture, output_texture: *c.SDL_GPUTexture) void {
    const crt_target = c.SDL_GPUColorTargetInfo{
        .texture = output_texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };
    const crt_pass = c.SDL_BeginGPURenderPass(cmd, &crt_target, 1, null);
    if (crt_pass) |cp| {
        c.SDL_BindGPUGraphicsPipeline(cp, g.crt_pipeline);

        const quad_binding = c.SDL_GPUBufferBinding{
            .buffer = g.fullscreen_quad_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(cp, 0, &quad_binding, 1);

        const crt_sampler_binding = c.SDL_GPUTextureSamplerBinding{
            .texture = input_texture,
            .sampler = g.crt_sampler,
        };
        c.SDL_BindGPUFragmentSamplers(cp, 0, &crt_sampler_binding, 1);

        const crt_uniforms = CrtUniforms{
            .resolution = crt_params.resolution,
            .distortion_strength = crt_params.distortion_strength,
            .aberration = crt_params.aberration,
            .zoom = crt_params.zoom,
        };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &crt_uniforms, @sizeOf(CrtUniforms));

        c.SDL_DrawGPUPrimitives(cp, 6, 1, 0, 0);
        c.SDL_EndGPURenderPass(cp);
    }
}

fn applyLutEffect(g: *GpuState, cmd: *c.SDL_GPUCommandBuffer, input_texture: *c.SDL_GPUTexture, output_texture: *c.SDL_GPUTexture) void {
    const lut_target = c.SDL_GPUColorTargetInfo{
        .texture = output_texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };
    const lut_pass = c.SDL_BeginGPURenderPass(cmd, &lut_target, 1, null);
    if (lut_pass) |lp| {
        c.SDL_BindGPUGraphicsPipeline(lp, g.lut_pipeline);

        const quad_binding = c.SDL_GPUBufferBinding{
            .buffer = g.fullscreen_quad_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(lp, 0, &quad_binding, 1);

        const sampler_bindings = [2]c.SDL_GPUTextureSamplerBinding{
            .{ .texture = input_texture, .sampler = g.crt_sampler },
            .{ .texture = g.lut_texture, .sampler = g.crt_sampler },
        };
        c.SDL_BindGPUFragmentSamplers(lp, 0, &sampler_bindings, 2);

        const lut_uniforms = LutUniforms{
            .strength = lut_params.strength,
        };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &lut_uniforms, @sizeOf(LutUniforms));

        c.SDL_DrawGPUPrimitives(lp, 6, 1, 0, 0);
        c.SDL_EndGPURenderPass(lp);
    }
}

fn createIdentityLut(device: *c.SDL_GPUDevice) !*c.SDL_GPUTexture {
    const LUT_SIZE: u32 = 32;
    const TEX_W: u32 = LUT_SIZE * LUT_SIZE; // 1024
    const TEX_H: u32 = LUT_SIZE; // 32

    // Generate identity LUT pixel data
    var pixels: [TEX_W * TEX_H * 4]u8 = undefined;
    for (0..TEX_H) |y| {
        for (0..TEX_W) |x| {
            const blue_slice = x / LUT_SIZE;
            const red = x % LUT_SIZE;
            const green = y;

            const idx = (y * TEX_W + x) * 4;
            pixels[idx + 0] = @intCast((red * 255 + 15) / 31);
            pixels[idx + 1] = @intCast((green * 255 + 15) / 31);
            pixels[idx + 2] = @intCast((blue_slice * 255 + 15) / 31);
            pixels[idx + 3] = 255;
        }
    }

    // Create GPU texture
    const tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = TEX_W,
        .height = TEX_H,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const gpu_tex = c.SDL_CreateGPUTexture(device, &tex_info) orelse return error.CreateGPUTextureFailed;

    // Upload via transfer buffer
    const data_size: u32 = TEX_W * TEX_H * 4;
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse return error.CreateBufferFailed;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse return error.MapBufferFailed;
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], &pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.AcquireCommandBufferFailed;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return error.BeginCopyPassFailed;
    c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = TEX_W,
        .rows_per_layer = TEX_H,
    }, &c.SDL_GPUTextureRegion{
        .texture = gpu_tex,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = TEX_W,
        .h = TEX_H,
        .d = 1,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(device, f);
    }

    return gpu_tex;
}

pub fn loadLutFromFile(path: [*:0]const u8) !void {
    const g = getGpu();

    const surface = c.IMG_Load(path) orelse {
        std.log.warn("loadLutFromFile: failed to load '{s}'", .{path});
        return error.LoadLutFailed;
    };
    defer c.SDL_DestroySurface(surface);

    const rgba = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888) orelse {
        std.log.warn("loadLutFromFile: failed to convert surface for '{s}'", .{path});
        return error.ConvertSurfaceFailed;
    };
    defer c.SDL_DestroySurface(rgba);

    const w: u32 = @intCast(rgba.*.w);
    const h: u32 = @intCast(rgba.*.h);

    if (w != 1024 or h != 32) {
        std.log.warn("loadLutFromFile: expected 1024x32, got {d}x{d} for '{s}'", .{ w, h, path });
        return error.InvalidLutDimensions;
    }

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
    const new_tex = c.SDL_CreateGPUTexture(g.device, &tex_info) orelse return error.CreateGPUTextureFailed;

    const pitch: u32 = @intCast(rgba.*.pitch);
    const data_size: u32 = pitch * h;
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(g.device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse {
        c.SDL_ReleaseGPUTexture(g.device, new_tex);
        return error.CreateBufferFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);

    const mapped = c.SDL_MapGPUTransferBuffer(g.device, transfer_buf, false) orelse {
        c.SDL_ReleaseGPUTexture(g.device, new_tex);
        return error.MapBufferFailed;
    };
    const pixels: [*]const u8 = @ptrCast(rgba.*.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);
        c.SDL_ReleaseGPUTexture(g.device, new_tex);
        return error.NoPixelData;
    });
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], pixels[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(g.device) orelse {
        c.SDL_ReleaseGPUTexture(g.device, new_tex);
        return error.AcquireCommandBufferFailed;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        c.SDL_ReleaseGPUTexture(g.device, new_tex);
        return error.BeginCopyPassFailed;
    };
    c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = pitch / 4,
        .rows_per_layer = h,
    }, &c.SDL_GPUTextureRegion{
        .texture = new_tex,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = w,
        .h = h,
        .d = 1,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (fence) |f| {
        _ = c.SDL_WaitForGPUFences(g.device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(g.device, f);
    }

    // Keep the previous LUT alive until submitted frames are done with it.
    queueTextureDestroy(g.lut_texture);
    g.lut_texture = new_tex;
}

pub fn loadLutFromIdentity() !void {
    const g = getGpu();
    const new_tex = createIdentityLut(g.device) catch |err| {
        std.log.warn("loadLutFromIdentity: failed to create identity LUT: {}", .{err});
        return err;
    };
    // Keep the previous LUT alive until submitted frames are done with it.
    queueTextureDestroy(g.lut_texture);
    g.lut_texture = new_tex;
}

fn submitFrame(g: *GpuState, cmd: *c.SDL_GPUCommandBuffer) void {
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);

    var di: u32 = 0;
    while (di < g.pending_destroy_count) : (di += 1) {
        c.SDL_ReleaseGPUTexture(g.device, g.pending_destroys[di]);
    }
    g.pending_destroy_count = 0;

    g.cmd_buf = null;
    g.swapchain_texture = null;
}

// ============================================================
// Drawing - renderCopyEx (sprites)
// ============================================================

pub fn renderCopy(tex: *Texture, src_rect: ?*const sdl.Rect, dst_rect: ?*const sdl.Rect) !void {
    try renderCopyEx(tex, src_rect, dst_rect, 0, null, .none);
}

pub fn renderCopyEx(
    tex: *Texture,
    src_rect: ?*const sdl.Rect,
    dst_rect: ?*const sdl.Rect,
    angle: f64,
    center: ?*const sdl.Point,
    flip: sdl.FlipMode,
) !void {
    const g = getGpu();

    // Determine pipeline based on texture blend mode
    const pipeline_type: PipelineType = switch (tex.blend_mode) {
        .add => .sprite_additive,
        else => .sprite_alpha,
    };
    ensureSpritePipeline(g, pipeline_type, tex.gpuTexture());

    // Source UV coords - atlas vs standalone
    var uv_left: f32 = undefined;
    var uv_top: f32 = undefined;
    var uv_right: f32 = undefined;
    var uv_bottom: f32 = undefined;
    if (tex.is_atlas) {
        const atlas_size: f32 = @floatFromInt(atlas.ATLAS_SIZE);
        const ax: f32 = @floatFromInt(tex.atlas_x);
        const ay: f32 = @floatFromInt(tex.atlas_y);
        if (src_rect) |sr| {
            uv_left = (ax + @as(f32, @floatFromInt(sr.x))) / atlas_size;
            uv_top = (ay + @as(f32, @floatFromInt(sr.y))) / atlas_size;
            uv_right = (ax + @as(f32, @floatFromInt(sr.x + sr.w))) / atlas_size;
            uv_bottom = (ay + @as(f32, @floatFromInt(sr.y + sr.h))) / atlas_size;
        } else {
            uv_left = ax / atlas_size;
            uv_top = ay / atlas_size;
            uv_right = (ax + @as(f32, @floatFromInt(tex.width))) / atlas_size;
            uv_bottom = (ay + @as(f32, @floatFromInt(tex.height))) / atlas_size;
        }
    } else {
        // Standalone texture: UVs relative to texture size (0..1)
        uv_left = 0;
        uv_top = 0;
        uv_right = 1;
        uv_bottom = 1;
        if (src_rect) |sr| {
            const tw: f32 = @floatFromInt(tex.width);
            const th: f32 = @floatFromInt(tex.height);
            uv_left = @as(f32, @floatFromInt(sr.x)) / tw;
            uv_top = @as(f32, @floatFromInt(sr.y)) / th;
            uv_right = @as(f32, @floatFromInt(sr.x + sr.w)) / tw;
            uv_bottom = @as(f32, @floatFromInt(sr.y + sr.h)) / th;
        }
    }

    // Destination rect
    var dx: f32 = 0;
    var dy: f32 = 0;
    var dw: f32 = @floatFromInt(tex.width);
    var dh: f32 = @floatFromInt(tex.height);
    if (dst_rect) |dr| {
        dx = @floatFromInt(dr.x);
        dy = @floatFromInt(dr.y);
        dw = @floatFromInt(dr.w);
        dh = @floatFromInt(dr.h);
    }

    // Apply flip to UVs
    if (flip == .horizontal) {
        const tmp = uv_left;
        uv_left = uv_right;
        uv_right = tmp;
    }
    if (flip == .vertical) {
        const tmp = uv_top;
        uv_top = uv_bottom;
        uv_bottom = tmp;
    }

    // Color modulation
    const cm = tex.color_mod;
    const vc = PackedColor{ .r = cm.r, .g = cm.g, .b = cm.b, .a = cm.a };

    // Generate 4 corners relative to center of rotation
    const cx: f32 = if (center) |ctr| @floatFromInt(ctr.x) else dw / 2.0;
    const cy: f32 = if (center) |ctr| @floatFromInt(ctr.y) else dh / 2.0;

    // Corner offsets from rotation center
    const corners = [4][2]f32{
        .{ -cx, -cy }, // top-left
        .{ dw - cx, -cy }, // top-right
        .{ dw - cx, dh - cy }, // bottom-right
        .{ -cx, dh - cy }, // bottom-left
    };

    const uvs = [4][2]f32{
        .{ uv_left, uv_top },
        .{ uv_right, uv_top },
        .{ uv_right, uv_bottom },
        .{ uv_left, uv_bottom },
    };

    // Rotation
    const rad: f32 = @floatCast(angle * std.math.pi / 180.0);
    const cos_a = @cos(rad);
    const sin_a = @sin(rad);

    // Translate rotation center to screen space
    const screen_cx = dx + cx;
    const screen_cy = dy + cy;

    var rotated: [4][2]f32 = undefined;
    for (corners, 0..) |corner, ci| {
        rotated[ci] = .{
            corner[0] * cos_a - corner[1] * sin_a + screen_cx,
            corner[0] * sin_a + corner[1] * cos_a + screen_cy,
        };
    }

    // Check if batch is full
    if (g.sprite_vertex_count + 6 > MAX_SPRITE_VERTICES) {
        // This shouldn't happen with 64K vertices. Log and skip.
        std.debug.print("Warning: sprite vertex buffer full, skipping draw\n", .{});
        return;
    }

    // Emit two triangles (0,1,2) (0,2,3)
    const idx = g.sprite_vertex_count;
    const tri_indices = [6]usize{ 0, 1, 2, 0, 2, 3 };
    for (tri_indices, 0..) |vi, ti| {
        g.sprite_vertices[idx + ti] = .{
            .x = rotated[vi][0],
            .y = rotated[vi][1],
            .u = uvs[vi][0],
            .v = uvs[vi][1],
            .color = vc,
        };
    }
    g.sprite_vertex_count += 6;
}

// ============================================================
// Drawing - lines and filled rects
// ============================================================

pub fn renderDrawLine(x1: i32, y1: i32, x2: i32, y2: i32) !void {
    const g = getGpu();
    ensureColorPipeline(g, .colored_lines);

    if (g.color_vertex_count + 2 > MAX_COLOR_VERTICES) {
        std.debug.print("Warning: color vertex buffer full, skipping draw\n", .{});
        return;
    }

    const dc = g.draw_color;
    const vc = PackedColor{ .r = dc.r, .g = dc.g, .b = dc.b, .a = dc.a };

    const idx = g.color_vertex_count;
    g.color_vertices[idx] = .{
        .x = @floatFromInt(x1),
        .y = @floatFromInt(y1),
        .color = vc,
    };
    g.color_vertices[idx + 1] = .{
        .x = @floatFromInt(x2),
        .y = @floatFromInt(y2),
        .color = vc,
    };
    g.color_vertex_count += 2;
}

pub fn renderFillRect(rect: sdl.Rect) !void {
    const g = getGpu();
    ensureColorPipeline(g, .colored_triangles);

    if (g.color_vertex_count + 6 > MAX_COLOR_VERTICES) {
        std.debug.print("Warning: color vertex buffer full, skipping draw\n", .{});
        return;
    }

    const dc = g.draw_color;
    const vc = PackedColor{ .r = dc.r, .g = dc.g, .b = dc.b, .a = dc.a };

    const x0: f32 = @floatFromInt(rect.x);
    const y0: f32 = @floatFromInt(rect.y);
    const x1_pos: f32 = x0 + @as(f32, @floatFromInt(rect.w));
    const y1_pos: f32 = y0 + @as(f32, @floatFromInt(rect.h));

    const idx = g.color_vertex_count;
    // Triangle 1: top-left, top-right, bottom-right
    g.color_vertices[idx + 0] = .{ .x = x0, .y = y0, .color = vc };
    g.color_vertices[idx + 1] = .{ .x = x1_pos, .y = y0, .color = vc };
    g.color_vertices[idx + 2] = .{ .x = x1_pos, .y = y1_pos, .color = vc };
    // Triangle 2: top-left, bottom-right, bottom-left
    g.color_vertices[idx + 3] = .{ .x = x0, .y = y0, .color = vc };
    g.color_vertices[idx + 4] = .{ .x = x1_pos, .y = y1_pos, .color = vc };
    g.color_vertices[idx + 5] = .{ .x = x0, .y = y1_pos, .color = vc };
    g.color_vertex_count += 6;
}

pub fn renderDrawRect(rect: sdl.Rect) !void {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    try renderDrawLine(x0, y0, x1, y0);
    try renderDrawLine(x1, y0, x1, y1);
    try renderDrawLine(x1, y1, x0, y1);
    try renderDrawLine(x0, y1, x0, y0);
}

// ============================================================
// Viewport
// ============================================================

pub fn renderSetViewport(rect: ?*const sdl.Rect) !void {
    const g = getGpu();

    // Finalize current batch before viewport change
    finalizeBatch(g);

    if (rect) |r| {
        g.viewport_x = @floatFromInt(r.x);
        g.viewport_y = @floatFromInt(r.y);
        g.viewport_w = @floatFromInt(r.w);
        g.viewport_h = @floatFromInt(r.h);
    } else {
        // Reset to full window
        var sw_w: c_int = 0;
        var sw_h: c_int = 0;
        _ = c.SDL_GetWindowSize(g.window, &sw_w, &sw_h);
        g.viewport_x = 0;
        g.viewport_y = 0;
        g.viewport_w = @floatFromInt(sw_w);
        g.viewport_h = @floatFromInt(sw_h);
    }

    // Record viewport change as a batch record
    if (g.batch_count < MAX_BATCH_RECORDS) {
        g.batch_records[g.batch_count] = .{ .set_viewport = .{
            .x = g.viewport_x,
            .y = g.viewport_y,
            .w = g.viewport_w,
            .h = g.viewport_h,
        } };
        g.batch_count += 1;
    }
}
