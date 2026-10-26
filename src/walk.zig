const std = @import("std");
const sys = @import("sys.zig");
const errors = @import("errors.zig");
const accounting = @import("accounting.zig");
const Options = @import("cli.zig").Options;
const InodeSet = @import("inodes.zig").InodeSet;
const paths = @import("path.zig");
const Path = paths.Path;
const joinPath = paths.joinPath;
const dupePathZ = paths.dupePathZ;

pub const WorkItem = struct {
    path: Path,
    dev: u64,
    size: i64 = 0,
};

pub const LOCAL_STACK_CAP = 64;
pub const BATCH_SPILL_CAP = 256;

pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    mutex: sys.Mutex = .{},
    cond: sys.Condition = .{},
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
        errors.writeErr(dir_path, errors.errnoMessage());
        ctx.had_error.store(true, .monotonic);
        _ = sys.close(dirfd);
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
        if (std.c.fstatat(dirfd, name_z, &st, flags) != 0) {
            errors.writeErrIn(dir_path, name, errors.errnoMessage());
            ctx.had_error.store(true, .monotonic);
            continue;
        }

        const is_dir = (st.mode & 0o170000) == 0o040000;
        const dev: u64 = @intCast(st.dev);

        if (!is_dir) {
            if (st.nlink > 1 and ctx.files.seen(dev, st.ino)) continue;
            const size: i64 = accounting.statBytes(st.size, st.blocks, ctx.opts.apparent);
            local_bytes.* += size;
        } else {
            if (ctx.dirs.seen(dev, st.ino)) continue;
            const size: i64 = accounting.statBytes(st.size, st.blocks, ctx.opts.apparent);
            local_bytes.* += size;

            if (joinPath(ctx.allocator, dir_path, name)) |child_path| {
                spill[spill_count.*] = .{ .path = child_path, .dev = dev, .size = size };
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

fn allocatedSizeAt(dirfd: c_int, name: []const u8, apparent: bool) i64 {
    var name_zbuf: [1024:0]u8 = undefined;
    if (name.len >= name_zbuf.len) return 0;
    @memcpy(name_zbuf[0..name.len], name);
    name_zbuf[name.len] = 0;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(dirfd, &name_zbuf, &st, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return 0;
    return accounting.statBytes(st.size, st.blocks, apparent);
}

pub fn workerFn(ctx: *WorkerContext) void {
    var attrList: sys.AttrList = .{
        .bitmapcount = sys.ATTR_BIT_MAP_COUNT,
        .commonattr = sys.ATTR_CMN_RETURNED_ATTRS | sys.ATTR_CMN_NAME | sys.ATTR_CMN_OBJTYPE | sys.ATTR_CMN_FILEID,
    };
    if (ctx.opts.apparent) {
        attrList.fileattr = sys.ATTR_FILE_DATALENGTH | sys.ATTR_FILE_LINKCOUNT;
        attrList.dirattr = sys.ATTR_DIR_DATALENGTH | sys.ATTR_DIR_LINKCOUNT;
    } else {
        attrList.fileattr = sys.ATTR_FILE_ALLOCSIZE | sys.ATTR_FILE_LINKCOUNT;
        attrList.dirattr = sys.ATTR_DIR_ALLOCSIZE | sys.ATTR_DIR_LINKCOUNT;
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

        var dirfd = sys.open(current.path.z(), 0x0000); // O_RDONLY
        if (dirfd < 0) {
            errors.writeErr(current.path.slice(), errors.errnoMessage());
            ctx.had_error.store(true, .monotonic);
            local_bytes -= current.size;
            current.path.deinit(ctx.allocator);
            if (local_top == 0) {
                ctx.queue.taskDone();
            }
            continue;
        }

        const parent_slice = current.path.slice();
        var bulk_attempts: usize = 0;

        while (true) {
            const ret = sys.getattrlistbulk(dirfd, &attrList, &buf, buf.len, 0);
            if (ret < 0) {
                const e = sys.__error().*;
                if (bulk_attempts == 0 and (e == sys.ENOTSUP or e == sys.EINVAL or e == sys.EACCES)) {
                    scanDirPosixFallback(ctx, dirfd, parent_slice, current.dev, &local_bytes, &spill, &spill_count);
                    dirfd = -1; // Closed by scanDirPosixFallback
                } else {
                    errors.writeErr(parent_slice, errors.errnoMessage());
                    ctx.had_error.store(true, .monotonic);
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
                if ((ret_common & sys.ATTR_CMN_OBJTYPE) != 0) {
                    obj_type = readU32(buf[offset..].ptr);
                    offset += 4;
                }

                var fileid: u64 = 0;
                if ((ret_common & sys.ATTR_CMN_FILEID) != 0) {
                    fileid = readU64(buf[offset..].ptr);
                    offset += 8;
                }

                var linkcount: u32 = 1;
                var allocsize: i64 = 0;

                if (obj_type == sys.VDIR) {
                    if ((ret_dir & sys.ATTR_DIR_LINKCOUNT) != 0) {
                        linkcount = readU32(buf[offset..].ptr);
                        offset += 4;
                    }
                    const have_dir_size = (ret_dir & (sys.ATTR_DIR_ALLOCSIZE | sys.ATTR_DIR_DATALENGTH)) != 0;
                    if (have_dir_size) {
                        allocsize = readI64(buf[offset..].ptr);
                        offset += 8;
                    }
                    if (!have_dir_size) {
                        allocsize = allocatedSizeAt(dirfd, name_slice, ctx.opts.apparent);
                    } else if (ctx.opts.apparent) {
                        allocsize = accounting.roundUp512(allocsize);
                    }

                    if (linkcount > 1 and ctx.dirs.seen(current.dev, fileid)) {} else {
                        local_bytes += allocsize;

                        if (joinPath(ctx.allocator, parent_slice, name_slice)) |child_path| {
                            const child_item = WorkItem{ .path = child_path, .dev = current.dev, .size = allocsize };
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
                } else if (obj_type == sys.VLNK and ctx.opts.follow == .all) {
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
                                    const dir_size: i64 = accounting.statBytes(st.size, st.blocks, ctx.opts.apparent);
                                    local_bytes += dir_size;

                                    if (joinPath(ctx.allocator, parent_slice, name_slice)) |child_path| {
                                        const child_item = WorkItem{ .path = child_path, .dev = dev, .size = dir_size };
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
                                    local_bytes += accounting.statBytes(st.size, st.blocks, ctx.opts.apparent);
                                }
                            }
                        }
                    }
                } else {
                    if ((ret_file & sys.ATTR_FILE_LINKCOUNT) != 0) {
                        linkcount = readU32(buf[offset..].ptr);
                        offset += 4;
                    }
                    const have_file_size = (ret_file & (sys.ATTR_FILE_ALLOCSIZE | sys.ATTR_FILE_DATALENGTH)) != 0;
                    if (have_file_size) {
                        allocsize = readI64(buf[offset..].ptr);
                        offset += 8;
                    }
                    if (!have_file_size) {
                        allocsize = allocatedSizeAt(dirfd, name_slice, ctx.opts.apparent);
                    } else if (ctx.opts.apparent) {
                        allocsize = accounting.roundUp512(allocsize);
                    }

                    if (linkcount > 1 and ctx.files.seen(current.dev, fileid)) {} else {
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
            _ = sys.close(dirfd);
        }
        current.path.deinit(ctx.allocator);

        if (local_top == 0) {
            ctx.queue.taskDone();
        }
    }

    if (local_bytes != 0) {
        _ = ctx.total_bytes.fetchAdd(local_bytes, .monotonic);
    }
}

pub const ScanResult = struct {
    bytes: i64,
    err: bool,
    printable: bool = true,
};

pub fn scanTarget(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: *const Options,
    files: *InodeSet,
) ScanResult {
    const zpath = dupePathZ(allocator, path) catch return .{ .bytes = 0, .err = true, .printable = false };
    defer zpath.deinit(allocator);

    var st: std.c.Stat = undefined;
    const flags: u32 = if (opts.follow != .none) 0 else std.posix.AT.SYMLINK_NOFOLLOW;
    if (std.c.fstatat(std.posix.AT.FDCWD, zpath.z(), &st, flags) != 0) {
        errors.writeErr(path, errors.errnoMessage());
        return .{ .bytes = 0, .err = true, .printable = false };
    }

    const is_dir = (st.mode & 0o170000) == 0o040000;
    const dev: u64 = @intCast(st.dev);

    if (!is_dir) {
        if (st.nlink > 1 and files.seen(dev, st.ino)) {
            return .{ .bytes = 0, .err = false };
        }
        const size: i64 = accounting.statBytes(st.size, st.blocks, opts.apparent);
        return .{ .bytes = size, .err = false };
    }

    const root_fd = sys.open(zpath.z(), 0x0000); // O_RDONLY
    if (root_fd < 0) {
        errors.writeErr(path, errors.errnoMessage());
        return .{ .bytes = 0, .err = true, .printable = false };
    }
    _ = sys.close(root_fd);

    var total_bytes = std.atomic.Value(i64).init(
        accounting.statBytes(st.size, st.blocks, opts.apparent),
    );
    var had_error = std.atomic.Value(bool).init(false);

    var dirs = InodeSet.init(allocator);
    defer dirs.deinit();
    _ = dirs.seen(dev, st.ino);

    var queue = WorkQueue.init(allocator, 16384) catch {
        errors.writeErr(path, "out of memory");
        return .{ .bytes = 0, .err = true, .printable = false };
    };
    defer queue.deinit();

    const initial_path = dupePathZ(allocator, path) catch {
        errors.writeErr(path, "out of memory");
        return .{ .bytes = 0, .err = true, .printable = false };
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
