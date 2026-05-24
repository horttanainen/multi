const std = @import("std");

const level = @import("level.zig");
const levelEditor = @import("level_editor.zig");
const menu = @import("menu.zig");
const aspectRatioMenu = @import("aspectRatioMenu.zig");

var splitscreen_value: bool = true;
var fixed_camera_value: bool = false;
var aspect_ratio_value: level.AspectRatio = level.defaultAspectRatio;
var aspect_ratio_label_buf: [64]u8 = undefined;

var gravity_config = menu.ConfigData{ .value = 10.0, .step = 0.5, .min = 0.0, .max = 200.0 };
var level_height_meters_config = menu.ConfigData{ .value = 12.0, .step = 0.5, .min = 1.0, .max = 200.0 };

var items = [_]menu.Item{
    .{ .label = "Gravity", .kind = .{ .config = &gravity_config }, .font = .medium },
    .{ .label = "Level Height (m)", .kind = .{ .config = &level_height_meters_config }, .font = .medium },
    .{ .label = "Aspect Ratio", .kind = .{ .button = actionOpenAspectRatio }, .font = .medium },
    .{ .label = "Splitscreen: ON", .kind = .{ .button = actionToggleSplitscreen } },
    .{ .label = "Fixed Camera: OFF", .kind = .{ .button = actionToggleFixedCamera } },
    .{ .label = "Save Changes", .kind = .{ .button = actionSaveChanges } },
    .{ .label = "Try Level", .kind = .{ .button = actionTryLevel } },
};

pub fn open(gravity: f32, levelHeightMeters: f32, aspectRatio: level.AspectRatio, splitscreen: bool, fixedCamera: bool) void {
    gravity_config.value = gravity;
    level_height_meters_config.value = levelHeightMeters;
    aspect_ratio_value = aspectRatio;
    fixed_camera_value = fixedCamera;
    splitscreen_value = splitscreen and !fixed_camera_value;
    updateAspectRatioLabel();
    updateSplitscreenLabel();
    updateFixedCameraLabel();
    menu.open(&items, .{});
}

fn updateAspectRatioLabel() void {
    items[2].label = std.fmt.bufPrintZ(&aspect_ratio_label_buf, "Aspect Ratio: {d}:{d}", .{ aspect_ratio_value.width, aspect_ratio_value.height }) catch "Aspect Ratio";
}

fn updateSplitscreenLabel() void {
    if (fixed_camera_value) {
        splitscreen_value = false;
    }
    items[3].label = if (splitscreen_value) "Splitscreen: ON" else "Splitscreen: OFF";
    items[3].disabled = fixed_camera_value;
}

fn updateFixedCameraLabel() void {
    items[4].label = if (fixed_camera_value) "Fixed Camera: ON" else "Fixed Camera: OFF";
}

fn getGravity() f32 {
    return gravity_config.value;
}

fn getLevelHeightMeters() f32 {
    return level_height_meters_config.value;
}

fn setAspectRatio(aspectRatio: level.AspectRatio) void {
    aspect_ratio_value = aspectRatio;
    updateAspectRatioLabel();
}

fn actionOpenAspectRatio() anyerror!void {
    aspectRatioMenu.push(aspect_ratio_value, setAspectRatio);
}

fn actionToggleSplitscreen() anyerror!void {
    if (fixed_camera_value) return;

    splitscreen_value = !splitscreen_value;
    updateSplitscreenLabel();
}

fn actionToggleFixedCamera() anyerror!void {
    fixed_camera_value = !fixed_camera_value;
    if (fixed_camera_value) {
        splitscreen_value = false;
    }
    updateSplitscreenLabel();
    updateFixedCameraLabel();
}

fn actionSaveChanges() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), aspect_ratio_value, splitscreen_value, fixed_camera_value);
    try levelEditor.reloadForEditor();
}

fn actionTryLevel() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getLevelHeightMeters(), aspect_ratio_value, splitscreen_value, fixed_camera_value);
    var pathBuf: [200]u8 = undefined;
    const path = try levelEditor.getEditorLevelPath(&pathBuf);
    try level.tryEditorLevel(path);
    menu.close();
}
