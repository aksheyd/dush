const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) !void {
    try c.mkdir("a/b");
    try c.mkdir("d/sub");
    try c.file("a/b/F", 257);
    try c.file("d/1", 4096);
    try c.file("d/sub/2", 4096);
    try c.file("q name", 0);
}

fn blocks(c: *h.Ctx, rel: []const u8) !u64 {
    return c.duTotal(&.{ "-s", "-B", "512", rel });
}

fn kib(b512: u64) u64 {
    return (b512 + 1) / 2;
}

test "gnu basic: empty file whose name has a space" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("basic q-name -k", &.{ "-k", "q name" }, &.{ "-sk", "q name" }, c.root);
    try c.same("basic q-name -A -k", &.{ "-A", "-k", "q name" }, &.{ "-A", "-sk", "q name" }, c.root);
    try c.same("basic q-name -h", &.{"q name"}, &.{ "-sh", "q name" }, c.root);
    try c.done();
}

test "gnu basic: nul line terminator [unsupported -0]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    const want = try c.du(&.{ "-sk", "q name" }, c.root);
    const out = try c.alloc().dupe(u8, want.stdout);
    std.mem.replaceScalar(u8, out, '\n', 0);
    try c.expect("basic -0", &.{ "-k", "-0", "q name" }, out, 0, c.root);
    try c.done();
}

test "gnu basic: summary of a" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("basic -s a", &.{ "-k", "a" }, &.{ "-sk", "a" }, c.root);
    try c.same("basic -s d", &.{ "-k", "d" }, &.{ "-sk", "d" }, c.root);
    try c.same("basic -s a d", &.{ "-k", "a", "d" }, &.{ "-sk", "a", "d" }, c.root);
    try c.done();
}

test "gnu basic: 512-byte block size [unsupported -B]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("basic -B 512 a", &.{ "-B", "512", "a" }, &.{ "-s", "-B", "512", "a" }, c.root);
    try c.done();
}

test "gnu basic: every file listed [unsupported -a]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("basic -a a", &.{ "-k", "-a", "a" }, &.{ "-k", "-a", "a" }, c.root);
    try c.same("basic -a d", &.{ "-k", "-a", "d" }, &.{ "-k", "-a", "d" }, c.root);
    try c.done();
}

test "gnu basic: separate dirs [unsupported -S]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    const ab = try blocks(&c, "a/b");
    const a = try blocks(&c, "a");
    const want_a = c.fmt("{d}\ta/b\n{d}\ta\n", .{ kib(ab), kib(a - ab) });
    try c.expect("basic -S a", &.{ "-k", "-S", "a" }, want_a, 0, c.root);
    const sub = try blocks(&c, "d/sub");
    const d = try blocks(&c, "d");
    const want_d = c.fmt("{d}\td/sub\n{d}\td\n", .{ kib(sub), kib(d - sub) });
    try c.expect("basic -S d", &.{ "-k", "-S", "d" }, want_d, 0, c.root);
    try c.done();
}
