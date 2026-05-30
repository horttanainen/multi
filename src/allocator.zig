const std = @import("std");

var gpa = std.heap.DebugAllocator(.{}){};
pub const allocator = gpa.allocator();

pub fn deinit() void {
    const status = gpa.deinit();
    if (status == .leak) @panic("We are leaking memory");
}
