const std = @import("std");

const config = @import("config.zig");
const sdl = @import("sdl.zig");

pub const Scope = enum {
    explosion,
    level_editor_static_spawn,
    player_death,
};

pub const PlayerDeathGameLoopMetrics = struct {
    terrain_updates_us: u64 = 0,
    rope_us: u64 = 0,
    blood_contacts_us: u64 = 0,
    blood_texture_us: u64 = 0,
    giblet_contacts_us: u64 = 0,
    projectile_contacts_us: u64 = 0,
    cleanup_us: u64 = 0,
    player_and_sensor_us: u64 = 0,
    animation_and_camera_us: u64 = 0,
};

pub const PlayerDeathFrameMetrics = struct {
    total_us: u64 = 0,
    physics_us: u64 = 0,
    input_us: u64 = 0,
    logic_us: u64 = 0,
    render_us: u64 = 0,
    game_loop: PlayerDeathGameLoopMetrics = .{},
};

pub const PlayerDeathTriggerMetrics = struct {
    calls: usize = 0,
    blood_spawn_us: u64 = 0,
    gib_us: u64 = 0,
    kill_us: u64 = 0,
    total_us: u64 = 0,
};

pub const PlayerDeathFrameStage = enum {
    physics,
    input,
    logic,
    render,
};

pub const PlayerDeathGameLoopStage = enum {
    terrain_updates,
    rope,
    blood_contacts,
    blood_texture,
    giblet_contacts,
    projectile_contacts,
    cleanup,
    player_and_sensor,
    animation_and_camera,
};

pub const PlayerDeathTriggerStage = enum {
    blood_spawn,
    gib,
    kill,
    total,
};

const playerDeathCaptureFrameCount: usize = 120;
const playerDeathWorstFrameCount: usize = 8;

const PlayerDeathWorstFrame = struct {
    valid: bool = false,
    frame_index: usize = 0,
    metrics: PlayerDeathFrameMetrics = .{},
};

const PlayerDeathCapture = struct {
    active: bool = false,
    event_id: u64 = 0,
    victim_id: usize = 0,
    gibbed: bool = false,
    frames_recorded: usize = 0,
    frames_remaining: usize = 0,
    over_16ms: usize = 0,
    over_25ms: usize = 0,
    over_33ms: usize = 0,
    frame_totals: PlayerDeathFrameMetrics = .{},
    max_frame_us: u64 = 0,
    worst_frames: [playerDeathWorstFrameCount]PlayerDeathWorstFrame = [_]PlayerDeathWorstFrame{.{}} ** playerDeathWorstFrameCount,
    trigger: PlayerDeathTriggerMetrics = .{},
};

var levelEditorStaticSpawnDepth: u32 = 0;
var playerDeathEventId: u64 = 0;
var playerDeathCapture: PlayerDeathCapture = .{};
var currentPlayerDeathFrameMetrics: PlayerDeathFrameMetrics = .{};

pub inline fn configured(comptime scope: Scope) bool {
    return switch (scope) {
        .explosion => config.perf.explosion,
        .level_editor_static_spawn => config.perf.level_editor_static_spawn,
        .player_death => config.perf.player_death,
    };
}

pub inline fn enabled(comptime scope: Scope) bool {
    if (comptime !configured(scope)) return false;
    return switch (scope) {
        .level_editor_static_spawn => levelEditorStaticSpawnDepth > 0,
        else => true,
    };
}

pub inline fn enter(comptime scope: Scope) void {
    if (comptime !configured(scope)) return;
    switch (scope) {
        .explosion => {},
        .level_editor_static_spawn => levelEditorStaticSpawnDepth += 1,
        .player_death => {},
    }
}

pub inline fn exit(comptime scope: Scope) void {
    if (comptime !configured(scope)) return;
    switch (scope) {
        .explosion => {},
        .level_editor_static_spawn => {
            if (levelEditorStaticSpawnDepth == 0) {
                std.log.warn("perf.exit: level editor static spawn scope was not active", .{});
                return;
            }
            levelEditorStaticSpawnDepth -= 1;
        },
        .player_death => {},
    }
}

pub inline fn begin(comptime scope: Scope) u64 {
    if (comptime !configured(scope)) return 0;
    if (!enabled(scope)) return 0;
    return sdl.getPerformanceCounter();
}

pub inline fn elapsedUs(start: u64) u64 {
    if (start == 0) return 0;

    const elapsed = sdl.getPerformanceCounter() - start;
    return elapsed * 1_000_000 / sdl.getPerformanceFrequency();
}

pub inline fn log(comptime scope: Scope, comptime fmt: []const u8, args: anytype) void {
    if (comptime !configured(scope)) return;
    if (!enabled(scope)) return;
    std.log.info(fmt, args);
}

fn addPlayerDeathGameLoopMetrics(target: *PlayerDeathGameLoopMetrics, metrics: PlayerDeathGameLoopMetrics) void {
    target.terrain_updates_us += metrics.terrain_updates_us;
    target.rope_us += metrics.rope_us;
    target.blood_contacts_us += metrics.blood_contacts_us;
    target.blood_texture_us += metrics.blood_texture_us;
    target.giblet_contacts_us += metrics.giblet_contacts_us;
    target.projectile_contacts_us += metrics.projectile_contacts_us;
    target.cleanup_us += metrics.cleanup_us;
    target.player_and_sensor_us += metrics.player_and_sensor_us;
    target.animation_and_camera_us += metrics.animation_and_camera_us;
}

fn addPlayerDeathFrameMetrics(target: *PlayerDeathFrameMetrics, metrics: PlayerDeathFrameMetrics) void {
    target.total_us += metrics.total_us;
    target.physics_us += metrics.physics_us;
    target.input_us += metrics.input_us;
    target.logic_us += metrics.logic_us;
    target.render_us += metrics.render_us;
    addPlayerDeathGameLoopMetrics(&target.game_loop, metrics.game_loop);
}

fn insertPlayerDeathWorstFrame(frame_index: usize, metrics: PlayerDeathFrameMetrics) void {
    var insert_index = playerDeathWorstFrameCount;
    for (playerDeathCapture.worst_frames, 0..) |worst, index| {
        if (!worst.valid or metrics.total_us > worst.metrics.total_us) {
            insert_index = index;
            break;
        }
    }
    if (insert_index == playerDeathWorstFrameCount) return;

    var index = playerDeathWorstFrameCount - 1;
    while (index > insert_index) : (index -= 1) {
        playerDeathCapture.worst_frames[index] = playerDeathCapture.worst_frames[index - 1];
    }
    playerDeathCapture.worst_frames[insert_index] = .{
        .valid = true,
        .frame_index = frame_index,
        .metrics = metrics,
    };
}

fn reportPlayerDeathCapture() void {
    const capture = playerDeathCapture;
    const frame_count = capture.frames_recorded;
    if (frame_count == 0) {
        std.log.warn("reportPlayerDeathCapture: capture {d} has no frames", .{capture.event_id});
        return;
    }

    std.log.info(
        "perf.player_death_summary event={d} victim={d} gibbed={} frames={d} avg_frame_us={d} max_frame_us={d} over_16ms={d} over_25ms={d} over_33ms={d} avg_physics_us={d} avg_input_us={d} avg_logic_us={d} avg_render_us={d}",
        .{
            capture.event_id,
            capture.victim_id,
            capture.gibbed,
            frame_count,
            capture.frame_totals.total_us / frame_count,
            capture.max_frame_us,
            capture.over_16ms,
            capture.over_25ms,
            capture.over_33ms,
            capture.frame_totals.physics_us / frame_count,
            capture.frame_totals.input_us / frame_count,
            capture.frame_totals.logic_us / frame_count,
            capture.frame_totals.render_us / frame_count,
        },
    );
    std.log.info(
        "perf.player_death_game_loop event={d} terrain_us={d} rope_us={d} blood_contacts_us={d} blood_texture_us={d} giblet_contacts_us={d} projectile_contacts_us={d} cleanup_us={d} player_sensor_us={d} animation_camera_us={d}",
        .{
            capture.event_id,
            capture.frame_totals.game_loop.terrain_updates_us,
            capture.frame_totals.game_loop.rope_us,
            capture.frame_totals.game_loop.blood_contacts_us,
            capture.frame_totals.game_loop.blood_texture_us,
            capture.frame_totals.game_loop.giblet_contacts_us,
            capture.frame_totals.game_loop.projectile_contacts_us,
            capture.frame_totals.game_loop.cleanup_us,
            capture.frame_totals.game_loop.player_and_sensor_us,
            capture.frame_totals.game_loop.animation_and_camera_us,
        },
    );
    std.log.info(
        "perf.player_death_creation event={d} trigger_calls={d} trigger_total_us={d} initial_blood_us={d} gib_us={d} kill_us={d}",
        .{
            capture.event_id,
            capture.trigger.calls,
            capture.trigger.total_us,
            capture.trigger.blood_spawn_us,
            capture.trigger.gib_us,
            capture.trigger.kill_us,
        },
    );

    for (capture.worst_frames, 0..) |worst, rank| {
        if (!worst.valid) continue;
        const frame = worst.metrics;
        std.log.info(
            "perf.player_death_worst event={d} rank={d} frame={d} total_us={d} physics_us={d} input_us={d} logic_us={d} render_us={d} terrain_us={d} rope_us={d} blood_contacts_us={d} blood_texture_us={d} giblet_contacts_us={d} projectile_contacts_us={d} cleanup_us={d} player_sensor_us={d} animation_camera_us={d}",
            .{
                capture.event_id,
                rank + 1,
                worst.frame_index,
                frame.total_us,
                frame.physics_us,
                frame.input_us,
                frame.logic_us,
                frame.render_us,
                frame.game_loop.terrain_updates_us,
                frame.game_loop.rope_us,
                frame.game_loop.blood_contacts_us,
                frame.game_loop.blood_texture_us,
                frame.game_loop.giblet_contacts_us,
                frame.game_loop.projectile_contacts_us,
                frame.game_loop.cleanup_us,
                frame.game_loop.player_and_sensor_us,
                frame.game_loop.animation_and_camera_us,
            },
        );
    }
}

pub inline fn beginPlayerDeathCapture(victim_id: usize, gibbed: bool) bool {
    if (comptime !configured(.player_death)) return false;
    if (playerDeathCapture.active) return false;

    playerDeathEventId += 1;
    playerDeathCapture = .{
        .active = true,
        .event_id = playerDeathEventId,
        .victim_id = victim_id,
        .gibbed = gibbed,
        .frames_remaining = playerDeathCaptureFrameCount,
        .trigger = .{ .calls = 1 },
    };
    return true;
}

pub inline fn beginPlayerDeathFrame() u64 {
    if (comptime !configured(.player_death)) return 0;
    currentPlayerDeathFrameMetrics = .{};
    return sdl.getPerformanceCounter();
}

pub inline fn isCapturingPlayerDeath(victim_id: usize) bool {
    if (comptime !configured(.player_death)) return false;
    return playerDeathCapture.active and playerDeathCapture.victim_id == victim_id;
}

pub inline fn recordPlayerDeathFrameStage(comptime stage: PlayerDeathFrameStage, start: u64) void {
    if (comptime !configured(.player_death)) return;
    const elapsed_us = elapsedUs(start);
    switch (stage) {
        .physics => currentPlayerDeathFrameMetrics.physics_us = elapsed_us,
        .input => currentPlayerDeathFrameMetrics.input_us = elapsed_us,
        .logic => currentPlayerDeathFrameMetrics.logic_us = elapsed_us,
        .render => currentPlayerDeathFrameMetrics.render_us = elapsed_us,
    }
}

pub inline fn recordPlayerDeathGameLoopStage(comptime stage: PlayerDeathGameLoopStage, start: u64) void {
    if (comptime !configured(.player_death)) return;
    const elapsed_us = elapsedUs(start);
    switch (stage) {
        .terrain_updates => currentPlayerDeathFrameMetrics.game_loop.terrain_updates_us += elapsed_us,
        .rope => currentPlayerDeathFrameMetrics.game_loop.rope_us += elapsed_us,
        .blood_contacts => currentPlayerDeathFrameMetrics.game_loop.blood_contacts_us += elapsed_us,
        .blood_texture => currentPlayerDeathFrameMetrics.game_loop.blood_texture_us += elapsed_us,
        .giblet_contacts => currentPlayerDeathFrameMetrics.game_loop.giblet_contacts_us += elapsed_us,
        .projectile_contacts => currentPlayerDeathFrameMetrics.game_loop.projectile_contacts_us += elapsed_us,
        .cleanup => currentPlayerDeathFrameMetrics.game_loop.cleanup_us += elapsed_us,
        .player_and_sensor => currentPlayerDeathFrameMetrics.game_loop.player_and_sensor_us += elapsed_us,
        .animation_and_camera => currentPlayerDeathFrameMetrics.game_loop.animation_and_camera_us += elapsed_us,
    }
}

pub inline fn recordPlayerDeathTriggerStage(comptime stage: PlayerDeathTriggerStage, start: u64) void {
    if (comptime !configured(.player_death)) return;
    if (!playerDeathCapture.active) return;
    const elapsed_us = elapsedUs(start);
    switch (stage) {
        .blood_spawn => playerDeathCapture.trigger.blood_spawn_us += elapsed_us,
        .gib => playerDeathCapture.trigger.gib_us += elapsed_us,
        .kill => playerDeathCapture.trigger.kill_us += elapsed_us,
        .total => playerDeathCapture.trigger.total_us += elapsed_us,
    }
}

pub inline fn finishPlayerDeathFrame(frame_start: u64) void {
    if (comptime !configured(.player_death)) return;
    if (!playerDeathCapture.active) return;

    currentPlayerDeathFrameMetrics.total_us = elapsedUs(frame_start);
    const metrics = currentPlayerDeathFrameMetrics;
    addPlayerDeathFrameMetrics(&playerDeathCapture.frame_totals, metrics);
    playerDeathCapture.max_frame_us = @max(playerDeathCapture.max_frame_us, metrics.total_us);
    if (metrics.total_us > 16_667) playerDeathCapture.over_16ms += 1;
    if (metrics.total_us > 25_000) playerDeathCapture.over_25ms += 1;
    if (metrics.total_us > 33_333) playerDeathCapture.over_33ms += 1;
    insertPlayerDeathWorstFrame(playerDeathCapture.frames_recorded, metrics);

    playerDeathCapture.frames_recorded += 1;
    playerDeathCapture.frames_remaining -= 1;
    if (playerDeathCapture.frames_remaining > 0) return;

    playerDeathCapture.active = false;
    reportPlayerDeathCapture();
}
