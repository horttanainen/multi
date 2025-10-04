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

// Generic thread-safe AutoArrayHashMap wrapper
pub fn ThreadSafeAutoArrayHashMap(comptime K: type, comptime V: type) type {
    return struct {
        map: std.AutoArrayHashMap(K, V),
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .map = std.AutoArrayHashMap(K, V).init(allocator),
                .mutex = .{},
            };
        }

        // Locking operations
        pub fn putLocking(self: *@This(), key: K, value: V) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.map.put(key, value);
        }

        pub fn getLocking(self: *@This(), key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(key);
        }

        pub fn getPtrLocking(self: *@This(), key: K) ?*V {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.getPtr(key);
        }

        pub fn fetchSwapRemoveLocking(self: *@This(), key: K) ?std.AutoArrayHashMap(K, V).KV {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.fetchSwapRemove(key);
        }

        pub fn replaceLocking(self: *@This(), new_map: std.AutoArrayHashMap(K, V)) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.map.deinit();
            self.map = new_map;
        }
    };
}
