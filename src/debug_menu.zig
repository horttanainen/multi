const std = @import("std");
const sdl = @import("sdl.zig");
const menu = @import("menu.zig");
const texture = @import("texture.zig");
const state = @import("state.zig");
const character_animation = @import("character_animation.zig");
const player_input = @import("player_input.zig");

var items = [_]menu.Item{
    .{ .label = "Close-up zoom", .shortcut = sdl.c.SDL_SCANCODE_Z, .font = .small, .kind = .{ .button = actionZoom } },
    .{ .label = "Artwork / overlay / sprites / stick", .shortcut = sdl.c.SDL_SCANCODE_V, .font = .small, .kind = .{ .button = actionView } },
    .{ .label = "Movement / standing / reference run", .shortcut = sdl.c.SDL_SCANCODE_P, .font = .small, .kind = .{ .button = actionPose } },
    .{ .label = "Joints and targets", .shortcut = sdl.c.SDL_SCANCODE_D, .font = .small, .kind = .{ .button = actionDiagnostics } },
    .{ .label = "Reload animation and artwork", .shortcut = sdl.c.SDL_SCANCODE_R, .font = .small, .kind = .{ .button = actionReload } },
    .{ .label = "Slow motion", .shortcut = sdl.c.SDL_SCANCODE_S, .font = .small, .kind = .{ .button = actionSlowMotion } },
    .{ .label = "Aiming", .shortcut = sdl.c.SDL_SCANCODE_F, .font = .small, .kind = .{ .button = actionAimMode } },
    .{ .label = "Movement input", .shortcut = sdl.c.SDL_SCANCODE_M, .font = .small, .kind = .{ .button = actionMovementMode } },
    .{ .label = "Restore profile input", .shortcut = sdl.c.SDL_SCANCODE_C, .font = .small, .kind = .{ .button = actionResetInput } },
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
    for (&items) |*item| {
        switch (item.shortcut orelse continue) {
            sdl.c.SDL_SCANCODE_F => item.label = switch (player_input.directionSettings.aimMode) {
                .free => "Aiming: free",
                .eight_directions => "Aiming: eight directions",
            },
            sdl.c.SDL_SCANCODE_M => item.label = switch (player_input.directionSettings.movementMode) {
                .axis_thresholds => "Movement: axis thresholds",
                .eight_directions => "Movement: eight directions",
            },
            else => {},
        }
    }
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

fn actionAimMode() !void {
    player_input.directionSettings.aimMode = switch (player_input.directionSettings.aimMode) {
        .free => .eight_directions,
        .eight_directions => .free,
    };
    std.log.info("debug_menu: aiming = {s}", .{@tagName(player_input.directionSettings.aimMode)});
}

fn actionMovementMode() !void {
    player_input.directionSettings.movementMode = switch (player_input.directionSettings.movementMode) {
        .axis_thresholds => .eight_directions,
        .eight_directions => .axis_thresholds,
    };
    std.log.info("debug_menu: movement input = {s}", .{@tagName(player_input.directionSettings.movementMode)});
}

fn actionResetInput() !void {
    player_input.resetDirectionSettings();
    std.log.info("debug_menu: restored profile input; movement = {s}, aiming = {s}", .{
        @tagName(player_input.directionSettings.movementMode),
        @tagName(player_input.directionSettings.aimMode),
    });
}

fn actionAtlasDump() !void {
    texture.saveAtlasesToDisk();
}
