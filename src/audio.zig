const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const allocator = @import("allocator.zig").allocator;
const runtime = @import("runtime.zig");

pub const AudioError = error{
    FailedToInitialize,
    LoadFailed,
    StreamFailed,
};

pub const Audio = struct {
    file: []const u8,
    durationMs: u32,
    volume: f32 = 1.0,
};

const SoundEntry = struct {
    stream: *c.SDL_AudioStream,
    buf: [*]u8,
    len: u32,
};

pub var device_id: c.SDL_AudioDeviceID = 0;
var activeSounds = std.AutoHashMap(usize, *SoundEntry).init(allocator);
var activeSoundsMutex: std.Io.Mutex = .init;
var acceptSoundTimers = false;
var nextId: usize = 1;

pub fn init() !void {
    var spec = c.SDL_AudioSpec{
        .format = c.SDL_AUDIO_S16,
        .channels = 2,
        .freq = 48000,
    };
    device_id = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
    if (device_id == 0) {
        std.log.err("audio.init: SDL_OpenAudioDevice failed: {s}", .{c.SDL_GetError()});
        return AudioError.FailedToInitialize;
    }

    activeSoundsMutex.lockUncancelable(runtime.io());
    acceptSoundTimers = true;
    activeSoundsMutex.unlock(runtime.io());
}

fn destroySoundEntry(entry: *SoundEntry) void {
    c.SDL_DestroyAudioStream(entry.stream);
    c.SDL_free(entry.buf);
    allocator.destroy(entry);
}

pub fn playFor(audio: Audio) !void {
    const path_z = try allocator.dupeZ(u8, audio.file);
    defer allocator.free(path_z);

    var buf: [*c]u8 = undefined;
    var len: u32 = undefined;
    var wav_spec: c.SDL_AudioSpec = undefined;

    if (!c.SDL_LoadWAV(path_z.ptr, &wav_spec, &buf, &len)) {
        std.log.warn("audio.playFor: SDL_LoadWAV failed for '{s}': {s}", .{ audio.file, c.SDL_GetError() });
        return AudioError.LoadFailed;
    }

    const stream = c.SDL_CreateAudioStream(&wav_spec, null) orelse {
        std.log.warn("audio.playFor: SDL_CreateAudioStream failed: {s}", .{c.SDL_GetError()});
        c.SDL_free(buf);
        return AudioError.StreamFailed;
    };

    if (!c.SDL_SetAudioStreamGain(stream, audio.volume)) {
        std.log.warn("audio.playFor: SDL_SetAudioStreamGain failed: {s}", .{c.SDL_GetError()});
    }

    if (!c.SDL_BindAudioStream(device_id, stream)) {
        std.log.warn("audio.playFor: SDL_BindAudioStream failed: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyAudioStream(stream);
        c.SDL_free(buf);
        return AudioError.StreamFailed;
    }

    if (!c.SDL_PutAudioStreamData(stream, buf, @intCast(len))) {
        std.log.warn("audio.playFor: SDL_PutAudioStreamData failed: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyAudioStream(stream);
        c.SDL_free(buf);
        return AudioError.StreamFailed;
    }

    if (!c.SDL_FlushAudioStream(stream)) {
        std.log.warn("audio.playFor: SDL_FlushAudioStream failed: {s}", .{c.SDL_GetError()});
    }

    const entry = try allocator.create(SoundEntry);
    entry.* = .{ .stream = stream, .buf = buf, .len = len };
    errdefer destroySoundEntry(entry);

    activeSoundsMutex.lockUncancelable(runtime.io());
    defer activeSoundsMutex.unlock(runtime.io());

    if (!acceptSoundTimers or device_id == 0) {
        destroySoundEntry(entry);
        return;
    }

    const id = nextId;
    nextId += 1;
    try activeSounds.put(id, entry);

    _ = sdl.addTimer(audio.durationMs, shutSound, @ptrFromInt(id));
}

fn shutSound(param: ?*anyopaque, _: sdl.TimerID, _: u32) callconv(.c) u32 {
    const id: usize = @intFromPtr(param.?);

    activeSoundsMutex.lockUncancelable(runtime.io());
    defer activeSoundsMutex.unlock(runtime.io());

    if (!acceptSoundTimers) {
        return 0;
    }

    if (activeSounds.fetchRemove(id)) |kv| {
        destroySoundEntry(kv.value);
    }

    return 0;
}

pub fn cleanupOne(audio: Audio) void {
    allocator.free(audio.file);
}

pub fn cleanup() void {
    activeSoundsMutex.lockUncancelable(runtime.io());
    defer activeSoundsMutex.unlock(runtime.io());

    acceptSoundTimers = false;

    var it = activeSounds.iterator();
    while (it.next()) |kv| {
        destroySoundEntry(kv.value_ptr.*);
    }
    activeSounds.clearAndFree();

    if (device_id != 0) {
        c.SDL_CloseAudioDevice(device_id);
        device_id = 0;
    }
}
