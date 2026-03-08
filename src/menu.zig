const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const window = @import("window.zig");
const delay = @import("delay.zig");
const gamepad = @import("gamepad.zig");

// ============================================================
// Types
// ============================================================

pub const ConfigData = struct {
    value: f32,
    step: f32,
    min: f32,
    max: f32,
};

pub const ItemKind = union(enum) {
    button: *const fn () anyerror!void,
    config: ConfigData,
};

pub const Item = struct {
    label: [:0]const u8,
    kind: ItemKind,
    font: text.Font = .large,
};

// ============================================================
// Engine state
// ============================================================

var is_open: bool = false;
var active_items: []Item = &.{};
var focused_index: usize = 0;
var editing_index: ?usize = null;
var editing_value: f32 = 0.0;

pub fn open(items: []Item) void {
    is_open = true;
    active_items = items;
    focused_index = 0;
    editing_index = null;
}

pub fn close() void {
    is_open = false;
}

pub fn isOpen() bool {
    return is_open;
}

// ============================================================
// Input handling
// ============================================================

pub fn handleInput() !void {
    if (editing_index != null) {
        handleEditInput();
    } else {
        try handleBrowseInput();
    }
}

fn handleBrowseInput() !void {
    const keys = sdl.getKeyboardState();
    const n = active_items.len;

    if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and !delay.check("menuNav")) {
        focused_index = (focused_index + n - 1) % n;
        delay.action("menuNav", 150);
    }
    if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and !delay.check("menuNav")) {
        focused_index = (focused_index + 1) % n;
        delay.action("menuNav", 150);
    }
    if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
        try activate(focused_index);
        delay.action("menuConfirm", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
        close();
        delay.action("menuToggle", 400);
    }

    var it = gamepad.assignedGamepads.valueIterator();
    while (it.next()) |gp| {
        const sdlGp = gp.gamepad orelse continue;
        if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
            focused_index = (focused_index + n - 1) % n;
            delay.action("menuNav", 150);
        }
        if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
            focused_index = (focused_index + 1) % n;
            delay.action("menuNav", 150);
        }
        if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
            try activate(focused_index);
            delay.action("menuConfirm", 200);
        }
        if ((sdl.getGamepadButton(sdlGp, .start) or sdl.getGamepadButton(sdlGp, .b)) and !delay.check("menuToggle")) {
            close();
            delay.action("menuToggle", 400);
        }
    }
}

fn handleEditInput() void {
    const ei = editing_index orelse return;
    switch (active_items[ei].kind) {
        .config => |*cfg| {
            const keys = sdl.getKeyboardState();
            if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and !delay.check("menuNav")) {
                editing_value = @min(cfg.max, editing_value + cfg.step);
                delay.action("menuNav", 150);
            }
            if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and !delay.check("menuNav")) {
                editing_value = @max(cfg.min, editing_value - cfg.step);
                delay.action("menuNav", 150);
            }
            if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
                cfg.value = editing_value;
                editing_index = null;
                delay.action("menuConfirm", 200);
            }
            if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
                editing_index = null;
                delay.action("menuToggle", 200);
            }

            var it = gamepad.assignedGamepads.valueIterator();
            while (it.next()) |gp| {
                const sdlGp = gp.gamepad orelse continue;
                if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
                    editing_value = @min(cfg.max, editing_value + cfg.step);
                    delay.action("menuNav", 150);
                }
                if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
                    editing_value = @max(cfg.min, editing_value - cfg.step);
                    delay.action("menuNav", 150);
                }
                if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
                    cfg.value = editing_value;
                    editing_index = null;
                    delay.action("menuConfirm", 200);
                }
                if (sdl.getGamepadButton(sdlGp, .b) and !delay.check("menuToggle")) {
                    editing_index = null;
                    delay.action("menuToggle", 200);
                }
            }
        },
        else => editing_index = null,
    }
}

fn activate(idx: usize) !void {
    switch (active_items[idx].kind) {
        .button => |action| try action(),
        .config => |cfg| {
            editing_index = idx;
            editing_value = cfg.value;
        },
    }
}

// ============================================================
// Drawing
// ============================================================

const BTN_H: i32 = 80;
const BTN_GAP: i32 = 12;
const COLOR_NORMAL = sdl.Color{ .r = 40, .g = 40, .b = 40, .a = 200 };
const COLOR_FOCUSED = sdl.Color{ .r = 220, .g = 60, .b = 140, .a = 220 };
const COLOR_EDITING = sdl.Color{ .r = 60, .g = 140, .b = 220, .a = 220 };
const COLOR_OVERLAY = sdl.Color{ .r = 0, .g = 0, .b = 0, .a = 160 };

pub fn draw() !void {
    if (!is_open) return;

    try gpu.renderSetViewport(null);
    try gpu.setRenderDrawColor(COLOR_OVERLAY);
    try gpu.renderFillRect(sdl.Rect{ .x = 0, .y = 0, .w = window.width, .h = window.height });

    const n: i32 = @intCast(active_items.len);
    const btn_w: i32 = @divFloor(window.width * 5, 10);
    const total_h: i32 = n * BTN_H + (n - 1) * BTN_GAP;
    const btn_x: i32 = @divFloor(window.width - btn_w, 2);
    const btn_y_start: i32 = @divFloor(window.height - total_h, 2);

    for (active_items, 0..) |item, i| {
        const y: i32 = btn_y_start + @as(i32, @intCast(i)) * (BTN_H + BTN_GAP);
        const rect = sdl.Rect{ .x = btn_x, .y = y, .w = btn_w, .h = BTN_H };

        const is_editing = if (editing_index) |ei| ei == i else false;
        const color = if (is_editing) COLOR_EDITING else if (i == focused_index) COLOR_FOCUSED else COLOR_NORMAL;
        try gpu.setRenderDrawColor(color);
        try gpu.renderFillRect(rect);

        var label_buf: [64]u8 = undefined;
        const label: [:0]const u8 = switch (item.kind) {
            .button => item.label,
            .config => |cfg| blk: {
                const val = if (is_editing) editing_value else cfg.value;
                break :blk try std.fmt.bufPrintZ(&label_buf, "{s}: {d:.1}", .{ item.label, val });
            },
        };

        try text.writeCenter(item.font, label, .{
            .x = btn_x + @divFloor(btn_w, 2),
            .y = y + @divFloor(BTN_H, 2),
        });
    }

    if (editing_index != null) {
        const hint_y = btn_y_start + n * (BTN_H + BTN_GAP) + 8;
        try text.writeCenter(.small, "Enter: Apply  Esc: Cancel", .{
            .x = @divFloor(window.width, 2),
            .y = hint_y,
        });
    }
}

