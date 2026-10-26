const std = @import("std");
const h = @import("harness.zig");

test "gnu 8gb: sparse 8 GiB file" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.sparse("big", 8 * 1024 * 1024 * 1024);
    try c.same("8gb -A -k", &.{ "-A", "-k", "big" }, &.{ "-A", "-sk", "big" }, c.root);
    try c.same("8gb -k", &.{ "-k", "big" }, &.{ "-sk", "big" }, c.root);
    try c.same("8gb -A -h", &.{ "-A", "big" }, &.{ "-A", "-sh", "big" }, c.root);
    try c.done();
}

test "gnu 8gb: apparent bytes [unsupported -B]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.sparse("big", 8 * 1024 * 1024 * 1024);
    try c.same("8gb -A -B 1", &.{ "-A", "-B", "1", "big" }, &.{ "-A", "-s", "-B", "1", "big" }, c.root);
    try c.done();
}

test "gnu 2g: dense file past 2 GiB [expensive: DUSH_GNU_EXPENSIVE=1]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    if (!c.flag("DUSH_GNU_EXPENSIVE")) {
        std.debug.print("skip 2g: set DUSH_GNU_EXPENSIVE=1 to write 2 GiB\n", .{});
        return error.SkipZigTest;
    }
    var f = try c.tmp.dir.createFile(c.io, "big", .{});
    defer f.close(c.io);
    const chunk = try c.alloc().alloc(u8, 1 << 20);
    @memset(chunk, 'x');
    var w = f.writer(c.io, &.{});
    for (0..2048) |_| try w.interface.writeAll(chunk);
    try w.interface.writeAll(chunk[0..48]);
    try w.interface.flush();
    try f.sync(c.io);
    try c.same("2g -k", &.{ "-k", "big" }, &.{ "-sk", "big" }, c.root);
    try c.same("2g -A -k", &.{ "-A", "-k", "big" }, &.{ "-A", "-sk", "big" }, c.root);
    try c.done();
}
