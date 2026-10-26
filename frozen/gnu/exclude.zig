const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) !void {
    for ([_][]const u8{ "a/b/c", "a/x/y", "a/u/v" }) |d| {
        try c.mkdir(d);
        try c.file(c.fmt("{s}/data", .{d}), 4096 * 3);
    }
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "excl", .data = "b\n" });
}

test "gnu exclude: -I one name [unsupported -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("exclude -I x", &.{ "-k", "-I", "x", "a" }, &.{ "-sk", "-I", "x", "a" }, c.root);
    try c.done();
}

test "gnu exclude: patterns from a file [unsupported --exclude-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("exclude --exclude-from", &.{ "-k", "--exclude-from=excl", "a" }, &.{ "-sk", "-I", "b", "a" }, c.root);
    try c.done();
}

test "gnu exclude: pattern matching the operand itself [unsupported -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("exclude -I a a", &.{ "-k", "-I", "a", "a" }, &.{ "-sk", "-I", "a", "a" }, c.root);
    try c.done();
}

test "gnu exclude: patterns with a slash [unsupported -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("exclude -I a/u -I a/b", &.{ "-k", "-I", "a/u", "-I", "a/b", "a" }, &.{ "-sk", "-I", "a/u", "-I", "a/b", "a" }, c.root);
    try c.done();
}

test "gnu exclude: --exclude long form [unsupported --exclude]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("exclude --exclude=x", &.{ "-k", "--exclude=x", "a" }, &.{ "-sk", "-I", "x", "a" }, c.root);
    try c.done();
}
