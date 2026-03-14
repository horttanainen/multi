const menu = @import("menu.zig");
const entity = @import("entity.zig");
const levelEditor = @import("level_editor.zig");
const box2d = @import("box2d.zig");
const delay = @import("delay.zig");

var selected_body_id: box2d.c.b2BodyId = undefined;

var items = [_]menu.Item{
    .{ .label = "static", .kind = .{ .button = selectStatic } },
    .{ .label = "dynamic", .kind = .{ .button = selectDynamic } },
    .{ .label = "goal", .kind = .{ .button = selectGoal } },
    .{ .label = "spawn", .kind = .{ .button = selectSpawn } },
};

pub fn open(bodyId: box2d.c.b2BodyId) void {
    selected_body_id = bodyId;
    delay.action("menuConfirm", 400); // prevent immediate selection from held A
    menu.open(&items, .{});
}

fn selectStatic() anyerror!void {
    try changeType("static");
}

fn selectDynamic() anyerror!void {
    try changeType("dynamic");
}

fn selectGoal() anyerror!void {
    try changeType("goal");
}

fn selectSpawn() anyerror!void {
    try changeType("spawn");
}

fn changeType(newType: []const u8) !void {
    try levelEditor.changeEntityType(selected_body_id, newType);
    delay.action("placeSprite", 400); // prevent re-opening entity config on close
    menu.close();
}
