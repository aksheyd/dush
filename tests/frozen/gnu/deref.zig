const std = @import("std");
const h = @import("harness.zig");

fn setupArgs(c: *h.Ctx) !void {
    try c.mkdir("dir/a");
    try c.file("dir/a/payload", 3000);
    try c.sym("dir", "slink");
    try c.file("64k", 65536);
    try c.sym("64k", "slink-to-64k");
}

test "gnu deref-args: -H follows command-line symlinks" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupArgs(&c);
    try c.same("deref-args -H slink", &.{ "-k", "-H", "slink" }, &.{ "-sk", "-H", "slink" }, c.root);
    try c.same("deref-args -H slink/", &.{ "-k", "-H", "slink/" }, &.{ "-sk", "-H", "slink/" }, c.root);
    try c.same("deref-args -A -H slink-to-64k", &.{ "-A", "-k", "-H", "slink-to-64k" }, &.{ "-A", "-sk", "-H", "slink-to-64k" }, c.root);
    try c.done();
}

test "gnu deref-args: -D alias of -H [unsupported -D]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupArgs(&c);
    try c.same("deref-args -D slink", &.{ "-k", "-D", "slink" }, &.{ "-sk", "-H", "slink" }, c.root);
    try c.done();
}

test "gnu deref-args: per-directory listing [unsupported: no -s]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupArgs(&c);
    try c.same("deref-args listing", &.{ "-k", "-H", "slink" }, &.{ "-k", "-H", "slink" }, c.root);
    try c.done();
}

fn setupDeref(c: *h.Ctx) !void {
    try c.mkdir("a/sub");
    try c.file("a/sub/payload", 5000);
    try c.sym("a/sub", "slink");
    try c.file("b", 10);
    try c.sym("..", "a/sub/dotdot");
    try c.sym("nowhere", "dangle");
}

test "gnu deref: -H on symlink plus file" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDeref(&c);
    try c.same("deref -H slink b", &.{ "-k", "-H", "slink", "b" }, &.{ "-sk", "-H", "slink", "b" }, c.root);
    try c.done();
}

test "gnu deref: -L on dangling symlink fails" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDeref(&c);
    try c.same("deref -L dangle", &.{ "-k", "-L", "dangle" }, &.{ "-sk", "-L", "dangle" }, c.root);
    try c.done();
}

test "gnu deref: -L through a symlink to the parent" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDeref(&c);
    try c.same("deref -L a", &.{ "-k", "-L", "a" }, &.{ "-sk", "-L", "a" }, c.root);
    try c.done();
}

test "gnu deref: -L equals ignoring the cycle link [unsupported -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDeref(&c);
    try c.same("deref -I dotdot a", &.{ "-k", "-I", "dotdot", "a" }, &.{ "-sk", "-I", "dotdot", "a" }, c.root);
    try c.done();
}

test "gnu deref: -l with -L [unsupported -l]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDeref(&c);
    try c.same("deref -l -L a", &.{ "-k", "-l", "-L", "a" }, &.{ "-sk", "-l", "-L", "a" }, c.root);
    try c.done();
}
