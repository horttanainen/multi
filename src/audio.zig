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

pub const CachedSound = struct {
    buf: [*]u8,
    len: c_int,
    volume: f32,
};

// Cached clips and their voices are owned by the main thread. SDL consumes the
// queued copies; the legacy timed sounds continue using their existing mutex.
pub var cached_sounds: std.StringHashMapUnmanaged(CachedSound) = .{};
pub var cached_voices: [4]?*c.SDL_AudioStream = @splat(null);
const cached_spec = c.SDL_AudioSpec{
    .format = c.SDL_AUDIO_F32,
    .channels = 2,
    .freq = 48000,
};

fn initCachedVoices() !void {
    if (cached_voices[0] != null) return;
    var created: [cached_voices.len]?*c.SDL_AudioStream = @splat(null);
    errdefer {
        for (created) |stream| {
            if (stream == null) continue;
            c.SDL_DestroyAudioStream(stream.?);
        }
    }
    for (&created) |*slot| {
        const stream = c.SDL_CreateAudioStream(&cached_spec, null) orelse {
            std.log.warn("audio.initCachedVoices: cannot create stream: {s}", .{c.SDL_GetError()});
            return AudioError.StreamFailed;
        };
        slot.* = stream;
        if (!c.SDL_BindAudioStream(device_id, stream)) {
            std.log.warn("audio.initCachedVoices: cannot bind stream: {s}", .{c.SDL_GetError()});
            return AudioError.StreamFailed;
        }
    }
    cached_voices = created;
}

// Called at asset load time. Duplicate IDs retain the already loaded sample.
pub fn preload(id: []const u8, clip: Audio) !void {
    if (device_id == 0) {
        std.log.warn("audio.preload: no audio device for '{s}'", .{id});
        return AudioError.FailedToInitialize;
    }
    if (cached_sounds.contains(id)) return;
    const path_z = try allocator.dupeZ(u8, clip.file);
    defer allocator.free(path_z);
    var source: [*c]u8 = undefined;
    var source_len: u32 = undefined;
    var source_spec: c.SDL_AudioSpec = undefined;
    if (!c.SDL_LoadWAV(path_z.ptr, &source_spec, &source, &source_len)) {
        std.log.warn("audio.preload: cannot load '{s}': {s}", .{ clip.file, c.SDL_GetError() });
        return AudioError.LoadFailed;
    }
    defer c.SDL_free(source);
    if (source_len == 0 or source_len > std.math.maxInt(c_int)) {
        std.log.warn("audio.preload: invalid sample length for '{s}': {d}", .{ id, source_len });
        return AudioError.LoadFailed;
    }
    var converted: [*c]u8 = undefined;
    var converted_len: c_int = undefined;
    if (!c.SDL_ConvertAudioSamples(
        &source_spec,
        source,
        @intCast(source_len),
        &cached_spec,
        &converted,
        &converted_len,
    )) {
        std.log.warn("audio.preload: cannot convert '{s}': {s}", .{ id, c.SDL_GetError() });
        return AudioError.LoadFailed;
    }
    errdefer c.SDL_free(converted);
    if (converted == null or converted_len <= 0) {
        std.log.warn("audio.preload: conversion produced no samples for '{s}'", .{id});
        return AudioError.LoadFailed;
    }
    try initCachedVoices();
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    try cached_sounds.put(allocator, owned_id, .{
        .buf = converted,
        .len = converted_len,
        .volume = std.math.clamp(clip.volume, 0, 1),
    });
}

// No disk reads, stream creation or timers on the input path. A full pool drops
// the new cue instead of queuing late feedback or cutting off an existing tail.
pub fn playCached(id: []const u8, volume: f32) bool {
    if (device_id == 0 or volume <= 0) {
        return false;
    }
    const clip = cached_sounds.get(id) orelse {
        std.log.warn("audio.playCached: sound '{s}' was not preloaded", .{id});
        return false;
    };
    if (clip.volume <= 0) return false;
    for (cached_voices) |slot| {
        if (slot == null) {
            std.log.warn("audio.playCached: cached voice is missing for '{s}'", .{id});
            return false;
        }
        const stream = slot.?;
        const queued = c.SDL_GetAudioStreamQueued(stream);
        const available = c.SDL_GetAudioStreamAvailable(stream);
        if (queued < 0 or available < 0) {
            std.log.warn("audio.playCached: cannot inspect stream: {s}", .{c.SDL_GetError()});
            return false;
        }
        if (queued != 0 or available != 0) {
            continue;
        }
        if (!c.SDL_SetAudioStreamGain(stream, clip.volume * std.math.clamp(volume, 0, 1))) {
            std.log.warn("audio.playCached: cannot set gain: {s}", .{c.SDL_GetError()});
            return false;
        }
        if (!c.SDL_PutAudioStreamData(stream, clip.buf, clip.len)) {
            std.log.warn("audio.playCached: cannot queue '{s}': {s}", .{ id, c.SDL_GetError() });
            return false;
        }
        if (!c.SDL_FlushAudioStream(stream)) {
            std.log.warn("audio.playCached: cannot flush '{s}': {s}", .{ id, c.SDL_GetError() });
            if (!c.SDL_ClearAudioStream(stream)) {
                std.log.warn("audio.playCached: cannot clear failed stream: {s}", .{c.SDL_GetError()});
            }
            return false;
        }
        return true;
    }
    return false;
}

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

    for (&cached_voices) |*stream| {
        if (stream.* == null) continue;
        c.SDL_DestroyAudioStream(stream.*.?);
        stream.* = null;
    }
    var cached = cached_sounds.iterator();
    while (cached.next()) |entry| {
        c.SDL_free(entry.value_ptr.buf);
        allocator.free(entry.key_ptr.*);
    }
    cached_sounds.clearAndFree(allocator);

    if (device_id != 0) {
        c.SDL_CloseAudioDevice(device_id);
        device_id = 0;
    }
}
