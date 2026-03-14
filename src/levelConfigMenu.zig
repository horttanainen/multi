const level = @import("level.zig");
const levelEditor = @import("level_editor.zig");
const menu = @import("menu.zig");

var splitscreen_value: bool = true;

var items = [_]menu.Item{
    .{ .label = "Gravity", .kind = .{ .config = .{ .value = 10.0, .step = 0.5, .min = 0.0, .max = 200.0 } }, .font = .medium },
    .{ .label = "Pixels Per Meter", .kind = .{ .config = .{ .value = 80.0, .step = 1.0, .min = 10.0, .max = 500.0 } }, .font = .medium },
    .{ .label = "Splitscreen: ON", .kind = .{ .button = actionToggleSplitscreen } },
    .{ .label = "Save Changes", .kind = .{ .button = actionSaveChanges } },
    .{ .label = "Try Level", .kind = .{ .button = actionTryLevel } },
};

pub fn open(gravity: f32, pixelsPerMeter: i32, splitscreen: bool) void {
    items[0].kind.config.value = gravity;
    items[1].kind.config.value = @floatFromInt(pixelsPerMeter);
    splitscreen_value = splitscreen;
    updateSplitscreenLabel();
    menu.open(&items, .{});
}

fn updateSplitscreenLabel() void {
    items[2].label = if (splitscreen_value) "Splitscreen: ON" else "Splitscreen: OFF";
}

fn getGravity() f32 {
    return items[0].kind.config.value;
}

fn getPixelsPerMeter() i32 {
    return @intFromFloat(items[1].kind.config.value);
}

fn actionToggleSplitscreen() anyerror!void {
    splitscreen_value = !splitscreen_value;
    updateSplitscreenLabel();
}

fn actionSaveChanges() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getPixelsPerMeter(), splitscreen_value);
    try levelEditor.reloadForEditor();
}

fn actionTryLevel() anyerror!void {
    try levelEditor.saveConfig(getGravity(), getPixelsPerMeter(), splitscreen_value);
    var pathBuf: [200]u8 = undefined;
    const path = try levelEditor.getEditorLevelPath(&pathBuf);
    try level.tryEditorLevel(path);
    menu.close();
}
