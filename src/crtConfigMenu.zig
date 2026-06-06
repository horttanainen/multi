const std = @import("std");

const config = @import("config.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");

var is_open: bool = false;
var staged_menu_enabled: bool = true;
var staged_game_enabled: bool = true;
var staged_menu_virtual_resolution_enabled: bool = true;
var staged_game_virtual_resolution_enabled: bool = true;
var staged_menu_scanlines_enabled: bool = true;
var staged_game_scanlines_enabled: bool = true;

var menu_barrel_config = menu.ConfigData{
    .value = 5.0,
    .step = 0.05,
    .min = settings.minCrtBarrel,
    .max = settings.maxCrtBarrel,
    .repeat_delay_ms = 75,
};
var menu_aberration_config = menu.ConfigData{
    .value = 0.015,
    .step = 0.001,
    .min = settings.minCrtAberration,
    .max = settings.maxCrtAberration,
    .repeat_delay_ms = 75,
};
var menu_zoom_config = menu.ConfigData{
    .value = 2.0,
    .step = 0.05,
    .min = settings.minCrtZoom,
    .max = settings.maxCrtZoom,
    .repeat_delay_ms = 75,
};
var menu_resolution_config = menu.ConfigData{
    .value = 360.0,
    .step = 60.0,
    .min = settings.minCrtResolution,
    .max = settings.maxCrtResolution,
    .repeat_delay_ms = 75,
};
var game_barrel_config = menu.ConfigData{
    .value = 0.15,
    .step = 0.05,
    .min = settings.minCrtBarrel,
    .max = settings.maxCrtBarrel,
    .repeat_delay_ms = 75,
};
var game_aberration_config = menu.ConfigData{
    .value = 0.004,
    .step = 0.001,
    .min = settings.minCrtAberration,
    .max = settings.maxCrtAberration,
    .repeat_delay_ms = 75,
};
var game_zoom_config = menu.ConfigData{
    .value = 1.0,
    .step = 0.05,
    .min = settings.minCrtZoom,
    .max = settings.maxCrtZoom,
    .repeat_delay_ms = 75,
};
var game_resolution_config = menu.ConfigData{
    .value = 720.0,
    .step = 60.0,
    .min = settings.minCrtResolution,
    .max = settings.maxCrtResolution,
    .repeat_delay_ms = 75,
};

const menu_toggle_item_index = 2;
const menu_virtual_resolution_item_index = 6;
const menu_resolution_item_index = 7;
const menu_scanlines_item_index = 8;
const game_toggle_item_index = 9;
const game_virtual_resolution_item_index = 13;
const game_resolution_item_index = 14;
const game_scanlines_item_index = 15;

var items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack } },
    .{ .label = "Reset Changes", .kind = .{ .button = actionResetChanges } },
    .{ .label = "Menu CRT: ON", .kind = .{ .button = actionToggleMenuCrt } },
    .{ .label = "Menu Barrel", .kind = .{ .config = &menu_barrel_config }, .font = .medium },
    .{ .label = "Menu Aberration", .kind = .{ .config = &menu_aberration_config }, .font = .medium },
    .{ .label = "Menu Zoom/Crop", .kind = .{ .config = &menu_zoom_config }, .font = .medium },
    .{ .label = "Menu Virtual Resolution: ON", .kind = .{ .button = actionToggleMenuVirtualResolution }, .font = .medium },
    .{ .label = "Menu Resolution", .kind = .{ .config = &menu_resolution_config }, .font = .medium },
    .{ .label = "Menu Scanlines: ON", .kind = .{ .button = actionToggleMenuScanlines }, .font = .medium },
    .{ .label = "Game CRT: ON", .kind = .{ .button = actionToggleGameCrt } },
    .{ .label = "Game Barrel", .kind = .{ .config = &game_barrel_config }, .font = .medium },
    .{ .label = "Game Aberration", .kind = .{ .config = &game_aberration_config }, .font = .medium },
    .{ .label = "Game Zoom/Crop", .kind = .{ .config = &game_zoom_config }, .font = .medium },
    .{ .label = "Game Virtual Resolution: ON", .kind = .{ .button = actionToggleGameVirtualResolution }, .font = .medium },
    .{ .label = "Game Resolution", .kind = .{ .config = &game_resolution_config }, .font = .medium },
    .{ .label = "Game Scanlines: ON", .kind = .{ .button = actionToggleGameScanlines }, .font = .medium },
};

pub fn push() void {
    loadFromSettings();
    refreshItems();
    is_open = true;
    menu.pushWithCleanup(&items, cleanupCrtConfigMenu, .{});
    menu.ensureFocusedVisible();
}

pub fn menuCrtParams() config.CrtParams {
    if (!is_open) return settings.menuCrtParams();
    return .{
        .enabled = staged_menu_enabled,
        .distortion_strength = menu_barrel_config.value,
        .aberration = menu_aberration_config.value,
        .zoom = menu_zoom_config.value,
        .virtual_resolution_enabled = staged_menu_virtual_resolution_enabled,
        .scanlines_enabled = staged_menu_scanlines_enabled,
        .resolution = resolutionFromHeight(menu_resolution_config.value),
    };
}

pub fn gameCrtParams() config.CrtParams {
    if (!is_open) return settings.gameCrtParams();
    return .{
        .enabled = staged_game_enabled,
        .distortion_strength = game_barrel_config.value,
        .aberration = game_aberration_config.value,
        .zoom = game_zoom_config.value,
        .virtual_resolution_enabled = staged_game_virtual_resolution_enabled,
        .scanlines_enabled = staged_game_scanlines_enabled,
        .resolution = resolutionFromHeight(game_resolution_config.value),
    };
}

fn loadFromSettings() void {
    staged_menu_enabled = settings.crt_menu_enabled;
    staged_game_enabled = settings.crt_game_enabled;
    staged_menu_virtual_resolution_enabled = settings.crt_menu_virtual_resolution_enabled;
    staged_game_virtual_resolution_enabled = settings.crt_game_virtual_resolution_enabled;
    staged_menu_scanlines_enabled = settings.crt_menu_scanlines_enabled;
    staged_game_scanlines_enabled = settings.crt_game_scanlines_enabled;
    menu_barrel_config.value = settings.crt_menu_barrel;
    menu_aberration_config.value = settings.crt_menu_aberration;
    menu_zoom_config.value = settings.crt_menu_zoom;
    menu_resolution_config.value = settings.crt_menu_resolution;
    game_barrel_config.value = settings.crt_game_barrel;
    game_aberration_config.value = settings.crt_game_aberration;
    game_zoom_config.value = settings.crt_game_zoom;
    game_resolution_config.value = settings.crt_game_resolution;
}

fn refreshItems() void {
    items[menu_toggle_item_index].label = if (staged_menu_enabled) "Menu CRT: ON" else "Menu CRT: OFF";
    items[menu_virtual_resolution_item_index].label = if (staged_menu_virtual_resolution_enabled) "Menu Virtual Resolution: ON" else "Menu Virtual Resolution: OFF";
    items[menu_resolution_item_index].hidden = !staged_menu_virtual_resolution_enabled;
    items[menu_scanlines_item_index].label = if (staged_menu_scanlines_enabled) "Menu Scanlines: ON" else "Menu Scanlines: OFF";
    items[game_toggle_item_index].label = if (staged_game_enabled) "Game CRT: ON" else "Game CRT: OFF";
    items[game_virtual_resolution_item_index].label = if (staged_game_virtual_resolution_enabled) "Game Virtual Resolution: ON" else "Game Virtual Resolution: OFF";
    items[game_resolution_item_index].hidden = !staged_game_virtual_resolution_enabled;
    items[game_scanlines_item_index].label = if (staged_game_scanlines_enabled) "Game Scanlines: ON" else "Game Scanlines: OFF";
}

fn resolutionFromHeight(height: f32) [2]f32 {
    return .{ height * (16.0 / 9.0), height };
}

fn actionBack() anyerror!void {
    try menu.back();
}

fn actionToggleMenuCrt() anyerror!void {
    staged_menu_enabled = !staged_menu_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionToggleGameCrt() anyerror!void {
    staged_game_enabled = !staged_game_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionToggleMenuVirtualResolution() anyerror!void {
    staged_menu_virtual_resolution_enabled = !staged_menu_virtual_resolution_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionToggleGameVirtualResolution() anyerror!void {
    staged_game_virtual_resolution_enabled = !staged_game_virtual_resolution_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionToggleMenuScanlines() anyerror!void {
    staged_menu_scanlines_enabled = !staged_menu_scanlines_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionToggleGameScanlines() anyerror!void {
    staged_game_scanlines_enabled = !staged_game_scanlines_enabled;
    refreshItems();
    menu.ensureFocusedVisible();
}

fn actionResetChanges() anyerror!void {
    loadFromSettings();
    refreshItems();
    menu.ensureFocusedVisible();
}

fn saveChanges() !void {
    settings.setMenuCrtSettings(
        staged_menu_enabled,
        menu_barrel_config.value,
        menu_aberration_config.value,
        menu_zoom_config.value,
        staged_menu_virtual_resolution_enabled,
        staged_menu_scanlines_enabled,
        menu_resolution_config.value,
    );
    settings.setGameCrtSettings(
        staged_game_enabled,
        game_barrel_config.value,
        game_aberration_config.value,
        game_zoom_config.value,
        staged_game_virtual_resolution_enabled,
        staged_game_scanlines_enabled,
        game_resolution_config.value,
    );
    try settings.save();
}

fn cleanupCrtConfigMenu() void {
    saveChanges() catch |err| {
        std.log.warn("crtConfigMenu.cleanupCrtConfigMenu: failed to save CRT settings: {}", .{err});
    };
    is_open = false;
}
