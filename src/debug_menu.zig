const std = @import("std");
const sdl = @import("sdl.zig");
const menu = @import("menu.zig");
const texture = @import("texture.zig");
const state = @import("state.zig");
const character_animation = @import("character_animation.zig");

var items = [_]menu.Item{
    .{ .label = "Close-up zoom", .shortcut = sdl.c.SDL_SCANCODE_Z, .font = .small, .kind = .{ .button = actionZoom } },
    .{ .label = "Sprites / stick / overlay", .shortcut = sdl.c.SDL_SCANCODE_V, .font = .small, .kind = .{ .button = actionView } },
    .{ .label = "Standing / running pose", .shortcut = sdl.c.SDL_SCANCODE_P, .font = .small, .kind = .{ .button = actionPose } },
    .{ .label = "Joints and targets", .shortcut = sdl.c.SDL_SCANCODE_D, .font = .small, .kind = .{ .button = actionDiagnostics } },
    .{ .label = "Reload animation JSON", .shortcut = sdl.c.SDL_SCANCODE_R, .font = .small, .kind = .{ .button = actionReload } },
    .{ .label = "Slow motion", .shortcut = sdl.c.SDL_SCANCODE_S, .font = .small, .kind = .{ .button = actionSlowMotion } },
    .{ .label = "Save texture atlases", .shortcut = sdl.c.SDL_SCANCODE_A, .font = .small, .kind = .{ .button = actionAtlasDump } },
};

const options: menu.OpenOptions = .{
    .overlay = true,
    .item_height = 40,
    .title = "§ DEBUG",
    .hint = "Letters select; § / Esc closes",
    .close_on_activate = true,
};

pub fn configure(args: []const [:0]const u8) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug-menu")) open();
    }
}

fn updateItems() void {
    const editing = state.editingLevel or state.editingBackground or state.editingMusic;
    for (items[0 .. items.len - 1]) |*item| item.hidden = editing;
}

pub fn open() void {
    updateItems();
    menu.open(&items, options);
}

pub fn handleKey(scancode: sdl.c.SDL_Scancode, keycode: sdl.c.SDL_Keycode, repeat: bool) bool {
    // SDL maps the Nordic section key differently on ANSI/ISO Mac keyboards.
    const prefix = keycode == 0x00a7 or scancode == sdl.c.SDL_SCANCODE_GRAVE or scancode == sdl.c.SDL_SCANCODE_NONUSBACKSLASH;
    if (!prefix) return false;
    if (repeat) return true;
    updateItems();
    menu.toggle(&items, options);
    return true;
}

fn actionZoom() !void {
    character_animation.reviewAction(.zoom);
}

fn actionView() !void {
    character_animation.reviewAction(.view);
}

fn actionPose() !void {
    character_animation.reviewAction(.pose);
}

fn actionDiagnostics() !void {
    character_animation.reviewAction(.diagnostics);
}

fn actionReload() !void {
    character_animation.reviewAction(.reload);
}

fn actionSlowMotion() !void {
    character_animation.reviewAction(.slow_motion);
}

fn actionAtlasDump() !void {
    texture.saveAtlasesToDisk();
}
