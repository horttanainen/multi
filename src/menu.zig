const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const config = @import("config.zig");
const text = @import("text.zig");
const window = @import("window.zig");
const delay = @import("delay.zig");
const gamepad = @import("gamepad.zig");
const sprite = @import("sprite.zig");
const cursor = @import("cursor.zig");

// ============================================================
// Types
// ============================================================

pub const ConfigData = struct {
    value: f32,
    step: f32,
    min: f32,
    max: f32,
    repeat_delay_ms: u32 = 150,
};

pub const ItemKind = union(enum) {
    button: *const fn () anyerror!void,
    config: *ConfigData,
    sprite_pick: []const u8,
};

pub const Item = struct {
    label: [:0]const u8,
    kind: ItemKind,
    font: text.Font = .large,
    image: ?u64 = null,
    cycle_names: ?[]const [:0]const u8 = null,
    cycle_index: ?*u8 = null,
    on_cycle: ?*const fn () void = null,
};

// ============================================================
// Layout options
// ============================================================

pub const Layout = enum { vertical, horizontal };

pub const OpenOptions = struct {
    layout: Layout = .vertical,
    item_height: i32 = BTN_H,
    minimal_edit: bool = false,
    back_fn: ?*const fn () anyerror!void = null,
};

// ============================================================
// Engine state
// ============================================================

var is_open: bool = false;
var active_items: []Item = &.{};
var focused_index: usize = 0;
var scroll_offset: usize = 0;
var scroll_anim: f32 = 0.0;
var editing_index: ?usize = null;
var editing_value: f32 = 0.0;
var pre_edit_value: f32 = 0.0;
var pre_edit_cycle_index: u8 = 0;
var close_fn: ?*const fn () void = null;
var current_layout: Layout = .vertical;
var current_item_height: i32 = BTN_H;
var current_minimal_edit: bool = false;
var current_back_fn: ?*const fn () anyerror!void = null;

const LERP_SPEED: f32 = 0.2;

pub fn open(items: []Item, options: OpenOptions) void {
    openImpl(items, null, options);
}

pub fn openWithCleanup(items: []Item, cleanup: *const fn () void, options: OpenOptions) void {
    openImpl(items, cleanup, options);
}

fn openImpl(items: []Item, cleanup: ?*const fn () void, options: OpenOptions) void {
    // Notify previous caller that it's being replaced
    const prev_fn = close_fn;
    close_fn = cleanup;
    if (prev_fn) |f| f();

    is_open = true;
    active_items = items;
    focused_index = 0;
    scroll_offset = 0;
    scroll_anim = 0.0;
    editing_index = null;
    current_layout = options.layout;
    current_item_height = options.item_height;
    current_minimal_edit = options.minimal_edit;
    current_back_fn = options.back_fn;
}

pub fn close() void {
    is_open = false;
    const f = close_fn;
    close_fn = null;
    if (f) |fn_ptr| fn_ptr();
}

pub fn isOpen() bool {
    return is_open;
}

pub fn isMinimalEditing() bool {
    return is_open and current_minimal_edit and editing_index != null;
}

pub fn focusedIndex() usize {
    return focused_index;
}

pub fn setFocusedIndex(index: usize) void {
    if (active_items.len == 0) {
        std.log.warn("menu.setFocusedIndex: cannot focus index {d} with no active items", .{index});
        return;
    }
    if (index >= active_items.len) {
        std.log.warn("menu.setFocusedIndex: index {d} is out of bounds for {d} items", .{ index, active_items.len });
        return;
    }

    focused_index = index;
    if (focused_index < scroll_offset) {
        scroll_offset = focused_index;
    } else if (focused_index >= scroll_offset + VISIBLE) {
        scroll_offset = focused_index - (VISIBLE - 1);
    }
    scroll_anim = @floatFromInt(scroll_offset);
}

// ============================================================
// Input handling
// ============================================================

pub fn handleInput() !void {
    if (editing_index != null) {
        try handleEditInput();
    } else {
        try handleBrowseInput();
    }
}

fn navUp() void {
    const n = active_items.len;
    if (focused_index == 0) {
        focused_index = n - 1;
        scroll_offset = if (n > VISIBLE) n - VISIBLE else 0;
        scroll_anim = @floatFromInt(scroll_offset);
    } else {
        focused_index -= 1;
        if (focused_index < scroll_offset) scroll_offset -= 1;
    }
}

fn navDown() void {
    const n = active_items.len;
    if (focused_index + 1 >= n) {
        focused_index = 0;
        scroll_offset = 0;
        scroll_anim = @floatFromInt(scroll_offset);
    } else {
        focused_index += 1;
        if (focused_index >= scroll_offset + VISIBLE) scroll_offset += 1;
    }
}

fn handleBrowseInput() !void {
    const keys = sdl.getKeyboardState();

    if (current_layout == .horizontal) {
        if ((keys[@intFromEnum(sdl.Scancode.left)] or keys[@intFromEnum(sdl.Scancode.a)]) and !delay.check("menuNav")) {
            navUp();
            delay.action("menuNav", 150);
        }
        if ((keys[@intFromEnum(sdl.Scancode.right)] or keys[@intFromEnum(sdl.Scancode.d)]) and !delay.check("menuNav")) {
            navDown();
            delay.action("menuNav", 150);
        }
    } else {
        if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and !delay.check("menuNav")) {
            navUp();
            delay.action("menuNav", 150);
        }
        if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and !delay.check("menuNav")) {
            navDown();
            delay.action("menuNav", 150);
        }
    }
    if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
        try activate(focused_index);
        delay.action("menuConfirm", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
        try goBack();
        delay.action("menuToggle", 400);
    }
    if (keys[@intFromEnum(sdl.Scancode.t)] and !delay.check("menuToggle")) {
        close();
        delay.action("menuToggle", 400);
    }

    var it = gamepad.assignedGamepads.valueIterator();
    while (it.next()) |gp| {
        const sdlGp = gp.gamepad orelse continue;
        if (current_layout == .horizontal) {
            if (sdl.getGamepadButton(sdlGp, .dpad_left) and !delay.check("menuNav")) {
                navUp();
                delay.action("menuNav", 150);
            }
            if (sdl.getGamepadButton(sdlGp, .dpad_right) and !delay.check("menuNav")) {
                navDown();
                delay.action("menuNav", 150);
            }
        } else {
            if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
                navUp();
                delay.action("menuNav", 150);
            }
            if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
                navDown();
                delay.action("menuNav", 150);
            }
        }
        if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
            try activate(focused_index);
            delay.action("menuConfirm", 200);
        }
        if ((sdl.getGamepadButton(sdlGp, .start) or sdl.getGamepadButton(sdlGp, .b)) and !delay.check("menuToggle")) {
            try goBack();
            delay.action("menuToggle", 400);
        }
        if (sdl.getGamepadButton(sdlGp, .y) and !delay.check("menuToggle")) {
            close();
            delay.action("menuToggle", 400);
        }
    }
}

fn goBack() !void {
    if (current_back_fn) |back| {
        try back();
    } else {
        close();
    }
}

fn handleEditInput() !void {
    const ei = editing_index orelse return;

    switch (active_items[ei].kind) {
        .config => |cfg| handleEditConfig(cfg),
        .button => |action| try handleEditButton(action),
        else => {
            editing_index = null;
        },
    }
}

fn handleEditConfig(cfg: *ConfigData) void {
    const keys = sdl.getKeyboardState();
    if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and !delay.check("menuNav")) {
        editing_value = @min(cfg.max, editing_value + cfg.step);
        cfg.value = editing_value;
        delay.action("menuNav", cfg.repeat_delay_ms);
    }
    if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and !delay.check("menuNav")) {
        editing_value = @max(cfg.min, editing_value - cfg.step);
        cfg.value = editing_value;
        delay.action("menuNav", cfg.repeat_delay_ms);
    }
    if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
        editing_index = null;
        delay.action("menuConfirm", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
        cfg.value = pre_edit_value;
        editing_index = null;
        delay.action("menuToggle", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.t)] and !delay.check("menuToggle")) {
        cfg.value = pre_edit_value;
        editing_index = null;
        close();
        delay.action("menuToggle", 400);
    }

    var it = gamepad.assignedGamepads.valueIterator();
    while (it.next()) |gp| {
        const sdlGp = gp.gamepad orelse continue;
        if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
            editing_value = @min(cfg.max, editing_value + cfg.step);
            cfg.value = editing_value;
            delay.action("menuNav", cfg.repeat_delay_ms);
        }
        if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
            editing_value = @max(cfg.min, editing_value - cfg.step);
            cfg.value = editing_value;
            delay.action("menuNav", cfg.repeat_delay_ms);
        }
        if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
            editing_index = null;
            delay.action("menuConfirm", 200);
        }
        if (sdl.getGamepadButton(sdlGp, .y) and !delay.check("menuToggle")) {
            cfg.value = pre_edit_value;
            editing_index = null;
            close();
            delay.action("menuToggle", 400);
        }
        if (sdl.getGamepadButton(sdlGp, .b) and !delay.check("menuToggle")) {
            cfg.value = pre_edit_value;
            editing_index = null;
            delay.action("menuToggle", 200);
        }
    }
}

fn handleEditButton(action: *const fn () anyerror!void) !void {
    const ei = editing_index orelse return;
    const item = &active_items[ei];
    const keys = sdl.getKeyboardState();

    if (item.cycle_names != null and item.cycle_index != null) {
        if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and !delay.check("menuNav")) {
            cycleItem(item, 1);
            delay.action("menuNav", 200);
        }
        if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and !delay.check("menuNav")) {
            cycleItem(item, -1);
            delay.action("menuNav", 200);
        }
    }

    if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
        if (item.cycle_names != null) {
            editing_index = null;
        } else {
            try action();
        }
        delay.action("menuConfirm", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
        revertCycleEdit(item);
        editing_index = null;
        delay.action("menuToggle", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.t)] and !delay.check("menuToggle")) {
        revertCycleEdit(item);
        editing_index = null;
        close();
        delay.action("menuToggle", 400);
    }

    var it = gamepad.assignedGamepads.valueIterator();
    while (it.next()) |gp| {
        const sdlGp = gp.gamepad orelse continue;

        if (item.cycle_names != null and item.cycle_index != null) {
            if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
                cycleItem(item, 1);
                delay.action("menuNav", 200);
            }
            if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
                cycleItem(item, -1);
                delay.action("menuNav", 200);
            }
        }

        if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
            if (item.cycle_names != null) {
                editing_index = null;
            } else {
                try action();
            }
            delay.action("menuConfirm", 200);
        }
        if (sdl.getGamepadButton(sdlGp, .y) and !delay.check("menuToggle")) {
            revertCycleEdit(item);
            editing_index = null;
            close();
            delay.action("menuToggle", 400);
        }
        if (sdl.getGamepadButton(sdlGp, .b) and !delay.check("menuToggle")) {
            revertCycleEdit(item);
            editing_index = null;
            delay.action("menuToggle", 200);
        }
    }
}

fn revertCycleEdit(item: *Item) void {
    const names = item.cycle_names orelse return;
    const idx = item.cycle_index orelse return;
    idx.* = pre_edit_cycle_index;
    item.label = names[idx.*];
    if (item.on_cycle) |cb| cb();
}

fn cycleItem(item: *Item, direction: i2) void {
    const names = item.cycle_names orelse return;
    const idx = item.cycle_index orelse return;
    const count: u8 = @intCast(names.len);
    if (direction > 0) {
        idx.* = (idx.* + 1) % count;
    } else {
        idx.* = if (idx.* == 0) count - 1 else idx.* - 1;
    }
    item.label = names[idx.*];
    if (item.on_cycle) |cb| cb();
}

fn activate(idx: usize) !void {
    switch (active_items[idx].kind) {
        .button => |action| {
            if (current_minimal_edit and active_items[idx].cycle_names != null) {
                // Cycle buttons enter minimal edit view on first press;
                // up/down cycling handled by handleEditButton.
                editing_index = idx;
                if (active_items[idx].cycle_index) |ci| {
                    pre_edit_cycle_index = ci.*;
                }
            } else {
                try action();
            }
        },
        .config => |cfg| {
            editing_index = idx;
            editing_value = cfg.value;
            pre_edit_value = cfg.value;
        },
        .sprite_pick => |key| {
            cursor.attachSprite(key);
            delay.action("placeSprite", 400);
            close();
        },
    }
}

// ============================================================
// Drawing
// ============================================================

const VISIBLE: usize = 3;
const BTN_H: i32 = 80;
const BTN_GAP: i32 = 12;
const IMG_PAD: i32 = 4;
const COLOR_NORMAL = config.menu.colorNormal;
const COLOR_FOCUSED = config.menu.colorFocused;
const COLOR_EDITING = config.menu.colorEditing;
const COLOR_OVERLAY = config.menu.colorOverlay;
const COLOR_SIDE = config.menu.colorSide;

pub fn draw() !void {
    if (!is_open) return;

    gpu.setZoom(1.0);

    // Advance scroll animation
    const target: f32 = @floatFromInt(scroll_offset);
    scroll_anim += (target - scroll_anim) * LERP_SPEED;
    if (@abs(target - scroll_anim) < 0.001) scroll_anim = target;

    try gpu.renderSetViewport(null);

    // In minimal edit mode, skip overlay and full menu when editing
    if (current_minimal_edit and editing_index != null) {
        try drawMinimalEdit();
        return;
    }

    try gpu.setRenderDrawColor(COLOR_OVERLAY);
    try gpu.renderFillRect(sdl.Rect{ .x = 0, .y = 0, .w = window.width, .h = window.height });

    if (current_layout == .horizontal) {
        try drawHorizontal();
    } else {
        try drawVertical();
    }
}

fn drawVertical() !void {
    const btn_w: i32 = @divFloor(window.width * 5, 10);
    const btn_x: i32 = @divFloor(window.width - btn_w, 2);
    const step: f32 = @floatFromInt(BTN_H + BTN_GAP);

    const center_item: f32 = scroll_anim + @as(f32, VISIBLE - 1) / 2.0;
    const screen_cy: i32 = @divFloor(window.height, 2);

    var hint_y: i32 = screen_cy;

    for (active_items, 0..) |item, i| {
        const fi: f32 = @floatFromInt(i);
        const y: i32 = screen_cy - @divFloor(BTN_H, 2) + @as(i32, @intFromFloat(@round((fi - center_item) * step)));

        if (y + BTN_H < 0 or y > window.height) continue;

        const in_window = i >= scroll_offset and i < scroll_offset + VISIBLE;
        const is_editing = if (editing_index) |ei| ei == i else false;
        const color = if (is_editing)
            COLOR_EDITING
        else if (i == focused_index)
            COLOR_FOCUSED
        else if (in_window)
            COLOR_NORMAL
        else
            COLOR_SIDE;

        try gpu.setRenderDrawColor(color);
        try gpu.renderFillRect(sdl.Rect{ .x = btn_x, .y = y, .w = btn_w, .h = BTN_H });

        if (item.image) |uuid| {
            if (sprite.getSprite(uuid)) |s| {
                const inner_w = btn_w - IMG_PAD * 2;
                const inner_h = BTN_H - IMG_PAD * 2;
                const sw: f32 = @floatFromInt(s.sizeP.x);
                const sh: f32 = @floatFromInt(s.sizeP.y);
                const scale = @min(
                    @as(f32, @floatFromInt(inner_w)) / sw,
                    @as(f32, @floatFromInt(inner_h)) / sh,
                );
                const dw: i32 = @intFromFloat(sw * scale);
                const dh: i32 = @intFromFloat(sh * scale);
                try gpu.renderCopy(s.texture, null, &sdl.Rect{
                    .x = btn_x + @divFloor(btn_w - dw, 2),
                    .y = y + @divFloor(BTN_H - dh, 2),
                    .w = dw,
                    .h = dh,
                });
            }
        } else {
            var label_buf: [64]u8 = undefined;
            const label: [:0]const u8 = switch (item.kind) {
                .button, .sprite_pick => item.label,
                .config => |cfg| blk: {
                    break :blk try std.fmt.bufPrintZ(&label_buf, "{s}: {d:.1}", .{ item.label, cfg.value });
                },
            };
            try text.writeCenter(item.font, label, .{
                .x = btn_x + @divFloor(btn_w, 2),
                .y = y + @divFloor(BTN_H, 2),
            });
        }

        if (in_window) hint_y = y + BTN_H;
    }

    if (editing_index != null) {
        try text.writeCenter(.small, "Enter: Apply  Esc: Cancel", .{
            .x = @divFloor(window.width, 2),
            .y = hint_y + BTN_GAP + 8,
        });
    }
}

fn drawMinimalEdit() !void {
    const ei = editing_index orelse return;
    const item = active_items[ei];

    const btn_w: i32 = @divFloor(window.width * 5, 10);
    const btn_x: i32 = @divFloor(window.width - btn_w, 2);
    const center_x: i32 = btn_x + @divFloor(btn_w, 2);
    const bottom_margin: i32 = 200;
    const y: i32 = window.height - BTN_H - bottom_margin;
    const adj_y_step: i32 = BTN_H + BTN_GAP;

    const current_alpha: u8 = 160;
    const adjacent_alpha: u8 = 60;
    const current_text_alpha: u8 = 230;
    const adjacent_text_alpha: u8 = 50;

    // Draw faded previous/next items for cycle buttons
    if (item.cycle_names) |names| {
        if (item.cycle_index) |idx| {
            const count: u8 = @intCast(names.len);
            const prev_idx = if (idx.* == 0) count - 1 else idx.* - 1;
            const next_idx = (idx.* + 1) % count;

            // Previous item box + text
            const prev_y = y - adj_y_step;
            try gpu.setRenderDrawColor(.{ .r = COLOR_EDITING.r, .g = COLOR_EDITING.g, .b = COLOR_EDITING.b, .a = adjacent_alpha });
            try gpu.renderFillRect(sdl.Rect{ .x = btn_x, .y = prev_y, .w = btn_w, .h = BTN_H });
            try text.writeCenterWithAlpha(item.font, names[prev_idx], .{
                .x = center_x,
                .y = prev_y + @divFloor(BTN_H, 2),
            }, adjacent_text_alpha);

            // Next item box + text
            const next_y = y + adj_y_step;
            try gpu.setRenderDrawColor(.{ .r = COLOR_EDITING.r, .g = COLOR_EDITING.g, .b = COLOR_EDITING.b, .a = adjacent_alpha });
            try gpu.renderFillRect(sdl.Rect{ .x = btn_x, .y = next_y, .w = btn_w, .h = BTN_H });
            try text.writeCenterWithAlpha(item.font, names[next_idx], .{
                .x = center_x,
                .y = next_y + @divFloor(BTN_H, 2),
            }, adjacent_text_alpha);
        }
    }

    // Current item box
    try gpu.setRenderDrawColor(.{ .r = COLOR_EDITING.r, .g = COLOR_EDITING.g, .b = COLOR_EDITING.b, .a = current_alpha });
    try gpu.renderFillRect(sdl.Rect{ .x = btn_x, .y = y, .w = btn_w, .h = BTN_H });

    var label_buf: [64]u8 = undefined;
    const label: [:0]const u8 = switch (item.kind) {
        .config => |cfg| blk: {
            break :blk std.fmt.bufPrintZ(&label_buf, "{s}: {d:.1}", .{ item.label, cfg.value }) catch item.label;
        },
        else => item.label,
    };
    try text.writeCenterWithAlpha(item.font, label, .{
        .x = center_x,
        .y = y + @divFloor(BTN_H, 2),
    }, current_text_alpha);

    const hint = if (item.cycle_names != null) "Up/Down: Cycle  Enter: Confirm  Esc: Back" else "Enter: Apply  Esc: Cancel";
    try text.writeCenter(.small, hint, .{
        .x = @divFloor(window.width, 2),
        .y = y + adj_y_step + BTN_H + BTN_GAP + 4,
    });
}

fn drawHorizontal() !void {
    const btn_h: i32 = current_item_height;
    const btn_w: i32 = btn_h; // square items
    const step: f32 = @floatFromInt(btn_w + BTN_GAP);

    const center_item: f32 = scroll_anim + @as(f32, VISIBLE - 1) / 2.0;
    const screen_cx: i32 = @divFloor(window.width, 2);
    const screen_cy: i32 = @divFloor(window.height, 2);

    for (active_items, 0..) |item, i| {
        const fi: f32 = @floatFromInt(i);
        const x: i32 = screen_cx - @divFloor(btn_w, 2) + @as(i32, @intFromFloat(@round((fi - center_item) * step)));

        if (x + btn_w < 0 or x > window.width) continue;

        const in_window = i >= scroll_offset and i < scroll_offset + VISIBLE;
        const color = if (i == focused_index)
            COLOR_FOCUSED
        else if (in_window)
            COLOR_NORMAL
        else
            COLOR_SIDE;

        try gpu.setRenderDrawColor(color);
        try gpu.renderFillRect(sdl.Rect{ .x = x, .y = screen_cy - @divFloor(btn_h, 2), .w = btn_w, .h = btn_h });

        if (item.image) |uuid| {
            if (sprite.getSprite(uuid)) |s| {
                const inner_w = btn_w - IMG_PAD * 2;
                const inner_h = btn_h - IMG_PAD * 2;
                const sw: f32 = @floatFromInt(s.sizeP.x);
                const sh: f32 = @floatFromInt(s.sizeP.y);
                const scale = @min(
                    @as(f32, @floatFromInt(inner_w)) / sw,
                    @as(f32, @floatFromInt(inner_h)) / sh,
                );
                const dw: i32 = @intFromFloat(sw * scale);
                const dh: i32 = @intFromFloat(sh * scale);
                try gpu.renderCopy(s.texture, null, &sdl.Rect{
                    .x = x + @divFloor(btn_w - dw, 2),
                    .y = screen_cy - @divFloor(dh, 2),
                    .w = dw,
                    .h = dh,
                });
            }
        } else {
            var label_buf: [64]u8 = undefined;
            const label: [:0]const u8 = switch (item.kind) {
                .button, .sprite_pick => item.label,
                .config => |cfg| blk: {
                    break :blk try std.fmt.bufPrintZ(&label_buf, "{s}: {d:.1}", .{ item.label, cfg.value });
                },
            };
            try text.writeCenter(item.font, label, .{
                .x = x + @divFloor(btn_w, 2),
                .y = screen_cy,
            });
        }
    }
}
