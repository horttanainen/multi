const std = @import("std");

// Generic thread-safe array list wrapper
pub fn ThreadSafeArrayList(comptime T: type) type {
    return struct {
        list: std.array_list.Managed(T),
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .list = std.array_list.Managed(T).init(allocator),
                .mutex = .{},
            };
        }

        // Locking operations
        pub fn appendLocking(self: *@This(), item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.list.append(item);
        }

        pub fn appendSliceLocking(self: *@This(), items: []const T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.list.appendSlice(items);
        }

        pub fn replaceLocking(self: *@This(), new_list: std.array_list.Managed(T)) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.list.deinit();
            self.list = new_list;
        }
    };
}
