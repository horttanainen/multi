const std = @import("std");

const destruction = @import("destruction.zig");
const particle = @import("particle.zig");
const perf = @import("perf.zig");
const time = @import("time.zig");

const Lane = enum(u8) {
    surface_texture,
    surface_collider,
    particle_stain,
    stain_texture,
};

const Priority = enum(u8) {
    normal,
    high,
};

const LaneBudget = struct {
    maximumUnits: usize,
    maximumPixels: ?usize = null,
    priority: Priority,
    maximumWaitFrames: u16,
};

const FrameUsage = struct {
    units: [laneCount]usize = [_]usize{0} ** laneCount,
    pixels: [laneCount]usize = [_]usize{0} ** laneCount,
    seconds: [laneCount]f64 = [_]f64{0} ** laneCount,
};

const UnitResult = struct {
    processed: bool,
    pixels: usize = 0,
};

const laneCount: usize = 4;
const sharedBudgetSeconds: f64 = 0.004;
const laneBudgets = [laneCount]LaneBudget{
    .{ .maximumUnits = 2, .priority = .high, .maximumWaitFrames = 1 },
    .{ .maximumUnits = 1, .priority = .high, .maximumWaitFrames = 1 },
    .{ .maximumUnits = 8, .priority = .normal, .maximumWaitFrames = 2 },
    .{ .maximumUnits = 4, .maximumPixels = 32 * 1024, .priority = .normal, .maximumWaitFrames = 2 },
};

var nextLaneIndex: usize = 0;
var laneWaitFrames: [laneCount]u16 = [_]u16{0} ** laneCount;

fn laneAt(index: usize) Lane {
    return @enumFromInt(index);
}

fn laneName(lane: Lane) []const u8 {
    return switch (lane) {
        .surface_texture => "surface_texture",
        .surface_collider => "surface_collider",
        .particle_stain => "particle_stain",
        .stain_texture => "stain_texture",
    };
}

fn laneHasPendingWork(lane: Lane) bool {
    return switch (lane) {
        .surface_texture => destruction.pendingSurfaceTextureUpdateCount() > 0,
        .surface_collider => destruction.pendingSurfaceColliderUpdateCount() > 0,
        .particle_stain => particle.pendingStains.items.len > 0,
        .stain_texture => particle.stainTextureUpdates.items.len > 0,
    };
}

fn hasPendingWork() bool {
    for (0..laneCount) |index| {
        if (laneHasPendingWork(laneAt(index))) return true;
    }
    return false;
}

fn stainTexturePixelCount() ?usize {
    if (particle.stainTextureUpdates.items.len == 0) return null;

    const rect = particle.stainTextureUpdates.items[0].dirtyRect;
    const width: usize = @intCast(@max(0, rect.maxX - rect.minX));
    const height: usize = @intCast(@max(0, rect.maxY - rect.minY));
    return width * height;
}

fn laneFitsPixelBudget(lane: Lane, usage: *const FrameUsage) bool {
    const index = @intFromEnum(lane);
    const maximumPixels = laneBudgets[index].maximumPixels orelse return true;
    const nextPixels = stainTexturePixelCount() orelse return false;
    if (usage.units[index] == 0) return true;
    if (usage.pixels[index] >= maximumPixels) return false;
    return nextPixels <= maximumPixels - usage.pixels[index];
}

fn laneCanRun(lane: Lane, usage: *const FrameUsage) bool {
    const index = @intFromEnum(lane);
    if (usage.units[index] >= laneBudgets[index].maximumUnits) return false;
    if (!laneHasPendingWork(lane)) return false;
    return laneFitsPixelBudget(lane, usage);
}

fn nextStarvedLane(usage: *const FrameUsage) ?Lane {
    var selectedIndex: ?usize = null;
    var selectedWaitFrames: u16 = 0;
    for (0..laneCount) |offset| {
        const index = (nextLaneIndex + offset) % laneCount;
        const lane = laneAt(index);
        if (!laneCanRun(lane, usage)) continue;
        if (laneWaitFrames[index] < laneBudgets[index].maximumWaitFrames) continue;
        if (selectedIndex != null and laneWaitFrames[index] <= selectedWaitFrames) continue;

        selectedIndex = index;
        selectedWaitFrames = laneWaitFrames[index];
    }
    if (selectedIndex == null) return null;
    return laneAt(selectedIndex.?);
}

fn nextPriorityLane(usage: *const FrameUsage) ?Lane {
    var selectedIndex: ?usize = null;
    var selectedPriority: u8 = 0;
    for (0..laneCount) |offset| {
        const index = (nextLaneIndex + offset) % laneCount;
        const lane = laneAt(index);
        if (!laneCanRun(lane, usage)) continue;

        const priority = @intFromEnum(laneBudgets[index].priority);
        if (selectedIndex != null and priority <= selectedPriority) continue;
        selectedIndex = index;
        selectedPriority = priority;
    }
    if (selectedIndex == null) return null;
    return laneAt(selectedIndex.?);
}

fn nextLane(usage: *const FrameUsage) ?Lane {
    const starvedLane = nextStarvedLane(usage);
    if (starvedLane != null) return starvedLane.?;
    return nextPriorityLane(usage);
}

fn processLane(lane: Lane) !UnitResult {
    return switch (lane) {
        .surface_texture => .{ .processed = destruction.processOneSurfaceTextureUpdate() },
        .surface_collider => .{ .processed = destruction.processOneSurfaceColliderChunk() },
        .particle_stain => .{ .processed = try particle.processOnePendingStain() },
        .stain_texture => blk: {
            const pixels = stainTexturePixelCount() orelse {
                std.log.err("deferred_work.processLane: stain texture lane has no pending region", .{});
                break :blk .{ .processed = false };
            };
            break :blk .{
                .processed = particle.processOneStainTextureUpdate(),
                .pixels = pixels,
            };
        },
    };
}

fn updateLaneWaitFrames(usage: *const FrameUsage) void {
    for (0..laneCount) |index| {
        const lane = laneAt(index);
        if (!laneHasPendingWork(lane) or usage.units[index] > 0) {
            laneWaitFrames[index] = 0;
            continue;
        }
        if (laneWaitFrames[index] == std.math.maxInt(u16)) continue;
        laneWaitFrames[index] += 1;
    }
}

fn microseconds(seconds: f64) u64 {
    return @intFromFloat(seconds * 1_000_000.0);
}

inline fn recordPerformance(usage: *const FrameUsage, totalSeconds: f64) void {
    if (comptime !perf.configured(.player_death)) return;

    const surfaceTextureIndex = @intFromEnum(Lane.surface_texture);
    const surfaceColliderIndex = @intFromEnum(Lane.surface_collider);
    const particleStainIndex = @intFromEnum(Lane.particle_stain);
    const stainTextureIndex = @intFromEnum(Lane.stain_texture);
    const terrainSeconds = usage.seconds[surfaceTextureIndex] + usage.seconds[surfaceColliderIndex];
    const bloodTextureSeconds = usage.seconds[particleStainIndex] + usage.seconds[stainTextureIndex];
    perf.recordPlayerDeathGameLoopElapsed(.terrain_updates, microseconds(terrainSeconds));
    perf.recordPlayerDeathGameLoopElapsed(.blood_texture, microseconds(bloodTextureSeconds));
    perf.log(
        .player_death,
        "perf.deferred_work total_us={d} surface_texture_units={d} surface_collider_units={d} particle_stain_units={d} stain_texture_units={d} stain_texture_pixels={d} pending_surface_texture={d} pending_surface_collider={d} pending_particle_stains={d} pending_stain_texture={d}",
        .{
            microseconds(totalSeconds),
            usage.units[surfaceTextureIndex],
            usage.units[surfaceColliderIndex],
            usage.units[particleStainIndex],
            usage.units[stainTextureIndex],
            usage.pixels[stainTextureIndex],
            destruction.pendingSurfaceTextureUpdateCount(),
            destruction.pendingSurfaceColliderUpdateCount(),
            particle.pendingStains.items.len,
            particle.stainTextureUpdates.items.len,
        },
    );
}

pub fn process() !void {
    if (!hasPendingWork()) {
        laneWaitFrames = [_]u16{0} ** laneCount;
        return;
    }

    const budgetStart = time.preciseNow();
    var usage: FrameUsage = .{};
    var processedAny = false;
    while (true) {
        if (processedAny and time.preciseNow() - budgetStart >= sharedBudgetSeconds) break;

        const pendingLane = nextLane(&usage);
        if (pendingLane == null) break;
        const lane = pendingLane.?;
        const laneIndex = @intFromEnum(lane);
        const unitStart = time.preciseNow();
        const result = try processLane(lane);
        const unitSeconds = time.preciseNow() - unitStart;
        nextLaneIndex = (laneIndex + 1) % laneCount;
        if (!result.processed) {
            std.log.err("deferred_work.process: lane '{s}' had no work after selection", .{laneName(lane)});
            usage.units[laneIndex] = laneBudgets[laneIndex].maximumUnits;
            continue;
        }

        usage.units[laneIndex] += 1;
        usage.pixels[laneIndex] += result.pixels;
        usage.seconds[laneIndex] += unitSeconds;
        processedAny = true;
    }

    updateLaneWaitFrames(&usage);
    recordPerformance(&usage, time.preciseNow() - budgetStart);
}
