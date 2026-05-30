const runtime = @import("runtime.zig");

pub fn generate() u64 {
    return runtime.random().int(u64);
}
