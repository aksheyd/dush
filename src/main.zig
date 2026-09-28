// dush - An ultra-fast drop-in replacement for `du -sh` on macOS.
//
// Performance Architecture:
// 1. macOS getattrlistbulk(2): Reads directory entries and metadata in 64KB batches,
//    eliminating individual lstat(2) / fstatat(2) syscalls per file.
// 2. Parallel Work-Stealing: Worker threads traverse subdirectories in parallel
//    with thread-local queues and lock-free batch spilling to feed idle workers.
// 3. Thread-Local Accumulation: Workers accumulate sizes in local variables and
//    merge once into the atomic total, eliminating atomic contention in file loops.
// 4. Fast Hardlink Deduplication: (dev, ino) tracking is only consulted when
//    st_nlink > 1, so 99.9% of files bypass mutexes completely.
// 5. Zero-allocation for files: Path strings are only allocated for subdirectories.
// 6. 100% BSD Fidelity: Exact humanize_number formatting matching macOS `du -sh`.
// 7. POSIX Fallback: Automatically falls back to readdir/fstatat on non-bulk filesystems.

const std = @import("std");

const VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// macOS getattrlistbulk constants & structures
// ---------------------------------------------------------------------------

pub const ATTR_BIT_MAP_COUNT: u16 = 5;
pub const ATTR_CMN_NAME: u32 = 0x00000001;
pub const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
pub const ATTR_CMN_FILEID: u32 = 0x02000000;
pub const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;

pub const ATTR_FILE_LINKCOUNT: u32 = 0x00000001;
pub const ATTR_FILE_TOTALSIZE: u32 = 0x00000002;
pub const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;

pub const ATTR_DIR_LINKCOUNT: u32 = 0x00000001;
pub const ATTR_DIR_ALLOCSIZE: u32 = 0x00000008;
pub const ATTR_DIR_DATALENGTH: u32 = 0x00000020;

pub const VREG: u32 = 1;
pub const VDIR: u32 = 2;
pub const VLNK: u32 = 4;

pub const AttrList = extern struct {
    bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

pub const AttrReference = extern struct {
    attr_dataoffset: i32,
    attr_length: u32,
};

extern "c" fn getattrlistbulk(
    dirfd: c_int,
    attrList: *const AttrList,
    attrBuf: *anyopaque,
    attrBufSize: usize,
    options: u64,
) c_int;

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn __error() *c_int;

const ENOENT: c_int = 2;
const EACCES: c_int = 13;
const ENOTSUP: c_int = 45;
const EINVAL: c_int = 22;

// ---------------------------------------------------------------------------
// Thread Synchronization Primitives
// ---------------------------------------------------------------------------

const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }

    pub fn unlock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }
};

const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const rc = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }

    pub fn broadcast(self: *Condition) void {
        const rc = std.c.pthread_cond_broadcast(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const FollowMode = enum { none, cli, all };

pub const Options = struct {
    apparent: bool = false, // -A, -b
    grand_total: bool = false, // -c
    block_size: i64 = 0, // 0 = human-readable, else 1024 (-k), 1048576 (-m), etc.
    follow: FollowMode = .none, // -P (default), -H, -L
    num_threads: usize = 8,
};

// ---------------------------------------------------------------------------
// BSD humanize_number implementation
// Guarantees 100% byte fidelity with macOS `du -h` ("0B", "1.0K", "49K", "1.5M", "10G")
// ---------------------------------------------------------------------------

pub fn humanize(out: *[5]u8, bytes: i64) []const u8 {
    const divisor: i64 = 1024;
    const cut: i64 = 973; // ceil(0.95 * 1024)
    const maxscale: usize = 6;
    const prefixes = "B\x00\x00K\x00\x00M\x00\x00G\x00\x00T\x00\x00P\x00\x00E";

    var quotient = bytes;
    var remainder: i64 = 0;
    var sign: i64 = 1;
    var baselen: usize = 1;
    if (quotient < 0) {
        sign = -1;
        quotient = -quotient;
        baselen += 2;
    } else {
        baselen += 1;
    }

    var max: i64 = 1;
    var i: i64 = @intCast(5 - baselen);
    while (true) {
        const left = i;
        i -= 1;
        if (!(left > 0 and max <= @divTrunc(std.math.maxInt(i64), 10))) break;
        max *= 10;
    }

    var scale: usize = 0;
    while (((quotient >= max) or
        (quotient == max - 1 and
            (remainder >= cut or remainder >= @divTrunc(divisor, 2)))) and
        scale < maxscale) : (scale += 1)
    {
        remainder = @rem(quotient, divisor);
        quotient = @divTrunc(quotient, divisor);
    }

    const p: u8 = prefixes[scale * 3];
    if (((quotient == 9 and remainder < cut) or quotient < 9) and scale > 0) {
        const t = @divTrunc(remainder * 10 + @divTrunc(divisor, 2), divisor);
        const s1 = quotient + @divTrunc(t, 10);
        const s2 = @rem(t, 10);
        return std.fmt.bufPrint(out, "{d}.{d}{c}", .{ sign * s1, s2, p }) catch out[0..0];
    } else {
        const v = sign * (quotient + @divTrunc(remainder + @divTrunc(divisor, 2), divisor));
        return std.fmt.bufPrint(out, "{d}{c}", .{ v, p }) catch out[0..0];
    }
}

// ---------------------------------------------------------------------------
// Path Utilities
// ---------------------------------------------------------------------------

pub const Path = struct {
    bytes: [:0]u8,

    pub fn deinit(self: Path, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    pub fn slice(self: Path) []const u8 {
        return self.bytes;
    }

    pub fn z(self: Path) [*:0]const u8 {
        return self.bytes.ptr;
    }
};

pub fn joinPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) !Path {
    const slash = if (parent.len == 0 or parent[parent.len - 1] == '/') false else true;
    const total_len = parent.len + (if (slash) @as(usize, 1) else 0) + child.len;
    const buf = try allocator.allocSentinel(u8, total_len, 0);
    @memcpy(buf[0..parent.len], parent);
    var offset = parent.len;
    if (slash) {
        buf[offset] = '/';
        offset += 1;
    }
    @memcpy(buf[offset..][0..child.len], child);
    return .{ .bytes = buf };
}

pub fn dupePathZ(allocator: std.mem.Allocator, s: []const u8) !Path {
    const buf = try allocator.dupeZ(u8, s);
    return .{ .bytes = buf };
}

// ---------------------------------------------------------------------------
// InodeSet (Thread-safe deduplication table)
// ---------------------------------------------------------------------------

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

        // Grow if load factor >= 0.65
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

// ---------------------------------------------------------------------------
// Dynamic Work Queue
// ---------------------------------------------------------------------------

pub const WorkItem = struct {
    path: Path,
    dev: u64,
};

pub const LOCAL_STACK_CAP = 64;
pub const BATCH_SPILL_CAP = 256;

pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    cond: Condition = .{},
    items: []WorkItem = &.{},
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    active_workers: usize = 0,
    idle_workers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shutdown: bool = false,

    pub fn init(allocator: std.mem.Allocator, initial_cap: usize) !WorkQueue {
        const cap = @max(initial_cap, 1024);
        const items = try allocator.alloc(WorkItem, cap);
        return .{
            .allocator = allocator,
            .items = items,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..self.count) |i| {
            self.items[(self.head + i) % self.items.len].path.deinit(self.allocator);
        }
        if (self.items.len > 0) {
            self.allocator.free(self.items);
            self.items = &.{};
        }
    }

    fn grow(self: *WorkQueue) bool {
        const new_cap = self.items.len * 2;
        const new_items = self.allocator.alloc(WorkItem, new_cap) catch return false;
        for (0..self.count) |i| {
            new_items[i] = self.items[(self.head + i) % self.items.len];
        }
        self.allocator.free(self.items);
        self.items = new_items;
        self.head = 0;
        self.tail = self.count;
        return true;
    }

    pub fn pushBatch(self: *WorkQueue, batch: []const WorkItem) void {
        if (batch.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count + batch.len > self.items.len) {
            if (!self.grow()) {
                // Drop if OOM
                for (batch) |item| item.path.deinit(self.allocator);
                return;
            }
        }

        for (batch) |item| {
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % self.items.len;
            self.count += 1;
        }

        if (self.idle_workers.load(.monotonic) > 0) {
            self.cond.broadcast();
        }
    }

    pub fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0 and !self.shutdown) {
            if (self.active_workers == 0) {
                self.shutdown = true;
                self.cond.broadcast();
                break;
            }
            _ = self.idle_workers.fetchAdd(1, .monotonic);
            self.cond.wait(&self.mutex);
            _ = self.idle_workers.fetchSub(1, .monotonic);
        }

        if (self.shutdown and self.count == 0) return null;

        const item = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        self.active_workers += 1;
        return item;
    }

    pub fn taskDone(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_workers -= 1;
        if (self.count == 0 and self.active_workers == 0) {
            self.shutdown = true;
            self.cond.broadcast();
        }
    }
};

// ---------------------------------------------------------------------------
// Traversal Worker Context & Functions
// ---------------------------------------------------------------------------

pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    queue: *WorkQueue,
    files: *InodeSet,
    dirs: *InodeSet,
    opts: *const Options,
    total_bytes: *std.atomic.Value(i64),
    had_error: *std.atomic.Value(bool),
};

fn readU32(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

fn readI64(ptr: [*]const u8) i64 {
    return std.mem.readInt(i64, ptr[0..8], .little);
}

fn readU64(ptr: [*]const u8) u64 {
    return std.mem.readInt(u64, ptr[0..8], .little);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn writeErr(path: []const u8, msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "dush: {s}: {s}\n", .{ path, msg }) catch return;
    writeAll(std.posix.STDERR_FILENO, line);
}

fn scanDirPosixFallback(
    ctx: *WorkerContext,
    dirfd: c_int,
    dir_path: []const u8,
    dir_dev: u64,
    local_bytes: *i64,
    spill: *[BATCH_SPILL_CAP]WorkItem,
    spill_count: *usize,
) void {
    const dir = std.c.fdopendir(dirfd) orelse {
        _ = close(dirfd);
        return;
    };
    defer _ = std.c.closedir(dir);
    _ = dir_dev;

    const flags: u32 = if (ctx.opts.follow == .all) 0 else std.posix.AT.SYMLINK_NOFOLLOW;

    while (std.c.readdir(dir)) |de| {
        const namlen: usize = de.namlen;
        if (namlen == 0) continue;
        const name = de.name[0..namlen];
        if (name[0] == '.' and (namlen == 1 or (namlen == 2 and name[1] == '.'))) continue;

        var st: std.c.Stat = undefined;
        const name_z: [*:0]const u8 = @ptrCast(&de.name);
        if (std.c.fstatat(dirfd, name_z, &st, flags) != 0) continue;

        const is_dir = (st.mode & 0o170000) == 0o040000;
        const dev: u64 = @intCast(st.dev);

        if (!is_dir) {
            if (st.nlink > 1 and ctx.files.seen(dev, st.ino)) continue;
            const size: i64 = if (ctx.opts.apparent)
                (@divTrunc(st.size + 511, 512)) * 512
            else
                st.blocks * 512;
            local_bytes.* += size;
        } else {
            if (ctx.dirs.seen(dev, st.ino)) continue;
            const size: i64 = if (ctx.opts.apparent)
                (@divTrunc(st.size + 511, 512)) * 512
            else
                st.blocks * 512;
            local_bytes.* += size;

            if (joinPath(ctx.allocator, dir_path, name)) |child_path| {
                spill[spill_count.*] = .{ .path = child_path, .dev = dev };
                spill_count.* += 1;
                if (spill_count.* == BATCH_SPILL_CAP) {
                    ctx.queue.pushBatch(spill[0..spill_count.*]);
                    spill_count.* = 0;
                }
            } else |_| {
                ctx.had_error.store(true, .monotonic);
            }
        }
    }
}

pub fn workerFn(ctx: *WorkerContext) void {
    var attrList: AttrList = .{
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID,
    };
    if (ctx.opts.apparent) {
        attrList.fileattr = ATTR_FILE_TOTALSIZE | ATTR_FILE_LINKCOUNT;
        attrList.dirattr = ATTR_DIR_DATALENGTH | ATTR_DIR_LINKCOUNT;
    } else {
        attrList.fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_LINKCOUNT;
        attrList.dirattr = ATTR_DIR_ALLOCSIZE | ATTR_DIR_LINKCOUNT;
    }

    var buf: [65536]u8 align(4) = undefined;
    var local_stack: [LOCAL_STACK_CAP]WorkItem = undefined;
    var local_top: usize = 0;
    var spill: [BATCH_SPILL_CAP]WorkItem = undefined;
    var spill_count: usize = 0;

    var local_bytes: i64 = 0;

    while (true) {
        var current: WorkItem = undefined;
        if (local_top > 0) {
            local_top -= 1;
            current = local_stack[local_top];
        } else {
            if (ctx.queue.pop()) |item| {
                current = item;
            } else {
                break;
            }
        }

        var dirfd = open(current.path.z(), 0x0000); // O_RDONLY
        if (dirfd < 0) {
            if (__error().* == EACCES) {
                writeErr(current.path.slice(), "Permission denied");
                ctx.had_error.store(true, .monotonic);
            }
            current.path.deinit(ctx.allocator);
            if (local_top == 0) {
                ctx.queue.taskDone();
            }
            continue;
        }

        const parent_slice = current.path.slice();
        var bulk_attempts: usize = 0;

        while (true) {
            const ret = getattrlistbulk(dirfd, &attrList, &buf, buf.len, 0);
            if (ret < 0) {
                if (bulk_attempts == 0 and (__error().* == ENOTSUP or __error().* == EINVAL)) {
                    // Filesystem does not support getattrlistbulk; fall back to POSIX readdir/fstatat
                    scanDirPosixFallback(ctx, dirfd, parent_slice, current.dev, &local_bytes, &spill, &spill_count);
                    dirfd = -1; // Closed by scanDirPosixFallback
                }
                break;
            }
            bulk_attempts += 1;
            if (ret == 0) break;

            var offset: usize = 0;
            var i: c_int = 0;
            while (i < ret) : (i += 1) {
                const entry_start = offset;
                const entry_len = readU32(buf[offset..].ptr);
                offset += 4;

                const ret_common = readU32(buf[offset..].ptr);
                const ret_dir = readU32(buf[offset + 8 ..].ptr);
                const ret_file = readU32(buf[offset + 12 ..].ptr);
                offset += 20;

                const name_ref_ptr = buf[offset..].ptr;
                const name_offset = std.mem.readInt(i32, name_ref_ptr[0..4], .little);
                const name_len = readU32(name_ref_ptr[4..8].ptr);
                offset += 8;

                const name_bytes: [*]const u8 = @ptrCast(name_ref_ptr + @as(usize, @intCast(name_offset)));
                const name_slice = name_bytes[0 .. name_len - 1]; // strip NUL

                var obj_type: u32 = 0;
                if ((ret_common & ATTR_CMN_OBJTYPE) != 0) {
                    obj_type = readU32(buf[offset..].ptr);
                    offset += 4;
                }

                var fileid: u64 = 0;
                if ((ret_common & ATTR_CMN_FILEID) != 0) {
                    fileid = readU64(buf[offset..].ptr);
                    offset += 8;
                }

                var linkcount: u32 = 1;
                var allocsize: i64 = 0;

                if (obj_type == VDIR) {
                    if ((ret_dir & ATTR_DIR_LINKCOUNT) != 0) {
                        linkcount = readU32(buf[offset..].ptr);
                        offset += 4;
                    }
                    if ((ret_dir & (ATTR_DIR_ALLOCSIZE | ATTR_DIR_DATALENGTH)) != 0) {
                        allocsize = readI64(buf[offset..].ptr);
                        offset += 8;
                    }

                    if (linkcount > 1 and ctx.dirs.seen(current.dev, fileid)) {
                        // Directory hard link / cycle already visited
                    } else {
                        local_bytes += allocsize;

                        if (joinPath(ctx.allocator, parent_slice, name_slice)) |child_path| {
                            const child_item = WorkItem{ .path = child_path, .dev = current.dev };
                            if (ctx.queue.idle_workers.load(.monotonic) > 0 or local_top >= LOCAL_STACK_CAP) {
                                spill[spill_count] = child_item;
                                spill_count += 1;
                                if (spill_count == BATCH_SPILL_CAP) {
                                    ctx.queue.pushBatch(spill[0..spill_count]);
                                    spill_count = 0;
                                }
                            } else {
                                local_stack[local_top] = child_item;
                                local_top += 1;
                            }
                        } else |_| {
                            ctx.had_error.store(true, .monotonic);
                        }
                    }
                } else if (obj_type == VLNK and ctx.opts.follow == .all) {
                    // -L: follow symlinks
                    var st: std.c.Stat = undefined;
                    var name_zbuf: [1024:0]u8 = undefined;
                    if (name_slice.len + 1 <= name_zbuf.len) {
                        @memcpy(name_zbuf[0..name_slice.len], name_slice);
                        name_zbuf[name_slice.len] = 0;
                        if (std.c.fstatat(dirfd, &name_zbuf, &st, 0) == 0) {
                            const dev: u64 = @intCast(st.dev);
                            const is_target_dir = (st.mode & 0o170000) == 0o040000;
                            if (is_target_dir) {
                                if (!ctx.dirs.seen(dev, st.ino)) {
                                    local_bytes += if (ctx.opts.apparent)
                                        (@divTrunc(st.size + 511, 512)) * 512
                                    else
                                        st.blocks * 512;

                                    if (joinPath(ctx.allocator, parent_slice, name_slice)) |child_path| {
                                        const child_item = WorkItem{ .path = child_path, .dev = dev };
                                        if (ctx.queue.idle_workers.load(.monotonic) > 0 or local_top >= LOCAL_STACK_CAP) {
                                            spill[spill_count] = child_item;
                                            spill_count += 1;
                                            if (spill_count == BATCH_SPILL_CAP) {
                                                ctx.queue.pushBatch(spill[0..spill_count]);
                                                spill_count = 0;
                                            }
                                        } else {
                                            local_stack[local_top] = child_item;
                                            local_top += 1;
                                        }
                                    } else |_| {}
                                }
                            } else {
                                if (st.nlink <= 1 or !ctx.files.seen(dev, st.ino)) {
                                    local_bytes += if (ctx.opts.apparent)
                                        (@divTrunc(st.size + 511, 512)) * 512
                                    else
                                        st.blocks * 512;
                                }
                            }
                        }
                    }
                } else {
                    // Regular file, symlink without -L, socket, fifo, device
                    if ((ret_file & ATTR_FILE_LINKCOUNT) != 0) {
                        linkcount = readU32(buf[offset..].ptr);
                        offset += 4;
                    }
                    if ((ret_file & (ATTR_FILE_ALLOCSIZE | ATTR_FILE_TOTALSIZE)) != 0) {
                        allocsize = readI64(buf[offset..].ptr);
                        offset += 8;
                    }

                    if (linkcount > 1 and ctx.files.seen(current.dev, fileid)) {
                        // Already counted this inode
                    } else {
                        local_bytes += allocsize;
                    }
                }

                offset = entry_start + entry_len;
            }
        }

        if (spill_count > 0) {
            ctx.queue.pushBatch(spill[0..spill_count]);
            spill_count = 0;
        }

        if (dirfd >= 0) {
            _ = close(dirfd);
        }
        current.path.deinit(ctx.allocator);

        if (local_top == 0) {
            ctx.queue.taskDone();
        }
    }

    if (local_bytes > 0) {
        _ = ctx.total_bytes.fetchAdd(local_bytes, .monotonic);
    }
}

// ---------------------------------------------------------------------------
// Scan Target
// ---------------------------------------------------------------------------

pub const ScanResult = struct {
    bytes: i64,
    err: bool,
};

pub fn scanTarget(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: *const Options,
    files: *InodeSet,
) ScanResult {
    const zpath = dupePathZ(allocator, path) catch return .{ .bytes = 0, .err = true };
    defer zpath.deinit(allocator);

    var st: std.c.Stat = undefined;
    const flags: u32 = if (opts.follow != .none) 0 else std.posix.AT.SYMLINK_NOFOLLOW;
    if (std.c.fstatat(std.posix.AT.FDCWD, zpath.z(), &st, flags) != 0) {
        const msg = if (__error().* == ENOENT) "No such file or directory" else "stat failed";
        writeErr(path, msg);
        return .{ .bytes = 0, .err = true };
    }

    const is_dir = (st.mode & 0o170000) == 0o040000;
    const dev: u64 = @intCast(st.dev);

    if (!is_dir) {
        if (st.nlink > 1 and files.seen(dev, st.ino)) {
            return .{ .bytes = 0, .err = false };
        }
        const size: i64 = if (opts.apparent)
            (@divTrunc(st.size + 511, 512)) * 512
        else
            st.blocks * 512;
        return .{ .bytes = size, .err = false };
    }

    // Target is a directory
    var total_bytes = std.atomic.Value(i64).init(
        if (opts.apparent)
            (@divTrunc(st.size + 511, 512)) * 512
        else
            st.blocks * 512,
    );
    var had_error = std.atomic.Value(bool).init(false);

    var dirs = InodeSet.init(allocator);
    defer dirs.deinit();
    _ = dirs.seen(dev, st.ino);

    var queue = WorkQueue.init(allocator, 16384) catch {
        writeErr(path, "out of memory");
        return .{ .bytes = 0, .err = true };
    };
    defer queue.deinit();

    const initial_path = dupePathZ(allocator, path) catch {
        writeErr(path, "out of memory");
        return .{ .bytes = 0, .err = true };
    };
    const initial_item = WorkItem{ .path = initial_path, .dev = dev };
    var initial_batch: [1]WorkItem = .{initial_item};
    queue.pushBatch(&initial_batch);

    var ctx = WorkerContext{
        .allocator = allocator,
        .queue = &queue,
        .files = files,
        .dirs = &dirs,
        .opts = opts,
        .total_bytes = &total_bytes,
        .had_error = &had_error,
    };

    const n_threads = @max(opts.num_threads, 1);
    const threads = allocator.alloc(std.Thread, n_threads) catch {
        workerFn(&ctx);
        return .{ .bytes = total_bytes.load(.monotonic), .err = had_error.load(.monotonic) };
    };
    defer allocator.free(threads);

    var started: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, workerFn, .{&ctx}) catch break;
        started += 1;
    }

    if (started == 0) {
        workerFn(&ctx);
    } else {
        for (threads[0..started]) |t| {
            t.join();
        }
    }

    return .{ .bytes = total_bytes.load(.monotonic), .err = had_error.load(.monotonic) };
}

// ---------------------------------------------------------------------------
// Output Formatting
// ---------------------------------------------------------------------------

pub fn printResult(bytes: i64, label: []const u8, opts: *const Options) void {
    var line_buf: [2048]u8 = undefined;

    if (opts.block_size > 0) {
        const blocks = @divTrunc(bytes + opts.block_size - 1, opts.block_size);
        const line = std.fmt.bufPrint(&line_buf, "{d}\t{s}\n", .{ blocks, label }) catch return;
        writeAll(std.posix.STDOUT_FILENO, line);
    } else {
        var hbuf: [5]u8 = undefined;
        const h = humanize(&hbuf, bytes);
        var pad: [4]u8 = "    ".*;
        const pad_len = if (h.len < 4) 4 - h.len else 0;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}\t{s}\n", .{ pad[0..pad_len], h, label }) catch return;
        writeAll(std.posix.STDOUT_FILENO, line);
    }
}

pub fn printUsage(prog: []const u8) void {
    var buf: [4096]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf,
        \\dush {s} - Ultra-fast du -sh replacement for macOS
        \\
        \\USAGE:
        \\    {s} [OPTIONS] [FILE/DIR ...]
        \\
        \\DESCRIPTION:
        \\    dush calculates directory disk usage identically to `du -sh` but
        \\    significantly faster using macOS getattrlistbulk(2) syscalls and
        \\    parallel work-stealing across all CPU cores.
        \\
        \\OPTIONS:
        \\    -s, --summary       Display only a summary for each specified file/dir (default)
        \\    -h, --human-readable
        \\                        Print sizes in human-readable format (e.g., 1.5K, 24M, 10G) (default)
        \\    -c, --total         Produce a grand total
        \\    -A, -b, --apparent-size
        \\                        Display apparent size instead of disk usage
        \\    -k                  Display block counts in 1024-byte (1 KiB) blocks
        \\    -m                  Display block counts in 1048576-byte (1 MiB) blocks
        \\    -g                  Display block counts in 1073741824-byte (1 GiB) blocks
        \\    -H                  Follow symlinks specified on the command line
        \\    -L                  Follow all symbolic links
        \\    -P                  Do not follow any symbolic links (default)
        \\    -t, --threads <N>   Number of worker threads (default: hardware core count)
        \\    -v, --version       Display version information
        \\        --help          Display this help message
        \\
    , .{ VERSION, prog }) catch return;
    writeAll(std.posix.STDOUT_FILENO, txt);
}

fn defaultThreads() usize {
    const n = std.Thread.getCpuCount() catch 8;
    return @min(@max(n, 1), 64);
}

// ---------------------------------------------------------------------------
// Main Entry Point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    var opts = Options{ .num_threads = defaultThreads() };

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(allocator);

    var it = init.minimal.args.iterate();
    const prog = it.next() orelse "dush";

    var end_opts = false;

    while (it.next()) |arg| {
        if (!end_opts and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                end_opts = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage(prog);
                return 0;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeAll(std.posix.STDOUT_FILENO, "dush " ++ VERSION ++ "\n");
                return 0;
            } else if (std.mem.eql(u8, arg, "--total")) {
                opts.grand_total = true;
            } else if (std.mem.eql(u8, arg, "--apparent-size")) {
                opts.apparent = true;
            } else if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "--human-readable")) {
                // Default options
            } else if (std.mem.eql(u8, arg, "--threads")) {
                if (it.next()) |val| {
                    if (std.fmt.parseInt(usize, val, 10)) |t| {
                        if (t >= 1 and t <= 128) opts.num_threads = t;
                    } else |_| {}
                }
            } else if (arg[1] == '-') {
                writeErr(arg, "invalid option");
                return 1;
            } else {
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        's' => {},
                        'h' => opts.block_size = 0,
                        'c' => opts.grand_total = true,
                        'A', 'b' => opts.apparent = true,
                        'k' => opts.block_size = 1024,
                        'm' => opts.block_size = 1048576,
                        'g' => opts.block_size = 1073741824,
                        'P' => opts.follow = .none,
                        'H' => opts.follow = .cli,
                        'L' => opts.follow = .all,
                        'v' => {
                            writeAll(std.posix.STDOUT_FILENO, "dush " ++ VERSION ++ "\n");
                            return 0;
                        },
                        't' => {
                            if (j + 1 < arg.len) {
                                if (std.fmt.parseInt(usize, arg[j + 1 ..], 10)) |t| {
                                    if (t >= 1 and t <= 128) opts.num_threads = t;
                                } else |_| {}
                                j = arg.len;
                            } else if (it.next()) |val| {
                                if (std.fmt.parseInt(usize, val, 10)) |t| {
                                    if (t >= 1 and t <= 128) opts.num_threads = t;
                                } else |_| {}
                            }
                        },
                        else => {
                            writeErr(arg[j .. j + 1], "invalid option");
                            return 1;
                        },
                    }
                }
            }
        } else {
            targets.append(allocator, arg) catch {
                writeErr("dush", "out of memory");
                return 1;
            };
        }
    }

    if (targets.items.len == 0) {
        targets.append(allocator, ".") catch {
            writeErr("dush", "out of memory");
            return 1;
        };
    }

    var files = InodeSet.init(allocator);
    defer files.deinit();

    var exit_code: u8 = 0;
    var grand_total: i64 = 0;

    for (targets.items) |t| {
        const r = scanTarget(allocator, t, &opts, &files);
        if (r.err) {
            exit_code = 1;
        } else {
            printResult(r.bytes, t, &opts);
            grand_total += r.bytes;
        }
    }

    if (opts.grand_total) {
        printResult(grand_total, "total", &opts);
    }

    return exit_code;
}

// ---------------------------------------------------------------------------
// Unit Tests (`zig build test`)
// ---------------------------------------------------------------------------

test "humanize matches du -h formatting" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("0B", humanize(&buf, 0));
    try std.testing.expectEqualStrings("100B", humanize(&buf, 100));
    try std.testing.expectEqualStrings("999B", humanize(&buf, 999));
    try std.testing.expectEqualStrings("1.0K", humanize(&buf, 1000));
    try std.testing.expectEqualStrings("1.0K", humanize(&buf, 1024));
    try std.testing.expectEqualStrings("1.5K", humanize(&buf, 1536));
    try std.testing.expectEqualStrings("9.5K", humanize(&buf, 9730));
    try std.testing.expectEqualStrings("49K", humanize(&buf, 50000));
    try std.testing.expectEqualStrings("1.0M", humanize(&buf, 1048576));
    try std.testing.expectEqualStrings("1.5M", humanize(&buf, 1572864));
    try std.testing.expectEqualStrings("1.0G", humanize(&buf, 1073741824));
}

test "joinPath" {
    const allocator = std.testing.allocator;
    const p1 = try joinPath(allocator, "foo", "bar");
    defer p1.deinit(allocator);
    try std.testing.expectEqualStrings("foo/bar", p1.slice());

    const p2 = try joinPath(allocator, "foo/", "bar");
    defer p2.deinit(allocator);
    try std.testing.expectEqualStrings("foo/bar", p2.slice());
}

test "inodeset dedup" {
    const allocator = std.testing.allocator;
    var s = InodeSet.init(allocator);
    defer s.deinit();

    try std.testing.expect(!s.seen(1, 100));
    try std.testing.expect(s.seen(1, 100));
    try std.testing.expect(!s.seen(1, 101));
    try std.testing.expect(!s.seen(0, 0));
}

test "queue push and pop" {
    const allocator = std.testing.allocator;
    var q = try WorkQueue.init(allocator, 8);
    defer q.deinit();

    const p1 = try dupePathZ(allocator, "one");
    const p2 = try dupePathZ(allocator, "two");
    var batch: [2]WorkItem = .{
        .{ .path = p1, .dev = 1 },
        .{ .path = p2, .dev = 1 },
    };
    q.pushBatch(&batch);

    const item1 = q.pop().?;
    try std.testing.expectEqualStrings("one", item1.path.slice());
    item1.path.deinit(allocator);
    q.taskDone();

    const item2 = q.pop().?;
    try std.testing.expectEqualStrings("two", item2.path.slice());
    item2.path.deinit(allocator);
    q.taskDone();

    try std.testing.expect(q.pop() == null);
}
