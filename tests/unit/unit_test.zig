const std = @import("std");
const dush = @import("dush");
const humanize = dush.format.humanize;
const roundUp512 = dush.accounting.roundUp512;
const joinPath = dush.path.joinPath;
const dupePathZ = dush.path.dupePathZ;
const InodeSet = dush.inodes.InodeSet;
const defaultThreadCount = dush.cli.defaultThreadCount;
const WorkQueue = dush.walk.WorkQueue;
const WorkItem = dush.walk.WorkItem;
const WorkerContext = dush.walk.WorkerContext;
const workerFn = dush.walk.workerFn;
const Options = dush.cli.Options;
const dup = dush.sys.dup;
const dup2 = dush.sys.dup2;
const open = dush.sys.open;
const close = dush.sys.close;

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

test "roundUp512 matches du -A per-entry rounding" {
    try std.testing.expectEqual(@as(i64, 0), roundUp512(0));
    try std.testing.expectEqual(@as(i64, 512), roundUp512(1));
    try std.testing.expectEqual(@as(i64, 512), roundUp512(512));
    try std.testing.expectEqual(@as(i64, 1024), roundUp512(513));
}

test "joinPath" {
    const allocator = std.testing.allocator;
    const p1 = try joinPath(allocator, "foo", "bar");
    defer p1.deinit(allocator);
    try std.testing.expectEqualStrings("foo/bar", p1.slice());

    const p2 = try joinPath(allocator, "foo/", "bar");
    defer p2.deinit(allocator);
    try std.testing.expectEqualStrings("foo//bar", p2.slice());

    const p3 = try joinPath(allocator, "/", "usr");
    defer p3.deinit(allocator);
    try std.testing.expectEqualStrings("/usr", p3.slice());
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

test "default threads prefer performance cores" {
    try std.testing.expectEqual(@as(usize, 4), defaultThreadCount(4, 10));
    try std.testing.expectEqual(@as(usize, 8), defaultThreadCount(8, 8));
    try std.testing.expectEqual(@as(usize, 8), defaultThreadCount(null, 8));
    try std.testing.expectEqual(@as(usize, 10), defaultThreadCount(0, 10));
    try std.testing.expectEqual(@as(usize, 1), defaultThreadCount(null, 0));
    try std.testing.expectEqual(@as(usize, 64), defaultThreadCount(null, 128));
    try std.testing.expectEqual(@as(usize, 64), defaultThreadCount(80, 96));
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

test "a directory that vanishes before it is opened is reported and not counted" {
    const allocator = std.testing.allocator;
    var queue = try WorkQueue.init(allocator, 16);
    defer queue.deinit();
    var files = InodeSet.init(allocator);
    defer files.deinit();
    var dirs = InodeSet.init(allocator);
    defer dirs.deinit();
    const opts = Options{ .apparent = true };
    var total_bytes = std.atomic.Value(i64).init(1024);
    var had_error = std.atomic.Value(bool).init(false);
    var batch: [1]WorkItem = .{.{ .path = try dupePathZ(allocator, "/nonexistent-dush-test/gone"), .dev = 0, .size = 512 }};
    queue.pushBatch(&batch);
    var ctx = WorkerContext{
        .allocator = allocator,
        .queue = &queue,
        .files = &files,
        .dirs = &dirs,
        .opts = &opts,
        .total_bytes = &total_bytes,
        .had_error = &had_error,
    };
    const saved_stderr = dup(std.posix.STDERR_FILENO);
    try std.testing.expect(saved_stderr >= 0);
    const devnull = open("/dev/null", 0x0001);
    try std.testing.expect(devnull >= 0);
    _ = dup2(devnull, std.posix.STDERR_FILENO);
    _ = close(devnull);
    workerFn(&ctx);
    _ = dup2(saved_stderr, std.posix.STDERR_FILENO);
    _ = close(saved_stderr);
    try std.testing.expectEqual(@as(i64, 512), total_bytes.load(.monotonic));
    try std.testing.expect(had_error.load(.monotonic));
}

test "statBytes and toBlocks round like du" {
    try std.testing.expectEqual(@as(i64, 1024), dush.accounting.statBytes(513, 8, true));
    try std.testing.expectEqual(@as(i64, 4096), dush.accounting.statBytes(513, 8, false));
    try std.testing.expectEqual(@as(i64, 1), dush.accounting.toBlocks(1, 1024));
    try std.testing.expectEqual(@as(i64, 0), dush.accounting.toBlocks(0, 1024));
    try std.testing.expectEqual(@as(i64, 2), dush.accounting.toBlocks(1025, 1024));
}
