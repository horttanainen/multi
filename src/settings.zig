const std = @import("std");
const allocator = @import("allocator.zig").allocator;
const fs = @import("fs.zig");
const lut = @import("lut.zig");

const SETTINGS_PATH = "settings.json";
const DEFAULT_LUT_STRENGTH: f32 = 1.0;

const StoredSettings = struct {
    lut_strength: ?f32 = null,
    preferred_color_grading: ?[]const u8 = null,
};

var lut_strength: f32 = DEFAULT_LUT_STRENGTH;
var preferred_color_grading: ?[]u8 = null;

pub fn init() !void {
    lut_strength = DEFAULT_LUT_STRENGTH;
    freePreferredColorGrading();

    var json_buf: [16384]u8 = undefined;
    const json_data = fs.readFile(SETTINGS_PATH, &json_buf) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.warn("settings.init: failed to read {s}: {}", .{ SETTINGS_PATH, err });
            return;
        },
    };

    const parsed = std.json.parseFromSlice(StoredSettings, allocator, json_data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("settings.init: failed to parse {s}: {}", .{ SETTINGS_PATH, err });
        return;
    };
    defer parsed.deinit();

    if (parsed.value.lut_strength) |strength| {
        lut_strength = std.math.clamp(strength, 0.0, 5.0);
    }

    if (parsed.value.preferred_color_grading) |name| {
        preferred_color_grading = allocator.dupe(u8, name) catch |err| {
            std.log.warn("settings.init: failed to store preferred_color_grading: {}", .{err});
            return;
        };
    }
}

pub fn cleanup() void {
    freePreferredColorGrading();
}

pub fn lutStrength() f32 {
    return lut_strength;
}

pub fn setLutStrength(value: f32) void {
    lut_strength = std.math.clamp(value, 0.0, 5.0);
}

pub fn preferredColorGrading() ?[]const u8 {
    return preferred_color_grading;
}

pub fn setPreferredColorGrading(name: ?[]const u8) !void {
    freePreferredColorGrading();
    if (name) |value| {
        preferred_color_grading = try allocator.dupe(u8, value);
    }
}

pub fn apply() void {
    const preferred = preferredColorGrading() orelse {
        _ = lut.select(0);
        return;
    };
    if (!lut.selectByName(preferred)) {
        std.log.warn("settings.apply: preferred LUT '{s}' was not found", .{preferred});
    }
}

pub fn save() !void {
    var buf: [512]u8 = undefined;
    const contents = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(StoredSettings{
        .lut_strength = lut_strength,
        .preferred_color_grading = if (preferred_color_grading) |p| @as(?[]const u8, p) else null,
    }, .{ .whitespace = .indent_2 })}) catch |err| {
        std.log.warn("settings.save: failed to serialize: {}", .{err});
        return err;
    };
    fs.writeFile(SETTINGS_PATH, contents) catch |err| {
        std.log.warn("settings.save: failed to write {s}: {}", .{ SETTINGS_PATH, err });
        return err;
    };
}

fn freePreferredColorGrading() void {
    if (preferred_color_grading) |name| {
        allocator.free(name);
        preferred_color_grading = null;
    }
}
