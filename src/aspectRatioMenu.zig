const std = @import("std");

const level = @import("level.zig");
const menu = @import("menu.zig");

var current_aspect_ratio: level.AspectRatio = level.defaultAspectRatio;
var on_change: ?*const fn (level.AspectRatio) void = null;

var custom_width_config = menu.ConfigData{ .value = 16.0, .step = 1.0, .min = 1.0, .max = 100.0 };
var custom_height_config = menu.ConfigData{ .value = 9.0, .step = 1.0, .min = 1.0, .max = 100.0 };

var items = [_]menu.Item{
    .{ .label = "16:9", .kind = .{ .button = actionUse16By9 }, .font = .medium },
    .{ .label = "4:3", .kind = .{ .button = actionUse4By3 }, .font = .medium },
    .{ .label = "1:1", .kind = .{ .button = actionUse1By1 }, .font = .medium },
    .{ .label = "9:16", .kind = .{ .button = actionUse9By16 }, .font = .medium },
    .{ .label = "Custom Width", .kind = .{ .config = &custom_width_config }, .font = .medium },
    .{ .label = "Custom Height", .kind = .{ .config = &custom_height_config }, .font = .medium },
    .{ .label = "Apply Custom W/H", .kind = .{ .button = actionUseCustom }, .font = .medium },
};

pub fn push(initialAspectRatio: level.AspectRatio, onChange: *const fn (level.AspectRatio) void) void {
    current_aspect_ratio = sanitizeAspectRatio(initialAspectRatio);
    custom_width_config.value = @floatFromInt(current_aspect_ratio.width);
    custom_height_config.value = @floatFromInt(current_aspect_ratio.height);
    on_change = onChange;
    menu.push(&items, .{});
}

fn sanitizeAspectRatio(aspectRatio: level.AspectRatio) level.AspectRatio {
    if (aspectRatio.width <= 0 or aspectRatio.height <= 0) {
        std.log.warn("sanitizeAspectRatio: invalid aspect ratio {d}:{d}, using default", .{ aspectRatio.width, aspectRatio.height });
        return level.defaultAspectRatio;
    }

    return aspectRatio;
}

fn applyAspectRatio(aspectRatio: level.AspectRatio) !void {
    current_aspect_ratio = sanitizeAspectRatio(aspectRatio);

    if (on_change == null) {
        std.log.warn("applyAspectRatio: no change callback registered", .{});
        try menu.back();
        return;
    }
    const changeFn = on_change.?;
    changeFn(current_aspect_ratio);
    try menu.back();
}

fn actionUse16By9() anyerror!void {
    try applyAspectRatio(.{ .width = 16, .height = 9 });
}

fn actionUse4By3() anyerror!void {
    try applyAspectRatio(.{ .width = 4, .height = 3 });
}

fn actionUse1By1() anyerror!void {
    try applyAspectRatio(.{ .width = 1, .height = 1 });
}

fn actionUse9By16() anyerror!void {
    try applyAspectRatio(.{ .width = 9, .height = 16 });
}

fn actionUseCustom() anyerror!void {
    const width: i32 = @intFromFloat(@round(custom_width_config.value));
    const height: i32 = @intFromFloat(@round(custom_height_config.value));
    try applyAspectRatio(.{ .width = width, .height = height });
}
