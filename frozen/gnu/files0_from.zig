const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx, list: []const u8) !void {
    try c.file("g", 0);
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "list", .data = list });
}

fn viaDu(c: *h.Ctx, label: []const u8, list: []const u8, extra: []const []const u8, names: []const []const u8, code: ?u8) !void {
    try setup(c, list);
    const a = c.alloc();
    const want = try c.du(try std.mem.concat(a, []const u8, &.{ &.{"-sk"}, extra, names }), c.root);
    try c.expect(label, try std.mem.concat(a, []const u8, &.{ &.{"-k"}, extra, &.{"--files0-from=list"} }), want.stdout, code orelse want.code.?, c.root);
}

test "gnu files0-from: extra operand is rejected [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c, "a");
    try c.expect("files0-from f-extra-arg", &.{ "-k", "--files0-from=list", "no-such" }, "", 1, c.root);
    try c.done();
}

test "gnu files0-from: missing list file [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.expect("files0-from missing1", &.{ "-k", "--files0-from=missing" }, "", 1, c.root);
    try c.done();
}

test "gnu files0-from: list names missing files [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from missing2", "missing\x00missing\x00", &.{}, &.{ "missing", "missing" }, null);
    try c.done();
}

test "gnu files0-from: duplicate names [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from duplicate1", "g\x00g\x00", &.{}, &.{ "g", "g" }, null);
    try c.done();
}

test "gnu files0-from: duplicate names with -l [unsupported --files0-from -l]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from duplicate2", "g\x00g\x00", &.{"-l"}, &.{ "g", "g" }, null);
    try c.done();
}

test "gnu files0-from: '-' named in a list read from stdin [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c, "");
    const got = try c.exec(&.{ "/bin/sh", "-c", "printf '%s' - | \"$0\" -k --files0-from=-", c.dush }, c.root, null);
    if (got.code != 1 or got.stdout.len != 0 or got.stderr.len == 0) {
        std.debug.print("MISMATCH files0-from minus-in-stdin\n  exit {?d}\n  stdout {s}\n  stderr {s}\n", .{ got.code, got.stdout, got.stderr });
        return error.Mismatch;
    }
    try c.done();
}

test "gnu files0-from: empty regular list [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c, "");
    try c.expect("files0-from empty", &.{ "-k", "--files0-from=list" }, "", 0, c.root);
    try c.done();
}

test "gnu files0-from: empty non-regular list [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.expect("files0-from empty-nonreg", &.{ "-k", "--files0-from=/dev/null" }, "", 0, c.root);
    try c.done();
}

test "gnu files0-from: one zero-length name [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c, "\x00");
    try c.expect("files0-from nul-1", &.{ "-k", "--files0-from=list" }, "", 1, c.root);
    try c.done();
}

test "gnu files0-from: two zero-length names [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c, "\x00\x00");
    try c.expect("files0-from nul-2", &.{ "-k", "--files0-from=list" }, "", 1, c.root);
    try c.done();
}

test "gnu files0-from: one name without terminator [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from 1", "g", &.{}, &.{"g"}, null);
    try c.done();
}

test "gnu files0-from: one name with terminator [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from 1a", "g\x00", &.{}, &.{"g"}, null);
    try c.done();
}

test "gnu files0-from: same name twice without final terminator [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from 2", "g\x00g", &.{}, &.{ "g", "g" }, null);
    try c.done();
}

test "gnu files0-from: same name twice with final terminator [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from 2a", "g\x00g\x00", &.{}, &.{ "g", "g" }, null);
    try c.done();
}

test "gnu files0-from: names after a zero-length name still count [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try viaDu(&c, "files0-from zero-len", "\x00g\x00", &.{}, &.{"g"}, 1);
    try c.done();
}

test "gnu files0-from-dir: list is a directory [unsupported --files0-from]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("dir");
    try c.expect("files0-from-dir", &.{ "-k", "--files0-from=dir" }, "", 1, c.root);
    try c.done();
}
