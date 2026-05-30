const std = @import("std");
const runtime = @import("runtime.zig");

// Generic thread-safe array list wrapper
pub fn ThreadSafeArrayList(comptime T: type) type {
    return struct {
        list: std.array_list.Managed(T),
        mutex: std.Io.Mutex,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .list = std.array_list.Managed(T).init(allocator),
                .mutex = .init,
            };
        }

        // Locking operations
        pub fn appendLocking(self: *@This(), item: T) !void {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            try self.list.append(item);
        }

        pub fn appendSliceLocking(self: *@This(), items: []const T) !void {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            try self.list.appendSlice(items);
        }

        pub fn replaceLocking(self: *@This(), new_list: std.array_list.Managed(T)) void {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            self.list.deinit();
            self.list = new_list;
        }
    };
}

// Generic thread-safe AutoArrayHashMap wrapper
pub fn ThreadSafeAutoArrayHashMap(comptime K: type, comptime V: type) type {
    return struct {
        map: std.AutoArrayHashMapUnmanaged(K, V),
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .map = std.AutoArrayHashMapUnmanaged(K, V).empty,
                .allocator = allocator,
                .mutex = .init,
            };
        }

        // Locking operations
        pub fn putLocking(self: *@This(), key: K, value: V) !void {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            try self.map.put(self.allocator, key, value);
        }

        pub fn getLocking(self: *@This(), key: K) ?V {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            return self.map.get(key);
        }

        pub fn getPtrLocking(self: *@This(), key: K) ?*V {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            return self.map.getPtr(key);
        }

        pub fn fetchSwapRemoveLocking(self: *@This(), key: K) ?std.AutoArrayHashMapUnmanaged(K, V).KV {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            return self.map.fetchSwapRemove(key);
        }

        pub fn replaceLocking(self: *@This(), new_map: std.AutoArrayHashMapUnmanaged(K, V)) void {
            self.mutex.lockUncancelable(runtime.io());
            defer self.mutex.unlock(runtime.io());
            self.map.deinit(self.allocator);
            self.map = new_map;
        }
    };
}
