const std = @import("std");
const Mutex = @import("sys.zig").Mutex;

pub const InodeKey = struct {
    dev: u64,
    ino: u64,
};

pub const InodeSet = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    keys: []InodeKey = &.{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) InodeSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InodeSet) void {
        if (self.keys.len > 0) {
            self.allocator.free(self.keys);
            self.keys = &.{};
            self.count = 0;
        }
    }

    fn hash(dev: u64, ino: u64) u64 {
        return (ino ^ (dev << 16)) *% 11400714819323198485;
    }

    pub fn seen(self: *InodeSet, dev: u64, ino: u64) bool {
        if (ino == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.keys.len == 0) {
            self.keys = self.allocator.alloc(InodeKey, 4096) catch return false;
            @memset(self.keys, .{ .dev = 0, .ino = 0 });
        }

        if (self.count * 3 >= self.keys.len * 2) {
            const new_cap = self.keys.len * 2;
            if (self.allocator.alloc(InodeKey, new_cap)) |new_keys| {
                @memset(new_keys, .{ .dev = 0, .ino = 0 });
                const mask = new_cap - 1;
                for (self.keys) |k| {
                    if (k.ino != 0) {
                        var idx: usize = @intCast(hash(k.dev, k.ino) & mask);
                        while (new_keys[idx].ino != 0) {
                            idx = (idx + 1) & mask;
                        }
                        new_keys[idx] = k;
                    }
                }
                self.allocator.free(self.keys);
                self.keys = new_keys;
            } else |_| {}
        }

        const mask = self.keys.len - 1;
        var idx: usize = @intCast(hash(dev, ino) & mask);
        while (self.keys[idx].ino != 0) {
            if (self.keys[idx].ino == ino and self.keys[idx].dev == dev) {
                return true; // Already seen
            }
            idx = (idx + 1) & mask;
        }

        self.keys[idx] = .{ .dev = dev, .ino = ino };
        self.count += 1;
        return false; // New entry
    }
};
