const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) !u64 {
    try c.mkdir("a/b");
    try c.mkdir("a/c");
    try c.file("a/b/0", 0);
    try c.file("a/b/1", 1);
    try c.file("a/b/2", 2);
    try c.file("a/b/3", 3);
    return 512 * try c.duTotal(&.{ "-s", "-B", "512", "a" });
}

test "gnu threshold: invalid sizes are rejected [unsupported -t threshold]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    _ = try setup(&c);
    try c.same("threshold -t SIZE", &.{ "-k", "-t", "SIZE", "a" }, &.{ "-sk", "-t", "SIZE", "a" }, c.root);
    try c.same("threshold -t -0", &.{ "-k", "-t", "-0", "a" }, &.{ "-sk", "-t", "-0", "a" }, c.root);
    try c.same("threshold -t ''", &.{ "-k", "-t", "", "a" }, &.{ "-sk", "-t", "", "a" }, c.root);
    try c.done();
}

test "gnu threshold: positive and negative bounds around the total [unsupported -t threshold]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const total = try setup(&c);
    const values = [_]i64{ 1, 0, -1 };
    for (values) |delta| {
        const n: i64 = @as(i64, @intCast(total)) + delta;
        for ([_]i64{ n, -n }) |t| {
            const arg = c.fmt("{d}", .{t});
            try c.same(c.fmt("threshold -t {s}", .{arg}), &.{ "-k", "-t", arg, "a" }, &.{ "-sk", "-t", arg, "a" }, c.root);
        }
    }
    try c.done();
}

test "gnu threshold: --threshold long form [unsupported --threshold]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const total = try setup(&c);
    const arg = c.fmt("{d}", .{total + 1});
    try c.same("threshold --threshold", &.{ "-k", c.fmt("--threshold={s}", .{arg}), "a" }, &.{ "-sk", "-t", arg, "a" }, c.root);
    try c.done();
}
