const state = @import("state.zig");
const menu = @import("menu.zig");
const levelEditor = @import("level_editor.zig");
const settingsMenu = @import("settingsMenu.zig");
const backgroundConfigMenu = @import("backgroundConfigMenu.zig");
const musicConfigMenu = @import("musicConfigMenu.zig");

var main_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionClose } },
    .{ .label = "Play", .kind = .{ .button = actionPlay } },
    .{ .label = "Settings", .kind = .{ .button = actionOpenSettings } },
    .{ .label = "Music", .kind = .{ .button = actionOpenMusic } },
    .{ .label = "Background Editor", .kind = .{ .button = actionOpenBackgroundEditor } },
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

fn actionOpenSettings() anyerror!void {
    settingsMenu.push();
}

fn actionOpenLevelEditorMenu() anyerror!void {
    menu.push(&level_editor_items, .{});
}

fn actionOpenMainMenu() anyerror!void {
    try menu.back();
}

fn actionPlay() anyerror!void {
    state.editingBackground = false;
    state.editingLevel = false;
    state.editingMusic = false;
    menu.close();
}

fn actionOpenMusic() anyerror!void {
    state.editingBackground = false;
    state.editingLevel = false;
    state.editingMusic = true;
    musicConfigMenu.push();
}

fn actionOpenBackgroundEditor() anyerror!void {
    state.editingBackground = true;
    state.editingLevel = false;
    state.editingMusic = false;
    backgroundConfigMenu.push();
}

fn actionQuitGame() anyerror!void {
    state.quitGame = true;
}

fn actionCreateNew() anyerror!void {
    menu.close();
    try levelEditor.createNewLevel();
}
