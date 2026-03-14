const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const lut = @import("lut.zig");
const menu = @import("menu.zig");

var on_back: ?*const fn () void = null;
var suppress_settings_cleanup: bool = false;
var suppress_lut_picker_cleanup: bool = false;

var items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack } },
    .{ .label = "Color Grading", .kind = .{ .button = actionOpenLutPicker } },
    .{ .label = "Regenerate Built-in Gradients", .kind = .{ .button = actionRegenerateBuiltinLuts } },
};

var lut_picker_items: []menu.Item = &.{};

pub fn open(back_fn: *const fn () void) void {
    on_back = back_fn;
    menu.openWithCleanup(&items, cleanupSettingsMenu, .{});
}

fn actionBack() anyerror!void {
    menu.close();
}

fn actionOpenLutPicker() anyerror!void {
    suppress_settings_cleanup = true;
    try openLutPicker(lut.currentIndex() + 1);
}

fn actionRegenerateBuiltinLuts() anyerror!void {
    lut.regenerateBuiltinLuts();
    lut.reloadCurrent();
}

fn actionBackToSettings() anyerror!void {
    menu.close();
}

fn buildLutPickerItems() ![]menu.Item {
    var list = std.array_list.Managed(menu.Item).init(allocator);
    defer list.deinit();

    try list.append(.{ .label = "Back", .kind = .{ .button = actionBackToSettings } });

    const current_index = lut.currentIndex();
    var index: usize = 0;
    while (index < lut.entryCount()) : (index += 1) {
        const name = lut.entryName(index) orelse continue;
        const label = if (index == current_index)
            try allocLabel("* {s}", .{name})
        else
            try allocLabel("{s}", .{name});

        try list.append(.{
            .label = label,
            .kind = .{ .button = actionSelectFocusedLut },
        });
    }

    return try list.toOwnedSlice();
}

fn openLutPicker(focus_index: usize) !void {
    const new_items = try buildLutPickerItems();
    menu.openWithCleanup(new_items, cleanupLutPickerItems, .{ .layout = .vertical });
    lut_picker_items = new_items;
    menu.setFocusedIndex(@min(focus_index, new_items.len - 1));
}

fn cleanupSettingsMenu() void {
    if (suppress_settings_cleanup) {
        suppress_settings_cleanup = false;
        return;
    }

    const back_fn = on_back orelse {
        std.log.warn("settingsMenu.cleanupSettingsMenu: no back handler is configured", .{});
        return;
    };
    back_fn();
}

fn cleanupLutPickerItems() void {
    if (lut_picker_items.len == 0) return;

    for (lut_picker_items[1..]) |item| {
        allocator.free(item.label);
    }
    allocator.free(lut_picker_items);
    lut_picker_items = &.{};

    if (suppress_lut_picker_cleanup) {
        suppress_lut_picker_cleanup = false;
        return;
    }

    menu.openWithCleanup(&items, cleanupSettingsMenu, .{});
}

fn allocLabel(comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    return try allocator.dupeZ(u8, tmp);
}

fn selectLutAndReturn(index: usize) anyerror!void {
    if (!lut.select(index)) {
        std.log.warn("settingsMenu.selectLutAndReturn: failed to select LUT {d}", .{index});
    }
    suppress_lut_picker_cleanup = true;
    try openLutPicker(index + 1);
}

fn actionSelectFocusedLut() anyerror!void {
    const focused = menu.focusedIndex();
    if (focused == 0) {
        std.log.warn("settingsMenu.actionSelectFocusedLut: focused back button instead of LUT entry", .{});
        return;
    }
    try selectLutAndReturn(focused - 1);
}
