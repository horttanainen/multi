const std = @import("std");
const dsp = @import("music/dsp.zig");
const instruments = @import("music/instruments.zig");
const entropy = @import("music/entropy.zig");
const procedural_americana_guitar = @import("procedural_americana_guitar.zig");
const procedural_taiko = @import("procedural_taiko.zig");
const procedural_hard_techno = @import("procedural_hard_techno.zig");
const runtime = @import("runtime.zig");

const SAMPLE_RATE_U32: u32 = 48000;
const CHANNEL_COUNT: u16 = 2;
const BYTES_PER_SAMPLE: u16 = 2;
const BYTES_PER_FRAME: u32 = CHANNEL_COUNT * BYTES_PER_SAMPLE;
const DEFAULT_OUT_PATH = "artifacts/procedural_renders/procedural_music_probe.wav";
const DEFAULT_SEED: u64 = 0xA6A1_6A01_0000_0001;

const StyleName = enum {
    americana_guitar,
    taiko,
    hard_techno,
};

const RenderConfig = struct {
    style: StyleName = .americana_guitar,
    duration_seconds: f32 = 24.0,
    out_path: []const u8 = DEFAULT_OUT_PATH,
    tempo_scale: f32 = 1.0,
    reverb_mix: f32 = 0.35,
    volume: f32 = 0.86,
    master_volume: f32 = 1.0,
    guitar_cue: procedural_americana_guitar.CuePreset = .open_road,
    taiko_cue: procedural_taiko.CuePreset = .matsuri,
    cue_style: ?StyleName = null,
    instrument_flavor: procedural_americana_guitar.InstrumentFlavor = .guitar,
    seed: u64 = DEFAULT_SEED,
    fixed_seed: bool = true,
    taiko_bus_stats: bool = false,
    taiko_isolate_kane: bool = false,
    taiko_isolate_nagado_back: bool = false,
    techno_bus: procedural_hard_techno.Bus = .mix,
    kick_drive: f32 = 2.3,
    kick_decay: f32 = 0.28,
    rumble_level: f32 = 0.52,
    percussion_level: f32 = 0.65,
    metal_voice: instruments.ElectronicAccentTone = .snare,
    techno_groove: procedural_hard_techno.Groove = .warehouse,
    techno_arrangement: procedural_hard_techno.Arrangement = .loop,
    techno_transitions: procedural_hard_techno.Transitions = .off,
    techno_lead: procedural_hard_techno.Lead = .off,
    lead_level: f32 = 0.75,
    lead_pattern: procedural_hard_techno.LeadPattern = .original,
    lead_transpose: i8 = 0,
    // Preserve earlier percussion/lead auditions unless bass is requested.
    bass_level: f32 = 0.0,
    bass_octaves: u8 = 0,
    techno_options_set: bool = false,
    instrument_set: bool = false,
};

const RenderStats = struct {
    samples: u64 = 0,
    finite_samples: u64 = 0,
    non_finite_samples: u64 = 0,
    sum_sq: f64 = 0.0,
    peak_abs: f32 = 0.0,
    sum: f64 = 0.0,
    clipped_samples: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    runtime.init(init.io);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var show_help = false;
    const cfg = parseConfig(args, &show_help) catch |err| {
        printUsage();
        return err;
    };
    if (show_help) {
        printUsage();
        return;
    }

    const total_frames = try frameCount(cfg.duration_seconds);
    _ = entropy.configureFixedSeed(cfg.fixed_seed, cfg.seed);
    applyStyleSettings(cfg);

    try ensureParentDir(cfg.out_path);
    const io_value = runtime.io();
    const file = try std.Io.Dir.cwd().createFile(io_value, cfg.out_path, .{ .truncate = true });
    defer file.close(io_value);

    try writeWavHeader(file, total_frames);
    const render_start_ms = std.Io.Clock.awake.now(io_value).toMilliseconds();
    const stats = try writeStyleFrames(file, cfg.style, total_frames, cfg.master_volume);
    const render_ms = std.Io.Clock.awake.now(io_value).toMilliseconds() - render_start_ms;

    if (stats.non_finite_samples > 0) {
        std.log.warn("procedural_music_probe: replaced {d} non-finite samples with silence", .{stats.non_finite_samples});
    }

    std.log.info(
        "procedural_music_probe: wrote {s} style={s} instrument={s} cue={s} duration_seconds={d:.3} frames={d} rms={d:.5} peak={d:.5}",
        .{
            cfg.out_path,
            styleLabel(cfg.style),
            instrumentLabel(cfg),
            cueLabel(cfg),
            cfg.duration_seconds,
            total_frames,
            renderRms(stats),
            stats.peak_abs,
        },
    );
    if (cfg.taiko_bus_stats) {
        logTaikoBusStats(cfg);
    }
    if (cfg.style == .hard_techno) {
        std.log.info("techno_render: bus={s} groove={s} arrangement={s} bpm={d:.3} kicks={d} hats_closed={d} hats_open={d} claps={d} metal={d} drive={d:.3} decay={d:.3} rumble={d:.3} percussion={d:.3} dc={d:.7} clipped={d} non_finite={d} render_ms={d}", .{
            @tagName(cfg.techno_bus),
            @tagName(cfg.techno_groove),
            @tagName(cfg.techno_arrangement),
            procedural_hard_techno.BASE_BPM * cfg.tempo_scale,
            procedural_hard_techno.kick_count,
            procedural_hard_techno.percussion_counts[0],
            procedural_hard_techno.percussion_counts[1],
            procedural_hard_techno.percussion_counts[2],
            procedural_hard_techno.percussion_counts[3],
            cfg.kick_drive,
            cfg.kick_decay,
            cfg.rumble_level,
            cfg.percussion_level,
            stats.sum / @as(f64, @floatFromInt(@max(stats.finite_samples, 1))),
            stats.clipped_samples,
            stats.non_finite_samples,
            render_ms,
        });
        std.log.info("techno_accent: voice={s}", .{@tagName(cfg.metal_voice)});
        if (cfg.techno_arrangement == .track) {
            for (procedural_hard_techno.section_frames, 0..) |entry, index| {
                const frame = entry orelse continue; // Partial renders may end before later sections.
                const section: procedural_hard_techno.TrackSection = @enumFromInt(index);
                const bar = if (index < procedural_hard_techno.track_sections.len)
                    procedural_hard_techno.track_sections[index].start_bar
                else
                    procedural_hard_techno.TRACK_BARS;
                std.log.info("techno_section: name={s} bar={d} frame={d} seconds={d:.6}", .{
                    @tagName(section), bar, frame, @as(f64, @floatFromInt(frame)) / dsp.SAMPLE_RATE,
                });
            }
        }
        std.log.info("techno_lead: tone={s} level={d:.3} notes={d}", .{
            @tagName(cfg.techno_lead), cfg.lead_level, procedural_hard_techno.lead_count,
        });
        std.log.info("techno_bass: level={d:.3} notes={d}", .{ cfg.bass_level, procedural_hard_techno.bass_count });
        if (stats.non_finite_samples > 0 or stats.clipped_samples > 0) {
            std.log.err("procedural_music_probe: invalid hard-techno output; inspect render statistics", .{});
            return error.InvalidAudioOutput;
        }
    }
}

fn parseConfig(args: []const []const u8, show_help: *bool) !RenderConfig {
    var cfg: RenderConfig = .{};
    var style_set = false;
    var duration_set = false;
    var idx: usize = 1;

    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help.* = true;
            return cfg;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            if (style_set) {
                std.log.err("procedural_music_probe: unexpected positional argument '{s}'", .{arg});
                return error.InvalidArgument;
            }
            cfg.style = try parseStyleArg(arg);
            style_set = true;
            idx += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--style")) {
            const value = try optionValue(args, idx, arg);
            cfg.style = try parseStyleArg(value);
            style_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--duration")) {
            const value = try optionValue(args, idx, arg);
            cfg.duration_seconds = try parsePositiveFloatArg("duration", value);
            duration_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            cfg.out_path = try optionValue(args, idx, arg);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tempo")) {
            const value = try optionValue(args, idx, arg);
            cfg.tempo_scale = try parseBoundedFloatArg("tempo", value, 0.35, 1.65);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reverb")) {
            const value = try optionValue(args, idx, arg);
            cfg.reverb_mix = try parseBoundedFloatArg("reverb", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--volume")) {
            const value = try optionValue(args, idx, arg);
            cfg.volume = try parseBoundedFloatArg("volume", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cue")) {
            const value = try optionValue(args, idx, arg);
            try parseCueArg(&cfg, value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--instrument")) {
            const value = try optionValue(args, idx, arg);
            cfg.instrument_flavor = try parseInstrumentFlavorArg(value);
            cfg.instrument_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            const value = try optionValue(args, idx, arg);
            cfg.seed = try parseSeedArg(value);
            cfg.fixed_seed = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--random-seed")) {
            cfg.fixed_seed = false;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--taiko-bus-stats")) {
            cfg.taiko_bus_stats = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--taiko-isolate-kane")) {
            cfg.taiko_isolate_kane = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--taiko-isolate-nagado-back")) {
            cfg.taiko_isolate_nagado_back = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--techno-bus")) {
            const value = try optionValue(args, idx, arg);
            cfg.techno_bus = std.meta.stringToEnum(procedural_hard_techno.Bus, value) orelse {
                std.log.err("procedural_music_probe: unknown techno bus '{s}' (use mix, kick, rumble, low_end, hats, clap, metal, percussion, lead, bass)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--kick-drive")) {
            cfg.kick_drive = try parseBoundedFloatArg("kick-drive", try optionValue(args, idx, arg), 1.0, 8.0);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--kick-decay")) {
            cfg.kick_decay = try parseBoundedFloatArg("kick-decay", try optionValue(args, idx, arg), 0.08, 0.8);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rumble")) {
            cfg.rumble_level = try parseBoundedFloatArg("rumble", try optionValue(args, idx, arg), 0.0, 1.0);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--groove")) {
            const value = try optionValue(args, idx, arg);
            cfg.techno_groove = std.meta.stringToEnum(procedural_hard_techno.Groove, value) orelse {
                std.log.err("procedural_music_probe: unknown groove '{s}' (use foundation, warehouse, rolling, machine)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--arrangement")) {
            const value = try optionValue(args, idx, arg);
            cfg.techno_arrangement = std.meta.stringToEnum(procedural_hard_techno.Arrangement, value) orelse {
                std.log.err("procedural_music_probe: unknown arrangement '{s}' (use loop, track)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--transitions")) {
            const value = try optionValue(args, idx, arg);
            cfg.techno_transitions = std.meta.stringToEnum(procedural_hard_techno.Transitions, value) orelse {
                std.log.err("procedural_music_probe: unknown transitions '{s}' (use off, gain, filtered)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--percussion")) {
            cfg.percussion_level = try parseBoundedFloatArg("percussion", try optionValue(args, idx, arg), 0.0, 1.0);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--metal-voice")) {
            const value = try optionValue(args, idx, arg);
            cfg.metal_voice = std.meta.stringToEnum(instruments.ElectronicAccentTone, value) orelse {
                std.log.err("procedural_music_probe: unknown metal voice '{s}' (use noise_burst, snare)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lead")) {
            const value = try optionValue(args, idx, arg);
            cfg.techno_lead = std.meta.stringToEnum(procedural_hard_techno.Lead, value) orelse {
                std.log.err("procedural_music_probe: unknown lead '{s}' (use off, razor, hollow, wide, machine, buzz, iron, corrosion, bass_synth)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lead-pattern")) {
            const value = try optionValue(args, idx, arg);
            cfg.lead_pattern = std.meta.stringToEnum(procedural_hard_techno.LeadPattern, value) orelse {
                std.log.err("procedural_music_probe: unknown lead pattern '{s}' (use original, bassline)", .{value});
                return error.InvalidArgument;
            };
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lead-transpose")) {
            const value = try optionValue(args, idx, arg);
            cfg.lead_transpose = std.fmt.parseInt(i8, value, 10) catch |err| {
                std.log.err("procedural_music_probe: invalid lead transpose '{s}': {}", .{ value, err });
                return error.InvalidArgument;
            };
            if (cfg.lead_transpose < -24 or cfg.lead_transpose > 0) {
                std.log.err("procedural_music_probe: lead transpose={d} outside supported range -24..0", .{cfg.lead_transpose});
                return error.InvalidArgument;
            }
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bass-octaves")) {
            const value = try optionValue(args, idx, arg);
            cfg.bass_octaves = std.fmt.parseInt(u8, value, 10) catch |err| {
                std.log.err("procedural_music_probe: invalid bass octaves '{s}': {}", .{ value, err });
                return error.InvalidArgument;
            };
            if (cfg.bass_octaves > 3) {
                std.log.err("procedural_music_probe: bass octaves={d} outside supported range 0..3", .{cfg.bass_octaves});
                return error.InvalidArgument;
            }
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bass-level")) {
            cfg.bass_level = try parseBoundedFloatArg("bass-level", try optionValue(args, idx, arg), 0.0, 1.0);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--master-volume")) {
            cfg.master_volume = try parseBoundedFloatArg("master-volume", try optionValue(args, idx, arg), 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lead-level")) {
            cfg.lead_level = try parseBoundedFloatArg("lead-level", try optionValue(args, idx, arg), 0.0, 1.0);
            cfg.techno_options_set = true;
            idx += 2;
            continue;
        }

        std.log.err("procedural_music_probe: unknown option '{s}'", .{arg});
        return error.InvalidArgument;
    }

    try validateRenderConfig(cfg);
    if (cfg.style == .hard_techno and cfg.techno_arrangement == .track and !duration_set) {
        // Include a second of silence after the finite arrangement to verify its end.
        cfg.duration_seconds = @as(f32, @floatFromInt(procedural_hard_techno.TRACK_BARS)) *
            4.0 * 60.0 / (procedural_hard_techno.BASE_BPM * cfg.tempo_scale) + 1.0;
    }
    return cfg;
}

fn optionValue(args: []const []const u8, option_idx: usize, option_name: []const u8) ![]const u8 {
    if (option_idx + 1 >= args.len) {
        std.log.err("procedural_music_probe: option {s} requires a value", .{option_name});
        return error.InvalidArgument;
    }
    return args[option_idx + 1];
}

fn parseStyleArg(arg: []const u8) !StyleName {
    const style = parseStyleName(arg) orelse {
        std.log.err("procedural_music_probe: unknown style '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return style;
}

fn parseStyleName(name: []const u8) ?StyleName {
    if (std.mem.eql(u8, name, "americana-guitar") or std.mem.eql(u8, name, "americana_guitar")) {
        return .americana_guitar;
    }
    if (std.mem.eql(u8, name, "taiko")) {
        return .taiko;
    }
    if (std.mem.eql(u8, name, "hard-techno") or std.mem.eql(u8, name, "hard_techno")) return .hard_techno;
    return null;
}

fn parseCueArg(cfg: *RenderConfig, arg: []const u8) !void {
    const guitar_cue = parseGuitarCueName(arg);
    if (guitar_cue != null) {
        cfg.guitar_cue = guitar_cue.?;
        cfg.cue_style = .americana_guitar;
        return;
    }

    const taiko_cue = parseTaikoCueName(arg);
    if (taiko_cue != null) {
        cfg.taiko_cue = taiko_cue.?;
        cfg.cue_style = .taiko;
        return;
    }

    std.log.err("procedural_music_probe: unknown cue '{s}'", .{arg});
    return error.InvalidArgument;
}

fn parseGuitarCueArg(arg: []const u8) !procedural_americana_guitar.CuePreset {
    const cue = parseGuitarCueName(arg) orelse {
        std.log.err("procedural_music_probe: unknown guitar cue '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return cue;
}

fn parseGuitarCueName(name: []const u8) ?procedural_americana_guitar.CuePreset {
    if (std.mem.eql(u8, name, "open-road") or std.mem.eql(u8, name, "open_road")) return .open_road;
    if (std.mem.eql(u8, name, "low-drone") or std.mem.eql(u8, name, "low_drone")) return .low_drone;
    if (std.mem.eql(u8, name, "rolling-travis") or std.mem.eql(u8, name, "rolling_travis")) return .rolling_travis;
    if (std.mem.eql(u8, name, "high-lonesome") or std.mem.eql(u8, name, "high_lonesome")) return .high_lonesome;
    return null;
}

fn parseTaikoCueArg(arg: []const u8) !procedural_taiko.CuePreset {
    const cue = parseTaikoCueName(arg) orelse {
        std.log.err("procedural_music_probe: unknown taiko cue '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return cue;
}

fn parseTaikoCueName(name: []const u8) ?procedural_taiko.CuePreset {
    if (std.mem.eql(u8, name, "matsuri")) return .matsuri;
    if (std.mem.eql(u8, name, "yatai-bayashi") or std.mem.eql(u8, name, "yatai_bayashi")) return .yatai_bayashi;
    if (std.mem.eql(u8, name, "miyake")) return .miyake;
    if (std.mem.eql(u8, name, "oroshi")) return .oroshi;
    if (std.mem.eql(u8, name, "hachijo")) return .hachijo;
    if (std.mem.eql(u8, name, "bon-odori") or std.mem.eql(u8, name, "bon_odori")) return .bon_odori;
    if (std.mem.eql(u8, name, "furi-uchi") or std.mem.eql(u8, name, "furi_uchi")) return .furi_uchi;
    return null;
}

fn parseInstrumentFlavorArg(arg: []const u8) !procedural_americana_guitar.InstrumentFlavor {
    const flavor = parseInstrumentFlavorName(arg) orelse {
        std.log.err("procedural_music_probe: unknown instrument '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return flavor;
}

fn parseInstrumentFlavorName(name: []const u8) ?procedural_americana_guitar.InstrumentFlavor {
    if (std.mem.eql(u8, name, "guitar")) return .guitar;
    if (std.mem.eql(u8, name, "electric") or std.mem.eql(u8, name, "electric-guitar") or std.mem.eql(u8, name, "electric_guitar")) return .electric;
    return null;
}

fn validateRenderConfig(cfg: RenderConfig) !void {
    if (cfg.techno_arrangement == .track and cfg.techno_groove != .warehouse) {
        std.log.err("procedural_music_probe: track mode arranges Warehouse/Machine; --groove selects loop patterns only", .{});
        return error.InvalidArgument;
    }
    if ((cfg.taiko_bus_stats or cfg.taiko_isolate_kane or cfg.taiko_isolate_nagado_back) and cfg.style != .taiko) {
        std.log.err("procedural_music_probe: taiko options require style=taiko", .{});
        return error.InvalidArgument;
    }
    if (cfg.techno_options_set and cfg.style != .hard_techno) {
        std.log.err("procedural_music_probe: techno options require style=hard-techno", .{});
        return error.InvalidArgument;
    }
    if (cfg.instrument_set and cfg.style != .americana_guitar) {
        std.log.err("procedural_music_probe: --instrument requires style=americana-guitar", .{});
        return error.InvalidArgument;
    }

    const cue_style = cfg.cue_style orelse return;
    if (cue_style == cfg.style) return;

    std.log.err("procedural_music_probe: cue={s} does not belong to style={s}", .{ cueLabelForStyle(cue_style, cfg), styleLabel(cfg.style) });
    return error.InvalidArgument;
}

fn parsePositiveFloatArg(label: []const u8, arg: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("procedural_music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed <= 0.0) {
        std.log.err("procedural_music_probe: {s} must be finite and > 0 (got {d})", .{ label, parsed });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseBoundedFloatArg(label: []const u8, arg: []const u8, min_value: f32, max_value: f32) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("procedural_music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed < min_value or parsed > max_value) {
        std.log.err("procedural_music_probe: {s}={d} outside supported range {d}..{d}", .{ label, parsed, min_value, max_value });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseSeedArg(arg: []const u8) !u64 {
    return std.fmt.parseInt(u64, arg, 0) catch |err| {
        std.log.err("procedural_music_probe: invalid seed='{s}': {}", .{ arg, err });
        return error.InvalidArgument;
    };
}

fn applyStyleSettings(cfg: RenderConfig) void {
    switch (cfg.style) {
        .hard_techno => {
            procedural_hard_techno.config = .{
                .tempo_scale = cfg.tempo_scale,
                .volume = cfg.volume,
                .kick_drive = cfg.kick_drive,
                .kick_decay = cfg.kick_decay,
                .rumble_level = cfg.rumble_level,
                .percussion_level = cfg.percussion_level,
                .metal_voice = cfg.metal_voice,
                .groove = cfg.techno_groove,
                .arrangement = cfg.techno_arrangement,
                .transitions = cfg.techno_transitions,
                .lead = cfg.techno_lead,
                .lead_level = cfg.lead_level,
                .lead_pattern = cfg.lead_pattern,
                .lead_transpose = cfg.lead_transpose,
                .bass_level = cfg.bass_level,
                .bass_octaves = cfg.bass_octaves,
                .room_mix = cfg.reverb_mix,
                .bus = cfg.techno_bus,
            };
        },
        .americana_guitar => {
            procedural_taiko.collect_bus_stats = false;
            procedural_americana_guitar.bpm = cfg.tempo_scale;
            procedural_americana_guitar.reverb_mix = cfg.reverb_mix;
            procedural_americana_guitar.guitar_vol = cfg.volume;
            procedural_americana_guitar.selected_cue = cfg.guitar_cue;
            procedural_americana_guitar.selected_instrument = cfg.instrument_flavor;
        },
        .taiko => {
            procedural_taiko.bpm = cfg.tempo_scale;
            procedural_taiko.reverb_mix = cfg.reverb_mix;
            procedural_taiko.drum_mix = cfg.volume;
            procedural_taiko.selected_cue = cfg.taiko_cue;
            procedural_taiko.collect_bus_stats = cfg.taiko_bus_stats;
            if (cfg.taiko_isolate_kane) {
                // Mute all non-kane busses so the atarigane patterns are auditable.
                // drum_mix gates odaiko+nagado; shaker_mix gates shime; slap_mix gates kane.
                procedural_taiko.drum_mix = 0.0;
                procedural_taiko.shaker_mix = 0.0;
                procedural_taiko.tone_mix = 0.0;
                procedural_taiko.slap_mix = 1.0;
            }
            if (cfg.taiko_isolate_nagado_back) {
                // Keep only V_NAGADO3 + V_NAGADO4; mute lead nagados, odaiko, shime, kane.
                procedural_taiko.voice_mute[0] = true; // V_ODAIKO
                procedural_taiko.voice_mute[1] = true; // V_NAGADO1
                procedural_taiko.voice_mute[2] = true; // V_NAGADO2
                procedural_taiko.voice_mute[5] = true; // V_SHIME1
                procedural_taiko.voice_mute[6] = true; // V_SHIME2
                procedural_taiko.voice_mute[7] = true; // V_KANE
            }
        },
    }
}

fn resetStyle(style: StyleName) void {
    switch (style) {
        .americana_guitar => procedural_americana_guitar.reset(),
        .taiko => procedural_taiko.reset(),
        .hard_techno => procedural_hard_techno.reset(),
    }
}

fn fillStyleBuffer(style: StyleName, buf: [*]f32, frames: usize) void {
    switch (style) {
        .americana_guitar => procedural_americana_guitar.fillBuffer(buf, frames),
        .taiko => procedural_taiko.fillBuffer(buf, frames),
        .hard_techno => procedural_hard_techno.fillBuffer(buf, frames),
    }
}

fn frameCount(duration_seconds: f32) !u32 {
    const max_frames = (std.math.maxInt(u32) - 36) / BYTES_PER_FRAME;
    const frame_count_float = @ceil(duration_seconds * dsp.SAMPLE_RATE);
    if (frame_count_float > @as(f32, @floatFromInt(max_frames))) {
        std.log.err("procedural_music_probe: duration={d} is too long for a PCM WAV file", .{duration_seconds});
        return error.InvalidArgument;
    }
    return @intFromFloat(frame_count_float);
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(runtime.io(), parent);
}

fn writeWavHeader(file: std.Io.File, total_frames: u32) !void {
    const data_size = total_frames * BYTES_PER_FRAME;
    const riff_size = 36 + data_size;
    const byte_rate = SAMPLE_RATE_U32 * BYTES_PER_FRAME;
    const block_align: u16 = CHANNEL_COUNT * BYTES_PER_SAMPLE;
    const bits_per_sample: u16 = BYTES_PER_SAMPLE * 8;

    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    writeU32Le(header[4..8], riff_size);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    writeU32Le(header[16..20], 16);
    writeU16Le(header[20..22], 1);
    writeU16Le(header[22..24], CHANNEL_COUNT);
    writeU32Le(header[24..28], SAMPLE_RATE_U32);
    writeU32Le(header[28..32], byte_rate);
    writeU16Le(header[32..34], block_align);
    writeU16Le(header[34..36], bits_per_sample);
    @memcpy(header[36..40], "data");
    writeU32Le(header[40..44], data_size);

    try file.writeStreamingAll(runtime.io(), &header);
}

fn writeStyleFrames(file: std.Io.File, style: StyleName, total_frames: u32, master_volume: f32) !RenderStats {
    const CHUNK_FRAMES = 1024;
    var samples: [CHUNK_FRAMES * 2]f32 = undefined;
    var bytes: [CHUNK_FRAMES * BYTES_PER_FRAME]u8 = undefined;
    var stats: RenderStats = .{};

    resetStyle(style);

    var frames_written: u32 = 0;
    while (frames_written < total_frames) {
        const remaining = total_frames - frames_written;
        const chunk_frames: u32 = @min(remaining, CHUNK_FRAMES);
        fillStyleBuffer(style, &samples, chunk_frames);

        var byte_idx: usize = 0;
        for (0..chunk_frames) |frame_idx| {
            const sample_idx = frame_idx * 2;
            const left = sanitizeSample(&stats, samples[sample_idx] * master_volume);
            const right = sanitizeSample(&stats, samples[sample_idx + 1] * master_volume);
            writeI16Le(bytes[byte_idx .. byte_idx + 2], floatToPcm16(left));
            writeI16Le(bytes[byte_idx + 2 .. byte_idx + 4], floatToPcm16(right));
            byte_idx += BYTES_PER_FRAME;
        }

        try file.writeStreamingAll(runtime.io(), bytes[0..byte_idx]);
        frames_written += chunk_frames;
    }

    return stats;
}

fn sanitizeSample(stats: *RenderStats, sample: f32) f32 {
    stats.samples += 1;
    if (!std.math.isFinite(sample)) {
        stats.non_finite_samples += 1;
        return 0.0;
    }

    stats.finite_samples += 1;
    const abs_sample = @abs(sample);
    stats.peak_abs = @max(stats.peak_abs, abs_sample);
    const sample_f64: f64 = sample;
    stats.sum_sq += sample_f64 * sample_f64;
    stats.sum += sample_f64;
    if (abs_sample > 1.0) stats.clipped_samples += 1;
    return std.math.clamp(sample, -1.0, 1.0);
}

fn floatToPcm16(sample: f32) i16 {
    const clipped = std.math.clamp(sample, -1.0, 1.0);
    return @intFromFloat(clipped * 32767.0);
}

fn renderRms(stats: RenderStats) f64 {
    if (stats.finite_samples == 0) return 0.0;
    return @sqrt(stats.sum_sq / @as(f64, @floatFromInt(stats.finite_samples)));
}

fn logTaikoBusStats(cfg: RenderConfig) void {
    const stats = procedural_taiko.getBusStats();
    std.log.info(
        "taiko_bus_stats: cue={s} samples={d} odaiko_rms={d:.5} peak={d:.5} nagado_rms={d:.5} peak={d:.5} shime_rms={d:.5} peak={d:.5} kane_rms={d:.5} peak={d:.5} dry_rms={d:.5} peak={d:.5} reverb_rms={d:.5} peak={d:.5} final_rms={d:.5} peak={d:.5}",
        .{
            taikoCueLabel(cfg.taiko_cue),
            stats.final.samples,
            procedural_taiko.meterRms(stats.odaiko),
            stats.odaiko.peak_abs,
            procedural_taiko.meterRms(stats.nagado),
            stats.nagado.peak_abs,
            procedural_taiko.meterRms(stats.shime),
            stats.shime.peak_abs,
            procedural_taiko.meterRms(stats.kane),
            stats.kane.peak_abs,
            procedural_taiko.meterRms(stats.dry),
            stats.dry.peak_abs,
            procedural_taiko.meterRms(stats.reverb),
            stats.reverb.peak_abs,
            procedural_taiko.meterRms(stats.final),
            stats.final.peak_abs,
        },
    );
}

fn writeU16Le(out: []u8, value: u16) void {
    out[0] = @intCast(value & 0x00FF);
    out[1] = @intCast((value >> 8) & 0x00FF);
}

fn writeU32Le(out: []u8, value: u32) void {
    out[0] = @intCast(value & 0x000000FF);
    out[1] = @intCast((value >> 8) & 0x000000FF);
    out[2] = @intCast((value >> 16) & 0x000000FF);
    out[3] = @intCast((value >> 24) & 0x000000FF);
}

fn writeI16Le(out: []u8, value: i16) void {
    const bits: u16 = @bitCast(value);
    writeU16Le(out, bits);
}

fn styleLabel(style: StyleName) []const u8 {
    return switch (style) {
        .americana_guitar => "americana-guitar",
        .taiko => "taiko",
        .hard_techno => "hard-techno",
    };
}

fn cueLabel(cfg: RenderConfig) []const u8 {
    return cueLabelForStyle(cfg.style, cfg);
}

fn cueLabelForStyle(style: StyleName, cfg: RenderConfig) []const u8 {
    return switch (style) {
        .americana_guitar => guitarCueLabel(cfg.guitar_cue),
        .taiko => taikoCueLabel(cfg.taiko_cue),
        .hard_techno => if (cfg.techno_arrangement == .track) "warehouse-track" else @tagName(cfg.techno_groove),
    };
}

fn guitarCueLabel(cue: procedural_americana_guitar.CuePreset) []const u8 {
    return switch (cue) {
        .open_road => "open-road",
        .low_drone => "low-drone",
        .rolling_travis => "rolling-travis",
        .high_lonesome => "high-lonesome",
    };
}

fn taikoCueLabel(cue: procedural_taiko.CuePreset) []const u8 {
    return switch (cue) {
        .matsuri => "matsuri",
        .yatai_bayashi => "yatai-bayashi",
        .miyake => "miyake",
        .oroshi => "oroshi",
        .hachijo => "hachijo",
        .bon_odori => "bon-odori",
        .furi_uchi => "furi-uchi",
    };
}

fn instrumentLabel(cfg: RenderConfig) []const u8 {
    return switch (cfg.style) {
        .americana_guitar => instrumentFlavorLabel(cfg.instrument_flavor),
        .taiko => "taiko-ensemble",
        .hard_techno => "electronic-percussion",
    };
}

fn instrumentFlavorLabel(flavor: procedural_americana_guitar.InstrumentFlavor) []const u8 {
    return switch (flavor) {
        .guitar => "guitar",
        .electric => "electric",
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zig build procedural-music-probe -- [style] [options]
        \\
        \\Styles:
        \\  americana-guitar
        \\  taiko
        \\  hard-techno        150 BPM kick, rumble and percussion grooves
        \\
        \\Options:
        \\  --duration SECONDS  default 24; track defaults to 128 bars + 1 second
        \\  --out PATH
        \\  --tempo SCALE       0.35..1.65, default 1.0
        \\  --reverb VALUE      0..1, techno rumble room / other styles' reverb
        \\  --volume VALUE      0..1, techno master / guitar level / taiko drum mix
        \\  --cue NAME          guitar: open-road, low-drone, rolling-travis, high-lonesome
        \\                      taiko: matsuri, yatai-bayashi, miyake, oroshi,
        \\                             hachijo, bon-odori, furi-uchi
        \\  --instrument NAME   guitar, electric (americana-guitar only)
        \\  --seed VALUE        decimal or 0x-prefixed fixed seed
        \\  --random-seed       use session randomness instead of fixed seed
        \\  --taiko-bus-stats   print taiko bus RMS/peak statistics
        \\  --techno-bus NAME   mix, kick, rumble, low_end, hats, clap, metal, percussion, lead, bass
        \\  --metal-voice NAME  noise_burst, snare (default)
        \\  --bass-level VALUE  0..1, default 0 (off); use 0.65 for the game bass mix
        \\  --bass-octaves N    0..3, transpose the sustained bass part (default 0)
        \\  --groove NAME       warehouse (default), rolling, machine, foundation
        \\  --arrangement NAME  loop (default), track (128 bars, Warehouse/Machine)
        \\  --transitions NAME  off (legacy default), gain, filtered (game); track only
        \\  --percussion VALUE  0..1, default 0.65 (hard-techno only)
        \\  --lead NAME         off (default), razor, hollow, wide, machine, buzz, iron, corrosion, bass_synth
        \\  --lead-pattern NAME original (default), bassline (sustained phrase)
        \\  --lead-transpose N  -24..0 semitones; -24 selects G2, default 0 (G4)
        \\  --lead-level VALUE  0..1, default 0.75 (hard-techno only)
        \\  --master-volume V    0..1, final playback gain (default 1)
        \\  --kick-drive VALUE  1..8, default 2.3 (hard-techno only)
        \\  --kick-decay SECS   0.08..0.8 to -60 dB, default 0.28 (hard-techno only)
        \\  --rumble VALUE      0..1, default 0.52 (hard-techno only)
        \\
    , .{});
}
