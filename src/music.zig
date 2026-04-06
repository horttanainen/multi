const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const audio = @import("audio.zig");
const procedural_ambient = @import("procedural_ambient.zig");
const procedural_choir = @import("procedural_choir.zig");
const procedural_african_drums = @import("procedural_african_drums.zig");
const procedural_taiko = @import("procedural_taiko.zig");
const allocator = @import("allocator.zig").allocator;
const AtomicU32 = std.atomic.Value(u32);

pub const Style = enum {
    ambient,
    choir,
    african_drums,
    taiko,
};

pub const Source = enum {
    procedural,
    file,
};

pub const ReactiveVisual = struct {
    loudness: f32,
    loudness_att: f32,
    low: f32,
    low_att: f32,
    mid: f32,
    mid_att: f32,
    high: f32,
    high_att: f32,
    onset: f32,
};

var stream: ?*c.SDL_AudioStream = null;
pub var current_style: Style = .ambient;
var current_source: Source = .procedural;
var volume: f32 = 0.5;
var low_filter_state: f32 = 0.0;
var mid_filter_state: f32 = 0.0;
var high_filter_state: f32 = 0.0;
var prev_loudness_raw: f32 = 0.0;
var prev_high_raw: f32 = 0.0;
var loudness_peak: f32 = 0.05;
var low_peak: f32 = 0.05;
var mid_peak: f32 = 0.05;
var high_peak: f32 = 0.05;
var onset_peak: f32 = 0.02;
var loudness_fast: f32 = 0.0;
var loudness_att: f32 = 0.0;
var low_fast: f32 = 0.0;
var low_att: f32 = 0.0;
var mid_fast: f32 = 0.0;
var mid_att: f32 = 0.0;
var high_fast: f32 = 0.0;
var high_att: f32 = 0.0;
var onset_env: f32 = 0.0;
var reactive_loudness_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_loudness_att_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_low_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_low_att_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_mid_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_mid_att_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_high_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_high_att_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
var reactive_onset_bits = AtomicU32.init(@bitCast(@as(f32, 0.0)));
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
    resetReactiveAnalysis();

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
    resetReactiveAnalysis();
    resetCurrentStyle();
    freeFileData();
}

pub fn playFile(path: []const u8) !void {
    freeFileData();
    resetReactiveAnalysis();

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
    resetReactiveAnalysis();
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

pub fn getReactiveVisual() ReactiveVisual {
    return .{
        .loudness = loadAtomicF32(&reactive_loudness_bits),
        .loudness_att = loadAtomicF32(&reactive_loudness_att_bits),
        .low = loadAtomicF32(&reactive_low_bits),
        .low_att = loadAtomicF32(&reactive_low_att_bits),
        .mid = loadAtomicF32(&reactive_mid_bits),
        .mid_att = loadAtomicF32(&reactive_mid_att_bits),
        .high = loadAtomicF32(&reactive_high_bits),
        .high_att = loadAtomicF32(&reactive_high_att_bits),
        .onset = loadAtomicF32(&reactive_onset_bits),
    };
}

fn resetCurrentStyle() void {
    switch (current_style) {
        .ambient => procedural_ambient.reset(),
        .choir => procedural_choir.reset(),
        .african_drums => procedural_african_drums.reset(),
        .taiko => procedural_taiko.reset(),
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
                    .ambient => procedural_ambient.fillBuffer(&buf, chunk_frames),
                    .choir => procedural_choir.fillBuffer(&buf, chunk_frames),
                    .african_drums => procedural_african_drums.fillBuffer(&buf, chunk_frames),
                    .taiko => procedural_taiko.fillBuffer(&buf, chunk_frames),
                }
                analyzeStereoBuffer(buf[0 .. chunk_frames * 2]);

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
                const sample_count = chunk_bytes / @sizeOf(f32);
                const sample_ptr: [*]const f32 = @ptrCast(@alignCast(buf + file_pos));
                analyzeStereoBuffer(sample_ptr[0..sample_count]);
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

fn analyzeStereoBuffer(samples: []const f32) void {
    const frame_count = samples.len / 2;
    if (frame_count == 0) return;

    var loudness_sq: f32 = 0.0;
    var low_sq: f32 = 0.0;
    var mid_sq: f32 = 0.0;
    var high_sq: f32 = 0.0;

    var i: usize = 0;
    while (i + 1 < samples.len) : (i += 2) {
        const mono = (samples[i] + samples[i + 1]) * 0.5;
        low_filter_state += (mono - low_filter_state) * 0.035;
        const high_input = mono - low_filter_state;
        high_filter_state += (high_input - high_filter_state) * 0.18;
        const high_band = high_input - high_filter_state;
        mid_filter_state += ((mono - low_filter_state - high_band) - mid_filter_state) * 0.12;

        loudness_sq += mono * mono;
        low_sq += low_filter_state * low_filter_state;
        mid_sq += mid_filter_state * mid_filter_state;
        high_sq += high_band * high_band;
    }

    const inv_frames = 1.0 / @as(f32, @floatFromInt(frame_count));
    const loudness_raw = @sqrt(loudness_sq * inv_frames);
    const low_raw = @sqrt(low_sq * inv_frames);
    const mid_raw = @sqrt(mid_sq * inv_frames);
    const high_raw = @sqrt(high_sq * inv_frames);

    const loudness_norm = normalizeSignal(loudness_raw, &loudness_peak, 0.992);
    const low_norm = normalizeSignal(low_raw, &low_peak, 0.992);
    const mid_norm = normalizeSignal(mid_raw, &mid_peak, 0.992);
    const high_norm = normalizeSignal(high_raw, &high_peak, 0.992);

    loudness_fast = followEnvelope(loudness_norm, loudness_fast, 0.45, 0.14);
    loudness_att = followEnvelope(loudness_norm, loudness_att, 0.18, 0.03);
    low_fast = followEnvelope(low_norm, low_fast, 0.48, 0.16);
    low_att = followEnvelope(low_norm, low_att, 0.16, 0.028);
    mid_fast = followEnvelope(mid_norm, mid_fast, 0.4, 0.12);
    mid_att = followEnvelope(mid_norm, mid_att, 0.14, 0.024);
    high_fast = followEnvelope(high_norm, high_fast, 0.36, 0.1);
    high_att = followEnvelope(high_norm, high_att, 0.12, 0.022);

    // Hi-hat/short-tick pulse detector: positive transient in the high band.
    const onset_flux = @max(0.0, high_raw - prev_high_raw);
    prev_loudness_raw = loudness_raw;
    prev_high_raw = high_raw;

    const onset_norm = normalizeSignal(onset_flux, &onset_peak, 0.98);
    onset_env *= 0.72;
    if (onset_norm > onset_env) onset_env = onset_norm;

    storeAtomicF32(&reactive_loudness_bits, loudness_fast);
    storeAtomicF32(&reactive_loudness_att_bits, loudness_att);
    storeAtomicF32(&reactive_low_bits, low_fast);
    storeAtomicF32(&reactive_low_att_bits, low_att);
    storeAtomicF32(&reactive_mid_bits, mid_fast);
    storeAtomicF32(&reactive_mid_att_bits, mid_att);
    storeAtomicF32(&reactive_high_bits, high_fast);
    storeAtomicF32(&reactive_high_att_bits, high_att);
    storeAtomicF32(&reactive_onset_bits, onset_env);
}

fn resetReactiveAnalysis() void {
    low_filter_state = 0.0;
    mid_filter_state = 0.0;
    high_filter_state = 0.0;
    prev_loudness_raw = 0.0;
    prev_high_raw = 0.0;
    loudness_peak = 0.05;
    low_peak = 0.05;
    mid_peak = 0.05;
    high_peak = 0.05;
    onset_peak = 0.02;
    loudness_fast = 0.0;
    loudness_att = 0.0;
    low_fast = 0.0;
    low_att = 0.0;
    mid_fast = 0.0;
    mid_att = 0.0;
    high_fast = 0.0;
    high_att = 0.0;
    onset_env = 0.0;

    storeAtomicF32(&reactive_loudness_bits, 0.0);
    storeAtomicF32(&reactive_loudness_att_bits, 0.0);
    storeAtomicF32(&reactive_low_bits, 0.0);
    storeAtomicF32(&reactive_low_att_bits, 0.0);
    storeAtomicF32(&reactive_mid_bits, 0.0);
    storeAtomicF32(&reactive_mid_att_bits, 0.0);
    storeAtomicF32(&reactive_high_bits, 0.0);
    storeAtomicF32(&reactive_high_att_bits, 0.0);
    storeAtomicF32(&reactive_onset_bits, 0.0);
}

fn normalizeSignal(raw: f32, peak: *f32, decay: f32) f32 {
    peak.* = @max(raw, peak.* * decay);
    const denom = @max(peak.* * 1.2, 0.0001);
    return std.math.clamp(raw / denom, 0.0, 1.0);
}

fn followEnvelope(raw: f32, state: f32, attack: f32, release: f32) f32 {
    if (raw > state) {
        return state + (raw - state) * attack;
    }
    return state + (raw - state) * release;
}

fn storeAtomicF32(slot: *AtomicU32, value: f32) void {
    slot.store(@bitCast(value), .monotonic);
}

fn loadAtomicF32(slot: *AtomicU32) f32 {
    return @bitCast(slot.load(.monotonic));
}
