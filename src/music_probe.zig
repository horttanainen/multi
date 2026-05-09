const std = @import("std");
const dsp = @import("music/dsp.zig");
const guitar_probe = @import("music/guitar_probe.zig");
const instruments = @import("music/instruments.zig");

const SAMPLE_RATE_U32: u32 = 48000;
const CHANNEL_COUNT: u16 = 2;
const BYTES_PER_SAMPLE: u16 = 2;
const BYTES_PER_FRAME: u32 = CHANNEL_COUNT * BYTES_PER_SAMPLE;
const DEFAULT_OUT_PATH = "artifacts/instrument_renders/music_probe.wav";

const InstrumentName = enum {
    sine_drone,
    choir,
    guitar_modal,
    guitar_contact_pick_modal,
    guitar_modal_pluck,
    guitar_bridge_body_pluck,
    guitar_admittance_pluck,
    guitar_two_pol_modal,
    guitar_commuted,
    guitar_sms_fit,
    guitar_ks,
    guitar_waveguide_raw,
    guitar_faust_pluck,
};

const RenderConfig = struct {
    instrument: InstrumentName = .sine_drone,
    note: u8 = 52,
    frequency_hz: ?f32 = null,
    velocity: f32 = 0.8,
    duration_seconds: f32 = 1.2,
    out_path: []const u8 = DEFAULT_OUT_PATH,
    guitar_params: guitar_probe.GuitarProbeParams = .{},
};

const RenderStats = struct {
    samples: u64 = 0,
    finite_samples: u64 = 0,
    non_finite_samples: u64 = 0,
    sum_sq: f64 = 0.0,
    peak_abs: f32 = 0.0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var show_help = false;
    const cfg = parseConfig(args, &show_help) catch |err| {
        printUsage();
        return err;
    };
    if (show_help) {
        printUsage();
        return;
    }

    const frequency_hz = renderFrequency(cfg);
    const total_frames = try frameCount(cfg.duration_seconds);

    try ensureParentDir(cfg.out_path);
    const file = try std.fs.cwd().createFile(cfg.out_path, .{ .truncate = true });
    defer file.close();

    try writeWavHeader(file, total_frames);
    const stats = try writeInstrumentFrames(file, cfg, frequency_hz, total_frames);

    if (stats.non_finite_samples > 0) {
        std.log.warn("music_probe: replaced {d} non-finite samples with silence", .{stats.non_finite_samples});
    }

    std.log.info(
        "music_probe: wrote {s} instrument={s} note={d} frequency_hz={d:.3} velocity={d:.3} duration_seconds={d:.3} frames={d} rms={d:.5} peak={d:.5}",
        .{
            cfg.out_path,
            instrumentLabel(cfg.instrument),
            cfg.note,
            frequency_hz,
            cfg.velocity,
            cfg.duration_seconds,
            total_frames,
            renderRms(stats),
            stats.peak_abs,
        },
    );
}

fn parseConfig(args: []const []const u8, show_help: *bool) !RenderConfig {
    var cfg: RenderConfig = .{};
    var instrument_set = false;
    var idx: usize = 1;

    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help.* = true;
            return cfg;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            if (instrument_set) {
                std.log.err("music_probe: unexpected positional argument '{s}'", .{arg});
                return error.InvalidArgument;
            }
            cfg.instrument = try parseInstrumentArg(arg);
            instrument_set = true;
            idx += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--instrument")) {
            const value = try optionValue(args, idx, arg);
            cfg.instrument = try parseInstrumentArg(value);
            instrument_set = true;
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--note")) {
            const value = try optionValue(args, idx, arg);
            cfg.note = try parseMidiNoteArg(value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--freq") or std.mem.eql(u8, arg, "--frequency")) {
            const value = try optionValue(args, idx, arg);
            cfg.frequency_hz = try parseFrequencyArg(value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--velocity")) {
            const value = try optionValue(args, idx, arg);
            cfg.velocity = try parseUnitFloatArg("velocity", value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--duration")) {
            const value = try optionValue(args, idx, arg);
            cfg.duration_seconds = try parsePositiveFloatArg("duration", value);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            cfg.out_path = try optionValue(args, idx, arg);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pluck-position")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.pluck_position = try parseBoundedFloatArg("pluck-position", value, 0.05, 0.45);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pluck-brightness")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.pluck_brightness = try parseBoundedFloatArg("pluck-brightness", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--string-mix")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.string_mix_scale = try parseBoundedFloatArg("string-mix", value, 0.0, 6.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-mix")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.body_mix_scale = try parseBoundedFloatArg("body-mix", value, 0.0, 6.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--attack-mix")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.attack_mix_scale = try parseBoundedFloatArg("attack-mix", value, 0.0, 8.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--mute")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.mute_amount = try parseBoundedFloatArg("mute", value, 0.0, 1.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--string-decay")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.string_decay_scale = try parseBoundedFloatArg("string-decay", value, 0.25, 3.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-gain")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.body_gain_scale = try parseBoundedFloatArg("body-gain", value, 0.0, 4.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-decay")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.body_decay_scale = try parseBoundedFloatArg("body-decay", value, 0.25, 3.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-freq")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.body_freq_scale = try parseBoundedFloatArg("body-freq", value, 0.75, 1.35);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pick-noise")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.pick_noise_scale = try parseBoundedFloatArg("pick-noise", value, 0.0, 4.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--attack-gain")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.attack_gain_scale = try parseBoundedFloatArg("attack-gain", value, 0.0, 4.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--attack-decay")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.attack_decay_scale = try parseBoundedFloatArg("attack-decay", value, 0.35, 2.5);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bridge-coupling")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.bridge_coupling_scale = try parseBoundedFloatArg("bridge-coupling", value, 0.0, 4.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--inharmonicity")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.inharmonicity_scale = try parseBoundedFloatArg("inharmonicity", value, 0.0, 3.0);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--high-decay")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.high_decay_scale = try parseBoundedFloatArg("high-decay", value, 0.35, 2.5);
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output-gain")) {
            const value = try optionValue(args, idx, arg);
            cfg.guitar_params.output_gain_scale = try parseBoundedFloatArg("output-gain", value, 0.0, 8.0);
            idx += 2;
            continue;
        }

        std.log.err("music_probe: unknown option '{s}'", .{arg});
        return error.InvalidArgument;
    }

    return cfg;
}

fn optionValue(args: []const []const u8, option_idx: usize, option_name: []const u8) ![]const u8 {
    if (option_idx + 1 >= args.len) {
        std.log.err("music_probe: option {s} requires a value", .{option_name});
        return error.InvalidArgument;
    }
    return args[option_idx + 1];
}

fn parseInstrumentArg(arg: []const u8) !InstrumentName {
    const instrument = parseInstrumentName(arg) orelse {
        std.log.err("music_probe: unknown instrument '{s}'", .{arg});
        return error.InvalidArgument;
    };
    return instrument;
}

fn parseInstrumentName(name: []const u8) ?InstrumentName {
    if (std.mem.eql(u8, name, "sine") or std.mem.eql(u8, name, "sine-drone") or std.mem.eql(u8, name, "sine_drone")) {
        return .sine_drone;
    }
    if (std.mem.eql(u8, name, "choir") or std.mem.eql(u8, name, "choir-part") or std.mem.eql(u8, name, "choir_part")) {
        return .choir;
    }
    if (std.mem.eql(u8, name, "guitar-modal") or std.mem.eql(u8, name, "guitar_modal")) {
        return .guitar_modal;
    }
    if (std.mem.eql(u8, name, "guitar-contact-pick-modal") or std.mem.eql(u8, name, "guitar_contact_pick_modal")) {
        return .guitar_contact_pick_modal;
    }
    if (std.mem.eql(u8, name, "guitar-modal-pluck") or std.mem.eql(u8, name, "guitar_modal_pluck")) {
        return .guitar_modal_pluck;
    }
    if (std.mem.eql(u8, name, "guitar-bridge-body-pluck") or std.mem.eql(u8, name, "guitar_bridge_body_pluck")) {
        return .guitar_bridge_body_pluck;
    }
    if (std.mem.eql(u8, name, "guitar-admittance-pluck") or std.mem.eql(u8, name, "guitar_admittance_pluck")) {
        return .guitar_admittance_pluck;
    }
    if (std.mem.eql(u8, name, "guitar-two-pol-modal") or std.mem.eql(u8, name, "guitar_two_pol_modal")) {
        return .guitar_two_pol_modal;
    }
    if (std.mem.eql(u8, name, "guitar-commuted") or std.mem.eql(u8, name, "guitar_commuted")) {
        return .guitar_commuted;
    }
    if (std.mem.eql(u8, name, "guitar-sms-fit") or std.mem.eql(u8, name, "guitar_sms_fit")) {
        return .guitar_sms_fit;
    }
    if (std.mem.eql(u8, name, "guitar-ks") or std.mem.eql(u8, name, "guitar_ks")) {
        return .guitar_ks;
    }
    if (std.mem.eql(u8, name, "guitar-waveguide-raw") or std.mem.eql(u8, name, "guitar_waveguide_raw")) {
        return .guitar_waveguide_raw;
    }
    if (std.mem.eql(u8, name, "guitar-faust-pluck") or std.mem.eql(u8, name, "guitar_faust_pluck")) {
        return .guitar_faust_pluck;
    }
    return null;
}

fn parseMidiNoteArg(arg: []const u8) !u8 {
    const parsed = std.fmt.parseInt(u16, arg, 10) catch |err| {
        std.log.err("music_probe: invalid note='{s}': {}", .{ arg, err });
        return error.InvalidArgument;
    };
    if (parsed > 127) {
        std.log.err("music_probe: note={d} out of MIDI range 0..127", .{parsed});
        return error.InvalidArgument;
    }
    return @intCast(parsed);
}

fn parseFrequencyArg(arg: []const u8) !f32 {
    const parsed = try parsePositiveFloatArg("frequency", arg);
    if (parsed < 8.0 or parsed > 20000.0) {
        std.log.err("music_probe: frequency={d} outside supported range 8..20000 Hz", .{parsed});
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseUnitFloatArg(label: []const u8, arg: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed < 0.0) {
        std.log.err("music_probe: {s} must be finite and >= 0 (got {d})", .{ label, parsed });
        return error.InvalidArgument;
    }
    if (parsed > 1.0) {
        std.log.err("music_probe: {s}={d} must be <= 1.0", .{ label, parsed });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parsePositiveFloatArg(label: []const u8, arg: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed <= 0.0) {
        std.log.err("music_probe: {s} must be finite and > 0 (got {d})", .{ label, parsed });
        return error.InvalidArgument;
    }
    return parsed;
}

fn parseBoundedFloatArg(label: []const u8, arg: []const u8, min_value: f32, max_value: f32) !f32 {
    const parsed = std.fmt.parseFloat(f32, arg) catch |err| {
        std.log.err("music_probe: invalid {s}='{s}': {}", .{ label, arg, err });
        return error.InvalidArgument;
    };
    if (!std.math.isFinite(parsed) or parsed < min_value or parsed > max_value) {
        std.log.err("music_probe: {s}={d} outside supported range {d}..{d}", .{ label, parsed, min_value, max_value });
        return error.InvalidArgument;
    }
    return parsed;
}

fn renderFrequency(cfg: RenderConfig) f32 {
    if (cfg.frequency_hz == null) {
        return dsp.midiToFreq(cfg.note);
    }
    return cfg.frequency_hz.?;
}

fn frameCount(duration_seconds: f32) !u32 {
    const max_frames = (std.math.maxInt(u32) - 36) / BYTES_PER_FRAME;
    const frame_count_float = @ceil(duration_seconds * dsp.SAMPLE_RATE);
    if (frame_count_float > @as(f32, @floatFromInt(max_frames))) {
        std.log.err("music_probe: duration={d} is too long for a PCM WAV file", .{duration_seconds});
        return error.InvalidArgument;
    }
    return @intFromFloat(frame_count_float);
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.fs.cwd().makePath(parent);
}

fn writeWavHeader(file: std.fs.File, total_frames: u32) !void {
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

    try file.writeAll(&header);
}

fn writeInstrumentFrames(file: std.fs.File, cfg: RenderConfig, frequency_hz: f32, total_frames: u32) !RenderStats {
    const CHUNK_FRAMES = 1024;
    var bytes: [CHUNK_FRAMES * BYTES_PER_FRAME]u8 = undefined;
    var stats: RenderStats = .{};

    var sine = instruments.sineDroneInit(frequency_hz, @max(frequency_hz * 8.0, 800.0), 1.0008, 1.0, 0.12, 0.42);
    var choir = instruments.choirPartInit(0.006, 0.0, 1);
    var guitar_modal: guitar_probe.GuitarModal = .{};
    var guitar_contact_pick_modal: guitar_probe.GuitarContactPickModal = .{};
    var guitar_modal_pluck: guitar_probe.GuitarModalPluck = .{};
    var guitar_bridge_body_pluck: guitar_probe.GuitarBridgeBodyPluck = .{};
    var guitar_admittance_pluck: guitar_probe.GuitarAdmittancePluck = .{};
    var guitar_two_pol_modal: guitar_probe.GuitarTwoPolModal = .{};
    var guitar_commuted: guitar_probe.GuitarCommuted = .{};
    var guitar_sms_fit: guitar_probe.GuitarSmsFit = .{};
    var guitar_ks: guitar_probe.GuitarKs = .{};
    var guitar_waveguide_raw: guitar_probe.GuitarWaveguideRaw = .{};
    var guitar_faust_pluck: guitar_probe.GuitarFaustPluck = .{};

    switch (cfg.instrument) {
        .choir => instruments.choirPartTrigger(&choir, frequency_hz, dsp.envelopeInit(0.012, 0.28, 0.72, 0.32)),
        .guitar_modal => guitar_probe.guitarModalTriggerWithParams(&guitar_modal, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_contact_pick_modal => guitar_probe.guitarContactPickModalTriggerWithParams(&guitar_contact_pick_modal, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_modal_pluck => guitar_probe.guitarModalPluckTriggerWithParams(&guitar_modal_pluck, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_bridge_body_pluck => guitar_probe.guitarBridgeBodyPluckTriggerWithParams(&guitar_bridge_body_pluck, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_admittance_pluck => guitar_probe.guitarAdmittancePluckTriggerWithParams(&guitar_admittance_pluck, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_two_pol_modal => guitar_probe.guitarTwoPolModalTriggerWithParams(&guitar_two_pol_modal, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_commuted => guitar_probe.guitarCommutedTriggerWithParams(&guitar_commuted, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_sms_fit => guitar_probe.guitarSmsFitTriggerWithParams(&guitar_sms_fit, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_ks => guitar_probe.guitarKsTriggerWithParams(&guitar_ks, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_waveguide_raw => guitar_probe.guitarWaveguideRawTriggerWithParams(&guitar_waveguide_raw, frequency_hz, cfg.velocity, cfg.guitar_params),
        .guitar_faust_pluck => guitar_probe.guitarFaustPluckTriggerWithParams(&guitar_faust_pluck, frequency_hz, cfg.velocity, cfg.guitar_params),
        .sine_drone => {},
    }

    const choir_note_off_frame = noteOffFrame(total_frames, 0.34);
    var choir_note_off_sent = false;
    var frames_written: u32 = 0;

    while (frames_written < total_frames) {
        const remaining = total_frames - frames_written;
        const chunk_frames: u32 = @min(remaining, CHUNK_FRAMES);
        var byte_idx: usize = 0;

        for (0..chunk_frames) |chunk_idx| {
            const frame_idx = frames_written + @as(u32, @intCast(chunk_idx));
            var mono = switch (cfg.instrument) {
                .sine_drone => renderSineDroneSample(&sine, frame_idx, total_frames),
                .choir => renderChoirSample(&choir, &choir_note_off_sent, frame_idx, choir_note_off_frame),
                .guitar_modal => guitar_probe.guitarModalProcess(&guitar_modal),
                .guitar_contact_pick_modal => guitar_probe.guitarContactPickModalProcess(&guitar_contact_pick_modal),
                .guitar_modal_pluck => guitar_probe.guitarModalPluckProcess(&guitar_modal_pluck),
                .guitar_bridge_body_pluck => guitar_probe.guitarBridgeBodyPluckProcess(&guitar_bridge_body_pluck),
                .guitar_admittance_pluck => guitar_probe.guitarAdmittancePluckProcess(&guitar_admittance_pluck),
                .guitar_two_pol_modal => guitar_probe.guitarTwoPolModalProcess(&guitar_two_pol_modal),
                .guitar_commuted => guitar_probe.guitarCommutedProcess(&guitar_commuted),
                .guitar_sms_fit => guitar_probe.guitarSmsFitProcess(&guitar_sms_fit),
                .guitar_ks => guitar_probe.guitarKsProcess(&guitar_ks),
                .guitar_waveguide_raw => guitar_probe.guitarWaveguideRawProcess(&guitar_waveguide_raw),
                .guitar_faust_pluck => guitar_probe.guitarFaustPluckProcess(&guitar_faust_pluck),
            };
            if (!instrumentHandlesVelocity(cfg.instrument)) {
                mono *= cfg.velocity;
            }

            const sample = sanitizeSample(&stats, mono);
            const pcm = floatToPcm16(sample);
            writeI16Le(bytes[byte_idx .. byte_idx + 2], pcm);
            writeI16Le(bytes[byte_idx + 2 .. byte_idx + 4], pcm);
            byte_idx += BYTES_PER_FRAME;
        }

        try file.writeAll(bytes[0..byte_idx]);
        frames_written += chunk_frames;
    }

    return stats;
}

fn noteOffFrame(total_frames: u32, release_seconds: f32) u32 {
    const release_frames: u32 = @intFromFloat(@ceil(release_seconds * dsp.SAMPLE_RATE));
    if (release_frames >= total_frames) return total_frames / 2;
    return total_frames - release_frames;
}

fn renderSineDroneSample(sine: *instruments.SineDrone, frame_idx: u32, total_frames: u32) f32 {
    const edge_fade = edgeFade(frame_idx, total_frames, 0.006);
    return instruments.sineDroneProcess(sine) * edge_fade;
}

fn renderChoirSample(choir: *instruments.ChoirPart, note_off_sent: *bool, frame_idx: u32, note_off_frame: u32) f32 {
    if (!note_off_sent.* and frame_idx >= note_off_frame) {
        dsp.voiceNoteOff(3, 4, &choir.voice);
        note_off_sent.* = true;
    }
    return instruments.choirPartProcess(choir) * 0.42;
}

fn edgeFade(frame_idx: u32, total_frames: u32, fade_seconds: f32) f32 {
    const fade_frames: u32 = @max(1, @as(u32, @intFromFloat(@ceil(fade_seconds * dsp.SAMPLE_RATE))));
    const attack = std.math.clamp(@as(f32, @floatFromInt(frame_idx)) / @as(f32, @floatFromInt(fade_frames)), 0.0, 1.0);
    const frames_left = if (frame_idx + 1 >= total_frames) 0 else total_frames - frame_idx - 1;
    const release = std.math.clamp(@as(f32, @floatFromInt(frames_left)) / @as(f32, @floatFromInt(fade_frames)), 0.0, 1.0);
    return @min(attack, release);
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

fn instrumentLabel(instrument: InstrumentName) []const u8 {
    return switch (instrument) {
        .sine_drone => "sine-drone",
        .choir => "choir",
        .guitar_modal => "guitar-modal",
        .guitar_contact_pick_modal => "guitar-contact-pick-modal",
        .guitar_modal_pluck => "guitar-modal-pluck",
        .guitar_bridge_body_pluck => "guitar-bridge-body-pluck",
        .guitar_admittance_pluck => "guitar-admittance-pluck",
        .guitar_two_pol_modal => "guitar-two-pol-modal",
        .guitar_commuted => "guitar-commuted",
        .guitar_sms_fit => "guitar-sms-fit",
        .guitar_ks => "guitar-ks",
        .guitar_waveguide_raw => "guitar-waveguide-raw",
        .guitar_faust_pluck => "guitar-faust-pluck",
    };
}

fn instrumentHandlesVelocity(instrument: InstrumentName) bool {
    return switch (instrument) {
        .guitar_modal, .guitar_contact_pick_modal, .guitar_modal_pluck, .guitar_bridge_body_pluck, .guitar_admittance_pluck, .guitar_two_pol_modal, .guitar_commuted, .guitar_sms_fit, .guitar_ks, .guitar_waveguide_raw, .guitar_faust_pluck => true,
        .sine_drone, .choir => false,
    };
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  zig build music-probe -- [instrument] [options]
        \\
        \\instruments:
        \\  sine | sine-drone
        \\  choir | choir-part
        \\  guitar-modal
        \\  guitar-contact-pick-modal
        \\  guitar-modal-pluck
        \\  guitar-bridge-body-pluck
        \\  guitar-admittance-pluck
        \\  guitar-two-pol-modal
        \\  guitar-commuted
        \\  guitar-sms-fit
        \\  guitar-ks
        \\  guitar-waveguide-raw
        \\  guitar-faust-pluck
        \\
        \\options:
        \\  --instrument <name>      instrument to render
        \\  --note <midi>            MIDI note 0..127, default 52
        \\  --freq <hz>              frequency override, range 8..20000
        \\  --velocity <0..1>        output velocity, default 0.8
        \\  --duration <seconds>     output duration, default 1.2
        \\  --out <path>             output WAV path
        \\  --pluck-position <0.05..0.45>
        \\  --pluck-brightness <0..1>
        \\  --string-mix <0..6>
        \\  --body-mix <0..6>
        \\  --attack-mix <0..8>
        \\  --mute <0..1>
        \\  --string-decay <0.25..3>
        \\  --body-gain <0..4>
        \\  --body-decay <0.25..3>
        \\  --body-freq <0.75..1.35>
        \\  --pick-noise <0..4>
        \\  --attack-gain <0..4>
        \\  --attack-decay <0.35..2.5>
        \\  --bridge-coupling <0..4>
        \\  --inharmonicity <0..3>
        \\  --high-decay <0.35..2.5>
        \\  --output-gain <0..8>
        \\
        \\examples:
        \\  zig build music-probe -- sine --note 52 --velocity 0.8 --duration 1.2 --out artifacts/instrument_renders/sine_52.wav
        \\  zig build music-probe -- choir --freq 164.814 --duration 1.5 --out artifacts/instrument_renders/choir_e3.wav
        \\  zig build music-probe -- guitar-modal --freq 164.814 --velocity 0.8 --duration 0.8 --out artifacts/instrument_renders/guitar_modal_first.wav
        \\  zig build music-probe -- guitar-ks --freq 164.814 --velocity 0.8 --duration 0.8 --out artifacts/instrument_renders/guitar_ks_first.wav
        \\  zig build music-probe -- guitar-modal-pluck --freq 390.2439 --duration 0.22 --pluck-position 0.145 --body-gain 1.1 --out artifacts/instrument_renders/pluck.wav
        \\
    , .{});
}
