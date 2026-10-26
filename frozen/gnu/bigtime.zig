const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) !bool {
    try c.file("future", 100);
    var f = try c.tmp.dir.openFile(c.io, "future", .{ .mode = .read_write });
    defer f.close(c.io);
    const far: std.Io.Timestamp = .{ .nanoseconds = @as(i96, std.math.maxInt(i64)) * std.time.ns_per_s };
    f.setTimestamps(c.io, .{ .modify_timestamp = .{ .new = far } }) catch return false;
    return true;
}

test "gnu bigtime: file with a far-future mtime" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    if (!try setup(&c)) {
        std.debug.print("skip bigtime: file system rejects the timestamp\n", .{});
        return error.SkipZigTest;
    }
    try c.same("bigtime -k", &.{ "-k", "future" }, &.{ "-sk", "future" }, c.root);
    try c.same("bigtime -A -k", &.{ "-A", "-k", "future" }, &.{ "-A", "-sk", "future" }, c.root);
    try c.done();
}

test "gnu bigtime: mtime column [unsupported --time]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    if (!try setup(&c)) return error.SkipZigTest;
    const size = try c.duTotal(&.{ "-sk", "future" });
    const got = try c.dushRun(&.{ "-k", "--time", "future" }, c.root);
    const prefix = c.fmt("{d}\t", .{size});
    if (got.code != 0 or !std.mem.startsWith(u8, got.stdout, prefix) or std.mem.count(u8, got.stdout, "\t") != 2) {
        std.debug.print("MISMATCH bigtime --time\n  exit {?d}\n  stdout {s}\n  stderr {s}\n", .{ got.code, got.stdout, got.stderr });
        return error.Mismatch;
    }
    try c.done();
}
