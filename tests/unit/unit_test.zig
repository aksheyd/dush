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
const Scale = dush.accounting.Scale;
const linkStep = dush.inodes.linkStep;
const dup = dush.sys.dup;
const dup2 = dush.sys.dup2;
const open = dush.sys.open;
const close = dush.sys.close;

test "humanize matches du -h formatting" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("0B", humanize(&buf, .binary, 0));
    try std.testing.expectEqualStrings("100B", humanize(&buf, .binary, 100));
    try std.testing.expectEqualStrings("999B", humanize(&buf, .binary, 999));
    try std.testing.expectEqualStrings("1.0K", humanize(&buf, .binary, 1000));
    try std.testing.expectEqualStrings("1.0K", humanize(&buf, .binary, 1024));
    try std.testing.expectEqualStrings("1.5K", humanize(&buf, .binary, 1536));
    try std.testing.expectEqualStrings("9.5K", humanize(&buf, .binary, 9730));
    try std.testing.expectEqualStrings("49K", humanize(&buf, .binary, 50000));
    try std.testing.expectEqualStrings("1.0M", humanize(&buf, .binary, 1048576));
    try std.testing.expectEqualStrings("1.5M", humanize(&buf, .binary, 1572864));
    try std.testing.expectEqualStrings("1.0G", humanize(&buf, .binary, 1073741824));
    try std.testing.expectEqualStrings("1.0k", humanize(&buf, .si, 1000));
    try std.testing.expectEqualStrings("1.0M", humanize(&buf, .si, 1000000));
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

    const p4 = try joinPath(allocator, "foo//", "bar");
    defer p4.deinit(allocator);
    try std.testing.expectEqualStrings("foo///bar", p4.slice());

    const p3 = try joinPath(allocator, "/", "usr");
    defer p3.deinit(allocator);
    try std.testing.expectEqualStrings("/usr", p3.slice());
}

test "linkStep counts each inode once and forgets it after its last link" {
    const first = linkStep(false, 0, 3);
    try std.testing.expect(!first.skip and first.live and first.links == 2);
    const second = linkStep(true, first.links, 3);
    try std.testing.expect(second.skip and second.live and second.links == 1);
    const third = linkStep(true, second.links, 3);
    try std.testing.expect(third.skip and !third.live);
    const again = linkStep(false, third.links, 3);
    try std.testing.expect(!again.skip and again.live);
}

test "inodeset visit follows du's link countdown" {
    const allocator = std.testing.allocator;
    var s = InodeSet.init(allocator);
    defer s.deinit();

    try std.testing.expect(!s.visit(1, 100, 2));
    try std.testing.expect(s.visit(1, 100, 2));
    try std.testing.expect(!s.visit(1, 100, 2));
    try std.testing.expect(!s.visit(1, 101, 2));
    try std.testing.expect(!s.visit(2, 100, 2));
    try std.testing.expect(!s.visit(0, 0, 2));
    try std.testing.expect(!s.visit(0, 0, 2));
}

test "Scale matches du's block arithmetic" {
    const def = Scale.init(false, 512, 512);
    try std.testing.expectEqual(@as(i64, 8), def.entryBlocks(513, 8));
    try std.testing.expectEqual(@as(i64, 8), def.display(8));
    try std.testing.expect(def.fastPathCompatible());

    const k = Scale.init(false, 512, 1024);
    try std.testing.expectEqual(@as(i64, 4), k.display(8));
    try std.testing.expectEqual(@as(i64, 1), k.display(1));
    try std.testing.expectEqual(@as(i64, 4096), k.humanBytes(8));

    const b1000 = Scale.init(false, 1000, 512);
    try std.testing.expectEqual(@as(i64, 2), b1000.cblocksize);
    try std.testing.expectEqual(@as(i64, 4), b1000.entryBlocks(0, 8));
    try std.testing.expect(!b1000.fastPathCompatible());

    const a = Scale.init(true, 512, 512);
    try std.testing.expectEqual(@as(i64, 2), a.entryBlocks(513, 8));
    try std.testing.expectEqual(@as(i64, 1024), a.humanBytes(2));
    try std.testing.expect(a.fastPathCompatible());

    const a1 = Scale.init(true, 1, 1024);
    try std.testing.expectEqual(@as(i64, 513), a1.entryBlocks(513, 8));
    try std.testing.expectEqual(@as(i64, 1), a1.display(513));

    try std.testing.expectEqual(@as(u64, 0), k.threshold(0));
    try std.testing.expectEqual(@as(u64, 2), k.threshold(2048));
    try std.testing.expect(k.passes(k.threshold(2048), 4));
    try std.testing.expect(!k.passes(k.threshold(4096), 4));
    try std.testing.expect(!k.passes(k.threshold(std.math.maxInt(u64)), 1 << 40));
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
    var total_bytes = std.atomic.Value(i64).init(1024);
    var had_error = std.atomic.Value(bool).init(false);
    var batch: [1]WorkItem = .{.{ .path = try dupePathZ(allocator, "/nonexistent-dush-test/gone"), .dev = 0, .size = 512 }};
    queue.pushBatch(&batch);
    var ctx = WorkerContext{
        .allocator = allocator,
        .queue = &queue,
        .files = &files,
        .dirs = &dirs,
        .apparent = true,
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
