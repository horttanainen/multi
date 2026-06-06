const std = @import("std");

const level = @import("level.zig");
const levelEditor = @import("level_editor.zig");
const levelEditorGrid = @import("level_editor_grid.zig");
const menu = @import("menu.zig");
const aspectRatioMenu = @import("aspectRatioMenu.zig");

var splitscreen_value: bool = true;
var aspect_ratio_value: level.AspectRatio = level.defaultAspectRatio;
var aspect_ratio_label_buf: [64]u8 = undefined;
var initial_gravity: f32 = 10.0;
var initial_level_height_meters: f32 = 12.0;
var initial_camera_zoom_meters: f32 = level.defaultCameraZoomMeters;
var initial_aspect_ratio: level.AspectRatio = level.defaultAspectRatio;
var initial_splitscreen: bool = true;
var initial_grid_visible: bool = false;
var initial_grid_granularity_meters: f32 = levelEditorGrid.defaultGranularityMeters;
var suppress_cleanup_save: bool = false;

var gravity_config = menu.ConfigData{ .value = 10.0, .step = 0.5, .min = 0.0, .max = 200.0 };
var level_height_meters_config = menu.ConfigData{ .value = 12.0, .step = 0.5, .min = 1.0, .max = 200.0 };
var camera_zoom_meters_config = menu.ConfigData{ .value = level.defaultCameraZoomMeters, .step = 0.5, .min = 1.0, .max = 200.0 };
var grid_granularity_config = menu.ConfigData{
    .value = levelEditorGrid.defaultGranularityMeters,
    .step = 0.25,
    .min = levelEditorGrid.minGranularityMeters,
    .max = levelEditorGrid.maxGranularityMeters,
    .repeat_delay_ms = 75,
    .on_change = actionSetGridGranularity,
};

const aspect_ratio_item_index = 3;
const splitscreen_item_index = 4;
const grid_toggle_item_index = 5;

var items = [_]menu.Item{
    .{ .label = "Gravity", .kind = .{ .config = &gravity_config }, .font = .medium },
    .{ .label = "Level Height (m)", .kind = .{ .config = &level_height_meters_config }, .font = .medium },
    .{ .label = "Camera Zoom (m)", .kind = .{ .config = &camera_zoom_meters_config }, .font = .medium },
    .{ .label = "Aspect Ratio", .kind = .{ .button = actionOpenAspectRatio }, .font = .medium },
    .{ .label = "Splitscreen: ON", .kind = .{ .button = actionToggleSplitscreen } },
    .{ .label = "Grid: OFF", .kind = .{ .button = actionToggleGrid } },
    .{ .label = "Grid Size (m)", .kind = .{ .config = &grid_granularity_config }, .font = .medium },
    .{ .label = "Reset Changes", .kind = .{ .button = actionResetChanges } },
    .{ .label = "Try Level", .kind = .{ .button = actionTryLevel } },
};

pub fn open(gravity: f32, levelHeightMeters: f32, cameraZoomMeters: f32, aspectRatio: level.AspectRatio, splitscreen: bool) void {
    initial_gravity = gravity;
    initial_level_height_meters = levelHeightMeters;
    initial_camera_zoom_meters = cameraZoomMeters;
    initial_aspect_ratio = aspectRatio;
    initial_splitscreen = splitscreen;
    initial_grid_visible = levelEditorGrid.isVisible();
    initial_grid_granularity_meters = levelEditorGrid.granularityMeters();
    suppress_cleanup_save = false;

    gravity_config.value = gravity;
    level_height_meters_config.value = levelHeightMeters;
    camera_zoom_meters_config.value = cameraZoomMeters;
    aspect_ratio_value = aspectRatio;
    splitscreen_value = splitscreen;
    updateAspectRatioLabel();
    updateSplitscreenLabel();
    syncLevelEditorGridItems();
    menu.openWithCleanup(&items, cleanupLevelConfigMenu, .{});
}

fn updateAspectRatioLabel() void {
    items[aspect_ratio_item_index].label = std.fmt.bufPrintZ(&aspect_ratio_label_buf, "Aspect Ratio: {d}:{d}", .{ aspect_ratio_value.width, aspect_ratio_value.height }) catch "Aspect Ratio";
}

fn updateSplitscreenLabel() void {
    items[splitscreen_item_index].label = if (splitscreen_value) "Splitscreen: ON" else "Splitscreen: OFF";
    items[splitscreen_item_index].disabled = false;
}

fn getGravity() f32 {
    return gravity_config.value;
}

fn getLevelHeightMeters() f32 {
    return level_height_meters_config.value;
}

fn getCameraZoomMeters() f32 {
    return camera_zoom_meters_config.value;
}

fn setAspectRatio(aspectRatio: level.AspectRatio) void {
    aspect_ratio_value = aspectRatio;
    updateAspectRatioLabel();
}

fn actionOpenAspectRatio() anyerror!void {
    aspectRatioMenu.push(aspect_ratio_value, setAspectRatio);
}

fn actionToggleSplitscreen() anyerror!void {
    splitscreen_value = !splitscreen_value;
    updateSplitscreenLabel();
}

fn actionToggleGrid() anyerror!void {
    levelEditorGrid.toggleVisible();
    updateGridToggleLabel();
}

fn actionSetGridGranularity(value: f32) void {
    levelEditorGrid.setGranularityMeters(value);
}

fn syncLevelEditorGridItems() void {
    grid_granularity_config.value = levelEditorGrid.granularityMeters();
    updateGridToggleLabel();
}

fn updateGridToggleLabel() void {
    items[grid_toggle_item_index].label = if (levelEditorGrid.isVisible()) "Grid: ON" else "Grid: OFF";
}

fn saveAndReload() !void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), getCameraZoomMeters(), aspect_ratio_value, splitscreen_value);
    try levelEditor.reloadForEditor();
}

fn actionResetChanges() anyerror!void {
    gravity_config.value = initial_gravity;
    level_height_meters_config.value = initial_level_height_meters;
    camera_zoom_meters_config.value = initial_camera_zoom_meters;
    aspect_ratio_value = initial_aspect_ratio;
    splitscreen_value = initial_splitscreen;
    levelEditorGrid.setVisible(initial_grid_visible);
    levelEditorGrid.setGranularityMeters(initial_grid_granularity_meters);
    updateAspectRatioLabel();
    updateSplitscreenLabel();
    syncLevelEditorGridItems();
}

fn actionTryLevel() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), getCameraZoomMeters(), aspect_ratio_value, splitscreen_value);
    try levelEditor.tryCurrentLevel();
    suppress_cleanup_save = true;
    menu.close();
}

fn cleanupLevelConfigMenu() void {
    if (suppress_cleanup_save) {
        suppress_cleanup_save = false;
        return;
    }

    saveAndReload() catch |err| {
        std.log.warn("levelConfigMenu.cleanupLevelConfigMenu: failed to save level config: {}", .{err});
    };
}
