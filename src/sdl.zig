// SDL3 bindings - thin Zig wrapper over SDL3 C API
// GPU-accelerated batch renderer using SDL_GPU
const std = @import("std");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

// ============================================================
// Types
// ============================================================

pub const Window = c.SDL_Window;
pub const Surface = c.SDL_Surface;
pub const Event = c.SDL_Event;
pub const Gamepad = c.SDL_Gamepad;
pub const Font = c.TTF_Font;

/// Opaque GPU device handle - game code passes this around as "renderer"
pub const Renderer = GpuState;

const ATLAS_SIZE: u32 = 8192;

// Skyline bottom-left bin packer.
// Tracks the top edge (skyline) of placed rectangles as a list of (x, y, width) segments.
// For each allocation, finds the position that results in the lowest Y placement.
const MAX_SKYLINE_NODES = 4096;

const SkylineNode = struct {
    x: u32,
    y: u32,
    width: u32,
};

const Atlas = struct {
    gpu_texture: *c.SDL_GPUTexture,
    width: u32 = ATLAS_SIZE,
    height: u32 = ATLAS_SIZE,
    nodes: [MAX_SKYLINE_NODES]SkylineNode = undefined,
    node_count: u32 = 0,

    fn init(self: *Atlas) void {
        self.nodes[0] = .{ .x = 0, .y = 0, .width = self.width };
        self.node_count = 1;
    }

    /// Check if a rectangle of (w x h) fits when placed starting at skyline node `index`.
    /// Returns the Y coordinate at which it would sit (max Y across spanned nodes), or null if it doesn't fit.
    fn rectangleFits(self: *const Atlas, index: u32, w: u32, h: u32) ?u32 {
        const x = self.nodes[index].x;
        if (x + w > self.width) return null;

        var width_left: i64 = @intCast(w);
        var i = index;
        var y: u32 = self.nodes[index].y;

        while (width_left > 0) {
            if (i >= self.node_count) return null;
            y = @max(y, self.nodes[i].y);
            if (y + h > self.height) return null;
            width_left -= @as(i64, @intCast(self.nodes[i].width));
            i += 1;
        }
        return y;
    }

    fn allocate(self: *Atlas, w: u32, h: u32) !struct { x: u32, y: u32 } {
        // Find best position (bottom-left heuristic: lowest Y, then leftmost X)
        var best_y: u32 = std.math.maxInt(u32);
        var best_x: u32 = std.math.maxInt(u32);
        var best_idx: ?u32 = null;

        for (0..self.node_count) |i| {
            if (self.rectangleFits(@intCast(i), w, h)) |y| {
                const x = self.nodes[i].x;
                if (y < best_y or (y == best_y and x < best_x)) {
                    best_y = y;
                    best_x = x;
                    best_idx = @intCast(i);
                }
            }
        }

        const idx = best_idx orelse return error.AtlasFull;
        self.addSkylineLevel(idx, best_x, best_y + h, w);
        return .{ .x = best_x, .y = best_y };
    }

    /// Insert a new skyline node and trim/remove nodes it covers.
    fn addSkylineLevel(self: *Atlas, index: u32, x: u32, y: u32, w: u32) void {
        if (self.node_count >= MAX_SKYLINE_NODES) return;

        // Shift nodes right to make room at `index`
        var j: u32 = self.node_count;
        while (j > index) : (j -= 1) {
            self.nodes[j] = self.nodes[j - 1];
        }
        self.nodes[index] = .{ .x = x, .y = y, .width = w };
        self.node_count += 1;

        // Shrink or remove subsequent nodes that overlap with the new node
        self.trimOverlapping(index);

        self.mergeSkylines();
    }

    fn trimOverlapping(self: *Atlas, index: u32) void {
        const check_from = index + 1;
        while (check_from < self.node_count) {
            const prev_end = self.nodes[check_from - 1].x + self.nodes[check_from - 1].width;
            if (self.nodes[check_from].x < prev_end) {
                const shrink = prev_end - self.nodes[check_from].x;
                if (shrink >= self.nodes[check_from].width) {
                    self.removeNode(check_from);
                } else {
                    self.nodes[check_from].x += shrink;
                    self.nodes[check_from].width -= shrink;
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn removeNode(self: *Atlas, index: u32) void {
        var k = index;
        while (k + 1 < self.node_count) : (k += 1) {
            self.nodes[k] = self.nodes[k + 1];
        }
        self.node_count -= 1;
    }

    /// Merge adjacent nodes at the same Y level.
    fn mergeSkylines(self: *Atlas) void {
        var i: u32 = 0;
        while (i + 1 < self.node_count) {
            if (self.nodes[i].y == self.nodes[i + 1].y) {
                self.nodes[i].width += self.nodes[i + 1].width;
                self.removeNode(i + 1);
                // don't increment — check merged node against next
            } else {
                i += 1;
            }
        }
    }
};

/// Texture wrapper - stores atlas region or standalone GPU texture + metadata
pub const Texture = struct {
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: i32,
    height: i32,
    is_atlas: bool = true,
    standalone_gpu_texture: ?*c.SDL_GPUTexture = null,
    color_mod: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    blend_mode: BlendMode = .blend,

    pub fn gpuTexture(self: *const Texture) *c.SDL_GPUTexture {
        if (self.is_atlas) {
            return getGpu().atlas.gpu_texture;
        }
        return self.standalone_gpu_texture.?;
    }
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const FRect = c.SDL_FRect;

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

pub const Scancode = enum(c_int) {
    a = c.SDL_SCANCODE_A,
    b = c.SDL_SCANCODE_B,
    c_ = c.SDL_SCANCODE_C,
    d = c.SDL_SCANCODE_D,
    e = c.SDL_SCANCODE_E,
    f = c.SDL_SCANCODE_F,
    g = c.SDL_SCANCODE_G,
    h = c.SDL_SCANCODE_H,
    i = c.SDL_SCANCODE_I,
    j = c.SDL_SCANCODE_J,
    k = c.SDL_SCANCODE_K,
    l = c.SDL_SCANCODE_L,
    m = c.SDL_SCANCODE_M,
    n = c.SDL_SCANCODE_N,
    o = c.SDL_SCANCODE_O,
    p = c.SDL_SCANCODE_P,
    q = c.SDL_SCANCODE_Q,
    r = c.SDL_SCANCODE_R,
    s = c.SDL_SCANCODE_S,
    t = c.SDL_SCANCODE_T,
    u = c.SDL_SCANCODE_U,
    v = c.SDL_SCANCODE_V,
    w = c.SDL_SCANCODE_W,
    x = c.SDL_SCANCODE_X,
    y = c.SDL_SCANCODE_Y,
    z = c.SDL_SCANCODE_Z,
    grave = c.SDL_SCANCODE_GRAVE,
    nonusbackslash = c.SDL_SCANCODE_NONUSBACKSLASH,
    up = c.SDL_SCANCODE_UP,
    down = c.SDL_SCANCODE_DOWN,
    left = c.SDL_SCANCODE_LEFT,
    right = c.SDL_SCANCODE_RIGHT,
    lshift = c.SDL_SCANCODE_LSHIFT,
    rshift = c.SDL_SCANCODE_RSHIFT,
    lctrl = c.SDL_SCANCODE_LCTRL,
    escape = c.SDL_SCANCODE_ESCAPE,
};

pub const GamepadAxis = enum(c_int) {
    leftx = c.SDL_GAMEPAD_AXIS_LEFTX,
    lefty = c.SDL_GAMEPAD_AXIS_LEFTY,
    rightx = c.SDL_GAMEPAD_AXIS_RIGHTX,
    righty = c.SDL_GAMEPAD_AXIS_RIGHTY,
    triggerleft = c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
    triggerright = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
};

pub const GamepadButton = enum(c_int) {
    a = c.SDL_GAMEPAD_BUTTON_SOUTH,
    b = c.SDL_GAMEPAD_BUTTON_EAST,
    x = c.SDL_GAMEPAD_BUTTON_WEST,
    y = c.SDL_GAMEPAD_BUTTON_NORTH,
    leftshoulder = c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
    rightshoulder = c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    dpad_left = c.SDL_GAMEPAD_BUTTON_DPAD_LEFT,
    dpad_right = c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
    dpad_up = c.SDL_GAMEPAD_BUTTON_DPAD_UP,
    dpad_down = c.SDL_GAMEPAD_BUTTON_DPAD_DOWN,
};

pub const EventType = struct {
    pub const quit = c.SDL_EVENT_QUIT;
    pub const window_resized = c.SDL_EVENT_WINDOW_RESIZED;
    pub const gamepad_added = c.SDL_EVENT_GAMEPAD_ADDED;
    pub const gamepad_removed = c.SDL_EVENT_GAMEPAD_REMOVED;
};

pub const FlipMode = enum(c_uint) {
    none = c.SDL_FLIP_NONE,
    horizontal = c.SDL_FLIP_HORIZONTAL,
    vertical = c.SDL_FLIP_VERTICAL,
};

pub const BlendMode = enum(c_uint) {
    none = c.SDL_BLENDMODE_NONE,
    blend = c.SDL_BLENDMODE_BLEND,
    add = c.SDL_BLENDMODE_ADD,
};

pub const PixelFormat = enum(c_uint) {
    rgba8888 = c.SDL_PIXELFORMAT_RGBA8888,
    bgra8888 = c.SDL_PIXELFORMAT_BGRA8888,
    argb8888 = c.SDL_PIXELFORMAT_ARGB8888,
    abgr8888 = c.SDL_PIXELFORMAT_ABGR8888,
};

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

// ============================================================
// GPU Batch Renderer State (deferred rendering)
// ============================================================

const MAX_SPRITE_VERTICES = 64 * 1024; // 64K vertices = ~10K sprites
const MAX_COLOR_VERTICES = 16 * 1024;
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
};

const GpuState = struct {
    device: *c.SDL_GPUDevice,
    window: *Window,

    // Texture atlas
    atlas: Atlas,

    // Pipelines
    sprite_alpha_pipeline: *c.SDL_GPUGraphicsPipeline,
    sprite_additive_pipeline: *c.SDL_GPUGraphicsPipeline,
    colored_triangles_pipeline: *c.SDL_GPUGraphicsPipeline,
    colored_lines_pipeline: *c.SDL_GPUGraphicsPipeline,

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
    draw_color: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    clear_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    draw_blend_mode: BlendMode = .blend,
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
};

var gpu: ?*GpuState = null;

fn getGpu() *GpuState {
    return gpu.?;
}

// ============================================================
// Init / Quit
// ============================================================

pub fn init(flags: struct {
    video: bool = false,
    audio: bool = false,
    gamepad: bool = false,
}) !void {
    var sdl_flags: c.SDL_InitFlags = 0;
    if (flags.video) sdl_flags |= c.SDL_INIT_VIDEO;
    if (flags.audio) sdl_flags |= c.SDL_INIT_AUDIO;
    if (flags.gamepad) sdl_flags |= c.SDL_INIT_GAMEPAD;
    if (!c.SDL_Init(sdl_flags)) return error.SDLInitFailed;
}

pub fn quit() void {
    c.SDL_Quit();
}

// ============================================================
// Window
// ============================================================

pub fn createWindow(title: [*:0]const u8, width: i32, height: i32, flags: struct {
    opengl: bool = false,
    resizable: bool = false,
}) !*Window {
    var sdl_flags: c.SDL_WindowFlags = 0;
    if (flags.opengl) sdl_flags |= c.SDL_WINDOW_OPENGL;
    if (flags.resizable) sdl_flags |= c.SDL_WINDOW_RESIZABLE;
    return c.SDL_CreateWindow(title, width, height, sdl_flags) orelse return error.CreateWindowFailed;
}

pub fn destroyWindow(window: *Window) void {
    c.SDL_DestroyWindow(window);
}

pub fn getDisplays() ![]c.SDL_DisplayID {
    var count: c_int = 0;
    const displays = c.SDL_GetDisplays(&count) orelse return error.GetDisplaysFailed;
    return displays[0..@intCast(count)];
}

pub fn getDisplayBounds(displayId: c.SDL_DisplayID) !Rect {
    var rect: c.SDL_Rect = undefined;
    if (!c.SDL_GetDisplayBounds(displayId, &rect)) return error.GetDisplayBoundsFailed;
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

pub fn setWindowPosition(window: *Window, x: i32, y: i32) !void {
    if (!c.SDL_SetWindowPosition(window, x, y)) return error.SetWindowPositionFailed;
}

// ============================================================
// Shader loading helpers
// ============================================================

const sprite_vert_msl = @embedFile("shaders/sprite.metal");
const sprite_frag_msl = @embedFile("shaders/sprite.metal");
const colored_vert_msl = @embedFile("shaders/colored.metal");
const colored_frag_msl = @embedFile("shaders/colored.metal");

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

fn createSpritePipeline(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    blend_state: c.SDL_GPUColorTargetBlendState,
) !*c.SDL_GPUGraphicsPipeline {
    const vert_shader = try createShader(
        device,
        sprite_vert_msl.ptr,
        sprite_vert_msl.len,
        "sprite_vert",
        c.SDL_GPU_SHADERSTAGE_VERTEX,
        0,
        1,
    );
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = try createShader(
        device,
        sprite_frag_msl.ptr,
        sprite_frag_msl.len,
        "sprite_frag",
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        1,
        0,
    );
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const vertex_buffer_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{
            .slot = 0,
            .pitch = @sizeOf(SpriteVertex),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
    };

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(SpriteVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(SpriteVertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(SpriteVertex, "color") },
    };

    const color_target = [_]c.SDL_GPUColorTargetDescription{
        .{
            .format = swapchain_format,
            .blend_state = blend_state,
        },
    };

    const pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = vertex_buffer_desc.len,
            .vertex_attributes = &vertex_attrs,
            .num_vertex_attributes = vertex_attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
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

fn createColoredPipeline(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    primitive_type: c.SDL_GPUPrimitiveType,
    blend_state: c.SDL_GPUColorTargetBlendState,
) !*c.SDL_GPUGraphicsPipeline {
    const vert_shader = try createShader(
        device,
        colored_vert_msl.ptr,
        colored_vert_msl.len,
        "colored_vert",
        c.SDL_GPU_SHADERSTAGE_VERTEX,
        0,
        1,
    );
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = try createShader(
        device,
        colored_frag_msl.ptr,
        colored_frag_msl.len,
        "colored_frag",
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        0,
        0,
    );
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const vertex_buffer_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{
            .slot = 0,
            .pitch = @sizeOf(ColorVertex),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
    };

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(ColorVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(ColorVertex, "color") },
    };

    const color_target = [_]c.SDL_GPUColorTargetDescription{
        .{
            .format = swapchain_format,
            .blend_state = blend_state,
        },
    };

    const pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = vertex_buffer_desc.len,
            .vertex_attributes = &vertex_attrs,
            .num_vertex_attributes = vertex_attrs.len,
        },
        .primitive_type = primitive_type,
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

// ============================================================
// Renderer (GPU Device)
// ============================================================

var gpu_state_storage: GpuState = undefined;
var mem_allocator: std.mem.Allocator = undefined;

pub fn createRenderer(window: *Window) !*Renderer {
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
    const sprite_alpha = try createSpritePipeline(device, swapchain_format, alpha_blend);
    const sprite_additive = try createSpritePipeline(device, swapchain_format, additive_blend);
    const colored_triangles = try createColoredPipeline(device, swapchain_format, c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST, alpha_blend);
    const colored_lines = try createColoredPipeline(device, swapchain_format, c.SDL_GPU_PRIMITIVETYPE_LINELIST, alpha_blend);

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

    // Create atlas GPU texture
    const atlas_tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = ATLAS_SIZE,
        .height = ATLAS_SIZE,
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
            var a = Atlas{ .gpu_texture = atlas_gpu_texture };
            a.init();
            break :blk a;
        },
        .sprite_alpha_pipeline = sprite_alpha,
        .sprite_additive_pipeline = sprite_additive,
        .colored_triangles_pipeline = colored_triangles,
        .colored_lines_pipeline = colored_lines,
        .sampler = gpu_sampler,
        .sprite_gpu_buffer = sprite_vb,
        .color_gpu_buffer = color_vb,
        .sprite_transfer_buffer = sprite_tb,
        .color_transfer_buffer = color_tb,
        .swapchain_format = swapchain_format,
    };

    gpu = &gpu_state_storage;
    return &gpu_state_storage;
}

pub fn destroyRenderer(renderer: *Renderer) void {
    _ = renderer;
    if (gpu) |g| {
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

pub fn setRenderDrawColor(renderer: *Renderer, color: Color) !void {
    _ = renderer;
    const g = getGpu();
    g.draw_color = color;
}

pub fn setRenderDrawBlendMode(renderer: *Renderer, mode: BlendMode) !void {
    _ = renderer;
    const g = getGpu();
    g.draw_blend_mode = mode;
}

pub fn getRenderDrawBlendMode(renderer: *Renderer) !BlendMode {
    _ = renderer;
    const g = getGpu();
    return g.draw_blend_mode;
}

// ============================================================
// Texture management
// ============================================================

/// Add a surface to the texture atlas. Returns an atlas-backed Texture.
pub fn addToAtlas(renderer: *Renderer, surface: *Surface) !*Texture {
    _ = renderer;
    const g = getGpu();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);

    const region = try g.atlas.allocate(w, h);

    const texture = try mem_allocator.create(Texture);
    texture.* = .{
        .atlas_x = region.x,
        .atlas_y = region.y,
        .width = @intCast(w),
        .height = @intCast(h),
        .is_atlas = true,
    };

    uploadToAtlasRegion(g, rgba_surface, region.x, region.y, w, h);
    return texture;
}

/// Create a standalone GPU texture (not in atlas). Used for ephemeral textures like text.
pub fn createStandaloneTexture(renderer: *Renderer, surface: *Surface) !*Texture {
    _ = renderer;
    const g = getGpu();

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
    const gpu_texture = c.SDL_CreateGPUTexture(g.device, &tex_info) orelse return error.CreateGPUTextureFailed;

    const texture = try mem_allocator.create(Texture);
    texture.* = .{
        .width = @intCast(w),
        .height = @intCast(h),
        .is_atlas = false,
        .standalone_gpu_texture = gpu_texture,
    };

    uploadTextureImmediate(g, gpu_texture, rgba_surface);
    return texture;
}

/// Upload surface pixel data to a sub-region of the atlas texture.
fn uploadToAtlasRegion(g: *GpuState, rgba_surface: *Surface, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
    const pitch: u32 = @intCast(rgba_surface.*.pitch);
    const data_size: u32 = pitch * h;

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    };
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(g.device, &transfer_info) orelse return;

    const mapped = c.SDL_MapGPUTransferBuffer(g.device, transfer_buf, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    };
    const pixels: [*]const u8 = @ptrCast(rgba_surface.*.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    });
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], pixels[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(g.device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    };

    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = pitch / 4,
        .rows_per_layer = h,
    };
    const dst_region = c.SDL_GPUTextureRegion{
        .texture = g.atlas.gpu_texture,
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
        _ = c.SDL_WaitForGPUFences(g.device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(g.device, f);
    }
    c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
}

/// Upload surface pixel data to a standalone GPU texture (full replacement).
fn uploadTextureImmediate(g: *GpuState, gpu_texture: *c.SDL_GPUTexture, rgba_surface: *Surface) void {
    const w: u32 = @intCast(rgba_surface.*.w);
    const h: u32 = @intCast(rgba_surface.*.h);
    const pitch: u32 = @intCast(rgba_surface.*.pitch);
    const data_size: u32 = pitch * h;

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    };
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(g.device, &transfer_info) orelse return;

    const mapped = c.SDL_MapGPUTransferBuffer(g.device, transfer_buf, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    };
    const pixels: [*]const u8 = @ptrCast(rgba_surface.*.pixels orelse {
        c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    });
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data_size], pixels[0..data_size]);
    c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);

    const cmd = c.SDL_AcquireGPUCommandBuffer(g.device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
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
        _ = c.SDL_WaitForGPUFences(g.device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(g.device, f);
    }
    c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);
}

pub fn destroyTexture(texture: *Texture) void {
    if (!texture.is_atlas) {
        // Standalone texture: release GPU texture
        if (texture.standalone_gpu_texture) |gpu_tex| {
            if (gpu) |g| {
                if (g.pending_destroy_count < MAX_PENDING_DESTROYS) {
                    g.pending_destroys[g.pending_destroy_count] = gpu_tex;
                    g.pending_destroy_count += 1;
                } else {
                    c.SDL_ReleaseGPUTexture(g.device, gpu_tex);
                }
            }
        }
    }
    // Atlas textures: just free the wrapper, atlas region is leaked (reclaimed on level reload)
    mem_allocator.destroy(texture);
}

/// Create a new Texture wrapper that shares the same atlas region.
pub fn cloneTexture(source: *Texture) !*Texture {
    const texture = try mem_allocator.create(Texture);
    texture.* = .{
        .atlas_x = source.atlas_x,
        .atlas_y = source.atlas_y,
        .width = source.width,
        .height = source.height,
        .is_atlas = source.is_atlas,
        .standalone_gpu_texture = source.standalone_gpu_texture,
        .color_mod = source.color_mod,
        .blend_mode = source.blend_mode,
    };
    return texture;
}

/// Allocate a new private atlas region for a texture and upload surface data there.
/// Used for copy-on-write when a texture shares its atlas region with the cache.
pub fn reallocateAtlasRegion(texture: *Texture, surface: *Surface) !void {
    const g = getGpu();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    const w: u32 = @intCast(texture.width);
    const h: u32 = @intCast(texture.height);

    const region = try g.atlas.allocate(w, h);
    texture.atlas_x = region.x;
    texture.atlas_y = region.y;

    uploadToAtlasRegion(g, rgba_surface, region.x, region.y, w, h);
}

/// Reset atlas packer state (call on level reload to reclaim all atlas space).
pub fn resetAtlas() void {
    const g = getGpu();
    g.atlas.init();
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

pub fn setTextureBlendMode(texture: *Texture, mode: BlendMode) !void {
    texture.blend_mode = mode;
}

/// Re-upload a texture from its associated surface (for terrain destruction, blood stains).
/// For atlas textures, uploads to the atlas sub-region. For standalone, uploads to the GPU texture.
pub fn reuploadTexture(texture: *Texture, surface: *Surface) !void {
    const g = getGpu();

    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888);
    if (rgba_surface == null) return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgba_surface);

    if (texture.is_atlas) {
        uploadToAtlasRegion(g, rgba_surface, texture.atlas_x, texture.atlas_y, @intCast(texture.width), @intCast(texture.height));
    } else {
        uploadTextureImmediate(g, texture.standalone_gpu_texture.?, rgba_surface);
    }
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

pub fn renderClear(renderer: *Renderer) !void {
    _ = renderer;
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

pub fn renderPresent(renderer: *Renderer) void {
    _ = renderer;
    const g = getGpu();

    // Finalize any pending batch
    finalizeBatch(g);

    const cmd = g.cmd_buf orelse return;
    const swapchain_tex = g.swapchain_texture orelse return;

    // Upload vertex data via copy pass using pre-allocated transfer buffers
    if (g.sprite_vertex_count > 0 or g.color_vertex_count > 0) {
        // Map and fill transfer buffers before starting copy pass
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

    // Begin render pass with clear
    const cc = g.clear_color;
    const color_target = c.SDL_GPUColorTargetInfo{
        .texture = swapchain_tex,
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
    if (render_pass == null) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        g.cmd_buf = null;
        g.swapchain_texture = null;
        return;
    }
    const rp = render_pass.?;

    // Set initial viewport to full window (use saved swapchain dimensions)
    setGpuViewport(rp, 0, 0, g.swapchain_w, g.swapchain_h);

    // Replay all batch records (track last-bound state to skip redundant GPU calls)
    var current_vp_w: f32 = g.swapchain_w;
    var current_vp_h: f32 = g.swapchain_h;
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
            .draw_sprites => |batch| {
                // Only rebind pipeline if changed
                if (last_pipeline != batch.pipeline) {
                    const pipeline = switch (batch.pipeline) {
                        .sprite_alpha => g.sprite_alpha_pipeline,
                        .sprite_additive => g.sprite_additive_pipeline,
                        else => g.sprite_alpha_pipeline,
                    };
                    c.SDL_BindGPUGraphicsPipeline(rp, pipeline);
                    last_pipeline = batch.pipeline;
                    uniforms_dirty = true; // pipeline bind resets uniform state
                }

                if (uniforms_dirty) {
                    const uniforms = ViewportUniforms{ .viewport_size = .{ current_vp_w, current_vp_h } };
                    c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(ViewportUniforms));
                    uniforms_dirty = false;
                }

                const binding = c.SDL_GPUBufferBinding{
                    .buffer = g.sprite_gpu_buffer,
                    .offset = batch.vertex_offset * @sizeOf(SpriteVertex),
                };
                c.SDL_BindGPUVertexBuffers(rp, 0, &binding, 1);

                // Only rebind texture if changed
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
            .draw_colored => |batch| {
                if (last_pipeline != batch.pipeline) {
                    const pipeline = switch (batch.pipeline) {
                        .colored_triangles => g.colored_triangles_pipeline,
                        .colored_lines => g.colored_lines_pipeline,
                        else => g.colored_triangles_pipeline,
                    };
                    c.SDL_BindGPUGraphicsPipeline(rp, pipeline);
                    last_pipeline = batch.pipeline;
                    last_texture = null; // switching to colored pipeline invalidates texture state
                    uniforms_dirty = true;
                }

                if (uniforms_dirty) {
                    const uniforms = ViewportUniforms{ .viewport_size = .{ current_vp_w, current_vp_h } };
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

    // End render pass and submit
    c.SDL_EndGPURenderPass(rp);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);

    // Release deferred texture destroys (now safe - command buffer submitted)
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

pub fn renderCopy(renderer: *Renderer, texture: *Texture, src_rect: ?*const Rect, dst_rect: ?*const Rect) !void {
    try renderCopyEx(renderer, texture, src_rect, dst_rect, 0, null, .none);
}

pub fn renderCopyEx(
    renderer: *Renderer,
    texture: *Texture,
    src_rect: ?*const Rect,
    dst_rect: ?*const Rect,
    angle: f64,
    center: ?*const Point,
    flip: FlipMode,
) !void {
    _ = renderer;
    const g = getGpu();

    // Determine pipeline based on texture blend mode
    const pipeline_type: PipelineType = switch (texture.blend_mode) {
        .add => .sprite_additive,
        else => .sprite_alpha,
    };
    ensureSpritePipeline(g, pipeline_type, texture.gpuTexture());

    // Source UV coords - atlas vs standalone
    var uv_left: f32 = undefined;
    var uv_top: f32 = undefined;
    var uv_right: f32 = undefined;
    var uv_bottom: f32 = undefined;
    if (texture.is_atlas) {
        const atlas_size: f32 = @floatFromInt(ATLAS_SIZE);
        const ax: f32 = @floatFromInt(texture.atlas_x);
        const ay: f32 = @floatFromInt(texture.atlas_y);
        if (src_rect) |sr| {
            uv_left = (ax + @as(f32, @floatFromInt(sr.x))) / atlas_size;
            uv_top = (ay + @as(f32, @floatFromInt(sr.y))) / atlas_size;
            uv_right = (ax + @as(f32, @floatFromInt(sr.x + sr.w))) / atlas_size;
            uv_bottom = (ay + @as(f32, @floatFromInt(sr.y + sr.h))) / atlas_size;
        } else {
            uv_left = ax / atlas_size;
            uv_top = ay / atlas_size;
            uv_right = (ax + @as(f32, @floatFromInt(texture.width))) / atlas_size;
            uv_bottom = (ay + @as(f32, @floatFromInt(texture.height))) / atlas_size;
        }
    } else {
        // Standalone texture: UVs relative to texture size (0..1)
        uv_left = 0;
        uv_top = 0;
        uv_right = 1;
        uv_bottom = 1;
        if (src_rect) |sr| {
            const tw: f32 = @floatFromInt(texture.width);
            const th: f32 = @floatFromInt(texture.height);
            uv_left = @as(f32, @floatFromInt(sr.x)) / tw;
            uv_top = @as(f32, @floatFromInt(sr.y)) / th;
            uv_right = @as(f32, @floatFromInt(sr.x + sr.w)) / tw;
            uv_bottom = @as(f32, @floatFromInt(sr.y + sr.h)) / th;
        }
    }

    // Destination rect
    var dx: f32 = 0;
    var dy: f32 = 0;
    var dw: f32 = @floatFromInt(texture.width);
    var dh: f32 = @floatFromInt(texture.height);
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
    const cm = texture.color_mod;
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

pub fn renderDrawLine(renderer: *Renderer, x1: i32, y1: i32, x2: i32, y2: i32) !void {
    _ = renderer;
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

pub fn renderFillRect(renderer: *Renderer, rect: Rect) !void {
    _ = renderer;
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

// ============================================================
// Viewport
// ============================================================

pub fn renderSetViewport(renderer: *Renderer, rect: ?*const Rect) !void {
    _ = renderer;
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

// ============================================================
// Surface
// ============================================================

pub fn createSurface(width: i32, height: i32, format: PixelFormat) !*Surface {
    return c.SDL_CreateSurface(width, height, @intFromEnum(format)) orelse return error.CreateSurfaceFailed;
}

pub fn destroySurface(surface: *Surface) void {
    c.SDL_DestroySurface(surface);
}

pub fn blitSurface(src: *Surface, src_rect: ?*const Rect, dst_surface: *Surface, dst_rect: ?*const Rect) !void {
    const sr = if (src_rect) |r| &c.SDL_Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } else null;
    const dr = if (dst_rect) |r| &c.SDL_Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } else null;
    if (!c.SDL_BlitSurface(src, sr, dst_surface, dr)) return error.BlitSurfaceFailed;
}

pub fn lockSurface(surface: *Surface) !void {
    if (!c.SDL_LockSurface(surface)) return error.LockSurfaceFailed;
}

pub fn unlockSurface(surface: *Surface) void {
    c.SDL_UnlockSurface(surface);
}

// ============================================================
// Events
// ============================================================

pub fn pollEvent(event: *Event) bool {
    return c.SDL_PollEvent(event);
}

// ============================================================
// Keyboard
// ============================================================

pub fn getKeyboardState() []const bool {
    var numkeys: c_int = 0;
    const state = c.SDL_GetKeyboardState(&numkeys);
    return state[0..@intCast(numkeys)];
}

// ============================================================
// Mouse
// ============================================================

pub fn getMouseState(x: *i32, y: *i32) u32 {
    var fx: f32 = 0;
    var fy: f32 = 0;
    const buttons = c.SDL_GetMouseState(&fx, &fy);
    x.* = @intFromFloat(fx);
    y.* = @intFromFloat(fy);
    return buttons;
}

// ============================================================
// Gamepad
// ============================================================

pub fn openGamepad(instanceId: c.SDL_JoystickID) !*Gamepad {
    return c.SDL_OpenGamepad(instanceId) orelse return error.OpenGamepadFailed;
}

pub fn closeGamepad(gamepad_handle: *Gamepad) void {
    c.SDL_CloseGamepad(gamepad_handle);
}

pub fn getGamepadAxis(gamepad_handle: *Gamepad, axis: GamepadAxis) i16 {
    return c.SDL_GetGamepadAxis(gamepad_handle, @intFromEnum(axis));
}

pub fn getGamepadButton(gamepad_handle: *Gamepad, button: GamepadButton) bool {
    return c.SDL_GetGamepadButton(gamepad_handle, @intFromEnum(button));
}

// ============================================================
// Timer
// ============================================================

pub const TimerID = c.SDL_TimerID;

pub const TimerCallback = *const fn (
    userdata: ?*anyopaque,
    timerID: TimerID,
    interval: u32,
) callconv(.c) u32;

pub fn addTimer(interval: u32, callback: TimerCallback, userdata: ?*anyopaque) TimerID {
    return c.SDL_AddTimer(interval, callback, userdata);
}

pub fn removeTimer(id: TimerID) void {
    _ = c.SDL_RemoveTimer(id);
}

// ============================================================
// Performance Counter
// ============================================================

pub fn getPerformanceFrequency() u64 {
    return c.SDL_GetPerformanceFrequency();
}

pub fn getPerformanceCounter() u64 {
    return c.SDL_GetPerformanceCounter();
}

// ============================================================
// TTF
// ============================================================

pub const ttf = struct {
    pub fn init() !void {
        if (!c.TTF_Init()) return error.TTFInitFailed;
    }

    pub fn quit() void {
        c.TTF_Quit();
    }

    pub fn openFont(path: [*:0]const u8, size: f32) !*Font {
        return c.TTF_OpenFont(path, size) orelse return error.OpenFontFailed;
    }

    pub fn closeFont(font: *Font) void {
        c.TTF_CloseFont(font);
    }

    pub fn renderTextSolid(font: *Font, text: [*:0]const u8, color: Color) !*Surface {
        const sdl_color = c.SDL_Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        return c.TTF_RenderText_Solid(font, text, 0, sdl_color) orelse return error.RenderTextSolidFailed;
    }
};

// ============================================================
// Atlas debug dump
// ============================================================

pub fn saveAtlasToDisk(path: [*:0]const u8) void {
    const g = getGpu();

    const bpp: u32 = 4;
    const data_size: u32 = ATLAS_SIZE * ATLAS_SIZE * bpp;

    // Create download transfer buffer
    const transfer_buf = c.SDL_CreateGPUTransferBuffer(g.device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = data_size,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create download transfer buffer\n", .{});
        return;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(g.device, transfer_buf);

    // Download atlas texture via copy pass
    const cmd = c.SDL_AcquireGPUCommandBuffer(g.device) orelse {
        std.debug.print("Failed to acquire command buffer for atlas dump\n", .{});
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        std.debug.print("Failed to begin copy pass for atlas dump\n", .{});
        return;
    };

    const src_region = c.SDL_GPUTextureRegion{
        .texture = g.atlas.gpu_texture,
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
        _ = c.SDL_WaitForGPUFences(g.device, true, @ptrCast(&f), 1);
        c.SDL_ReleaseGPUFence(g.device, f);
    }

    // Map and create surface from downloaded data
    const mapped = c.SDL_MapGPUTransferBuffer(g.device, transfer_buf, false) orelse {
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
        c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);
        return;
    }

    if (c.IMG_SavePNG(surface, path)) {
        std.debug.print("Atlas saved to {s}\n", .{path});
    } else {
        std.debug.print("Failed to save atlas: {s}\n", .{c.SDL_GetError()});
    }

    c.SDL_DestroySurface(surface);
    c.SDL_UnmapGPUTransferBuffer(g.device, transfer_buf);
}

// ============================================================
// Image
// ============================================================

pub const image = struct {
    pub fn load(path: [*:0]const u8) !*Surface {
        return c.IMG_Load(path) orelse return error.IMGLoadFailed;
    }
};
