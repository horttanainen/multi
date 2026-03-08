const state = @import("state.zig");
const menu = @import("menu.zig");
const levelEditor = @import("level_editor.zig");

var main_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionClose } },
    .{ .label = "Level Editor", .kind = .{ .button = actionOpenLevelEditorMenu } },
    .{ .label = "Quit Game", .kind = .{ .button = actionQuitGame } },
};

var level_editor_items = [_]menu.Item{
    .{ .label = "Back to Main Menu", .kind = .{ .button = actionOpenMainMenu } },
    .{ .label = "Create New", .kind = .{ .button = actionCreateNew } },
};

pub fn openGameMenu() void {
    menu.open(&main_items, .{});
}

fn actionClose() anyerror!void {
    menu.close();
}

fn actionOpenLevelEditorMenu() anyerror!void {
    menu.open(&level_editor_items, .{});
}

fn actionOpenMainMenu() anyerror!void {
    menu.open(&main_items, .{});
}

fn actionQuitGame() anyerror!void {
    state.quitGame = true;
}

fn actionCreateNew() anyerror!void {
    menu.close();
    try levelEditor.createNewLevel();
}
