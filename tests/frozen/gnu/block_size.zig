const std = @import("std");
const h = @import("harness.zig");

const names = [_][]const u8{ "100kb", "100kib", "100mb", "100mib", "10kb", "10kib", "10mb", "10mib", "1kb", "1kib", "1mb", "1mib" };
const sizes = [_]u64{ 100000, 102400, 100000000, 104857600, 10000, 10240, 10000000, 10485760, 1000, 1024, 1000000, 1048576 };

fn setup(c: *h.Ctx) !void {
    for (names, sizes) |n, s| try c.sparse(n, s);
}

fn args(c: *h.Ctx, pre: []const []const u8) ![]const []const u8 {
    return std.mem.concat(c.alloc(), []const u8, &.{ pre, &names });
}

test "gnu block-size: apparent KiB" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -A -k", try args(&c, &.{ "-A", "-k" }), try args(&c, &.{ "-A", "-sk" }), c.root);
    try c.done();
}

test "gnu block-size: apparent MiB" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -A -m", try args(&c, &.{ "-A", "-m" }), try args(&c, &.{ "-A", "-sm" }), c.root);
    try c.done();
}

test "gnu block-size: apparent human" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -A -h", try args(&c, &.{"-A"}), try args(&c, &.{ "-A", "-sh" }), c.root);
    try c.done();
}

test "gnu block-size: disk usage KiB of sparse files" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -k", try args(&c, &.{"-k"}), try args(&c, &.{"-sk"}), c.root);
    try c.done();
}

test "gnu block-size: explicit KiB block size [unsupported -B]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -A -B 1024", try args(&c, &.{ "-A", "-B", "1024" }), try args(&c, &.{ "-A", "-s", "-B", "1024" }), c.root);
    try c.done();
}

test "gnu block-size: explicit MiB block size [unsupported -B]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("block-size -A -B 1048576", try args(&c, &.{ "-A", "-B", "1048576" }), try args(&c, &.{ "-A", "-s", "-B", "1048576" }), c.root);
    try c.done();
}
