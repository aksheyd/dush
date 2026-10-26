const std = @import("std");
const Mutex = @import("sys.zig").Mutex;

pub const LinkStep = struct {
    skip: bool,
    links: i64,
    live: bool,
};

pub fn linkStep(live: bool, links: i64, nlink: i64) LinkStep {
    if (live) {
        const left = links - 1;
        return .{ .skip = true, .links = left, .live = left > 0 };
    }
    return .{ .skip = false, .links = nlink - 1, .live = true };
}

pub const Entry = struct {
    dev: u64,
    ino: u64,
    links: i64 = 0,
    live: bool = false,
};

pub const InodeSet = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    keys: []Entry = &.{},
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

    fn grow(self: *InodeSet) void {
        const new_cap = self.keys.len * 2;
        const new_keys = self.allocator.alloc(Entry, new_cap) catch return;
        @memset(new_keys, .{ .dev = 0, .ino = 0 });
        const mask = new_cap - 1;
        for (self.keys) |k| {
            if (k.ino != 0) {
                var idx: usize = @intCast(hash(k.dev, k.ino) & mask);
                while (new_keys[idx].ino != 0) idx = (idx + 1) & mask;
                new_keys[idx] = k;
            }
        }
        self.allocator.free(self.keys);
        self.keys = new_keys;
    }

    pub fn visit(self: *InodeSet, dev: u64, ino: u64, nlink: i64) bool {
        if (ino == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.keys.len == 0) {
            self.keys = self.allocator.alloc(Entry, 4096) catch return false;
            @memset(self.keys, .{ .dev = 0, .ino = 0 });
        }
        if (self.count * 3 >= self.keys.len * 2) self.grow();

        const mask = self.keys.len - 1;
        var idx: usize = @intCast(hash(dev, ino) & mask);
        while (self.keys[idx].ino != 0) {
            const e = &self.keys[idx];
            if (e.ino == ino and e.dev == dev) {
                const step = linkStep(e.live, e.links, nlink);
                e.links = step.links;
                e.live = step.live;
                return step.skip;
            }
            idx = (idx + 1) & mask;
        }

        const step = linkStep(false, 0, nlink);
        self.keys[idx] = .{ .dev = dev, .ino = ino, .links = step.links, .live = step.live };
        self.count += 1;
        return step.skip;
    }
};
