const sdl = @import("zsdl");

pub const TimerCallback = *const fn (
    interval: u32,
    param: ?*anyopaque,
) callconv(.c) u32;

pub const addTimer = SDL_AddTimer;
extern fn SDL_AddTimer(interval: u32, callback: TimerCallback, param: ?*anyopaque) i32;

pub const removeTimer = SDL_RemoveTimer;
extern fn SDL_RemoveTimer(id: i32) c_int;
