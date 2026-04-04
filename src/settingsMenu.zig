const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const lut = @import("lut.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");

var on_back: ?*const fn () void = null;
var is_open: bool = false;
var showing_lut_picker: bool = false;
var staged_preferred_lut_index: usize = 0;

var lut_strength_config = menu.ConfigData{ .value = 1.0, .step = 0.05, .min = 0.0, .max = 5.0, .repeat_delay_ms = 75 };

var items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack } },
    .{ .label = "Color Grading: None", .kind = .{ .button = actionOpenLutPicker } },
    .{ .label = "LUT Strength", .kind = .{ .config = &lut_strength_config } },
    .{ .label = "Regenerate Built-in Gradients", .kind = .{ .button = actionRegenerateBuiltinLuts } },
    .{ .label = "Save Changes", .kind = .{ .button = actionSaveChanges } },
};

var lut_picker_items: []menu.Item = &.{};
var color_grading_label_buf: [96:0]u8 = undefined;

pub fn open(back_fn: *const fn () void) void {
    openImpl(back_fn, .replace);
}

pub fn push() void {
    openImpl(null, .push);
}

pub fn isOpen() bool {
    return is_open;
}

pub fn lutStrength() f32 {
    if (!is_open) return settings.lutStrength();
    return lut_strength_config.value;
}

fn actionBack() anyerror!void {
    try menu.back();
}

fn actionOpenLutPicker() anyerror!void {
    try openLutPicker(staged_preferred_lut_index + 1);
}

fn actionRegenerateBuiltinLuts() anyerror!void {
    lut.regenerateBuiltinLuts();
}

fn actionSaveChanges() anyerror!void {
    settings.setLutStrength(lut_strength_config.value);

    if (staged_preferred_lut_index == 0) {
        try settings.setPreferredColorGrading(null);
    } else {
        const name = lut.entryName(staged_preferred_lut_index) orelse {
            std.log.warn("settingsMenu.actionSaveChanges: staged LUT {d} has no name", .{staged_preferred_lut_index});
            return;
        };
        try settings.setPreferredColorGrading(name);
    }

    try settings.save();
    settings.apply();
    menu.close();
}

fn actionBackToSettings() anyerror!void {
    try menu.back();
}

fn buildLutPickerItems() ![]menu.Item {
    var list = std.array_list.Managed(menu.Item).init(allocator);
    defer list.deinit();

    try list.append(.{ .label = "Back", .kind = .{ .button = actionBackToSettings } });

    var index: usize = 0;
    while (index < lut.entryCount()) : (index += 1) {
        const name = lut.entryName(index) orelse continue;
        const label = if (index == staged_preferred_lut_index)
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

fn refreshColorGradingLabel() void {
    const name = lut.entryName(staged_preferred_lut_index) orelse {
        std.log.warn("settingsMenu.refreshColorGradingLabel: LUT {d} has no name", .{staged_preferred_lut_index});
        items[1].label = "Color Grading: ???";
        return;
    };
    items[1].label = std.fmt.bufPrintZ(&color_grading_label_buf, "Color Grading: {s}", .{name}) catch |err| blk: {
        std.log.warn("settingsMenu.refreshColorGradingLabel: failed to format label: {}", .{err});
        break :blk "Color Grading: ???";
    };
}

fn refreshLutPickerLabels() void {
    if (lut_picker_items.len == 0) return;

    for (lut_picker_items[1..], 0..) |*item, index| {
        const name = lut.entryName(index) orelse continue;
        const label = if (index == staged_preferred_lut_index)
            allocLabel("* {s}", .{name}) catch continue
        else
            allocLabel("{s}", .{name}) catch continue;
        allocator.free(item.label);
        item.label = label;
    }
}

fn openLutPicker(focus_index: usize) !void {
    showing_lut_picker = true;
    const new_items = try buildLutPickerItems();
    menu.pushWithCleanup(new_items, cleanupLutPickerItems, .{ .layout = .vertical });
    lut_picker_items = new_items;
    menu.setFocusedIndex(@min(focus_index, new_items.len - 1));
}

fn cleanupSettingsMenu() void {
    is_open = false;
    showing_lut_picker = false;
    settings.apply();

    if (on_back) |back_fn| back_fn();
}

const OpenMode = enum { replace, push };

fn openImpl(back_fn: ?*const fn () void, mode: OpenMode) void {
    on_back = back_fn;
    is_open = true;
    showing_lut_picker = false;
    staged_preferred_lut_index = getSavedLutIndex();
    lut_strength_config.value = settings.lutStrength();
    refreshColorGradingLabel();

    switch (mode) {
        .replace => menu.openWithCleanup(&items, cleanupSettingsMenu, .{}),
        .push => menu.pushWithCleanup(&items, cleanupSettingsMenu, .{}),
    }
}

fn cleanupLutPickerItems() void {
    if (lut_picker_items.len == 0) return;

    for (lut_picker_items[1..]) |item| {
        allocator.free(item.label);
    }
    allocator.free(lut_picker_items);
    lut_picker_items = &.{};
    showing_lut_picker = false;
}

fn allocLabel(comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    return try allocator.dupeZ(u8, tmp);
}

fn selectLutAndReturn(index: usize) anyerror!void {
    staged_preferred_lut_index = index;
    if (!lut.select(index)) {
        std.log.warn("settingsMenu.selectLutAndReturn: failed to preview LUT {d}", .{index});
    }
    refreshColorGradingLabel();
    refreshLutPickerLabels();
}

fn actionSelectFocusedLut() anyerror!void {
    const focused = menu.focusedIndex();
    if (focused == 0) {
        std.log.warn("settingsMenu.actionSelectFocusedLut: focused back button instead of LUT entry", .{});
        return;
    }
    try selectLutAndReturn(focused - 1);
}

fn getSavedLutIndex() usize {
    const preferred = settings.preferredColorGrading() orelse return 0;

    var index: usize = 0;
    while (index < lut.entryCount()) : (index += 1) {
        const name = lut.entryName(index) orelse continue;
        if (std.mem.eql(u8, preferred, name)) {
            return index;
        }
    }

    std.log.warn("settingsMenu.getSavedLutIndex: saved LUT '{s}' was not found", .{preferred});
    return 0;
}
