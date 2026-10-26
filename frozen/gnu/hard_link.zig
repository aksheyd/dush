const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) !void {
    try c.mkdir("dir/sub");
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "dir/f1", .data = "non-empty\n" });
    try c.hard("dir/f1", "dir/f2");
    try c.sym("f1", "dir/f3");
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "dir/sub/F", .data = "non-empty\n" });
    try c.mkdir("test-dir");
    try c.tmp.dir.writeFile(c.io, .{ .sub_path = "test-dir/file1", .data = "content\n" });
    try c.hard("test-dir/file1", "test-dir/file2");
}

test "gnu hard-link: link pair counted once" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("hard-link dir", &.{ "-k", "dir" }, &.{ "-sk", "dir" }, c.root);
    try c.same("hard-link -L dir", &.{ "-k", "-L", "dir" }, &.{ "-sk", "-L", "dir" }, c.root);
    try c.same("hard-link test-dir", &.{ "-k", "test-dir" }, &.{ "-sk", "test-dir" }, c.root);
    try c.same("hard-link -A test-dir", &.{ "-A", "-k", "test-dir" }, &.{ "-A", "-sk", "test-dir" }, c.root);
    try c.done();
}

test "gnu hard-link: -l counts every link [unsupported -l]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try std.testing.expect(try c.duTotal(&.{ "-skl", "test-dir" }) > try c.duTotal(&.{ "-sk", "test-dir" }));
    try c.same("hard-link -l test-dir", &.{ "-k", "-l", "test-dir" }, &.{ "-sk", "-l", "test-dir" }, c.root);
    try c.same("hard-link -l -L -I sub dir", &.{ "-k", "-l", "-L", "-I", "sub", "dir" }, &.{ "-sk", "-l", "-L", "-I", "sub", "dir" }, c.root);
    try c.done();
}

test "gnu hard-link: -a lists one name per inode [unsupported -a -I]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try setup(&c);
    try c.same("hard-link -a -I sub dir", &.{ "-k", "-a", "-I", "sub", "dir" }, &.{ "-k", "-a", "-I", "sub", "dir" }, c.root);
    try c.same("hard-link -a -L -I sub dir", &.{ "-k", "-a", "-L", "-I", "sub", "dir" }, &.{ "-k", "-a", "-L", "-I", "sub", "dir" }, c.root);
    try c.done();
}
