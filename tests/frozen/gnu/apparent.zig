const std = @import("std");
const h = @import("harness.zig");

fn setup(c: *h.Ctx) ![]const []const u8 {
    try c.mkdir("d");
    var list: std.ArrayList([]const u8) = .empty;
    for (1..101) |i| {
        const rel = c.fmt("d/{d}", .{i});
        try c.tmp.dir.writeFile(c.io, .{ .sub_path = rel, .data = "foo\n" });
        try list.append(c.alloc(), rel);
    }
    return list.items;
}

test "gnu apparent: each file and the dir" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const files = try setup(&c);
    const a = c.alloc();
    try c.same("apparent separate -A -k", try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-k" }, files }), try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-sk" }, files }), c.root);
    try c.same("apparent separate -A -k -c", try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-k", "-c" }, files }), try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-sk", "-c" }, files }), c.root);
    try c.same("apparent together -A -k", &.{ "-A", "-k", "d" }, &.{ "-A", "-sk", "d" }, c.root);
    try c.same("apparent -b alias", &.{ "-b", "-k", "d" }, &.{ "-A", "-sk", "d" }, c.root);
    try c.same("apparent --apparent-size", &.{ "--apparent-size", "-k", "d" }, &.{ "-A", "-sk", "d" }, c.root);
    try c.done();
}

test "gnu apparent: byte totals agree [unsupported -B]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const files = try setup(&c);
    const a = c.alloc();
    try c.same("apparent together -A -B 1", &.{ "-A", "-B", "1", "d" }, &.{ "-A", "-s", "-B", "1", "d" }, c.root);
    try c.same("apparent separate -A -B 1 -c", try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-B", "1", "-c" }, files }), try std.mem.concat(a, []const u8, &.{ &.{ "-A", "-s", "-B", "1", "-c" }, files }), c.root);
    try c.done();
}
