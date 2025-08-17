const std = @import("std");
const shared = @import("shared.zig");

const c = @cImport({
    @cInclude("miniaudio.h");
});

const AudioError = error{
    FailedToInitialize,
};

// keep these alive while the sound plays
var engine: c.ma_engine = undefined;
var decoder: c.ma_decoder = undefined;
var sound: c.ma_sound = undefined;

pub fn init() !void {
    // 1) Init engine
    if (c.ma_engine_init(null, &engine) != c.MA_SUCCESS)
        return error.FailedToInitialize;

    // 2) Load file bytes yourself (rules out cwd/path issues)
    const bytes = try std.fs.cwd().readFileAlloc(std.heap.c_allocator,
        "sounds/cannonfire.mp3", std.math.maxInt(usize));
    // NOTE: free later, _after_ you uninit the decoder+sound
    // because decoder reads from this buffer.

    // 3) Init a decoder from memory (needs -DMA_ENABLE_MP3 in build)
    if (c.ma_decoder_init_memory(bytes.ptr, bytes.len, null, &decoder) != c.MA_SUCCESS)
        return error.DecoderInitFailed;

    // 4) Use the decoder as a data source for a sound
    // ma_decoder is-a ma_data_source, so cast its address:
    const ds: *c.ma_data_source = @ptrCast(&decoder);
    if (c.ma_sound_init_from_data_source(&engine, ds, 0, null, &sound) != c.MA_SUCCESS)
        return error.SoundInitFailed;

    // 5) Start playback (async)
    _ = c.ma_sound_start(&sound);
}

pub fn cleanup() void {
    // Stop and uninit in reverse order
    c.ma_sound_uninit(&sound);
    _ = c.ma_decoder_uninit(&decoder);
    c.ma_engine_uninit(&engine);
    // If you used readFileAlloc above, free the bytes here as well.
}
