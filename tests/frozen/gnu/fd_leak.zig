const std = @import("std");
const h = @import("harness.zig");

test "gnu fd-leak: 1296 file operands" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    var list: std.ArrayList([]const u8) = .empty;
    for (chars) |x| {
        for (chars) |y| {
            const name = c.fmt("{c}{c}", .{ x, y });
            try c.file(name, if (y == 'a') 5000 else 0);
            try list.append(c.alloc(), name);
        }
    }
    const a = c.alloc();
    try c.same("fd-leak -k", try std.mem.concat(a, []const u8, &.{ &.{"-k"}, list.items }), try std.mem.concat(a, []const u8, &.{ &.{"-sk"}, list.items }), c.root);
    try c.same("fd-leak -k -c", try std.mem.concat(a, []const u8, &.{ &.{ "-k", "-c" }, list.items }), try std.mem.concat(a, []const u8, &.{ &.{ "-sk", "-c" }, list.items }), c.root);
    try c.done();
}
