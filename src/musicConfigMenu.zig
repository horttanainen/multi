const std = @import("std");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const state = @import("state.zig");
const music = @import("music.zig");
const procedural_choir = @import("procedural_choir.zig");
const procedural_ambient = @import("procedural_ambient.zig");
const procedural_african_drums = @import("procedural_african_drums.zig");
const procedural_taiko = @import("procedural_taiko.zig");
const procedural_americana_guitar = @import("procedural_americana_guitar.zig");

// ============================================================
// Style selection
// ============================================================

const style_targets = [_]music.Style{
    .ambient,
    .choir,
    .african_drums,
    .taiko,
    .americana_guitar,
};
const STYLE_COUNT = style_targets.len;
var style_value: u8 = 0;

const style_names = [STYLE_COUNT][:0]const u8{
    "Style: Ambient",
    "Style: Choir",
    "Style: African Drums",
    "Style: Taiko",
    "Style: Americana Guitar",
};

const AMBIENT_CUE_COUNT = 4;
var ambient_cue_value: u8 = 0;
const ambient_cue_names = [AMBIENT_CUE_COUNT][:0]const u8{
    "Cue: Dawn",
    "Cue: Twilight",
    "Cue: Space",
    "Cue: Forest",
};

const CHOIR_CUE_COUNT = 4;
var choir_cue_value: u8 = 0;
const choir_cue_names = [CHOIR_CUE_COUNT][:0]const u8{
    "Cue: Cathedral",
    "Cue: Procession",
    "Cue: Vigil",
    "Cue: Crusade",
};

const AFRICAN_CUE_COUNT = 4;
var african_cue_value: u8 = 0;
const african_cue_names = [AFRICAN_CUE_COUNT][:0]const u8{
    "Cue: Kuku",
    "Cue: Djole",
    "Cue: Fanga",
    "Cue: Soli",
};
const TAIKO_CUE_COUNT = 4;
var taiko_cue_value: u8 = 0;
const taiko_cue_names = [TAIKO_CUE_COUNT][:0]const u8{
    "Cue: Matsuri",
    "Cue: Yatai-bayashi",
    "Cue: Miyake",
    "Cue: Oroshi",
};
const AMERICANA_GUITAR_CUE_COUNT = 4;
var americana_guitar_cue_value: u8 = 0;
const americana_guitar_cue_names = [AMERICANA_GUITAR_CUE_COUNT][:0]const u8{
    "Cue: Open Road",
    "Cue: Low Drone",
    "Cue: Rolling Travis",
    "Cue: High Lonesome",
};

// ============================================================
// Shared configs (all styles)
// ============================================================

// zig fmt: off
var volume_config = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var reverb_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var bpm_config    = menu.ConfigData{ .value = 1.0, .step = 0.01, .min = 0, .max = 2.0, .repeat_delay_ms = 75 };

// --- Ambient-specific ---
var amb_drone_vol_config  = menu.ConfigData{ .value = 0.6,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var amb_pad_vol_config    = menu.ConfigData{ .value = 0.53, .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.15, .repeat_delay_ms = 75 };
var amb_melody_vol_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.12, .repeat_delay_ms = 75 };
var amb_arp_vol_config    = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.05, .repeat_delay_ms = 75 };

// --- Choir-specific ---
var choir_vol_config         = menu.ConfigData{ .value = 0.6,  .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0, .shader_scale = 0.25, .repeat_delay_ms = 75 };
var choir_breathiness_config = menu.ConfigData{ .value = 0.3,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var choir_drone_mix_config   = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var choir_chant_mix_config   = menu.ConfigData{ .value = 0.58, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var african_drum_mix_config   = menu.ConfigData{ .value = 0.9,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var african_shaker_mix_config = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var african_tone_mix_config   = menu.ConfigData{ .value = 0.62, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var african_slap_mix_config   = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// --- Taiko-specific ---
var taiko_drum_mix_config   = menu.ConfigData{ .value = 0.9,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var taiko_shime_mix_config  = menu.ConfigData{ .value = 0.55, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var taiko_nagado_mix_config = menu.ConfigData{ .value = 0.65, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var taiko_kane_mix_config   = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
// zig fmt: on

// ============================================================
// Menu items
// ============================================================

const IDX_STYLE: usize = 1;

var main_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack }, .font = .medium },
    .{ .label = "Style: Ambient", .kind = .{ .button = actionCycleStyle }, .font = .medium, .cycle_names = &style_names, .cycle_index = &style_value, .on_cycle = onCycleStyle },
    .{ .label = "Tweak", .kind = .{ .button = actionOpenTweak }, .font = .medium },
    .{ .label = "Volume", .kind = .{ .config = &volume_config }, .font = .medium },
    .{ .label = "Tempo Scale", .kind = .{ .config = &bpm_config }, .font = .medium },
    .{ .label = "Reverb", .kind = .{ .config = &reverb_config }, .font = .medium },
};

// --- Ambient sub-menu ---
var ambient_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Cue: Dawn", .kind = .{ .button = actionCycleAmbientCue }, .font = .medium, .cycle_names = &ambient_cue_names, .cycle_index = &ambient_cue_value, .on_cycle = onCycleAmbientCue },
    .{ .label = "Drone Volume", .kind = .{ .config = &amb_drone_vol_config }, .font = .medium },
    .{ .label = "Pad Volume", .kind = .{ .config = &amb_pad_vol_config }, .font = .medium },
    .{ .label = "Melody Volume", .kind = .{ .config = &amb_melody_vol_config }, .font = .medium },
    .{ .label = "Arp Volume", .kind = .{ .config = &amb_arp_vol_config }, .font = .medium },
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

var african_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerAfricanCue }, .font = .medium },
    .{ .label = "Cue: Kuku", .kind = .{ .button = actionCycleAfricanCue }, .font = .medium, .cycle_names = &african_cue_names, .cycle_index = &african_cue_value, .on_cycle = onCycleAfricanCue },
    .{ .label = "Drum Presence", .kind = .{ .config = &african_drum_mix_config }, .font = .medium },
    .{ .label = "Shaker Presence", .kind = .{ .config = &african_shaker_mix_config }, .font = .medium },
    .{ .label = "Tone Drum", .kind = .{ .config = &african_tone_mix_config }, .font = .medium },
    .{ .label = "Slap Drum", .kind = .{ .config = &african_slap_mix_config }, .font = .medium },
};

var taiko_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerTaikoCue }, .font = .medium },
    .{ .label = "Cue: Matsuri", .kind = .{ .button = actionCycleTaikoCue }, .font = .medium, .cycle_names = &taiko_cue_names, .cycle_index = &taiko_cue_value, .on_cycle = onCycleTaikoCue },
    .{ .label = "Drum Presence", .kind = .{ .config = &taiko_drum_mix_config }, .font = .medium },
    .{ .label = "Shime Volume", .kind = .{ .config = &taiko_shime_mix_config }, .font = .medium },
    .{ .label = "Nagado Volume", .kind = .{ .config = &taiko_nagado_mix_config }, .font = .medium },
    .{ .label = "Atarigane Volume", .kind = .{ .config = &taiko_kane_mix_config }, .font = .medium },
};

var americana_guitar_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Trigger Cue", .kind = .{ .button = actionTriggerAmericanaGuitarCue }, .font = .medium },
    .{ .label = "Cue: Open Road", .kind = .{ .button = actionCycleAmericanaGuitarCue }, .font = .medium, .cycle_names = &americana_guitar_cue_names, .cycle_index = &americana_guitar_cue_value, .on_cycle = onCycleAmericanaGuitarCue },
};

// ============================================================
// Public API
// ============================================================

pub fn open(back_fn: ?*const fn () anyerror!void) void {
    openImpl(back_fn, .replace);
}

pub fn push() void {
    openImpl(null, .push);
}

const OpenMode = enum { replace, push };

fn openImpl(back_fn: ?*const fn () anyerror!void, mode: OpenMode) void {
    state.editingMusic = true;
    loadFromParams();
    const options = menu.OpenOptions{
        .minimal_edit = true,
        .back_fn = back_fn,
    };
    switch (mode) {
        .replace => menu.open(&main_items, options),
        .push => menu.push(&main_items, options),
    }
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
    style_value = styleToCycleIndex(settings.music_style);
    updateStyleLabel();

    volume_config.value = settings.music_volume;
    fromShader(&bpm_config, settings.music_bpm);
    reverb_config.value = settings.music_reverb_mix;

    switch (settings.music_style) {
        .ambient => {
            ambient_cue_value = settings.music_ambient_cue;
            fromShader(&amb_drone_vol_config, settings.music_ambient_drone_vol);
            fromShader(&amb_pad_vol_config, settings.music_ambient_pad_vol);
            fromShader(&amb_melody_vol_config, settings.music_ambient_melody_vol);
            fromShader(&amb_arp_vol_config, settings.music_ambient_arp_vol);
        },
        .choir => {
            fromShader(&choir_vol_config, settings.music_choir_vol);
            choir_breathiness_config.value = settings.music_choir_breathiness;
            choir_drone_mix_config.value = settings.music_choir_drone_mix;
            choir_chant_mix_config.value = settings.music_choir_chant_mix;
            choir_cue_value = settings.music_choir_cue;
        },
        .african_drums => {
            african_cue_value = settings.music_african_cue;
            african_drum_mix_config.value = settings.music_african_drum_mix;
            african_shaker_mix_config.value = settings.music_african_shaker_mix;
            african_tone_mix_config.value = settings.music_african_bass_mix;
            african_slap_mix_config.value = settings.music_african_drone_mix;
        },
        .taiko => {
            taiko_cue_value = settings.music_taiko_cue;
            taiko_drum_mix_config.value = settings.music_taiko_drum_mix;
            taiko_shime_mix_config.value = settings.music_taiko_shime_mix;
            taiko_nagado_mix_config.value = settings.music_taiko_nagado_mix;
            taiko_kane_mix_config.value = settings.music_taiko_kane_mix;
        },
        .americana_guitar => {
            americana_guitar_cue_value = settings.music_americana_guitar_cue;
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
    cfg.value = std.math.clamp((val - cfg.shader_offset) / cfg.shader_scale, cfg.min, cfg.max);
}

fn applyMenuToSettings(save_changes: bool) !void {
    settings.music_style = style_targets[style_value];
    settings.music_volume = volume_config.value;
    settings.music_bpm = toShader(&bpm_config);
    settings.music_reverb_mix = reverb_config.value;

    switch (settings.music_style) {
        .ambient => {
            settings.music_ambient_cue = ambient_cue_value;
            settings.music_ambient_drone_vol = toShader(&amb_drone_vol_config);
            settings.music_ambient_pad_vol = toShader(&amb_pad_vol_config);
            settings.music_ambient_melody_vol = toShader(&amb_melody_vol_config);
            settings.music_ambient_arp_vol = toShader(&amb_arp_vol_config);
        },
        .choir => {
            settings.music_choir_vol = toShader(&choir_vol_config);
            settings.music_choir_breathiness = choir_breathiness_config.value;
            settings.music_choir_drone_mix = choir_drone_mix_config.value;
            settings.music_choir_chant_mix = choir_chant_mix_config.value;
            settings.music_choir_cue = choir_cue_value;
        },
        .african_drums => {
            settings.music_african_cue = african_cue_value;
            settings.music_african_drum_mix = african_drum_mix_config.value;
            settings.music_african_shaker_mix = african_shaker_mix_config.value;
            settings.music_african_bass_mix = african_tone_mix_config.value;
            settings.music_african_drone_mix = african_slap_mix_config.value;
        },
        .taiko => {
            settings.music_taiko_cue = taiko_cue_value;
            settings.music_taiko_drum_mix = taiko_drum_mix_config.value;
            settings.music_taiko_shime_mix = taiko_shime_mix_config.value;
            settings.music_taiko_nagado_mix = taiko_nagado_mix_config.value;
            settings.music_taiko_kane_mix = taiko_kane_mix_config.value;
        },
        .americana_guitar => {
            settings.music_americana_guitar_cue = americana_guitar_cue_value;
        },
    }

    settings.applyMusic();
    if (!save_changes) return;
    try settings.save();
}

fn styleToCycleIndex(style: music.Style) u8 {
    var i: usize = 0;
    while (i < style_targets.len) : (i += 1) {
        if (style_targets[i] == style) return @intCast(i);
    }
    return 0; // Ambient fallback for removed/unknown styles.
}

// ============================================================
// Actions
// ============================================================

fn actionBack() anyerror!void {
    try applyMenuToSettings(true);
    state.editingMusic = false;
    try menu.back();
}

fn actionBackToMain() anyerror!void {
    try applyMenuToSettings(false);
    try menu.back();
}

fn actionCycleStyle() anyerror!void {
    style_value = (style_value + 1) % @as(u8, @intCast(STYLE_COUNT));
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
        .ambient => menu.push(&ambient_items, .{ .minimal_edit = true }),
        .choir => menu.push(&choir_items, .{ .minimal_edit = true }),
        .african_drums => menu.push(&african_items, .{ .minimal_edit = true }),
        .taiko => menu.push(&taiko_items, .{ .minimal_edit = true }),
        .americana_guitar => menu.push(&americana_guitar_items, .{ .minimal_edit = true }),
    }
}

fn actionCycleAmbientCue() anyerror!void {
    ambient_cue_value = (ambient_cue_value + 1) % AMBIENT_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_ambient.triggerCue();
}

fn onCycleAmbientCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleAmbientCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_ambient.triggerCue();
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

fn actionTriggerAfricanCue() anyerror!void {
    try applyMenuToSettings(false);
    procedural_african_drums.triggerCue();
}

fn actionCycleAfricanCue() anyerror!void {
    african_cue_value = (african_cue_value + 1) % AFRICAN_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_african_drums.triggerCue();
}

fn onCycleAfricanCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleAfricanCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_african_drums.triggerCue();
}

fn actionTriggerTaikoCue() anyerror!void {
    try applyMenuToSettings(false);
    procedural_taiko.triggerCue();
}

fn actionCycleTaikoCue() anyerror!void {
    taiko_cue_value = (taiko_cue_value + 1) % TAIKO_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_taiko.triggerCue();
}

fn onCycleTaikoCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleTaikoCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_taiko.triggerCue();
}

fn actionTriggerAmericanaGuitarCue() anyerror!void {
    try applyMenuToSettings(false);
    procedural_americana_guitar.triggerCue();
}

fn actionCycleAmericanaGuitarCue() anyerror!void {
    americana_guitar_cue_value = (americana_guitar_cue_value + 1) % AMERICANA_GUITAR_CUE_COUNT;
    try applyMenuToSettings(false);
    procedural_americana_guitar.triggerCue();
}

fn onCycleAmericanaGuitarCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleAmericanaGuitarCue: failed to apply settings: {}", .{err});
        return;
    };
    procedural_americana_guitar.triggerCue();
}
