// Comprehensive test suite for `dush` written in Zig.
// Validates behavioral and numerical equivalence between `dush` and macOS `du -sh`.

const std = @import("std");

extern "c" fn link(path1: [*:0]const u8, path2: [*:0]const u8) c_int;
extern "c" fn symlink(path1: [*:0]const u8, path2: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: std.c.off_t) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const MODE_644: c_uint = 0o644;

fn getDushBin() []const u8 {
    if (std.c.getenv("DUSH_BIN")) |p| {
        return std.mem.span(p);
    }
    return "./dush";
}

const RunOutput = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !RunOutput {
    const res = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
    });
    return .{
        .term = res.term,
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

fn normalizeOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var prev_space = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '\t') {
            if (!prev_space) {
                try list.append(allocator, ' ');
                prev_space = true;
            }
        } else {
            try list.append(allocator, c);
            prev_space = false;
        }
    }
    return list.toOwnedSlice(allocator);
}

fn assertOutputParity(allocator: std.mem.Allocator, dush_out: []const u8, du_out: []const u8) !void {
    const norm_dush = try normalizeOutput(allocator, dush_out);
    defer allocator.free(norm_dush);
    const norm_du = try normalizeOutput(allocator, du_out);
    defer allocator.free(norm_du);
    try std.testing.expectEqualStrings(norm_du, norm_dush);
}

// ---------------------------------------------------------------------------
// Parity Tests
// ---------------------------------------------------------------------------

test "parity: default dot" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    const r1 = try runCmd(allocator, &.{ dush_bin });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh" });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: single directory" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    const r1 = try runCmd(allocator, &.{ dush_bin, ".git" });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", ".git" });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: multiple arguments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var d1_buf: [std.fs.max_path_bytes]u8 = undefined;
    const d1_p = try std.fmt.bufPrint(&d1_buf, "{s}/dir1", .{root_path});
    var d2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const d2_p = try std.fmt.bufPrint(&d2_buf, "{s}/dir2", .{root_path});
    var f1_buf: [std.fs.max_path_bytes]u8 = undefined;
    const f1_p = try std.fmt.bufPrint(&f1_buf, "{s}/file1.txt", .{root_path});

    try tmp.dir.createDirPath(io, "dir1");
    try tmp.dir.createDirPath(io, "dir2");

    // Populate files
    var fbuf: [std.fs.max_path_bytes]u8 = undefined;
    const sub_f1 = try std.fmt.bufPrint(&fbuf, "{s}/test.bin", .{d1_p});
    const sub_f1_z = try allocator.dupeZ(u8, sub_f1);
    defer allocator.free(sub_f1_z);
    const fd1 = open(sub_f1_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd1 >= 0) {
        _ = ftruncate(fd1, 50000);
        _ = close(fd1);
    }

    const sub_f2 = try std.fmt.bufPrint(&fbuf, "{s}/test2.bin", .{d2_p});
    const sub_f2_z = try allocator.dupeZ(u8, sub_f2);
    defer allocator.free(sub_f2_z);
    const fd2 = open(sub_f2_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd2 >= 0) {
        _ = ftruncate(fd2, 120000);
        _ = close(fd2);
    }

    const f1_z = try allocator.dupeZ(u8, f1_p);
    defer allocator.free(f1_z);
    const fd3 = open(f1_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd3 >= 0) {
        _ = ftruncate(fd3, 1000);
        _ = close(fd3);
    }

    const r1 = try runCmd(allocator, &.{ dush_bin, d1_p, d2_p, f1_p });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", d1_p, d2_p, f1_p });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: flag combinations (-sh, -hs)" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    const r1 = try runCmd(allocator, &.{ dush_bin, "-sh", ".git" });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ dush_bin, "-hs", ".git" });
    defer r2.deinit(allocator);
    const r3 = try runCmd(allocator, &.{ "du", "-sh", ".git" });
    defer r3.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r3.term);
    try assertOutputParity(allocator, r1.stdout, r3.stdout);
    try assertOutputParity(allocator, r2.stdout, r3.stdout);
}

test "parity: grand total (-c)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a_p = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root_path});
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b_p = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root_path});

    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");

    var fbuf: [std.fs.max_path_bytes]u8 = undefined;
    const fa_p = try std.fmt.bufPrint(&fbuf, "{s}/f", .{a_p});
    const fa_z = try allocator.dupeZ(u8, fa_p);
    defer allocator.free(fa_z);
    const fda = open(fa_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fda >= 0) {
        _ = ftruncate(fda, 20000);
        _ = close(fda);
    }

    const fb_p = try std.fmt.bufPrint(&fbuf, "{s}/g", .{b_p});
    const fb_z = try allocator.dupeZ(u8, fb_p);
    defer allocator.free(fb_z);
    const fdb = open(fb_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fdb >= 0) {
        _ = ftruncate(fdb, 40000);
        _ = close(fdb);
    }

    const r1 = try runCmd(allocator, &.{ dush_bin, "-c", a_p, b_p });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", "-c", a_p, b_p });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: block size units (-k, -m, -g)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fp = try std.fmt.bufPrint(&file_buf, "{s}/file.bin", .{root_path});
    const fp_z = try allocator.dupeZ(u8, fp);
    defer allocator.free(fp_z);

    const fd = open(fp_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd >= 0) {
        _ = ftruncate(fd, 200000);
        _ = close(fd);
    }

    const flags = [_][]const u8{ "-k", "-m", "-g" };
    const du_flags = [_][]const u8{ "-sk", "-sm", "-sg" };

    inline for (flags, du_flags) |flag, du_flag| {
        const r1 = try runCmd(allocator, &.{ dush_bin, flag, root_path });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", du_flag, root_path });
        defer r2.deinit(allocator);

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }
}

test "parity: apparent size (-A) and odd sizes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;

    // 10MB sparse file
    const sp = try std.fmt.bufPrint(&pbuf, "{s}/sparse.bin", .{root_path});
    const sp_z = try allocator.dupeZ(u8, sp);
    defer allocator.free(sp_z);
    const fd1 = open(sp_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd1 >= 0) {
        _ = ftruncate(fd1, 10 * 1024 * 1024);
        _ = close(fd1);
    }

    // Odd-sized file (1000 bytes)
    const op = try std.fmt.bufPrint(&pbuf, "{s}/odd.bin", .{root_path});
    const op_z = try allocator.dupeZ(u8, op);
    defer allocator.free(op_z);
    const fd2 = open(op_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd2 >= 0) {
        _ = ftruncate(fd2, 1000);
        _ = close(fd2);
    }

    const r1 = try runCmd(allocator, &.{ dush_bin, "-A", root_path });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", "-A", root_path });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: hardlink deduplication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var pbuf1: [std.fs.max_path_bytes]u8 = undefined;
    const f1 = try std.fmt.bufPrint(&pbuf1, "{s}/f1", .{root_path});
    const f1_z = try allocator.dupeZ(u8, f1);
    defer allocator.free(f1_z);

    var pbuf2: [std.fs.max_path_bytes]u8 = undefined;
    const f2 = try std.fmt.bufPrint(&pbuf2, "{s}/f2", .{root_path});
    const f2_z = try allocator.dupeZ(u8, f2);
    defer allocator.free(f2_z);

    const fd = open(f1_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd >= 0) {
        _ = ftruncate(fd, 65536);
        _ = close(fd);
    }

    _ = link(f1_z, f2_z);

    const r1 = try runCmd(allocator, &.{ dush_bin, root_path });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", root_path });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}

test "parity: symbolic links (-P, -L, -H)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_p = try std.fmt.bufPrint(&target_buf, "{s}/target", .{root_path});
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_p = try std.fmt.bufPrint(&link_buf, "{s}/link", .{root_path});

    try tmp.dir.createDirPath(io, "target");

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fp = try std.fmt.bufPrint(&file_buf, "{s}/file", .{target_p});
    const fp_z = try allocator.dupeZ(u8, fp);
    defer allocator.free(fp_z);
    const fd = open(fp_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd >= 0) {
        _ = ftruncate(fd, 50000);
        _ = close(fd);
    }

    const target_z = try allocator.dupeZ(u8, target_p);
    defer allocator.free(target_z);
    const link_z = try allocator.dupeZ(u8, link_p);
    defer allocator.free(link_z);
    _ = symlink(target_z, link_z);

    // 1. Default -P (do not follow)
    {
        const r1 = try runCmd(allocator, &.{ dush_bin, link_p });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sh", link_p });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }

    // 2. -L (follow all)
    {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-L", link_p });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sh", "-L", link_p });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }

    // 3. -H (follow command-line link)
    {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-H", link_p });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sh", "-H", link_p });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }
}

test "parity: nonexistent path handling" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    const r = try runCmd(allocator, &.{ dush_bin, "nonexistent_path_xyz_123" });
    defer r.deinit(allocator);

    try std.testing.expect(r.term != .exited or r.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
}

test "parity: deep directory hierarchy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(cur_buf[0..root_path.len], root_path);
    var cur_len = root_path.len;

    var depth: usize = 0;
    while (depth < 20) : (depth += 1) {
        const next = try std.fmt.bufPrint(cur_buf[cur_len..], "/sub_{d}", .{depth});
        cur_len += next.len;
        const cur_z = try allocator.dupeZ(u8, cur_buf[0..cur_len]);
        defer allocator.free(cur_z);
        _ = mkdir(cur_z, 0o755);

        var dummy_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dummy = try std.fmt.bufPrint(&dummy_buf, "{s}/dummy.txt", .{cur_buf[0..cur_len]});
        const dummy_z = try allocator.dupeZ(u8, dummy);
        defer allocator.free(dummy_z);
        const fd = open(dummy_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
        if (fd >= 0) {
            _ = write(fd, "test depth data\n", 16);
            _ = close(fd);
        }
    }

    const r1 = try runCmd(allocator, &.{ dush_bin, root_path });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sh", root_path });
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);
}
