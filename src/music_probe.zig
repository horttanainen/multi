const std = @import("std");
const dsp = @import("music/dsp.zig");
const entropy = @import("music/entropy.zig");
const procedural_ambient = @import("procedural_ambient.zig");
const procedural_choir = @import("procedural_choir.zig");
const procedural_african_drums = @import("procedural_african_drums.zig");
const procedural_taiko = @import("procedural_taiko.zig");

const ProbeStyle = enum {
    ambient,
    choir,
    african_drums,
    taiko,
};

const ProbeConfig = struct {
    style: ProbeStyle = .taiko,
    cue_index: ?u8 = null,
    speed_x: f32 = 100.0,
    wall_seconds: f32 = 5.0,
    report_sim_seconds: f32 = 8.0,
    fixed_seed: ?u64 = null,
    transition_one: ?CueTransitionSpec = null,
    transition_two: ?CueTransitionSpec = null,
};

const ProbeStats = struct {
    samples: u64 = 0,
    finite_samples: u64 = 0,
    non_finite_samples: u64 = 0,
    sum_sq: f64 = 0.0,
    peak_abs: f32 = 0.0,
    diff_sum_sq: f64 = 0.0,
    diff_peak_abs: f32 = 0.0,
    prev_lr: [2]f32 = .{ 0.0, 0.0 },
    diff_hot_blocks: u64 = 0,
    diff_total_blocks: u64 = 0,
};

const CueTransitionSpec = struct {
    cue_index: u8,
    at_sim_seconds: f32,
};

fn parseStyle(name: []const u8) ?ProbeStyle {
    if (std.mem.eql(u8, name, "ambient")) return .ambient;
    if (std.mem.eql(u8, name, "choir")) return .choir;
    if (std.mem.eql(u8, name, "african")) return .african_drums;
    if (std.mem.eql(u8, name, "african_drums")) return .african_drums;
    if (std.mem.eql(u8, name, "taiko")) return .taiko;
    return null;
}

fn parseF32Arg(label: []const u8, arg: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    return parsed;
}

fn parseU8Arg(label: []const u8, arg: []const u8) !u8 {
    const parsed_u32 = std.fmt.parseInt(u32, arg, 10) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (parsed_u32 > 255) {
        std.log.err("music_probe: {s}={d} out of range for u8", .{ label, parsed_u32 });
        return error.InvalidArgument;
    }
    return @intCast(parsed_u32);
}

fn parseU64Arg(label: []const u8, arg: []const u8) !u64 {
    const parsed_u64 = std.fmt.parseInt(u64, arg, 10) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    return parsed_u64;
}

fn argIsUnset(arg: []const u8) bool {
    return arg.len == 0 or
        std.mem.eql(u8, arg, "-") or
        std.mem.eql(u8, arg, "none") or
        std.mem.eql(u8, arg, "null");
}

fn parseConfig(args: []const []const u8) !ProbeConfig {
    var cfg: ProbeConfig = .{};
    if (args.len <= 1) return cfg;

    const parsed_style = parseStyle(args[1]);
    if (parsed_style == null) {
        std.log.err("music_probe: unknown style '{s}'", .{args[1]});
        return error.InvalidArgument;
    }
    cfg.style = parsed_style.?;

    if (args.len > 2) {
        cfg.cue_index = try parseU8Arg("cue_index", args[2]);
    }
    if (args.len > 3) {
        cfg.speed_x = try parseF32Arg("speed_x", args[3]);
    }
    if (args.len > 4) {
        cfg.wall_seconds = try parseF32Arg("wall_seconds", args[4]);
    }
    if (args.len > 5) {
        cfg.report_sim_seconds = try parseF32Arg("report_sim_seconds", args[5]);
    }
    if (args.len > 6 and !argIsUnset(args[6])) {
        cfg.fixed_seed = try parseU64Arg("fixed_seed", args[6]);
    }

    if (args.len > 7) {
        const has_cue = args.len > 7 and !argIsUnset(args[7]);
        const has_time = args.len > 8 and !argIsUnset(args[8]);
        if (has_cue != has_time) {
            std.log.err("music_probe: transition_one requires both cue and at_seconds (args[7], args[8])", .{});
            return error.InvalidArgument;
        }
        if (has_cue and has_time) {
            cfg.transition_one = .{
                .cue_index = try parseU8Arg("transition_one_cue", args[7]),
                .at_sim_seconds = try parseF32Arg("transition_one_at_seconds", args[8]),
            };
        }
    }

    if (args.len > 9) {
        const has_cue = args.len > 9 and !argIsUnset(args[9]);
        const has_time = args.len > 10 and !argIsUnset(args[10]);
        if (has_cue != has_time) {
            std.log.err("music_probe: transition_two requires both cue and at_seconds (args[9], args[10])", .{});
            return error.InvalidArgument;
        }
        if (has_cue and has_time) {
            cfg.transition_two = .{
                .cue_index = try parseU8Arg("transition_two_cue", args[9]),
                .at_sim_seconds = try parseF32Arg("transition_two_at_seconds", args[10]),
            };
        }
    }

    if (cfg.speed_x <= 0.0) {
        std.log.err("music_probe: speed_x must be > 0 (got {d})", .{cfg.speed_x});
        return error.InvalidArgument;
    }
    if (cfg.wall_seconds <= 0.0) {
        std.log.err("music_probe: wall_seconds must be > 0 (got {d})", .{cfg.wall_seconds});
        return error.InvalidArgument;
    }
    if (cfg.report_sim_seconds <= 0.0) {
        std.log.err("music_probe: report_sim_seconds must be > 0 (got {d})", .{cfg.report_sim_seconds});
        return error.InvalidArgument;
    }
    if (cfg.transition_one) |transition| {
        if (transition.at_sim_seconds <= 0.0) {
            std.log.err("music_probe: transition_one_at_seconds must be > 0 (got {d})", .{transition.at_sim_seconds});
            return error.InvalidArgument;
        }
    }
    if (cfg.transition_two) |transition| {
        if (transition.at_sim_seconds <= 0.0) {
            std.log.err("music_probe: transition_two_at_seconds must be > 0 (got {d})", .{transition.at_sim_seconds});
            return error.InvalidArgument;
        }
    }
    if (cfg.transition_one != null and cfg.transition_two != null) {
        if (cfg.transition_two.?.at_sim_seconds <= cfg.transition_one.?.at_sim_seconds) {
            std.log.err(
                "music_probe: transition_two_at_seconds ({d}) must be > transition_one_at_seconds ({d})",
                .{ cfg.transition_two.?.at_sim_seconds, cfg.transition_one.?.at_sim_seconds },
            );
            return error.InvalidArgument;
        }
    }

    return cfg;
}

fn clampCue(cue: u8) u8 {
    return std.math.clamp(cue, 0, 3);
}

fn configureStyle(cfg: ProbeConfig) void {
    const cue = if (cfg.cue_index) |c| clampCue(c) else null;
    switch (cfg.style) {
        .ambient => {
            if (cue != null) procedural_ambient.selected_cue = @enumFromInt(cue.?);
            procedural_ambient.reset();
        },
        .choir => {
            if (cue != null) procedural_choir.selected_cue = @enumFromInt(cue.?);
            procedural_choir.reset();
        },
        .african_drums => {
            if (cue != null) procedural_african_drums.selected_cue = @enumFromInt(cue.?);
            procedural_african_drums.reset();
        },
        .taiko => {
            if (cue != null) procedural_taiko.selected_cue = @enumFromInt(cue.?);
            procedural_taiko.reset();
        },
    }
}

fn applyCue(style: ProbeStyle, cue: u8) void {
    const clamped = clampCue(cue);
    switch (style) {
        .ambient => {
            procedural_ambient.selected_cue = @enumFromInt(clamped);
            procedural_ambient.triggerCue();
        },
        .choir => {
            procedural_choir.selected_cue = @enumFromInt(clamped);
            procedural_choir.triggerCue();
        },
        .african_drums => {
            procedural_african_drums.selected_cue = @enumFromInt(clamped);
            procedural_african_drums.triggerCue();
        },
        .taiko => {
            procedural_taiko.selected_cue = @enumFromInt(clamped);
            procedural_taiko.triggerCue();
        },
    }
}

fn fillStyle(style: ProbeStyle, buf: [*]f32, frames: usize) void {
    switch (style) {
        .ambient => procedural_ambient.fillBuffer(buf, frames),
        .choir => procedural_choir.fillBuffer(buf, frames),
        .african_drums => procedural_african_drums.fillBuffer(buf, frames),
        .taiko => procedural_taiko.fillBuffer(buf, frames),
    }
}

fn logStyleSnapshot(style: ProbeStyle, sim_seconds: f64) void {
    switch (style) {
        .ambient => {
            const s = procedural_ambient.debugSnapshot();
            std.log.info(
                "probe ambient t={d:.2}s cue={d}->{d} sel={d} p={d:.2} root={d} scale={s} chord={d}/{d} arcs={d:.2}/{d:.2}/{d:.2} dir={d:.2}/{d:.2}/{d:.2} sec={d}:{d:.2}/{d}/{d} cadence={d:.2}->{d:.2} layers={d:.2},{d:.2},{d:.2},{d:.2}",
                .{
                    sim_seconds,
                    s.cue_from,
                    s.cue_to,
                    s.cue_selected,
                    s.cue_progress,
                    s.key_root,
                    @tagName(s.key_scale),
                    s.chord_index,
                    s.chord_count,
                    s.micro,
                    s.meso,
                    s.macro,
                    s.longform_intensity,
                    s.longform_cadence,
                    s.longform_modulation,
                    s.section_id,
                    s.section_progress,
                    s.section_transition_count,
                    s.section_distinct_transition_count,
                    s.chord_change_beats,
                    s.next_chord_change_beats,
                    s.drone_level,
                    s.pad_level,
                    s.melody_level,
                    s.arp_level,
                },
            );
        },
        .choir => {
            const s = procedural_choir.debugSnapshot();
            std.log.info(
                "probe choir t={d:.2}s cue={d}->{d} sel={d} p={d:.2} root={d} scale={s} chord={d}/{d} arcs={d:.2}/{d:.2}/{d:.2} dir={d:.2}/{d:.2}/{d:.2} sec={d}:{d:.2}/{d}/{d} cadence={d:.2}->{d:.2} chant_ctr={d:.2} layers={d:.2},{d:.2},{d:.2},{d:.2}",
                .{
                    sim_seconds,
                    s.cue_from,
                    s.cue_to,
                    s.cue_selected,
                    s.cue_progress,
                    s.key_root,
                    @tagName(s.key_scale),
                    s.chord_index,
                    s.chord_count,
                    s.micro,
                    s.meso,
                    s.macro,
                    s.longform_intensity,
                    s.longform_cadence,
                    s.longform_modulation,
                    s.section_id,
                    s.section_progress,
                    s.section_transition_count,
                    s.section_distinct_transition_count,
                    s.chord_change_beats,
                    s.next_chord_change_beats,
                    s.chant_beat_counter,
                    s.drone_level,
                    s.pad_level,
                    s.chant_level,
                    s.breath_level,
                },
            );
        },
        .african_drums => {
            const s = procedural_african_drums.debugSnapshot();
            std.log.info(
                "probe african t={d:.2}s cue={d}->{d} sel={d} p={d:.2} root={d} scale={s} chord={d}/{d} arcs={d:.2}/{d:.2}/{d:.2} dir={d:.2}/{d:.2}/{d:.2} sec={d}:{d:.2}/{d}/{d} cadence={d:.2}->{d:.2} step={d} lead_cycle={d} break={any}/{d}",
                .{
                    sim_seconds,
                    s.cue_from,
                    s.cue_to,
                    s.cue_selected,
                    s.cue_progress,
                    s.key_root,
                    @tagName(s.key_scale),
                    s.chord_index,
                    s.chord_count,
                    s.micro,
                    s.meso,
                    s.macro,
                    s.longform_intensity,
                    s.longform_cadence,
                    s.longform_modulation,
                    s.section_id,
                    s.section_progress,
                    s.section_transition_count,
                    s.section_distinct_transition_count,
                    s.chord_change_beats,
                    s.next_chord_change_beats,
                    s.current_step,
                    s.lead_cycle_count,
                    s.in_break,
                    s.break_remaining,
                },
            );
        },
        .taiko => {
            const s = procedural_taiko.debugSnapshot();
            std.log.info(
                "probe taiko t={d:.2}s cue={d}->{d} structural={d} sel={d} p={d:.2} root={d} scale={s} chord={d}/{d} arcs={d:.2}/{d:.2}/{d:.2} dir={d:.2}/{d:.2}/{d:.2} sec={d}:{d:.2}/{d}/{d} sec_targets={d:.2}/{d:.2}/{d:.2} cadence={d:.2}->{d:.2} step={d} lead_cycle={d} break={any} call={any}/{any}",
                .{
                    sim_seconds,
                    s.cue_from,
                    s.cue_to,
                    s.cue_structural,
                    s.cue_selected,
                    s.cue_progress,
                    s.key_root,
                    @tagName(s.key_scale),
                    s.chord_index,
                    s.chord_count,
                    s.micro,
                    s.meso,
                    s.macro,
                    s.longform_intensity,
                    s.longform_cadence,
                    s.longform_modulation,
                    s.section_id,
                    s.section_progress,
                    s.section_transition_count,
                    s.section_distinct_transition_count,
                    s.section_density,
                    s.section_harmonic_motion,
                    s.section_cadence_scale,
                    s.chord_change_beats,
                    s.next_chord_change_beats,
                    s.sequencer_step,
                    s.lead_cycle_count,
                    s.in_break,
                    s.in_call_response,
                    s.is_response_phase,
                },
            );
        },
    }
}

fn updateStats(stats: *ProbeStats, buf: []const f32) void {
    var block_sum_sq: f64 = 0.0;
    var block_diff_sum_sq: f64 = 0.0;
    var block_finite: u64 = 0;

    for (buf, 0..) |sample, idx| {
        stats.samples += 1;
        if (!std.math.isFinite(sample)) {
            stats.non_finite_samples += 1;
            continue;
        }
        stats.finite_samples += 1;
        block_finite += 1;

        const sample_f64: f64 = sample;
        stats.sum_sq += sample_f64 * sample_f64;
        block_sum_sq += sample_f64 * sample_f64;

        const abs_sample = @abs(sample);
        stats.peak_abs = @max(stats.peak_abs, abs_sample);

        const channel: usize = idx & 1;
        const diff = sample - stats.prev_lr[channel];
        stats.prev_lr[channel] = sample;
        const diff_f64: f64 = diff;
        stats.diff_sum_sq += diff_f64 * diff_f64;
        block_diff_sum_sq += diff_f64 * diff_f64;
        stats.diff_peak_abs = @max(stats.diff_peak_abs, @abs(diff));
    }

    if (block_finite == 0) return;

    const block_rms = @sqrt(block_sum_sq / @as(f64, @floatFromInt(block_finite)));
    if (block_rms <= 0.000001) return;

    const block_diff_rms = @sqrt(block_diff_sum_sq / @as(f64, @floatFromInt(block_finite)));
    stats.diff_total_blocks += 1;
    if (block_diff_rms > 0.003 and block_diff_rms / block_rms > 0.58) {
        stats.diff_hot_blocks += 1;
    }
}

fn usage() void {
    std.log.info(
        "usage: zig run src/music_probe.zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache -- [style] [cue_index] [speed_x] [wall_seconds] [report_sim_seconds] [fixed_seed|-] [transition1_cue|-] [transition1_at_seconds|-] [transition2_cue|-] [transition2_at_seconds|-]",
        .{},
    );
    std.log.info("example: zig run src/music_probe.zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache -- taiko 3 100 5 8 1337 0 60 3 120", .{});
    std.log.info("faster: zig run -O ReleaseFast src/music_probe.zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache -- taiko 3 100 5 8", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cfg = parseConfig(args) catch |err| {
        usage();
        return err;
    };

    if (cfg.fixed_seed) |fixed_seed| {
        _ = entropy.configureFixedSeed(true, fixed_seed);
    }

    configureStyle(cfg);
    std.log.info(
        "music_probe: style={s} cue={s} speed_x={d:.2} wall_seconds={d:.2} report_sim_seconds={d:.2} seed={s}",
        .{
            @tagName(cfg.style),
            if (cfg.cue_index) |_| args[2] else "default",
            cfg.speed_x,
            cfg.wall_seconds,
            cfg.report_sim_seconds,
            if (cfg.fixed_seed == null) "random" else "fixed",
        },
    );
    if (cfg.fixed_seed) |fixed_seed| {
        std.log.info("music_probe: fixed_seed={d}", .{fixed_seed});
    }
    if (cfg.transition_one) |transition| {
        std.log.info("music_probe: transition_one cue={d} at={d:.2}s", .{ transition.cue_index, transition.at_sim_seconds });
    }
    if (cfg.transition_two) |transition| {
        std.log.info("music_probe: transition_two cue={d} at={d:.2}s", .{ transition.cue_index, transition.at_sim_seconds });
    }

    const block_frames: usize = 2048;
    var buf: [block_frames * 2]f32 = undefined;
    const target_sim_seconds: f64 = @max(
        @as(f64, cfg.speed_x) * @as(f64, cfg.wall_seconds),
        @as(f64, cfg.report_sim_seconds),
    );
    var sim_seconds: f64 = 0.0;
    var next_report_seconds: f64 = @as(f64, cfg.report_sim_seconds);
    var stats: ProbeStats = .{};
    var transition_one_done = cfg.transition_one == null;
    var transition_two_done = cfg.transition_two == null;

    // Emit initial state so smoke tests can compare "start point" behavior across seeds.
    logStyleSnapshot(cfg.style, sim_seconds);

    var timer = try std.time.Timer.start();
    while (sim_seconds < target_sim_seconds) {
        if (!transition_one_done) {
            const transition = cfg.transition_one.?;
            if (sim_seconds >= @as(f64, transition.at_sim_seconds)) {
                applyCue(cfg.style, transition.cue_index);
                std.log.info(
                    "music_probe: cue_transition stage=1 cue={d} sim_t={d:.2}",
                    .{ transition.cue_index, sim_seconds },
                );
                transition_one_done = true;
            }
        }
        if (!transition_two_done) {
            const transition = cfg.transition_two.?;
            if (sim_seconds >= @as(f64, transition.at_sim_seconds)) {
                applyCue(cfg.style, transition.cue_index);
                std.log.info(
                    "music_probe: cue_transition stage=2 cue={d} sim_t={d:.2}",
                    .{ transition.cue_index, sim_seconds },
                );
                transition_two_done = true;
            }
        }

        fillStyle(cfg.style, &buf, block_frames);
        updateStats(&stats, buf[0 .. block_frames * 2]);
        sim_seconds += @as(f64, @floatFromInt(block_frames)) / @as(f64, dsp.SAMPLE_RATE);
        if (sim_seconds < next_report_seconds and sim_seconds < target_sim_seconds) continue;
        logStyleSnapshot(cfg.style, sim_seconds);
        if (stats.non_finite_samples > 0) {
            std.log.warn("music_probe: detected non-finite samples={d}", .{stats.non_finite_samples});
        }
        next_report_seconds += @as(f64, cfg.report_sim_seconds);
    }

    const wall_seconds = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_s);
    if (wall_seconds <= 0.0) {
        std.log.warn("music_probe: measured non-positive wall time, reporting with fallback", .{});
    }
    const safe_wall = @max(wall_seconds, 0.000001);
    const achieved_speed_x = sim_seconds / safe_wall;
    const rms = if (stats.finite_samples == 0)
        0.0
    else
        @sqrt(stats.sum_sq / @as(f64, @floatFromInt(stats.finite_samples)));
    const diff_rms = if (stats.finite_samples == 0)
        0.0
    else
        @sqrt(stats.diff_sum_sq / @as(f64, @floatFromInt(stats.finite_samples)));
    const hf_ratio = if (rms <= 0.000001) 0.0 else diff_rms / rms;
    const hf_hot_block_ratio = if (stats.diff_total_blocks == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.diff_hot_blocks)) / @as(f64, @floatFromInt(stats.diff_total_blocks));

    std.log.info(
        "music_probe summary: sim_seconds={d:.2} wall_seconds={d:.3} achieved_speed_x={d:.2} rms={d:.5} peak={d:.5} finite_samples={d} non_finite_samples={d} hf_ratio={d:.5} hf_peak={d:.5} hf_hot_block_ratio={d:.5}",
        .{
            sim_seconds,
            wall_seconds,
            achieved_speed_x,
            rms,
            stats.peak_abs,
            stats.finite_samples,
            stats.non_finite_samples,
            hf_ratio,
            stats.diff_peak_abs,
            hf_hot_block_ratio,
        },
    );
}
