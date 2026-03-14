const level = @import("level.zig");
const levelEditor = @import("level_editor.zig");
const menu = @import("menu.zig");

var splitscreen_value: bool = true;
var fixed_camera_value: bool = false;

var gravity_config = menu.ConfigData{ .value = 10.0, .step = 0.5, .min = 0.0, .max = 200.0 };
var pixels_per_meter_config = menu.ConfigData{ .value = 80.0, .step = 1.0, .min = 10.0, .max = 500.0 };

var items = [_]menu.Item{
    .{ .label = "Gravity", .kind = .{ .config = &gravity_config }, .font = .medium },
    .{ .label = "Pixels Per Meter", .kind = .{ .config = &pixels_per_meter_config }, .font = .medium },
    .{ .label = "Splitscreen: ON", .kind = .{ .button = actionToggleSplitscreen } },
    .{ .label = "Fixed Camera: OFF", .kind = .{ .button = actionToggleFixedCamera } },
    .{ .label = "Save Changes", .kind = .{ .button = actionSaveChanges } },
    .{ .label = "Try Level", .kind = .{ .button = actionTryLevel } },
};

pub fn open(gravity: f32, pixelsPerMeter: i32, splitscreen: bool, fixedCamera: bool) void {
    gravity_config.value = gravity;
    pixels_per_meter_config.value = @floatFromInt(pixelsPerMeter);
    splitscreen_value = splitscreen;
    fixed_camera_value = fixedCamera;
    updateSplitscreenLabel();
    updateFixedCameraLabel();
    menu.open(&items, .{});
}

fn updateSplitscreenLabel() void {
    items[2].label = if (splitscreen_value) "Splitscreen: ON" else "Splitscreen: OFF";
}

fn updateFixedCameraLabel() void {
    items[3].label = if (fixed_camera_value) "Fixed Camera: ON" else "Fixed Camera: OFF";
}

fn getGravity() f32 {
    return gravity_config.value;
}

fn getPixelsPerMeter() i32 {
    return @intFromFloat(pixels_per_meter_config.value);
}

fn actionToggleSplitscreen() anyerror!void {
    splitscreen_value = !splitscreen_value;
    updateSplitscreenLabel();
}

fn actionToggleFixedCamera() anyerror!void {
    fixed_camera_value = !fixed_camera_value;
    updateFixedCameraLabel();
}

fn actionSaveChanges() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getPixelsPerMeter(), splitscreen_value, fixed_camera_value);
    try levelEditor.reloadForEditor();
}

fn actionTryLevel() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getPixelsPerMeter(), splitscreen_value, fixed_camera_value);
    var pathBuf: [200]u8 = undefined;
    const path = try levelEditor.getEditorLevelPath(&pathBuf);
    try level.tryEditorLevel(path);
    menu.close();
}
