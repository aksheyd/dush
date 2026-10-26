const std = @import("std");
const h = @import("harness.zig");

test "gnu long-sloop: 400-link symlink chain under -L" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    for (1..401) |i| try c.mkdir(c.fmt("{d}", .{i}));
    for (1..401) |i| try c.sym(c.fmt("../{d}", .{i + 1}), c.fmt("{d}/s", .{i}));
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "401", .data = "foo\n" });
    try c.same("long-sloop -L 1", &.{ "-k", "-L", "1" }, &.{ "-sk", "-L", "1" }, c.root);
    try c.same("long-sloop -P 1", &.{ "-k", "-P", "1" }, &.{ "-sk", "-P", "1" }, c.root);
    try c.done();
}

test "gnu no-deref: symlink operand is not followed by default" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("dir/a/b");
    try c.file("dir/a/b/data", 8000);
    try c.sym("dir", "slink");
    try c.same("no-deref slink", &.{ "-k", "slink" }, &.{ "-sk", "slink" }, c.root);
    try c.same("no-deref -P slink", &.{ "-k", "-P", "slink" }, &.{ "-sk", "-P", "slink" }, c.root);
    try c.done();
}

fn setupTrailing(c: *h.Ctx) !void {
    try c.mkdir("dir/1/2");
    try c.file("dir/1/2/data", 6000);
    try c.sym("dir", "slink");
}

test "gnu trailing-slash: symlink to dir with a trailing slash" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupTrailing(&c);
    try c.same("trailing-slash slink/", &.{ "-k", "slink/" }, &.{ "-sk", "slink/" }, c.root);
    try c.same("trailing-slash -L slink", &.{ "-k", "-L", "slink" }, &.{ "-sk", "-L", "slink" }, c.root);
    try c.same("trailing-slash dir/", &.{ "-k", "dir/" }, &.{ "-sk", "dir/" }, c.root);
    try c.same("trailing-slash dir//", &.{ "-k", "dir//" }, &.{ "-sk", "dir//" }, c.root);
    try c.done();
}

test "gnu trailing-slash: per-directory listing [unsupported: no -s]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupTrailing(&c);
    try c.same("trailing-slash listing slink/", &.{ "-k", "slink/" }, &.{ "-k", "slink/" }, c.root);
    try c.same("trailing-slash listing -L slink", &.{ "-k", "-L", "slink" }, &.{ "-k", "-L", "slink" }, c.root);
    try c.done();
}
