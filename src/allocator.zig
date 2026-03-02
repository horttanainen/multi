const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub fn deinit() void {
    const status = gpa.deinit();
    if (status == .leak) @panic("We are leaking memory");
}
