const std = @import("std");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const state = @import("state.zig");
const minecraft_piano = @import("minecraft_piano.zig");
const procedural_80s_rock = @import("procedural_80s_rock.zig");
const procedural_choir = @import("procedural_choir.zig");

// ============================================================
// Style selection
// ============================================================

const STYLE_COUNT = 6;
var style_value: u8 = 0;

const style_names = [STYLE_COUNT][:0]const u8{
    "Style: Ambient",
    "Style: House",
    "Style: Piano",
    "Style: Choir",
    "Style: Minecraft",
    "Style: 80s Rock",
};

const MINECRAFT_CUE_COUNT = 5;
var minecraft_cue_value: u8 = 0;
const minecraft_cue_names = [MINECRAFT_CUE_COUNT][:0]const u8{
    "Cue: Washed Open",
    "Cue: Warm Suspended",
    "Cue: Bright Air",
    "Cue: Lonely Sparse",
    "Cue: Combat",
};

const ROCK80S_CUE_COUNT = 4;
var rock80s_cue_value: u8 = 0;
const rock80s_cue_names = [ROCK80S_CUE_COUNT][:0]const u8{
    "Cue: Arena",
    "Cue: Night Drive",
    "Cue: Power Ballad",
    "Cue: Combat",
};

const CHOIR_CUE_COUNT = 4;
var choir_cue_value: u8 = 0;
const choir_cue_names = [CHOIR_CUE_COUNT][:0]const u8{
    "Cue: Cathedral",
    "Cue: Procession",
    "Cue: Vigil",
    "Cue: Crusade",
};

// ============================================================
// Shared configs (all styles)
// ============================================================

// zig fmt: off
var volume_config = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var reverb_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var bpm_config    = menu.ConfigData{ .value = 0.36, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 30.0, .shader_scale = 170.0, .repeat_delay_ms = 75 };

// --- Ambient-specific ---
var amb_drone_vol_config  = menu.ConfigData{ .value = 0.6,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var amb_pad_vol_config    = menu.ConfigData{ .value = 0.53, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.15, .repeat_delay_ms = 75 };
var amb_melody_vol_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.12, .repeat_delay_ms = 75 };
var amb_arp_vol_config    = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.05, .repeat_delay_ms = 75 };

// --- House-specific ---
var house_kick_vol_config  = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.5,  .repeat_delay_ms = 75 };
var house_hihat_vol_config = menu.ConfigData{ .value = 0.48, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var house_bass_vol_config  = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.4,  .repeat_delay_ms = 75 };
var house_pad_vol_config   = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.12, .repeat_delay_ms = 75 };
var house_stab_config      = menu.ConfigData{ .value = 0.4, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// --- Piano-specific ---
var piano_note_vol_config    = menu.ConfigData{ .value = 0.48, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var piano_rest_config        = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var piano_brightness_config  = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// --- Minecraft-specific ---
var minecraft_bed_mix_config    = menu.ConfigData{ .value = 0.8,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_cloud_mix_config  = menu.ConfigData{ .value = 0.7,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_harmony_mix_config = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_bell_amount_config = menu.ConfigData{ .value = 0.45, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_hammer_mix_config  = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_cue_gap_config      = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 4.0, .shader_scale = 116.0, .repeat_delay_ms = 75 };
var minecraft_cue_length_config   = menu.ConfigData{ .value = 0.22, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 8.0, .shader_scale = 112.0, .repeat_delay_ms = 75 };
var minecraft_cue_density_config  = menu.ConfigData{ .value = 0.45, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_wow_config          = menu.ConfigData{ .value = 0.2, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_blur_config         = menu.ConfigData{ .value = 0.4, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var minecraft_attack_softness_config = menu.ConfigData{ .value = 0.35, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// --- 80s Rock-specific ---
var rock80s_lead_mix_config = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var rock80s_drive_config    = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var rock80s_drum_mix_config = menu.ConfigData{ .value = 0.8, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var rock80s_bass_mix_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var rock80s_gate_config     = menu.ConfigData{ .value = 0.45, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// --- Choir-specific ---
var choir_vol_config         = menu.ConfigData{ .value = 0.6,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var choir_breathiness_config = menu.ConfigData{ .value = 0.3,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var choir_drone_mix_config   = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var choir_chant_mix_config   = menu.ConfigData{ .value = 0.58, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
// zig fmt: on

// ============================================================
// Menu items
// ============================================================

var stored_back_fn: ?*const fn () anyerror!void = null;
const IDX_STYLE: usize = 1;

var main_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack }, .font = .medium },
    .{ .label = "Style: Ambient", .kind = .{ .button = actionCycleStyle }, .font = .medium, .cycle_names = &style_names, .cycle_index = &style_value, .on_cycle = onCycleStyle },
    .{ .label = "Tweak", .kind = .{ .button = actionOpenTweak }, .font = .medium },
    .{ .label = "Volume", .kind = .{ .config = &volume_config }, .font = .medium },
    .{ .label = "BPM", .kind = .{ .config = &bpm_config }, .font = .medium },
    .{ .label = "Reverb", .kind = .{ .config = &reverb_config }, .font = .medium },
};

// --- Ambient sub-menu ---
var ambient_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Drone Volume", .kind = .{ .config = &amb_drone_vol_config }, .font = .medium },
    .{ .label = "Pad Volume", .kind = .{ .config = &amb_pad_vol_config }, .font = .medium },
    .{ .label = "Melody Volume", .kind = .{ .config = &amb_melody_vol_config }, .font = .medium },
    .{ .label = "Arp Volume", .kind = .{ .config = &amb_arp_vol_config }, .font = .medium },
};

// --- House sub-menu ---
var house_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Kick Volume", .kind = .{ .config = &house_kick_vol_config }, .font = .medium },
    .{ .label = "Hi-hat Volume", .kind = .{ .config = &house_hihat_vol_config }, .font = .medium },
    .{ .label = "Bass Volume", .kind = .{ .config = &house_bass_vol_config }, .font = .medium },
    .{ .label = "Pad Volume", .kind = .{ .config = &house_pad_vol_config }, .font = .medium },
    .{ .label = "Stab Chance", .kind = .{ .config = &house_stab_config }, .font = .medium },
};

// --- Piano sub-menu ---
var piano_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Note Volume", .kind = .{ .config = &piano_note_vol_config }, .font = .medium },
    .{ .label = "Rest Chance", .kind = .{ .config = &piano_rest_config }, .font = .medium },
    .{ .label = "Brightness", .kind = .{ .config = &piano_brightness_config }, .font = .medium },
};

var minecraft_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerMinecraftCue }, .font = .medium },
    .{ .label = "Cue: Washed Open", .kind = .{ .button = actionCycleMinecraftCue }, .font = .medium, .cycle_names = &minecraft_cue_names, .cycle_index = &minecraft_cue_value, .on_cycle = onCycleMinecraftCue },
    .{ .label = "Note Volume", .kind = .{ .config = &piano_note_vol_config }, .font = .medium },
    .{ .label = "Rest Chance", .kind = .{ .config = &piano_rest_config }, .font = .medium },
    .{ .label = "Brightness", .kind = .{ .config = &piano_brightness_config }, .font = .medium },
    .{ .label = "Ambient Bed", .kind = .{ .config = &minecraft_bed_mix_config }, .font = .medium },
    .{ .label = "Resonance Cloud", .kind = .{ .config = &minecraft_cloud_mix_config }, .font = .medium },
    .{ .label = "Harmony Presence", .kind = .{ .config = &minecraft_harmony_mix_config }, .font = .medium },
    .{ .label = "Bell Amount", .kind = .{ .config = &minecraft_bell_amount_config }, .font = .medium },
    .{ .label = "Hammer Noise", .kind = .{ .config = &minecraft_hammer_mix_config }, .font = .medium },
    .{ .label = "Cue Density", .kind = .{ .config = &minecraft_cue_density_config }, .font = .medium },
    .{ .label = "Wow", .kind = .{ .config = &minecraft_wow_config }, .font = .medium },
    .{ .label = "Blur", .kind = .{ .config = &minecraft_blur_config }, .font = .medium },
    .{ .label = "Attack Softness", .kind = .{ .config = &minecraft_attack_softness_config }, .font = .medium },
};

var rock80s_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerRock80sCue }, .font = .medium },
    .{ .label = "Cue: Arena", .kind = .{ .button = actionCycleRock80sCue }, .font = .medium, .cycle_names = &rock80s_cue_names, .cycle_index = &rock80s_cue_value, .on_cycle = onCycleRock80sCue },
    .{ .label = "Lead Presence", .kind = .{ .config = &rock80s_lead_mix_config }, .font = .medium },
    .{ .label = "Drive", .kind = .{ .config = &rock80s_drive_config }, .font = .medium },
    .{ .label = "Drums", .kind = .{ .config = &rock80s_drum_mix_config }, .font = .medium },
    .{ .label = "Bass", .kind = .{ .config = &rock80s_bass_mix_config }, .font = .medium },
    .{ .label = "Gate", .kind = .{ .config = &rock80s_gate_config }, .font = .medium },
};

// --- Choir sub-menu ---
var choir_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerChoirCue }, .font = .medium },
    .{ .label = "Cue: Cathedral", .kind = .{ .button = actionCycleChoirCue }, .font = .medium, .cycle_names = &choir_cue_names, .cycle_index = &choir_cue_value, .on_cycle = onCycleChoirCue },
    .{ .label = "Choir Volume", .kind = .{ .config = &choir_vol_config }, .font = .medium },
    .{ .label = "Breathiness", .kind = .{ .config = &choir_breathiness_config }, .font = .medium },
    .{ .label = "Drone Presence", .kind = .{ .config = &choir_drone_mix_config }, .font = .medium },
    .{ .label = "Chant Presence", .kind = .{ .config = &choir_chant_mix_config }, .font = .medium },
};

// ============================================================
// Public API
// ============================================================

pub fn open(back_fn: ?*const fn () anyerror!void) void {
    stored_back_fn = back_fn;
    state.editingMusic = true;
    loadFromParams();
    menu.open(&main_items, .{ .minimal_edit = true, .back_fn = back_fn });
}

pub fn sync() void {
    if (!menu.isOpen()) {
        state.editingMusic = false;
        return;
    }

    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.sync: failed to apply live preview: {}", .{err});
    };
}

// ============================================================
// Internal helpers
// ============================================================

fn loadFromParams() void {
    style_value = @intFromEnum(settings.music_style);
    updateStyleLabel();

    volume_config.value = settings.music_volume;
    fromShader(&bpm_config, settings.music_bpm);
    reverb_config.value = settings.music_reverb_mix;

    switch (settings.music_style) {
        .ambient => {
            fromShader(&amb_drone_vol_config, settings.music_ambient_drone_vol);
            fromShader(&amb_pad_vol_config, settings.music_ambient_pad_vol);
            fromShader(&amb_melody_vol_config, settings.music_ambient_melody_vol);
            fromShader(&amb_arp_vol_config, settings.music_ambient_arp_vol);
        },
        .house => {
            fromShader(&house_kick_vol_config, settings.music_house_kick_vol);
            fromShader(&house_hihat_vol_config, settings.music_house_hihat_vol);
            fromShader(&house_bass_vol_config, settings.music_house_bass_vol);
            fromShader(&house_pad_vol_config, settings.music_house_pad_vol);
            house_stab_config.value = settings.music_house_stab_chance;
        },
        .piano => {
            fromShader(&piano_note_vol_config, settings.music_piano_note_vol);
            piano_rest_config.value = settings.music_piano_rest_chance;
            piano_brightness_config.value = settings.music_piano_brightness;
        },
        .choir => {
            fromShader(&choir_vol_config, settings.music_choir_vol);
            choir_breathiness_config.value = settings.music_choir_breathiness;
            choir_drone_mix_config.value = settings.music_choir_drone_mix;
            choir_chant_mix_config.value = settings.music_choir_chant_mix;
            choir_cue_value = settings.music_choir_cue;
        },
        .minecraft => {
            fromShader(&piano_note_vol_config, settings.music_piano_note_vol);
            piano_rest_config.value = settings.music_piano_rest_chance;
            piano_brightness_config.value = settings.music_piano_brightness;
            minecraft_bed_mix_config.value = settings.music_minecraft_bed_mix;
            minecraft_cloud_mix_config.value = settings.music_minecraft_cloud_mix;
            minecraft_harmony_mix_config.value = settings.music_minecraft_harmony_mix;
            minecraft_bell_amount_config.value = settings.music_minecraft_bell_amount;
            minecraft_hammer_mix_config.value = settings.music_minecraft_hammer_mix;
            minecraft_cue_value = settings.music_minecraft_cue;
            minecraft_cue_density_config.value = settings.music_minecraft_cue_density;
            minecraft_wow_config.value = settings.music_minecraft_wow;
            minecraft_blur_config.value = settings.music_minecraft_blur;
            minecraft_attack_softness_config.value = settings.music_minecraft_attack_softness;
        },
        .rock80s => {
            rock80s_cue_value = settings.music_rock80s_cue;
            rock80s_lead_mix_config.value = settings.music_rock80s_lead_mix;
            rock80s_drive_config.value = settings.music_rock80s_drive;
            rock80s_drum_mix_config.value = settings.music_rock80s_drum_mix;
            rock80s_bass_mix_config.value = settings.music_rock80s_bass_mix;
            rock80s_gate_config.value = settings.music_rock80s_gate;
        },
    }
}

fn updateStyleLabel() void {
    main_items[IDX_STYLE].label = style_names[style_value];
}

fn toShader(cfg: *const menu.ConfigData) f32 {
    return cfg.shader_offset + cfg.value * cfg.shader_scale;
}

fn fromShader(cfg: *menu.ConfigData, val: f32) void {
    if (cfg.shader_scale == 0) return;
    cfg.value = std.math.clamp((val - cfg.shader_offset) / cfg.shader_scale, 0.0, 1.0);
}

fn applyMenuToSettings(save_changes: bool) !void {
    settings.music_style = @enumFromInt(style_value);
    settings.music_volume = volume_config.value;
    settings.music_bpm = toShader(&bpm_config);
    settings.music_reverb_mix = reverb_config.value;

    switch (settings.music_style) {
        .ambient => {
            settings.music_ambient_drone_vol = toShader(&amb_drone_vol_config);
            settings.music_ambient_pad_vol = toShader(&amb_pad_vol_config);
            settings.music_ambient_melody_vol = toShader(&amb_melody_vol_config);
            settings.music_ambient_arp_vol = toShader(&amb_arp_vol_config);
        },
        .house => {
            settings.music_house_kick_vol = toShader(&house_kick_vol_config);
            settings.music_house_hihat_vol = toShader(&house_hihat_vol_config);
            settings.music_house_bass_vol = toShader(&house_bass_vol_config);
            settings.music_house_pad_vol = toShader(&house_pad_vol_config);
            settings.music_house_stab_chance = house_stab_config.value;
        },
        .piano => {
            settings.music_piano_note_vol = toShader(&piano_note_vol_config);
            settings.music_piano_rest_chance = piano_rest_config.value;
            settings.music_piano_brightness = piano_brightness_config.value;
        },
        .choir => {
            settings.music_choir_vol = toShader(&choir_vol_config);
            settings.music_choir_breathiness = choir_breathiness_config.value;
            settings.music_choir_drone_mix = choir_drone_mix_config.value;
            settings.music_choir_chant_mix = choir_chant_mix_config.value;
            settings.music_choir_cue = choir_cue_value;
        },
        .minecraft => {
            settings.music_piano_note_vol = toShader(&piano_note_vol_config);
            settings.music_piano_rest_chance = piano_rest_config.value;
            settings.music_piano_brightness = piano_brightness_config.value;
            settings.music_minecraft_bed_mix = minecraft_bed_mix_config.value;
            settings.music_minecraft_cloud_mix = minecraft_cloud_mix_config.value;
            settings.music_minecraft_harmony_mix = minecraft_harmony_mix_config.value;
            settings.music_minecraft_bell_amount = minecraft_bell_amount_config.value;
            settings.music_minecraft_hammer_mix = minecraft_hammer_mix_config.value;
            settings.music_minecraft_cue = minecraft_cue_value;
            settings.music_minecraft_cue_density = minecraft_cue_density_config.value;
            settings.music_minecraft_wow = minecraft_wow_config.value;
            settings.music_minecraft_blur = minecraft_blur_config.value;
            settings.music_minecraft_attack_softness = minecraft_attack_softness_config.value;
        },
        .rock80s => {
            settings.music_rock80s_cue = rock80s_cue_value;
            settings.music_rock80s_lead_mix = rock80s_lead_mix_config.value;
            settings.music_rock80s_drive = rock80s_drive_config.value;
            settings.music_rock80s_drum_mix = rock80s_drum_mix_config.value;
            settings.music_rock80s_bass_mix = rock80s_bass_mix_config.value;
            settings.music_rock80s_gate = rock80s_gate_config.value;
        },
    }

    settings.applyMusic();
    if (!save_changes) return;
    try settings.save();
}

// ============================================================
// Actions
// ============================================================

fn actionBack() anyerror!void {
    try applyMenuToSettings(true);
    state.editingMusic = false;
    if (stored_back_fn) |back| {
        try back();
    } else {
        menu.close();
    }
}

fn actionBackToMain() anyerror!void {
    try applyMenuToSettings(false);
    menu.open(&main_items, .{ .minimal_edit = true, .back_fn = stored_back_fn });
}

fn actionCycleStyle() anyerror!void {
    style_value = (style_value + 1) % STYLE_COUNT;
    updateStyleLabel();
    try applyMenuToSettings(false);
    loadFromParams();
}

fn onCycleStyle() void {
    updateStyleLabel();
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleStyle: failed to apply settings: {}", .{err});
        return;
    };
    loadFromParams();
}

fn actionOpenTweak() anyerror!void {
    try applyMenuToSettings(false);
    switch (settings.music_style) {
        .ambient => menu.open(&ambient_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
        .house => menu.open(&house_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
        .piano => menu.open(&piano_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
        .choir => menu.open(&choir_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
        .minecraft => menu.open(&minecraft_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
        .rock80s => menu.open(&rock80s_items, .{ .minimal_edit = true, .back_fn = actionBackToMain }),
    }
}

fn actionTriggerMinecraftCue() anyerror!void {
    try applyMenuToSettings(false);
    minecraft_piano.triggerCue();
}

fn actionCycleMinecraftCue() anyerror!void {
    minecraft_cue_value = (minecraft_cue_value + 1) % MINECRAFT_CUE_COUNT;
    try applyMenuToSettings(false);
    minecraft_piano.triggerCue();
}

fn onCycleMinecraftCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleMinecraftCue: failed to apply settings: {}", .{err});
        return;
    };
    minecraft_piano.triggerCue();
}

fn actionTriggerRock80sCue() anyerror!void {
    try applyMenuToSettings(false);
    procedural_80s_rock.triggerCue();
}

fn actionCycleRock80sCue() anyerror!void {
    rock80s_cue_value = (rock80s_cue_value + 1) % ROCK80S_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_80s_rock.triggerCue();
}

fn onCycleRock80sCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleRock80sCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_80s_rock.triggerCue();
}

fn actionTriggerChoirCue() anyerror!void {
    try applyMenuToSettings(false);
    procedural_choir.triggerCue();
}

fn actionCycleChoirCue() anyerror!void {
    choir_cue_value = (choir_cue_value + 1) % CHOIR_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_choir.triggerCue();
}

fn onCycleChoirCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleChoirCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_choir.triggerCue();
}
