const std = @import("std");
const h = @import("harness.zig");

test "gnu restore-wd: two dir operands" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("a");
    try c.mkdir("b");
    try c.file("b/data", 5000);
    try c.same("restore-wd a b", &.{ "-k", "a", "b" }, &.{ "-sk", "a", "b" }, c.root);
    try c.done();
}

test "gnu two-args: nested and parent operands" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("sub/t/1");
    try c.mkdir("sub/t/2");
    try c.file("sub/t/1/data", 5000);
    try c.file("sub/t/2/data", 9000);
    try c.file("sub/top", 3000);
    const sub = c.p("sub");
    try c.same("two-args t/1 t/2", &.{ "-k", "t/1", "t/2" }, &.{ "-sk", "t/1", "t/2" }, sub);
    try c.same("two-args . t", &.{ "-k", ".", "t" }, &.{ "-sk", ".", "t" }, sub);
    try c.same("two-args .. t", &.{ "-k", "..", "t" }, &.{ "-sk", "..", "t" }, sub);
    try c.same("two-args t . -c", &.{ "-k", "-c", "t", "." }, &.{ "-sk", "-c", "t", "." }, sub);
    try c.done();
}

fn setupDepth(c: *h.Ctx) !void {
    try c.mkdir("a/b/c/d/e");
    try c.file("a/b/c/d/e/data", 4000);
    try c.file("a/b/data", 2000);
}

test "gnu max-depth: -d 2 [unsupported -d]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDepth(&c);
    try c.same("max-depth -d 2", &.{ "-k", "-d", "2", "a" }, &.{ "-k", "-d", "2", "a" }, c.root);
    try c.done();
}

test "gnu max-depth: -d 1 [unsupported -d]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDepth(&c);
    try c.same("max-depth -d 1", &.{ "-k", "-d", "1", "a" }, &.{ "-k", "-d", "1", "a" }, c.root);
    try c.done();
}

test "gnu max-depth: -d 0 equals -s [unsupported -d]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDepth(&c);
    try c.same("max-depth -d 0", &.{ "-k", "-d", "0", "a" }, &.{ "-k", "-d", "0", "a" }, c.root);
    try c.done();
}

test "gnu max-depth: --max-depth=2 long form [unsupported --max-depth]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDepth(&c);
    try c.same("max-depth --max-depth=2", &.{ "-k", "--max-depth=2", "a" }, &.{ "-k", "-d", "2", "a" }, c.root);
    try c.done();
}

test "gnu max-depth: negative depth is rejected [unsupported -d]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupDepth(&c);
    try c.same("max-depth -d -1", &.{ "-k", "-d", "-1", "a" }, &.{ "-k", "-d", "-1", "a" }, c.root);
    try c.done();
}

fn setupFs(c: *h.Ctx) !void {
    try c.mkdir("b/c");
    try c.mkdir("y/z");
    try c.mkdir("d");
    try c.file("b/c/data", 4000);
    try c.file("y/z/data", 6000);
    try c.sym("/dev", "d/x");
    try c.file("f", 100);
}

test "gnu one-file-system: -x on local dirs [unsupported -x]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupFs(&c);
    try c.same("one-file-system -x b y", &.{ "-k", "-x", "b", "y" }, &.{ "-sk", "-x", "b", "y" }, c.root);
    try c.same("one-file-system -x f", &.{ "-k", "-x", "f" }, &.{ "-sk", "-x", "f" }, c.root);
    try c.done();
}

test "gnu one-file-system: -x -L stops at a symlink to another fs [unsupported -x]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setupFs(&c);
    try c.same("one-file-system -x -L d", &.{ "-k", "-x", "-L", "d" }, &.{ "-sk", "-x", "-L", "d" }, c.root);
    try c.done();
}

test "gnu slash: root with everything ignored [unsupported -x -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.same("slash", &.{ "-k", "-x", "-I", "[^/]*", "/" }, &.{ "-sk", "-x", "-I", "[^/]*", "/" }, c.root);
    try c.done();
}
