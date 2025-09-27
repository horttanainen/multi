const std = @import("std");
const shared = @import("shared.zig");
const timer = @import("sdl_timer.zig");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("miniaudio.h");
});

pub const AudioError = error{
    FailedToInitialize,
    DecoderInitFailed,
    SoundInitFailed,
};

pub const Audio = struct {
    file: []const u8,
    durationMs: u32
};

var engine: c.ma_engine = undefined;

const SoundEntry = struct {
    sound: c.ma_sound,
    decoder: c.ma_decoder,
    data: []u8,
};

pub var activeSounds = std.AutoHashMap(usize, *SoundEntry).init(shared.allocator);
var nextId: usize = 1;

pub fn init() !void {
    if (c.ma_engine_init(null, &engine) != c.MA_SUCCESS)
        return AudioError.FailedToInitialize;
}

pub fn playFor(audio: Audio) !void {
    const entry = try shared.allocator.create(SoundEntry);
    entry.data = try std.fs.cwd().readFileAlloc(shared.allocator, audio.file, config.maxAudioSizeInBytes);

    if (c.ma_decoder_init_memory(entry.data.ptr, entry.data.len, null, &entry.decoder) != c.MA_SUCCESS) {
        shared.allocator.destroy(entry);
        shared.allocator.free(entry.data);
        return AudioError.DecoderInitFailed;
    }

    const ds: *c.ma_data_source = @ptrCast(&entry.decoder);
    if (c.ma_sound_init_from_data_source(&engine, ds, 0, null, &entry.sound) != c.MA_SUCCESS) {
        _ = c.ma_decoder_uninit(&entry.decoder);
        shared.allocator.destroy(entry);
        shared.allocator.free(entry.data);
        return AudioError.SoundInitFailed;
    }

    _ = c.ma_sound_start(&entry.sound);

    const id = nextId;
    nextId += 1;
    try activeSounds.put(id, entry);

    _ = timer.addTimer(audio.durationMs, shutSound, @ptrFromInt(id));
}

fn shutSound(interval: u32, param: ?*anyopaque) callconv(.c) u32 {
    _ = interval;
    const id: usize = @intFromPtr(param.?);

    if (activeSounds.fetchRemove(id)) |kv| {
        const entry = kv.value;

        // Stop & free in reverse order
        c.ma_sound_uninit(&entry.sound);
        _ = c.ma_decoder_uninit(&entry.decoder);
        shared.allocator.free(entry.data);
        shared.allocator.destroy(entry);
    }

    return 0;
}

pub fn cleanup() void {
    var it = activeSounds.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        c.ma_sound_uninit(&entry.sound);
        _ = c.ma_decoder_uninit(&entry.decoder);
        shared.allocator.free(entry.data);
        shared.allocator.destroy(entry);
    }
    activeSounds.deinit();

    c.ma_engine_uninit(&engine);
}
