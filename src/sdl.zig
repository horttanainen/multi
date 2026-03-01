// SDL3 bindings - thin Zig wrapper over SDL3 C API
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
pub const Renderer = c.SDL_Renderer;
pub const Texture = c.SDL_Texture;
pub const Surface = c.SDL_Surface;
pub const Event = c.SDL_Event;
pub const Gamepad = c.SDL_Gamepad;
pub const Font = c.TTF_Font;

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
// Renderer
// ============================================================

pub fn createRenderer(window: *Window) !*Renderer {
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.CreateRendererFailed;
    // Enable vsync
    _ = c.SDL_SetRenderVSync(renderer, 1);
    return renderer;
}

pub fn destroyRenderer(renderer: *Renderer) void {
    c.SDL_DestroyRenderer(renderer);
}

pub fn setRenderDrawColor(renderer: *Renderer, color: Color) !void {
    if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)) return error.SetRenderDrawColorFailed;
}

pub fn renderClear(renderer: *Renderer) !void {
    if (!c.SDL_RenderClear(renderer)) return error.RenderClearFailed;
}

pub fn renderPresent(renderer: *Renderer) void {
    _ = c.SDL_RenderPresent(renderer);
}

pub fn renderCopy(renderer: *Renderer, texture: *Texture, src_rect: ?*const Rect, dst_rect: ?*const Rect) !void {
    const src = if (src_rect) |r| &toFRect(r.*) else null;
    const dst = if (dst_rect) |r| &toFRect(r.*) else null;
    if (!c.SDL_RenderTexture(renderer, texture, src, dst)) return error.RenderCopyFailed;
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
    const src = if (src_rect) |r| &toFRect(r.*) else null;
    const dst = if (dst_rect) |r| &toFRect(r.*) else null;
    const ctr = if (center) |p| &c.SDL_FPoint{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) } else null;
    if (!c.SDL_RenderTextureRotated(renderer, texture, src, dst, angle, ctr, @intFromEnum(flip))) return error.RenderCopyExFailed;
}

pub fn renderDrawLine(renderer: *Renderer, x1: i32, y1: i32, x2: i32, y2: i32) !void {
    if (!c.SDL_RenderLine(renderer, @floatFromInt(x1), @floatFromInt(y1), @floatFromInt(x2), @floatFromInt(y2))) return error.RenderDrawLineFailed;
}

pub fn renderFillRect(renderer: *Renderer, rect: Rect) !void {
    const frect = toFRect(rect);
    if (!c.SDL_RenderFillRect(renderer, &frect)) return error.RenderFillRectFailed;
}

pub fn renderSetViewport(renderer: *Renderer, rect: ?*const Rect) !void {
    const r = if (rect) |re| &c.SDL_Rect{ .x = re.x, .y = re.y, .w = re.w, .h = re.h } else null;
    if (!c.SDL_SetRenderViewport(renderer, r)) return error.SetRenderViewportFailed;
}

pub fn setRenderDrawBlendMode(renderer: *Renderer, mode: BlendMode) !void {
    if (!c.SDL_SetRenderDrawBlendMode(renderer, @intFromEnum(mode))) return error.SetRenderDrawBlendModeFailed;
}

pub fn getRenderDrawBlendMode(renderer: *Renderer) !BlendMode {
    var mode: c.SDL_BlendMode = undefined;
    if (!c.SDL_GetRenderDrawBlendMode(renderer, &mode)) return error.GetRenderDrawBlendModeFailed;
    return @enumFromInt(mode);
}

// ============================================================
// Texture
// ============================================================

pub fn createTextureFromSurface(renderer: *Renderer, surface: *Surface) !*Texture {
    return c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.CreateTextureFromSurfaceFailed;
}

pub fn destroyTexture(texture: *Texture) void {
    c.SDL_DestroyTexture(texture);
}

pub fn queryTexture(texture: *Texture, w: *i32, h: *i32) !void {
    var fw: f32 = 0;
    var fh: f32 = 0;
    if (!c.SDL_GetTextureSize(texture, &fw, &fh)) return error.QueryTextureFailed;
    w.* = @intFromFloat(fw);
    h.* = @intFromFloat(fh);
}

pub fn setTextureColorMod(texture: *Texture, r: u8, g: u8, b: u8) !void {
    if (!c.SDL_SetTextureColorMod(texture, r, g, b)) return error.SetTextureColorModFailed;
}

pub fn setTextureAlphaMod(texture: *Texture, a: u8) !void {
    if (!c.SDL_SetTextureAlphaMod(texture, a)) return error.SetTextureAlphaModFailed;
}

pub fn setTextureBlendMode(texture: *Texture, mode: BlendMode) !void {
    if (!c.SDL_SetTextureBlendMode(texture, @intFromEnum(mode))) return error.SetTextureBlendModeFailed;
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

pub fn blitSurface(src: *Surface, src_rect: ?*const Rect, dst: *Surface, dst_rect: ?*const Rect) !void {
    const sr = if (src_rect) |r| &c.SDL_Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } else null;
    const dr = if (dst_rect) |r| &c.SDL_Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } else null;
    if (!c.SDL_BlitSurface(src, sr, dst, dr)) return error.BlitSurfaceFailed;
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

pub fn closeGamepad(gamepad: *Gamepad) void {
    c.SDL_CloseGamepad(gamepad);
}

pub fn getGamepadAxis(gamepad: *Gamepad, axis: GamepadAxis) i16 {
    return c.SDL_GetGamepadAxis(gamepad, @intFromEnum(axis));
}

pub fn getGamepadButton(gamepad: *Gamepad, button: GamepadButton) bool {
    return c.SDL_GetGamepadButton(gamepad, @intFromEnum(button));
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
// Image
// ============================================================

pub const image = struct {
    pub fn load(path: [*:0]const u8) !*Surface {
        return c.IMG_Load(path) orelse return error.IMGLoadFailed;
    }
};

// ============================================================
// Helpers
// ============================================================

fn toFRect(rect: Rect) c.SDL_FRect {
    return .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
}
