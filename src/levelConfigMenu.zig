const std = @import("std");

const level = @import("level.zig");
const levelEditor = @import("level_editor.zig");
const menu = @import("menu.zig");
const aspectRatioMenu = @import("aspectRatioMenu.zig");

var splitscreen_value: bool = true;
var aspect_ratio_value: level.AspectRatio = level.defaultAspectRatio;
var aspect_ratio_label_buf: [64]u8 = undefined;

var gravity_config = menu.ConfigData{ .value = 10.0, .step = 0.5, .min = 0.0, .max = 200.0 };
var level_height_meters_config = menu.ConfigData{ .value = 12.0, .step = 0.5, .min = 1.0, .max = 200.0 };
var camera_zoom_meters_config = menu.ConfigData{ .value = level.defaultCameraZoomMeters, .step = 0.5, .min = 1.0, .max = 200.0 };

const aspect_ratio_item_index = 3;
const splitscreen_item_index = 4;

var items = [_]menu.Item{
    .{ .label = "Gravity", .kind = .{ .config = &gravity_config }, .font = .medium },
    .{ .label = "Level Height (m)", .kind = .{ .config = &level_height_meters_config }, .font = .medium },
    .{ .label = "Camera Zoom (m)", .kind = .{ .config = &camera_zoom_meters_config }, .font = .medium },
    .{ .label = "Aspect Ratio", .kind = .{ .button = actionOpenAspectRatio }, .font = .medium },
    .{ .label = "Splitscreen: ON", .kind = .{ .button = actionToggleSplitscreen } },
    .{ .label = "Save Changes", .kind = .{ .button = actionSaveChanges } },
    .{ .label = "Try Level", .kind = .{ .button = actionTryLevel } },
};

pub fn open(gravity: f32, levelHeightMeters: f32, cameraZoomMeters: f32, aspectRatio: level.AspectRatio, splitscreen: bool) void {
    gravity_config.value = gravity;
    level_height_meters_config.value = levelHeightMeters;
    camera_zoom_meters_config.value = cameraZoomMeters;
    aspect_ratio_value = aspectRatio;
    splitscreen_value = splitscreen;
    updateAspectRatioLabel();
    updateSplitscreenLabel();
    menu.open(&items, .{});
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

fn actionSaveChanges() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), getCameraZoomMeters(), aspect_ratio_value, splitscreen_value);
    try levelEditor.reloadForEditor();
}

fn actionTryLevel() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), getCameraZoomMeters(), aspect_ratio_value, splitscreen_value);
    try levelEditor.tryCurrentLevel();
    menu.close();
}
