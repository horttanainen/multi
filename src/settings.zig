const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const fs = @import("fs.zig");
const gpu = @import("gpu.zig");
const lut = @import("lut.zig");
const background_paint = @import("background_paint.zig");
const music = @import("music.zig");
const procedural_music = @import("procedural_music.zig");
const procedural_house = @import("procedural_house.zig");
const piano_generator = @import("piano_generator.zig");
const minecraft_piano = @import("minecraft_piano.zig");
const procedural_choir = @import("procedural_choir.zig");

const SETTINGS_PATH = "settings.json";
const DEFAULT_LUT_STRENGTH: f32 = 1.0;
const DEFAULT_MUSIC_STYLE: music.Style = .house;
const DEFAULT_MUSIC_BPM: f32 = 120.0;
const DEFAULT_MUSIC_REVERB_MIX: f32 = 0.35;
const DEFAULT_AMBIENT_DRONE_VOL: f32 = 0.15;
const DEFAULT_AMBIENT_PAD_VOL: f32 = 0.08;
const DEFAULT_AMBIENT_MELODY_VOL: f32 = 0.06;
const DEFAULT_AMBIENT_ARP_VOL: f32 = 0.025;
const DEFAULT_HOUSE_KICK_VOL: f32 = 0.25;
const DEFAULT_HOUSE_HIHAT_VOL: f32 = 0.12;
const DEFAULT_HOUSE_BASS_VOL: f32 = 0.2;
const DEFAULT_HOUSE_PAD_VOL: f32 = 0.06;
const DEFAULT_HOUSE_STAB_CHANCE: f32 = 0.4;
const DEFAULT_PIANO_NOTE_VOL: f32 = 0.12;
const DEFAULT_PIANO_REST_CHANCE: f32 = 0.5;
const DEFAULT_PIANO_BRIGHTNESS: f32 = 0.5;
const DEFAULT_MUSIC_VOLUME: f32 = 0.5;
const DEFAULT_MINECRAFT_BED_MIX: f32 = 0.8;
const DEFAULT_MINECRAFT_CLOUD_MIX: f32 = 0.7;
const DEFAULT_MINECRAFT_HARMONY_MIX: f32 = 0.55;
const DEFAULT_MINECRAFT_BELL_AMOUNT: f32 = 0.45;
const DEFAULT_MINECRAFT_HAMMER_MIX: f32 = 0.25;
const DEFAULT_CHOIR_VOL: f32 = 0.15;
const DEFAULT_CHOIR_BREATHINESS: f32 = 0.3;

const StoredSettings = struct {
    lut_strength: ?f32 = null,
    preferred_color_grading: ?[]const u8 = null,
    bg_spin_rotation: ?f32 = null,
    bg_spin_speed: ?f32 = null,
    bg_contrast: ?f32 = null,
    bg_spin_amount: ?f32 = null,
    bg_pixel_filter: ?f32 = null,
    bg_offset_x: ?f32 = null,
    bg_offset_y: ?f32 = null,
    bg_colour_1_r: ?f32 = null,
    bg_colour_1_g: ?f32 = null,
    bg_colour_1_b: ?f32 = null,
    bg_colour_2_r: ?f32 = null,
    bg_colour_2_g: ?f32 = null,
    bg_colour_2_b: ?f32 = null,
    bg_colour_3_r: ?f32 = null,
    bg_colour_3_g: ?f32 = null,
    bg_colour_3_b: ?f32 = null,
    bg_swirl_type: ?f32 = null,
    bg_noise_type: ?f32 = null,
    bg_color_mode: ?f32 = null,
    bg_offset_z: ?f32 = null,
    bg_noise_scale: ?f32 = null,
    bg_noise_octaves: ?f32 = null,
    bg_color_intensity: ?f32 = null,
    bg_swirl_segments: ?f32 = null,
    bg_swirl_count: ?f32 = null,
    bg_swirl_c1_x: ?f32 = null,
    bg_swirl_c1_y: ?f32 = null,
    bg_swirl_c2_x: ?f32 = null,
    bg_swirl_c2_y: ?f32 = null,
    bg_swirl_c3_x: ?f32 = null,
    bg_swirl_c3_y: ?f32 = null,
    bg_swirl_c4_x: ?f32 = null,
    bg_swirl_c4_y: ?f32 = null,
    bg_noise_speed: ?f32 = null,
    bg_noise_amplitude: ?f32 = null,
    bg_color_speed: ?f32 = null,
    bg_swirl_falloff: ?f32 = null,
    music_style: ?u8 = null,
    music_volume: ?f32 = null,
    music_bpm: ?f32 = null,
    music_reverb_mix: ?f32 = null,
    music_ambient_drone_vol: ?f32 = null,
    music_ambient_pad_vol: ?f32 = null,
    music_ambient_melody_vol: ?f32 = null,
    music_ambient_arp_vol: ?f32 = null,
    music_house_kick_vol: ?f32 = null,
    music_house_hihat_vol: ?f32 = null,
    music_house_bass_vol: ?f32 = null,
    music_house_pad_vol: ?f32 = null,
    music_house_stab_chance: ?f32 = null,
    music_piano_note_vol: ?f32 = null,
    music_piano_rest_chance: ?f32 = null,
    music_piano_brightness: ?f32 = null,
    music_minecraft_bed_mix: ?f32 = null,
    music_minecraft_cloud_mix: ?f32 = null,
    music_minecraft_harmony_mix: ?f32 = null,
    music_minecraft_bell_amount: ?f32 = null,
    music_minecraft_hammer_mix: ?f32 = null,
    music_choir_vol: ?f32 = null,
    music_choir_breathiness: ?f32 = null,
};

var lut_strength: f32 = DEFAULT_LUT_STRENGTH;
var preferred_color_grading: ?[]u8 = null;
var has_bg_preset: bool = false;
var bg_preset: gpu.PaintUniforms = undefined;
pub var music_style: music.Style = DEFAULT_MUSIC_STYLE;
pub var music_volume: f32 = DEFAULT_MUSIC_VOLUME;
pub var music_bpm: f32 = DEFAULT_MUSIC_BPM;
pub var music_reverb_mix: f32 = DEFAULT_MUSIC_REVERB_MIX;
pub var music_ambient_drone_vol: f32 = DEFAULT_AMBIENT_DRONE_VOL;
pub var music_ambient_pad_vol: f32 = DEFAULT_AMBIENT_PAD_VOL;
pub var music_ambient_melody_vol: f32 = DEFAULT_AMBIENT_MELODY_VOL;
pub var music_ambient_arp_vol: f32 = DEFAULT_AMBIENT_ARP_VOL;
pub var music_house_kick_vol: f32 = DEFAULT_HOUSE_KICK_VOL;
pub var music_house_hihat_vol: f32 = DEFAULT_HOUSE_HIHAT_VOL;
pub var music_house_bass_vol: f32 = DEFAULT_HOUSE_BASS_VOL;
pub var music_house_pad_vol: f32 = DEFAULT_HOUSE_PAD_VOL;
pub var music_house_stab_chance: f32 = DEFAULT_HOUSE_STAB_CHANCE;
pub var music_piano_note_vol: f32 = DEFAULT_PIANO_NOTE_VOL;
pub var music_piano_rest_chance: f32 = DEFAULT_PIANO_REST_CHANCE;
pub var music_piano_brightness: f32 = DEFAULT_PIANO_BRIGHTNESS;
pub var music_minecraft_bed_mix: f32 = DEFAULT_MINECRAFT_BED_MIX;
pub var music_minecraft_cloud_mix: f32 = DEFAULT_MINECRAFT_CLOUD_MIX;
pub var music_minecraft_harmony_mix: f32 = DEFAULT_MINECRAFT_HARMONY_MIX;
pub var music_minecraft_bell_amount: f32 = DEFAULT_MINECRAFT_BELL_AMOUNT;
pub var music_minecraft_hammer_mix: f32 = DEFAULT_MINECRAFT_HAMMER_MIX;
pub var music_choir_vol: f32 = DEFAULT_CHOIR_VOL;
pub var music_choir_breathiness: f32 = DEFAULT_CHOIR_BREATHINESS;

pub fn init() !void {
    lut_strength = DEFAULT_LUT_STRENGTH;
    freePreferredColorGrading();
    has_bg_preset = false;
    resetMusicSettings();

    var json_buf: [16384]u8 = undefined;
    const json_data = fs.readFile(SETTINGS_PATH, &json_buf) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.warn("settings.init: failed to read {s}: {}", .{ SETTINGS_PATH, err });
            return;
        },
    };

    const parsed = std.json.parseFromSlice(StoredSettings, allocator, json_data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("settings.init: failed to parse {s}: {}", .{ SETTINGS_PATH, err });
        return;
    };
    defer parsed.deinit();

    if (parsed.value.lut_strength) |strength| {
        lut_strength = std.math.clamp(strength, 0.0, 5.0);
    }

    if (parsed.value.preferred_color_grading) |name| {
        preferred_color_grading = allocator.dupe(u8, name) catch |err| {
            std.log.warn("settings.init: failed to store preferred_color_grading: {}", .{err});
            return;
        };
    }

    loadBgPreset(parsed.value);
    loadMusicSettings(parsed.value);
}

fn loadBgPreset(s: StoredSettings) void {
    const spin_rotation = s.bg_spin_rotation orelse return;
    const spin_speed = s.bg_spin_speed orelse return;
    has_bg_preset = true;
    bg_preset = .{
        .resolution = .{ 0, 0 },
        .spin_rotation = spin_rotation,
        .spin_speed = spin_speed,
        .offset = .{ s.bg_offset_x orelse 0, s.bg_offset_y orelse 0 },
        .contrast = s.bg_contrast orelse 2.0,
        .spin_amount = s.bg_spin_amount orelse 0.4,
        .pixel_filter = s.bg_pixel_filter orelse 250,
        .time = 0,
        .colour_1 = .{ s.bg_colour_1_r orelse 0.5, s.bg_colour_1_g orelse 0.3, s.bg_colour_1_b orelse 0.3 },
        .colour_2 = .{ s.bg_colour_2_r orelse 0.3, s.bg_colour_2_g orelse 0.5, s.bg_colour_2_b orelse 0.3 },
        .colour_3 = .{ s.bg_colour_3_r orelse 0.3, s.bg_colour_3_g orelse 0.3, s.bg_colour_3_b orelse 0.5 },
        .swirl_type = s.bg_swirl_type orelse 0,
        .noise_type = s.bg_noise_type orelse 0,
        .color_mode = s.bg_color_mode orelse 0,
        .offset_z = s.bg_offset_z orelse 1.0,
        .noise_scale = s.bg_noise_scale orelse 1.0,
        .noise_octaves = s.bg_noise_octaves orelse 5.0,
        .color_intensity = s.bg_color_intensity orelse 1.0,
        .swirl_segments = s.bg_swirl_segments orelse 6.0,
        .swirl_count = s.bg_swirl_count orelse 1.0,
        .swirl_center_1 = .{ s.bg_swirl_c1_x orelse 0.0, s.bg_swirl_c1_y orelse 0.0 },
        .swirl_center_2 = .{ s.bg_swirl_c2_x orelse 0.25, s.bg_swirl_c2_y orelse 0.0 },
        .swirl_center_3 = .{ s.bg_swirl_c3_x orelse -0.25, s.bg_swirl_c3_y orelse 0.2 },
        .swirl_center_4 = .{ s.bg_swirl_c4_x orelse 0.0, s.bg_swirl_c4_y orelse -0.25 },
        .noise_speed = s.bg_noise_speed orelse 0.5,
        .noise_amplitude = s.bg_noise_amplitude orelse 1.0,
        .color_speed = s.bg_color_speed orelse 0.0,
        .swirl_falloff = s.bg_swirl_falloff orelse 5.0,
    };
}

pub fn cleanup() void {
    freePreferredColorGrading();
}

pub fn lutStrength() f32 {
    return lut_strength;
}

pub fn setLutStrength(value: f32) void {
    lut_strength = std.math.clamp(value, 0.0, 5.0);
}

pub fn preferredColorGrading() ?[]const u8 {
    return preferred_color_grading;
}

pub fn setPreferredColorGrading(name: ?[]const u8) !void {
    freePreferredColorGrading();
    if (name) |value| {
        preferred_color_grading = try allocator.dupe(u8, value);
    }
}

pub fn apply() void {
    const preferred = preferredColorGrading() orelse {
        _ = lut.select(0);
        return;
    };
    if (!lut.selectByName(preferred)) {
        std.log.warn("settings.apply: preferred LUT '{s}' was not found", .{preferred});
    }
}

pub fn applyMusic() void {
    const style_changed = music.current_style != music_style;
    music.setVolume(music_volume);

    procedural_music.bpm = music_bpm;
    procedural_music.reverb_mix = music_reverb_mix;
    procedural_music.drone_vol = music_ambient_drone_vol;
    procedural_music.pad_vol = music_ambient_pad_vol;
    procedural_music.melody_vol = music_ambient_melody_vol;
    procedural_music.arp_vol = music_ambient_arp_vol;

    procedural_house.bpm = music_bpm;
    procedural_house.reverb_mix = music_reverb_mix;
    procedural_house.kick_vol = music_house_kick_vol;
    procedural_house.hihat_vol = music_house_hihat_vol;
    procedural_house.bass_vol = music_house_bass_vol;
    procedural_house.pad_vol = music_house_pad_vol;
    procedural_house.stab_chance = music_house_stab_chance;

    piano_generator.bpm = music_bpm;
    piano_generator.reverb_mix = music_reverb_mix;
    piano_generator.note_vol = music_piano_note_vol;
    piano_generator.rest_chance = music_piano_rest_chance;
    piano_generator.brightness = music_piano_brightness;

    minecraft_piano.bpm = music_bpm;
    minecraft_piano.reverb_mix = music_reverb_mix;
    minecraft_piano.note_vol = music_piano_note_vol;
    minecraft_piano.rest_chance = music_piano_rest_chance;
    minecraft_piano.brightness = music_piano_brightness;
    minecraft_piano.bed_mix = music_minecraft_bed_mix;
    minecraft_piano.cloud_mix = music_minecraft_cloud_mix;
    minecraft_piano.harmony_mix = music_minecraft_harmony_mix;
    minecraft_piano.bell_amount = music_minecraft_bell_amount;
    minecraft_piano.hammer_mix = music_minecraft_hammer_mix;

    procedural_choir.bpm = music_bpm;
    procedural_choir.reverb_mix = music_reverb_mix;
    procedural_choir.choir_vol = music_choir_vol;
    procedural_choir.breathiness = music_choir_breathiness;

    if (!style_changed) return;
    music.playStyle(music_style);
}

pub fn applyBackgroundPreset() void {
    if (!has_bg_preset) return;
    const prev_res = background_paint.uniforms.resolution;
    const prev_time = background_paint.uniforms.time;
    background_paint.uniforms = bg_preset;
    background_paint.uniforms.resolution = prev_res;
    background_paint.uniforms.time = prev_time;
    std.log.info("settings: applied saved background preset", .{});
}

pub fn saveBackgroundPreset(u: gpu.PaintUniforms) !void {
    has_bg_preset = true;
    bg_preset = u;
    try save();
}

pub fn save() !void {
    var buf: [4096]u8 = undefined;
    var stored = StoredSettings{
        .lut_strength = lut_strength,
        .preferred_color_grading = if (preferred_color_grading) |p| @as(?[]const u8, p) else null,
        .music_style = @intFromEnum(music_style),
        .music_volume = music_volume,
        .music_bpm = music_bpm,
        .music_reverb_mix = music_reverb_mix,
        .music_ambient_drone_vol = music_ambient_drone_vol,
        .music_ambient_pad_vol = music_ambient_pad_vol,
        .music_ambient_melody_vol = music_ambient_melody_vol,
        .music_ambient_arp_vol = music_ambient_arp_vol,
        .music_house_kick_vol = music_house_kick_vol,
        .music_house_hihat_vol = music_house_hihat_vol,
        .music_house_bass_vol = music_house_bass_vol,
        .music_house_pad_vol = music_house_pad_vol,
        .music_house_stab_chance = music_house_stab_chance,
        .music_piano_note_vol = music_piano_note_vol,
        .music_piano_rest_chance = music_piano_rest_chance,
        .music_piano_brightness = music_piano_brightness,
        .music_minecraft_bed_mix = music_minecraft_bed_mix,
        .music_minecraft_cloud_mix = music_minecraft_cloud_mix,
        .music_minecraft_harmony_mix = music_minecraft_harmony_mix,
        .music_minecraft_bell_amount = music_minecraft_bell_amount,
        .music_minecraft_hammer_mix = music_minecraft_hammer_mix,
        .music_choir_vol = music_choir_vol,
        .music_choir_breathiness = music_choir_breathiness,
    };

    if (has_bg_preset) {
        stored.bg_spin_rotation = bg_preset.spin_rotation;
        stored.bg_spin_speed = bg_preset.spin_speed;
        stored.bg_contrast = bg_preset.contrast;
        stored.bg_spin_amount = bg_preset.spin_amount;
        stored.bg_pixel_filter = bg_preset.pixel_filter;
        stored.bg_offset_x = bg_preset.offset[0];
        stored.bg_offset_y = bg_preset.offset[1];
        stored.bg_colour_1_r = bg_preset.colour_1[0];
        stored.bg_colour_1_g = bg_preset.colour_1[1];
        stored.bg_colour_1_b = bg_preset.colour_1[2];
        stored.bg_colour_2_r = bg_preset.colour_2[0];
        stored.bg_colour_2_g = bg_preset.colour_2[1];
        stored.bg_colour_2_b = bg_preset.colour_2[2];
        stored.bg_colour_3_r = bg_preset.colour_3[0];
        stored.bg_colour_3_g = bg_preset.colour_3[1];
        stored.bg_colour_3_b = bg_preset.colour_3[2];
        stored.bg_swirl_type = bg_preset.swirl_type;
        stored.bg_noise_type = bg_preset.noise_type;
        stored.bg_color_mode = bg_preset.color_mode;
        stored.bg_offset_z = bg_preset.offset_z;
        stored.bg_noise_scale = bg_preset.noise_scale;
        stored.bg_noise_octaves = bg_preset.noise_octaves;
        stored.bg_color_intensity = bg_preset.color_intensity;
        stored.bg_swirl_segments = bg_preset.swirl_segments;
        stored.bg_swirl_count = bg_preset.swirl_count;
        stored.bg_swirl_c1_x = bg_preset.swirl_center_1[0];
        stored.bg_swirl_c1_y = bg_preset.swirl_center_1[1];
        stored.bg_swirl_c2_x = bg_preset.swirl_center_2[0];
        stored.bg_swirl_c2_y = bg_preset.swirl_center_2[1];
        stored.bg_swirl_c3_x = bg_preset.swirl_center_3[0];
        stored.bg_swirl_c3_y = bg_preset.swirl_center_3[1];
        stored.bg_swirl_c4_x = bg_preset.swirl_center_4[0];
        stored.bg_swirl_c4_y = bg_preset.swirl_center_4[1];
        stored.bg_noise_speed = bg_preset.noise_speed;
        stored.bg_noise_amplitude = bg_preset.noise_amplitude;
        stored.bg_color_speed = bg_preset.color_speed;
        stored.bg_swirl_falloff = bg_preset.swirl_falloff;
    }

    const contents = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(stored, .{ .whitespace = .indent_2 })}) catch |err| {
        std.log.warn("settings.save: failed to serialize: {}", .{err});
        return err;
    };
    fs.writeFile(SETTINGS_PATH, contents) catch |err| {
        std.log.warn("settings.save: failed to write {s}: {}", .{ SETTINGS_PATH, err });
        return err;
    };
}

fn freePreferredColorGrading() void {
    if (preferred_color_grading) |name| {
        allocator.free(name);
        preferred_color_grading = null;
    }
}

fn resetMusicSettings() void {
    music_style = DEFAULT_MUSIC_STYLE;
    music_volume = DEFAULT_MUSIC_VOLUME;
    music_bpm = DEFAULT_MUSIC_BPM;
    music_reverb_mix = DEFAULT_MUSIC_REVERB_MIX;
    music_ambient_drone_vol = DEFAULT_AMBIENT_DRONE_VOL;
    music_ambient_pad_vol = DEFAULT_AMBIENT_PAD_VOL;
    music_ambient_melody_vol = DEFAULT_AMBIENT_MELODY_VOL;
    music_ambient_arp_vol = DEFAULT_AMBIENT_ARP_VOL;
    music_house_kick_vol = DEFAULT_HOUSE_KICK_VOL;
    music_house_hihat_vol = DEFAULT_HOUSE_HIHAT_VOL;
    music_house_bass_vol = DEFAULT_HOUSE_BASS_VOL;
    music_house_pad_vol = DEFAULT_HOUSE_PAD_VOL;
    music_house_stab_chance = DEFAULT_HOUSE_STAB_CHANCE;
    music_piano_note_vol = DEFAULT_PIANO_NOTE_VOL;
    music_piano_rest_chance = DEFAULT_PIANO_REST_CHANCE;
    music_piano_brightness = DEFAULT_PIANO_BRIGHTNESS;
    music_minecraft_bed_mix = DEFAULT_MINECRAFT_BED_MIX;
    music_minecraft_cloud_mix = DEFAULT_MINECRAFT_CLOUD_MIX;
    music_minecraft_harmony_mix = DEFAULT_MINECRAFT_HARMONY_MIX;
    music_minecraft_bell_amount = DEFAULT_MINECRAFT_BELL_AMOUNT;
    music_minecraft_hammer_mix = DEFAULT_MINECRAFT_HAMMER_MIX;
    music_choir_vol = DEFAULT_CHOIR_VOL;
    music_choir_breathiness = DEFAULT_CHOIR_BREATHINESS;
}

fn loadMusicSettings(s: StoredSettings) void {
    if (s.music_style) |style_int| {
        if (style_int < 5) {
            music_style = @enumFromInt(style_int);
        }
    }

    music_volume = std.math.clamp(s.music_volume orelse DEFAULT_MUSIC_VOLUME, 0.0, 1.0);
    music_bpm = std.math.clamp(s.music_bpm orelse DEFAULT_MUSIC_BPM, 30.0, 200.0);
    music_reverb_mix = std.math.clamp(s.music_reverb_mix orelse DEFAULT_MUSIC_REVERB_MIX, 0.0, 1.0);
    music_ambient_drone_vol = std.math.clamp(s.music_ambient_drone_vol orelse DEFAULT_AMBIENT_DRONE_VOL, 0.0, 1.0);
    music_ambient_pad_vol = std.math.clamp(s.music_ambient_pad_vol orelse DEFAULT_AMBIENT_PAD_VOL, 0.0, 1.0);
    music_ambient_melody_vol = std.math.clamp(s.music_ambient_melody_vol orelse DEFAULT_AMBIENT_MELODY_VOL, 0.0, 1.0);
    music_ambient_arp_vol = std.math.clamp(s.music_ambient_arp_vol orelse DEFAULT_AMBIENT_ARP_VOL, 0.0, 1.0);
    music_house_kick_vol = std.math.clamp(s.music_house_kick_vol orelse DEFAULT_HOUSE_KICK_VOL, 0.0, 1.0);
    music_house_hihat_vol = std.math.clamp(s.music_house_hihat_vol orelse DEFAULT_HOUSE_HIHAT_VOL, 0.0, 1.0);
    music_house_bass_vol = std.math.clamp(s.music_house_bass_vol orelse DEFAULT_HOUSE_BASS_VOL, 0.0, 1.0);
    music_house_pad_vol = std.math.clamp(s.music_house_pad_vol orelse DEFAULT_HOUSE_PAD_VOL, 0.0, 1.0);
    music_house_stab_chance = std.math.clamp(s.music_house_stab_chance orelse DEFAULT_HOUSE_STAB_CHANCE, 0.0, 1.0);
    music_piano_note_vol = std.math.clamp(s.music_piano_note_vol orelse DEFAULT_PIANO_NOTE_VOL, 0.0, 1.0);
    music_piano_rest_chance = std.math.clamp(s.music_piano_rest_chance orelse DEFAULT_PIANO_REST_CHANCE, 0.0, 1.0);
    music_piano_brightness = std.math.clamp(s.music_piano_brightness orelse DEFAULT_PIANO_BRIGHTNESS, 0.0, 1.0);
    music_minecraft_bed_mix = std.math.clamp(s.music_minecraft_bed_mix orelse DEFAULT_MINECRAFT_BED_MIX, 0.0, 1.0);
    music_minecraft_cloud_mix = std.math.clamp(s.music_minecraft_cloud_mix orelse DEFAULT_MINECRAFT_CLOUD_MIX, 0.0, 1.0);
    music_minecraft_harmony_mix = std.math.clamp(s.music_minecraft_harmony_mix orelse DEFAULT_MINECRAFT_HARMONY_MIX, 0.0, 1.0);
    music_minecraft_bell_amount = std.math.clamp(s.music_minecraft_bell_amount orelse DEFAULT_MINECRAFT_BELL_AMOUNT, 0.0, 1.0);
    music_minecraft_hammer_mix = std.math.clamp(s.music_minecraft_hammer_mix orelse DEFAULT_MINECRAFT_HAMMER_MIX, 0.0, 1.0);
    music_choir_vol = std.math.clamp(s.music_choir_vol orelse DEFAULT_CHOIR_VOL, 0.0, 1.0);
    music_choir_breathiness = std.math.clamp(s.music_choir_breathiness orelse DEFAULT_CHOIR_BREATHINESS, 0.0, 1.0);
}
