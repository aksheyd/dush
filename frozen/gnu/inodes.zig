const std = @import("std");
const h = @import("harness.zig");

test "gnu inodes: counts per state of d [unsupported --inodes]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("d");
    try c.expect("inodes empty", &.{ "--inodes", "d" }, "1\td\n", 0, c.root);
    try c.file("d/f", 0);
    try c.expect("inodes one file", &.{ "--inodes", "d" }, "2\td\n", 0, c.root);
    try c.hard("d/f", "d/h");
    try c.expect("inodes hard link once", &.{ "--inodes", "d" }, "2\td\n", 0, c.root);
    try c.expect("inodes -l", &.{ "--inodes", "-l", "d" }, "3\td\n", 0, c.root);
    try c.mkdir("d/d");
    try c.expect("inodes subdir", &.{ "--inodes", "d" }, "3\td\n", 0, c.root);
    try c.expect("inodes -c", &.{ "--inodes", "-c", "d" }, "3\td\n3\ttotal\n", 0, c.root);
    try c.file("d/d/f", 0);
    try c.expect("inodes nested", &.{ "--inodes", "d" }, "4\td\n", 0, c.root);
    try c.done();
}

test "gnu inodes: human count of 1024 [unsupported --inodes]" {
    var c: h.Ctx = undefined;
    try c.init();
    defer c.deinit();
    try c.mkdir("d");
    for (1..1024) |i| try c.file(c.fmt("d/file{d}", .{i}), 0);
    try c.expect("inodes -h", &.{ "--inodes", "-h", "d" }, "1.0K\td\n", 0, c.root);
    try c.expect("inodes -k raw", &.{ "--inodes", "-k", "d" }, "1024\td\n", 0, c.root);
    try c.done();
}
