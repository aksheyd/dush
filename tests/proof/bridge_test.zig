const std = @import("std");
const dush = @import("dush");
const accounting = dush.accounting;
const format = dush.format;
const InodeSet = dush.inodes.InodeSet;

const golden = @embedFile("golden");

const Entry = struct {
    op: usize,
    dev: u64,
    ino: u64,
    nlink: u64,
    blocks: i64,
    size: i64,
};

const max_entries = 64;
const max_workers = 8;

const Counts = struct {
    humanize: usize = 0,
    round: usize = 0,
    stat_bytes: usize = 0,
    blocks: usize = 0,
    traces: usize = 0,
    parallel_runs: usize = 0,
};

fn next(it: *std.mem.TokenIterator(u8, .scalar)) !i64 {
    const tok = it.next() orelse return error.ShortLine;
    return std.fmt.parseInt(i64, tok, 10);
}

fn charge(set: *InodeSet, e: Entry, apparent: bool) i64 {
    return set.chargeFile(e.dev, e.ino, e.nlink, accounting.statBytes(e.size, e.blocks, apparent));
}

const Worker = struct {
    set: *InodeSet,
    entries: []const Entry,
    apparent: bool,
    id: usize,
    n: usize,
    total: *std.atomic.Value(i64),

    fn run(self: *const Worker) void {
        var local: i64 = 0;
        var i = self.id;
        while (i < self.entries.len) : (i += self.n) {
            local += charge(self.set, self.entries[i], self.apparent);
        }
        _ = self.total.fetchAdd(local, .monotonic);
    }
};

fn checkTrace(it: *std.mem.TokenIterator(u8, .scalar), counts: *Counts) !void {
    const apparent = (try next(it)) == 1;
    const nops: usize = @intCast(try next(it));
    var op_totals: [8]i64 = undefined;
    for (op_totals[0..nops]) |*t| t.* = try next(it);
    const grand = try next(it);
    const n: usize = @intCast(try next(it));
    var entries: [max_entries]Entry = undefined;
    for (entries[0..n]) |*e| {
        e.* = .{
            .op = @intCast(try next(it)),
            .dev = @intCast(try next(it)),
            .ino = @intCast(try next(it)),
            .nlink = @intCast(try next(it)),
            .blocks = try next(it),
            .size = try next(it),
        };
    }

    var set = InodeSet.init(std.testing.allocator);
    defer set.deinit();
    var got_ops = [_]i64{0} ** 8;
    for (entries[0..n]) |e| got_ops[e.op] += charge(&set, e, apparent);
    var grand_total: i64 = 0;
    for (got_ops[0..nops], op_totals[0..nops]) |got, want| {
        try std.testing.expectEqual(want, got);
        grand_total += got;
    }
    try std.testing.expectEqual(grand, grand_total);
    counts.traces += 1;

    var workers: usize = 1;
    while (workers <= max_workers) : (workers *= 2) {
        var shared = InodeSet.init(std.testing.allocator);
        defer shared.deinit();
        var total = std.atomic.Value(i64).init(0);
        var ctxs: [max_workers]Worker = undefined;
        var threads: [max_workers]std.Thread = undefined;
        for (0..workers) |w| {
            ctxs[w] = .{ .set = &shared, .entries = entries[0..n], .apparent = apparent, .id = w, .n = workers, .total = &total };
            threads[w] = try std.Thread.spawn(.{}, Worker.run, .{&ctxs[w]});
        }
        for (threads[0..workers]) |t| t.join();
        try std.testing.expectEqual(grand, total.load(.monotonic));
        counts.parallel_runs += 1;
    }
}

test "src accounting and formatting match the Lean golden vectors" {
    var counts: Counts = .{};
    var lines = std.mem.tokenizeScalar(u8, golden, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = it.next() orelse continue;
        if (std.mem.eql(u8, kind, "H")) {
            const n = try next(&it);
            const want = it.next() orelse return error.ShortLine;
            var buf: [5]u8 = undefined;
            std.testing.expectEqualStrings(want, format.humanize(&buf, n)) catch |err| {
                std.debug.print("humanize({d})\n", .{n});
                return err;
            };
            counts.humanize += 1;
        } else if (std.mem.eql(u8, kind, "R")) {
            const n = try next(&it);
            try std.testing.expectEqual(try next(&it), accounting.roundUp512(n));
            counts.round += 1;
        } else if (std.mem.eql(u8, kind, "S")) {
            const apparent = (try next(&it)) == 1;
            const size = try next(&it);
            const blocks = try next(&it);
            try std.testing.expectEqual(try next(&it), accounting.statBytes(size, blocks, apparent));
            counts.stat_bytes += 1;
        } else if (std.mem.eql(u8, kind, "B")) {
            const bs = try next(&it);
            const n = try next(&it);
            try std.testing.expectEqual(try next(&it), accounting.toBlocks(n, bs));
            counts.blocks += 1;
        } else if (std.mem.eql(u8, kind, "A")) {
            try checkTrace(&it, &counts);
        } else return error.UnknownVector;
    }
    try std.testing.expect(counts.humanize > 1000 and counts.round > 1000 and counts.traces > 100);
}
