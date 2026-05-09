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
// zig fmt: on

// ============================================================
// Menu items
// ============================================================

const IDX_STYLE: usize = 1;
const IDX_CUE: usize = 2;

var main_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack }, .font = .medium },
    .{ .label = "Style: Ambient", .kind = .{ .button = actionCycleStyle }, .font = .medium, .cycle_names = &style_names, .cycle_index = &style_value, .on_cycle = onCycleStyle },
    .{ .label = "Cue: Dawn", .kind = .{ .button = actionCycleCue }, .font = .medium, .cycle_names = &ambient_cue_names, .cycle_index = &ambient_cue_value, .on_cycle = onCycleCue },
    .{ .label = "Volume", .kind = .{ .config = &volume_config }, .font = .medium },
    .{ .label = "Tempo Scale", .kind = .{ .config = &bpm_config }, .font = .medium },
    .{ .label = "Reverb", .kind = .{ .config = &reverb_config }, .font = .medium },
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
    ambient_cue_value = settings.music_ambient_cue;
    choir_cue_value = settings.music_choir_cue;
    african_cue_value = settings.music_african_cue;
    taiko_cue_value = settings.music_taiko_cue;
    americana_guitar_cue_value = settings.music_americana_guitar_cue;
    updateCueRow();
}

fn updateStyleLabel() void {
    main_items[IDX_STYLE].label = style_names[style_value];
}

fn updateCueRow() void {
    const item = &main_items[IDX_CUE];
    switch (style_targets[style_value]) {
        .ambient => {
            item.cycle_names = &ambient_cue_names;
            item.cycle_index = &ambient_cue_value;
            item.label = ambient_cue_names[ambient_cue_value];
        },
        .choir => {
            item.cycle_names = &choir_cue_names;
            item.cycle_index = &choir_cue_value;
            item.label = choir_cue_names[choir_cue_value];
        },
        .african_drums => {
            item.cycle_names = &african_cue_names;
            item.cycle_index = &african_cue_value;
            item.label = african_cue_names[african_cue_value];
        },
        .taiko => {
            item.cycle_names = &taiko_cue_names;
            item.cycle_index = &taiko_cue_value;
            item.label = taiko_cue_names[taiko_cue_value];
        },
        .americana_guitar => {
            item.cycle_names = &americana_guitar_cue_names;
            item.cycle_index = &americana_guitar_cue_value;
            item.label = americana_guitar_cue_names[americana_guitar_cue_value];
        },
    }
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
        },
        .choir => {
            settings.music_choir_cue = choir_cue_value;
        },
        .african_drums => {
            settings.music_african_cue = african_cue_value;
        },
        .taiko => {
            settings.music_taiko_cue = taiko_cue_value;
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

fn actionCycleStyle() anyerror!void {
    style_value = (style_value + 1) % @as(u8, @intCast(STYLE_COUNT));
    updateStyleLabel();
    updateCueRow();
    try applyMenuToSettings(false);
    triggerCurrentCue();
}

fn onCycleStyle() void {
    updateStyleLabel();
    updateCueRow();
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleStyle: failed to apply settings: {}", .{err});
        return;
    };
    triggerCurrentCue();
}

fn actionCycleCue() anyerror!void {
    const idx = activeCueValue();
    idx.* = (idx.* + 1) % activeCueCount();
    updateCueRow();
    try applyMenuToSettings(false);
    triggerCurrentCue();
}

fn onCycleCue() void {
    applyMenuToSettings(false) catch |err| {
        std.log.warn("musicConfigMenu.onCycleCue: failed to apply settings: {}", .{err});
        return;
    };
    triggerCurrentCue();
}

fn activeCueValue() *u8 {
    switch (style_targets[style_value]) {
        .ambient => return &ambient_cue_value,
        .choir => return &choir_cue_value,
        .african_drums => return &african_cue_value,
        .taiko => return &taiko_cue_value,
        .americana_guitar => return &americana_guitar_cue_value,
    }
}

fn activeCueCount() u8 {
    return switch (style_targets[style_value]) {
        .ambient => AMBIENT_CUE_COUNT,
        .choir => CHOIR_CUE_COUNT,
        .african_drums => AFRICAN_CUE_COUNT,
        .taiko => TAIKO_CUE_COUNT,
        .americana_guitar => AMERICANA_GUITAR_CUE_COUNT,
    };
}

fn triggerCurrentCue() void {
    switch (settings.music_style) {
        .ambient => procedural_ambient.triggerCue(),
        .choir => procedural_choir.triggerCue(),
        .african_drums => procedural_african_drums.triggerCue(),
        .taiko => procedural_taiko.triggerCue(),
        .americana_guitar => procedural_americana_guitar.triggerCue(),
    }
}
