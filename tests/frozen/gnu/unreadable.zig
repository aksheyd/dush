const std = @import("std");
const h = @import("harness.zig");

test "gnu inacc-dest: unsearchable subdir, operand ." {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    for ([_][]const u8{ "f/a", "f/b", "f/c", "f/d", "f/e" }) |d| try c.mkdir(d);
    try c.file("f/c/j", 0);
    try c.file("f/a/data", 9000);
    try c.chmod("a-x", "f/c");
    const f = c.p("f");
    try c.same("inacc-dest no operand", &.{"-k"}, &.{"-sk"}, f);
    try c.same("inacc-dest .", &.{ "-k", "." }, &.{ "-sk", "." }, f);
    try c.same("inacc-dest f", &.{ "-k", "f" }, &.{ "-sk", "f" }, c.root);
    try c.done();
}

test "gnu inacc-dir: mode-0 subdir keeps the total" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("a/sub");
    try c.file("a/top", 5000);
    try c.file("a/sub/inner", 7000);
    try c.same("inacc-dir readable", &.{ "-k", "a" }, &.{ "-sk", "a" }, c.root);
    try c.chmod("0", "a/sub");
    try c.same("inacc-dir mode 0", &.{ "-k", "a" }, &.{ "-sk", "a" }, c.root);
    try c.same("inacc-dir mode 0 -h", &.{"a"}, &.{ "-sh", "a" }, c.root);
    try c.done();
}

test "gnu inaccessible-cwd: absolute operand from a mode-0 cwd" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("no-x");
    try c.mkdir("a/b");
    try c.file("a/b/data", 6000);
    const a = c.p("a");
    try c.sameLocked("inaccessible-cwd", "no-x", &.{ "-k", a }, &.{ "-sk", a });
    try c.done();
}

test "gnu no-x: dir without search permission" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("d/no-x/y");
    try c.file("d/keep", 3000);
    try c.chmod("u=rw", "d/no-x");
    try c.same("no-x d", &.{ "-k", "d" }, &.{ "-sk", "d" }, c.root);
    try c.done();
}

test "gnu long-from-unreadable: path deeper than PATH_MAX from a mode-0 cwd" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const name = "x" ** 200;
    var dir = try c.tmp.dir.createDirPathOpen(c.io, name, .{});
    for (0..51) |_| {
        const next = try dir.createDirPathOpen(c.io, name, .{});
        dir.close(c.io);
        dir = next;
    }
    try dir.writeFile(c.io, .{ .sub_path = "leaf", .data = "x" ** 5000 });
    dir.close(c.io);
    try c.mkdir("inaccessible");
    const top = c.p(name);
    try c.sameLocked("long-from-unreadable", "inaccessible", &.{ "-k", top }, &.{ "-sk", top });
    try c.done();
}
