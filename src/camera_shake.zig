const std = @import("std");

const allocator = @import("allocator.zig").allocator;
const camera = @import("camera.zig");
const runtime = @import("runtime.zig");
const time = @import("time.zig");
const vec = @import("vector.zig");

pub const Capture = struct {
    propagation_duration_ms: u32,
    duration_ms: u32,
    max_offset_screen_pixels: f32,
};

pub const Listener = struct {
    camera_id: usize,
    strength: f32,
    direction: vec.Vec2,
    arrival_fraction: f32,
};

const Event = struct {
    capture_id: u64,
    camera_id: usize,
    starts_at: f64,
    duration_seconds: f64,
    max_offset_screen_pixels: f32,
    strength: f32,
    direction: vec.Vec2,
    noise_seed: u64,
};

const noiseFrequencyHz: f64 = 24;
const directionalWeight: f32 = 0.35;
const noiseWeight: f32 = 1.0 - directionalWeight;
const maximumCombinedOffsetScreenPixels: f32 = 32;
const deathDurationMs: u32 = 240;
const deathMaxOffsetScreenPixels: f32 = 12;
const gibDeathDurationMs: u32 = 340;
const gibDeathMaxOffsetScreenPixels: f32 = 22;

var events: std.ArrayListUnmanaged(Event) = .empty;
var nextCaptureId: u64 = 1;

fn hash64(input: u64) u64 {
    var value = input;
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    value *%= 0x94d049bb133111eb;
    value ^= value >> 31;
    return value;
}

fn noiseValue(seed: u64, sampleIndex: u64) f32 {
    const bits: u24 = @truncate(hash64(seed ^ sampleIndex) >> 40);
    const unit = @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(std.math.maxInt(u24)));
    return unit * 2 - 1;
}

fn smoothNoise(seed: u64, samplePosition: f64) f32 {
    const lowerPosition = @floor(samplePosition);
    const lowerIndex: u64 = @intFromFloat(lowerPosition);
    const fraction: f32 = @floatCast(samplePosition - lowerPosition);
    const smoothed = fraction * fraction * (3 - 2 * fraction);
    return std.math.lerp(noiseValue(seed, lowerIndex), noiseValue(seed, lowerIndex + 1), smoothed);
}

pub fn beginCapture() u64 {
    const captureId = nextCaptureId;
    nextCaptureId +%= 1;
    return captureId;
}

pub fn capture(captureId: u64, listener: Listener, captureData: Capture) !void {
    var existingIndex: ?usize = null;
    for (events.items, 0..) |existingEvent, index| {
        if (existingEvent.capture_id != captureId or existingEvent.camera_id != listener.camera_id) continue;
        if (existingEvent.strength >= listener.strength) return;
        existingIndex = index;
        break;
    }

    const now = time.realNow();
    const propagationSeconds = @as(f64, @floatFromInt(captureData.propagation_duration_ms)) / 1000.0;
    const event = Event{
        .capture_id = captureId,
        .camera_id = listener.camera_id,
        .starts_at = now + listener.arrival_fraction * propagationSeconds,
        .duration_seconds = @as(f64, @floatFromInt(captureData.duration_ms)) / 1000.0,
        .max_offset_screen_pixels = captureData.max_offset_screen_pixels * listener.strength,
        .strength = listener.strength,
        .direction = listener.direction,
        .noise_seed = runtime.random().int(u64),
    };
    if (existingIndex == null) {
        try events.append(allocator, event);
        return;
    }
    events.items[existingIndex.?] = event;
}

pub fn capturePlayerDeath(cameraId: usize, direction: vec.Vec2, gibbed: bool) !void {
    const durationMs = if (gibbed) gibDeathDurationMs else deathDurationMs;
    const maxOffsetScreenPixels = if (gibbed) gibDeathMaxOffsetScreenPixels else deathMaxOffsetScreenPixels;
    try capture(beginCapture(), .{
        .camera_id = cameraId,
        .strength = 1,
        .direction = direction,
        .arrival_fraction = 0,
    }, .{
        .propagation_duration_ms = 0,
        .duration_ms = durationMs,
        .max_offset_screen_pixels = maxOffsetScreenPixels,
    });
}

fn eventOffsetScreenPixels(event: Event, now: f64) vec.Vec2 {
    const elapsed = now - event.starts_at;
    const progress = std.math.clamp(elapsed / event.duration_seconds, 0, 1);
    const trauma = @as(f32, @floatCast(1 - progress));
    const amplitude = event.max_offset_screen_pixels * trauma * trauma;
    const samplePosition = elapsed * noiseFrequencyHz;
    var noise = vec.Vec2{
        .x = smoothNoise(event.noise_seed ^ 0x9e3779b97f4a7c15, samplePosition),
        .y = smoothNoise(event.noise_seed ^ 0xd1b54a32d192ed03, samplePosition),
    };
    const noiseMagnitude = vec.magnitude(noise);
    if (noiseMagnitude > 1) noise = vec.mul(noise, 1 / noiseMagnitude);

    const combinedDirection = vec.add(
        vec.mul(event.direction, directionalWeight),
        vec.mul(noise, noiseWeight),
    );
    return vec.mul(combinedDirection, amplitude);
}

pub fn update(zoom: f32) void {
    for (camera.cameras.values()) |*cam| {
        cam.shakeOffsetPx = vec.zero;
    }

    const now = time.realNow();
    var index: usize = 0;
    while (index < events.items.len) {
        const event = events.items[index];
        if (now < event.starts_at) {
            index += 1;
            continue;
        }
        if (now >= event.starts_at + event.duration_seconds) {
            _ = events.swapRemove(index);
            continue;
        }

        const cam = camera.cameras.getPtr(event.camera_id) orelse {
            _ = events.swapRemove(index);
            continue;
        };
        const offsetScreenPixels = eventOffsetScreenPixels(event, now);
        cam.shakeOffsetPx = vec.add(cam.shakeOffsetPx, vec.mul(offsetScreenPixels, 1 / zoom));
        index += 1;
    }

    const maximumWorldOffset = maximumCombinedOffsetScreenPixels / zoom;
    for (camera.cameras.values()) |*cam| {
        const magnitude = vec.magnitude(cam.shakeOffsetPx);
        if (magnitude <= maximumWorldOffset) continue;
        cam.shakeOffsetPx = vec.mul(cam.shakeOffsetPx, maximumWorldOffset / magnitude);
    }
}

pub fn cleanup() void {
    events.clearAndFree(allocator);
    nextCaptureId = 1;
    for (camera.cameras.values()) |*cam| {
        cam.shakeOffsetPx = vec.zero;
    }
}
