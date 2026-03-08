const std = @import("std");
const data = @import("data.zig");
const sprite = @import("sprite.zig");
const menu = @import("menu.zig");

const allocator = @import("allocator.zig").allocator;

var items: []menu.Item = &.{};

pub fn open() !void {
    var list = std.array_list.Managed(menu.Item).init(allocator);
    defer list.deinit();

    var it = data.spriteDataMap.keyIterator();
    while (it.next()) |key| {
        try list.append(.{
            .label = "",
            .kind = .{ .sprite_pick = key.* },
            .image = data.createSpriteFrom(key.*),
        });
    }

    if (items.len > 0) cleanup();
    items = try list.toOwnedSlice();
    menu.openWithCleanup(items, cleanup, .{ .layout = .horizontal, .item_height = 180 });
}

fn cleanup() void {
    for (items) |item| {
        if (item.image) |uuid| sprite.cleanupLater(uuid);
    }
    if (items.len > 0) {
        allocator.free(items);
        items = &.{};
    }
}
