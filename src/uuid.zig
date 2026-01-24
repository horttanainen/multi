const std = @import("std");

pub fn generate() u64 {
    return std.crypto.random.int(u64);
}
