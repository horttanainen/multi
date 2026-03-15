const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const audio = @import("audio.zig");
const procedural_music = @import("procedural_music.zig");
const procedural_house = @import("procedural_house.zig");
const piano_generator = @import("piano_generator.zig");
const minecraft_piano = @import("minecraft_piano.zig");
const procedural_80s_rock = @import("procedural_80s_rock.zig");
const procedural_choir = @import("procedural_choir.zig");
const allocator = @import("allocator.zig").allocator;

pub const Style = enum {
    ambient,
    house,
    piano,
    choir,
    minecraft,
    rock80s,
};

pub const Source = enum {
    procedural,
    file,
};

var stream: ?*c.SDL_AudioStream = null;
pub var current_style: Style = .ambient;
var current_source: Source = .procedural;
var volume: f32 = 0.5;
const output_spec = c.SDL_AudioSpec{
    .format = c.SDL_AUDIO_F32,
    .channels = 2,
    .freq = 48000,
};

// File playback state
var file_buf: ?[*c]u8 = null;
var file_len: u32 = 0;
var file_pos: u32 = 0;

pub fn init() !void {
    const s = c.SDL_CreateAudioStream(&output_spec, null) orelse {
        std.log.err("music.init: SDL_CreateAudioStream failed: {s}", .{c.SDL_GetError()});
        return error.StreamFailed;
    };

    if (!c.SDL_SetAudioStreamGain(s, volume)) {
        std.log.warn("music.init: SDL_SetAudioStreamGain failed: {s}", .{c.SDL_GetError()});
    }

    if (!c.SDL_SetAudioStreamGetCallback(s, musicCallback, null)) {
        std.log.err("music.init: SDL_SetAudioStreamGetCallback failed: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyAudioStream(s);
        return error.StreamFailed;
    }

    if (!c.SDL_BindAudioStream(audio.device_id, s)) {
        std.log.err("music.init: SDL_BindAudioStream failed: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyAudioStream(s);
        return error.StreamFailed;
    }

    stream = s;
    std.log.info("music: initialized (style=ambient)", .{});
}

pub fn playStyle(style: Style) void {
    current_style = style;
    current_source = .procedural;
    resetCurrentStyle();
    freeFileData();
}

pub fn playFile(path: []const u8) !void {
    freeFileData();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var spec: c.SDL_AudioSpec = undefined;
    var buf: [*c]u8 = undefined;
    var len: u32 = undefined;

    if (!c.SDL_LoadWAV(path_z.ptr, &spec, &buf, &len)) {
        std.log.warn("music.playFile: SDL_LoadWAV failed for '{s}': {s}", .{ path, c.SDL_GetError() });
        return error.LoadFailed;
    }

    var converted_buf: [*c]u8 = undefined;
    var converted_len: c_int = 0;
    if (!c.SDL_ConvertAudioSamples(&spec, buf, @intCast(len), &output_spec, &converted_buf, &converted_len)) {
        std.log.warn("music.playFile: SDL_ConvertAudioSamples failed for '{s}': {s}", .{ path, c.SDL_GetError() });
        c.SDL_free(buf);
        return error.LoadFailed;
    }

    c.SDL_free(buf);

    if (converted_len <= 0) {
        std.log.warn("music.playFile: converted file '{s}' has no audio data", .{path});
        c.SDL_free(converted_buf);
        return error.LoadFailed;
    }

    file_buf = converted_buf;
    file_len = @intCast(converted_len);
    file_pos = 0;
    current_source = .file;
    std.log.info("music: playing file '{s}'", .{path});
}

pub fn stop() void {
    current_source = .procedural;
    current_style = .ambient;
    resetCurrentStyle();
    freeFileData();
}

pub fn setVolume(vol: f32) void {
    volume = std.math.clamp(vol, 0.0, 1.0);
    if (stream) |s| {
        if (!c.SDL_SetAudioStreamGain(s, volume)) {
            std.log.warn("music.setVolume: failed: {s}", .{c.SDL_GetError()});
        }
    }
}

pub fn cleanup() void {
    if (stream) |s| {
        c.SDL_DestroyAudioStream(s);
        stream = null;
    }
    freeFileData();
}

fn resetCurrentStyle() void {
    switch (current_style) {
        .ambient => procedural_music.reset(),
        .house => procedural_house.reset(),
        .piano => piano_generator.reset(),
        .choir => procedural_choir.reset(),
        .minecraft => minecraft_piano.reset(),
        .rock80s => procedural_80s_rock.reset(),
    }
}

fn freeFileData() void {
    if (file_buf) |buf| {
        c.SDL_free(buf);
        file_buf = null;
        file_len = 0;
        file_pos = 0;
    }
}

fn musicCallback(_: ?*anyopaque, s: ?*c.SDL_AudioStream, additional_amount: c_int, _: c_int) callconv(.c) void {
    if (additional_amount <= 0) {
        std.log.warn("musicCallback: non-positive request size {d}, skipping", .{additional_amount});
        return;
    }

    if (s == null) {
        std.log.warn("musicCallback: stream was null, skipping request", .{});
        return;
    }
    const stream_ptr = s.?;

    const needed: usize = @intCast(additional_amount);

    switch (current_source) {
        .procedural => {
            const bytes_per_frame: usize = @sizeOf(f32) * 2;
            if (needed < bytes_per_frame) {
                std.log.warn("musicCallback: request {d} is smaller than one frame", .{needed});
                return;
            }

            var remaining_bytes = needed;
            while (remaining_bytes >= bytes_per_frame) {
                var buf: [8192]f32 = undefined;
                const max_frames = buf.len / 2;
                const chunk_frames = @min(remaining_bytes / bytes_per_frame, max_frames);
                const chunk_bytes = chunk_frames * bytes_per_frame;

                switch (current_style) {
                    .ambient => procedural_music.fillBuffer(&buf, chunk_frames),
                    .house => procedural_house.fillBuffer(&buf, chunk_frames),
                    .piano => piano_generator.fillBuffer(&buf, chunk_frames),
                    .choir => procedural_choir.fillBuffer(&buf, chunk_frames),
                    .minecraft => minecraft_piano.fillBuffer(&buf, chunk_frames),
                    .rock80s => procedural_80s_rock.fillBuffer(&buf, chunk_frames),
                }

                if (!c.SDL_PutAudioStreamData(stream_ptr, &buf, @intCast(chunk_bytes))) {
                    std.log.warn("musicCallback: SDL_PutAudioStreamData failed for procedural audio: {s}", .{c.SDL_GetError()});
                    return;
                }

                remaining_bytes -= chunk_bytes;
            }
        },
        .file => {
            if (file_buf == null) {
                std.log.warn("musicCallback: file source selected without loaded data", .{});
                return;
            }
            const buf = file_buf.?;

            var remaining_bytes = needed;
            while (remaining_bytes > 0) {
                if (file_pos >= file_len) {
                    file_pos = 0;
                }

                const available = file_len - file_pos;
                if (available == 0) {
                    std.log.warn("musicCallback: file playback buffer length is zero, skipping", .{});
                    return;
                }

                const chunk_bytes = @min(@as(u32, @intCast(remaining_bytes)), available);
                if (!c.SDL_PutAudioStreamData(stream_ptr, buf + file_pos, @intCast(chunk_bytes))) {
                    std.log.warn("musicCallback: SDL_PutAudioStreamData failed for file audio: {s}", .{c.SDL_GetError()});
                    return;
                }

                file_pos += chunk_bytes;
                remaining_bytes -= chunk_bytes;
            }
        },
    }
}
