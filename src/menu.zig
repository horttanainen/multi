const std = @import("std");
const sdl = @import("sdl.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const window = @import("window.zig");
const delay = @import("delay.zig");
const gamepad = @import("gamepad.zig");
const levelEditor = @import("level_editor.zig");
const state = @import("state.zig");

// ============================================================
// Types
// ============================================================

const MenuId = enum { main, level_editor };

const MenuItem = struct {
    label: [:0]const u8,
    action: *const fn () anyerror!void,
};

const BackEntry = struct {
    label: [:0]const u8, // e.g. "Game", "Main Menu"
    restore: ?MenuId, // null = close menu entirely
};

// ============================================================
// Static menu item tables (Back button is auto-appended)
// ============================================================

const main_items = [_]MenuItem{
    .{ .label = "Level Editor", .action = actionOpenLevelEditorMenu },
    .{ .label = "Quit Game", .action = actionQuitGame },
};

const level_editor_items = [_]MenuItem{
    .{ .label = "Create New", .action = actionCreateNew },
};

// ============================================================
// Module state
// ============================================================

var is_open: bool = false;
var current_menu: MenuId = .main;
var focused_index: usize = 0;
var back_stack: [8]BackEntry = undefined;
var back_depth: usize = 0;

// ============================================================
// Public API
// ============================================================

pub fn openMenu(from_label: [:0]const u8) void {
    is_open = true;
    current_menu = .main;
    focused_index = 0;
    back_depth = 0;
    back_stack[0] = .{ .label = from_label, .restore = null };
    back_depth = 1;
    // "menuToggle" is set by the caller; no separate delay needed here.
}

pub fn closeMenu() void {
    is_open = false;
    back_depth = 0;
}

pub fn isOpen() bool {
    return is_open;
}

pub fn handleInput() !void {
    const keys = sdl.getKeyboardState();

    if ((keys[@intFromEnum(sdl.Scancode.up)] or keys[@intFromEnum(sdl.Scancode.w)]) and
        !delay.check("menuNav"))
    {
        navigateUp();
        delay.action("menuNav", 150);
    }
    if ((keys[@intFromEnum(sdl.Scancode.down)] or keys[@intFromEnum(sdl.Scancode.s)]) and
        !delay.check("menuNav"))
    {
        navigateDown();
        delay.action("menuNav", 150);
    }
    if (keys[@intFromEnum(sdl.Scancode.return_)] and !delay.check("menuConfirm")) {
        try confirm();
        delay.action("menuConfirm", 200);
    }
    if (keys[@intFromEnum(sdl.Scancode.escape)] and !delay.check("menuToggle")) {
        back();
        delay.action("menuToggle", 400);
    }

    // Gamepad input – any assigned gamepad can navigate the menu
    var it = gamepad.assignedGamepads.valueIterator();
    while (it.next()) |gp| {
        const sdlGp = gp.gamepad orelse continue;

        if (sdl.getGamepadButton(sdlGp, .dpad_up) and !delay.check("menuNav")) {
            navigateUp();
            delay.action("menuNav", 150);
        }
        if (sdl.getGamepadButton(sdlGp, .dpad_down) and !delay.check("menuNav")) {
            navigateDown();
            delay.action("menuNav", 150);
        }
        if (sdl.getGamepadButton(sdlGp, .a) and !delay.check("menuConfirm")) {
            try confirm();
            delay.action("menuConfirm", 200);
        }
        if ((sdl.getGamepadButton(sdlGp, .start) or sdl.getGamepadButton(sdlGp, .b)) and
            !delay.check("menuToggle"))
        {
            back();
            delay.action("menuToggle", 400);
        }
    }
}

// ============================================================
// Drawing
// ============================================================

const BTN_H: i32 = 80;
const BTN_GAP: i32 = 12;
const COLOR_NORMAL = sdl.Color{ .r = 40, .g = 40, .b = 40, .a = 200 };
const COLOR_FOCUSED = sdl.Color{ .r = 220, .g = 60, .b = 140, .a = 220 };
const COLOR_TEXT = sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const COLOR_OVERLAY = sdl.Color{ .r = 0, .g = 0, .b = 0, .a = 160 };

pub fn draw() !void {
    // Reset to full window coordinates
    try gpu.renderSetViewport(null);

    // Dim overlay
    try gpu.setRenderDrawColor(COLOR_OVERLAY);
    try gpu.renderFillRect(sdl.Rect{
        .x = 0,
        .y = 0,
        .w = window.width,
        .h = window.height,
    });

    const items = getStaticItems();
    const n: i32 = @intCast(items.len + 1); // +1 for Back button
    const btn_w: i32 = @divFloor(window.width * 4, 10);
    const total_h: i32 = n * BTN_H + (n - 1) * BTN_GAP;
    const btn_x: i32 = @divFloor(window.width - btn_w, 2);
    const btn_y_start: i32 = @divFloor(window.height - total_h, 2);

    var back_label_buf: [64]u8 = undefined;
    const back_label: [:0]const u8 = std.fmt.bufPrintZ(
        &back_label_buf,
        "Back to {s}",
        .{back_stack[back_depth - 1].label},
    ) catch "Back";

    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const y: i32 = btn_y_start + @as(i32, @intCast(i)) * (BTN_H + BTN_GAP);
        const rect = sdl.Rect{ .x = btn_x, .y = y, .w = btn_w, .h = BTN_H };

        const color = if (i == focused_index) COLOR_FOCUSED else COLOR_NORMAL;
        try gpu.setRenderDrawColor(color);
        try gpu.renderFillRect(rect);

        // Back button is first (index 0), static items follow
        const label: [:0]const u8 = if (i == 0) back_label else items[i - 1].label;

        const dims = try text.measure(.large, label);
        const text_x = btn_x + @divFloor(btn_w - dims.x, 2);
        const text_y = y + @divFloor(BTN_H - dims.y, 2);
        try text.write(.large, label, .{ .x = text_x, .y = text_y });
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn getStaticItems() []const MenuItem {
    return switch (current_menu) {
        .main => &main_items,
        .level_editor => &level_editor_items,
    };
}

fn totalItemCount() usize {
    return getStaticItems().len + 1;
}

fn navigateUp() void {
    const n = totalItemCount();
    focused_index = (focused_index + n - 1) % n;
}

fn navigateDown() void {
    focused_index = (focused_index + 1) % totalItemCount();
}

fn confirm() !void {
    if (focused_index == 0) {
        back();
        return;
    }
    const items = getStaticItems();
    try items[focused_index - 1].action();
}

fn back() void {
    if (back_depth == 0) {
        closeMenu();
        return;
    }
    back_depth -= 1;
    const entry = back_stack[back_depth];
    if (entry.restore) |menu_id| {
        current_menu = menu_id;
        focused_index = 0;
    } else {
        closeMenu();
    }
}

// ============================================================
// Menu actions
// ============================================================

fn actionOpenLevelEditorMenu() anyerror!void {
    back_stack[back_depth] = .{ .label = "Main Menu", .restore = .main };
    back_depth += 1;
    current_menu = .level_editor;
    focused_index = 0;
}

fn actionCreateNew() anyerror!void {
    closeMenu();
    try levelEditor.createNewLevel();
}

fn actionQuitGame() anyerror!void {
    state.quitGame = true;
}
