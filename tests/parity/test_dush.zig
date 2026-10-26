
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

fn runIn(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !RunOutput {
    const res = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
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


test "parity: default dot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try sizedTree(io, tmp.dir, &.{ "dd/ff", "dd/ee/gg" });
    try tmp.dir.writeFile(io, .{ .sub_path = "big", .data = "y" ** 300000 });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var here = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer here.close(io);
    const cwd = cwd_buf[0..try here.realPath(io, &cwd_buf)];
    const dush_bin = try std.fs.path.resolve(allocator, &.{ cwd, getDushBin() });
    defer allocator.free(dush_bin);

    const r1 = try runIn(allocator, &.{dush_bin}, root);
    defer r1.deinit(allocator);
    const r2 = try runIn(allocator, &.{ "du", "-sh" }, root);
    defer r2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try std.testing.expectEqualStrings(r2.stdout, r1.stdout);
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

    const sp = try std.fmt.bufPrint(&pbuf, "{s}/sparse.bin", .{root_path});
    const sp_z = try allocator.dupeZ(u8, sp);
    defer allocator.free(sp_z);
    const fd1 = open(sp_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd1 >= 0) {
        _ = ftruncate(fd1, 10 * 1024 * 1024);
        _ = close(fd1);
    }

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

test "parity: apparent size rounds each entry to 512 bytes (-A -k)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    try tmp.dir.createDirPath(io, "a/b/c");
    const names = [_][]const u8{ "one", "a/two", "a/b/three", "a/b/c/four", "a/b/c/five", "a/six", "seven", "a/b/eight" };
    for (names) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/c/odd", .data = "x" ** 1500 });
    try tmp.dir.symLink(io, "a/b/c/odd", "a/link", .{});

    const r1 = try runCmd(allocator, &.{ dush_bin, "-A", "-k", root_path });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-A", "-sk", root_path });
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

    {
        const r1 = try runCmd(allocator, &.{ dush_bin, link_p });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sh", link_p });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }

    {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-L", link_p });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sh", "-L", link_p });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }

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

test "parity: symlink inside a directory (-P and -L)" {
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
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, 'x');
        var left: usize = 50 * 1024;
        while (left > 0) {
            const n = @min(left, chunk.len);
            const wrote = write(fd, &chunk, n);
            if (wrote <= 0) break;
            left -= @intCast(wrote);
        }
        _ = close(fd);
    }

    const target_z = try allocator.dupeZ(u8, target_p);
    defer allocator.free(target_z);
    const link_z = try allocator.dupeZ(u8, link_p);
    defer allocator.free(link_z);
    _ = symlink(target_z, link_z);

    {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-k", root_path });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sk", root_path });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }

    {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-k", "-L", root_path });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sk", "-L", root_path });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
    }
}

fn mountFat32(allocator: std.mem.Allocator, dmg: []const u8, mountpoint: []const u8) !void {
    const create = try runCmd(allocator, &.{
        "hdiutil", "create", "-size", "64m", "-fs", "FAT32",
        "-volname", "DUSHFAT", "-ov", dmg,
    });
    defer create.deinit(allocator);
    if (create.term != .exited or create.term.exited != 0) {
        std.debug.print("hdiutil create stderr:\n{s}\n", .{create.stderr});
        return error.HdiutilCreate;
    }

    const attach = try runCmd(allocator, &.{
        "hdiutil", "attach", "-nobrowse", "-mountpoint", mountpoint, dmg,
    });
    defer attach.deinit(allocator);
    if (attach.term != .exited or attach.term.exited != 0) {
        std.debug.print("hdiutil attach stderr:\n{s}\n", .{attach.stderr});
        return error.HdiutilAttach;
    }
}

test "parity: FAT32 bulk sizes match du" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root_path = path_buf[0..path_len];

    var dmg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dmg = try std.fmt.bufPrint(&dmg_buf, "{s}/fat.dmg", .{root_path});
    var mnt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mnt = try std.fmt.bufPrint(&mnt_buf, "{s}/mnt", .{root_path});
    try tmp.dir.createDirPath(io, "mnt");

    try mountFat32(allocator, dmg, mnt);
    defer {
        const detach = runCmd(allocator, &.{ "hdiutil", "detach", mnt }) catch null;
        if (detach) |d| d.deinit(allocator);
    }

    var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/sub", .{mnt});
    const sub_z = try allocator.dupeZ(u8, sub);
    defer allocator.free(sub_z);
    _ = mkdir(sub_z, 0o755);

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_p = try std.fmt.bufPrint(&file_buf, "{s}/b.txt", .{mnt});
    const file_z = try allocator.dupeZ(u8, file_p);
    defer allocator.free(file_z);
    const fd = open(file_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd >= 0) {
        _ = write(fd, "hellohello\n", 11);
        _ = close(fd);
    }

    var nested_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nested_p = try std.fmt.bufPrint(&nested_buf, "{s}/a.txt", .{sub});
    const nested_z = try allocator.dupeZ(u8, nested_p);
    defer allocator.free(nested_z);
    const fd2 = open(nested_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd2 >= 0) {
        _ = write(fd2, "hello\n", 6);
        _ = close(fd2);
    }

    const r1 = try runCmd(allocator, &.{ dush_bin, "-k", mnt });
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, &.{ "du", "-sk", mnt });
    defer r2.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r2.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);

    const r3 = try runCmd(allocator, &.{ dush_bin, "-A", "-k", mnt });
    defer r3.deinit(allocator);
    const r4 = try runCmd(allocator, &.{ "du", "-A", "-sk", mnt });
    defer r4.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r3.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r4.term);
    try assertOutputParity(allocator, r3.stdout, r4.stdout);
}

test "parity: nonexistent path handling" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    const r = try runCmd(allocator, &.{ dush_bin, "nonexistent_path_xyz_123" });
    defer r.deinit(allocator);

    try std.testing.expect(r.term != .exited or r.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
}

extern "c" fn chmod(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn sortedErrorLines(allocator: std.mem.Allocator, stderr: []const u8, prog: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, prog));
        try lines.append(allocator, line[prog.len..]);
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return lines;
}

fn assertErrorParity(allocator: std.mem.Allocator, dush_argv: []const []const u8, du_argv: []const []const u8) !void {
    const r1 = try runCmd(allocator, dush_argv);
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, du_argv);
    defer r2.deinit(allocator);

    try std.testing.expectEqual(r2.term, r1.term);
    try assertOutputParity(allocator, r1.stdout, r2.stdout);

    var dush_lines = try sortedErrorLines(allocator, r1.stderr, "dush: ");
    defer dush_lines.deinit(allocator);
    var du_lines = try sortedErrorLines(allocator, r2.stderr, "du: ");
    defer du_lines.deinit(allocator);
    try std.testing.expect(du_lines.items.len > 0);
    try std.testing.expectEqual(du_lines.items.len, dush_lines.items.len);
    for (du_lines.items, dush_lines.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

const LockedTree = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    const locked = [_]struct { name: [:0]const u8, mode: std.c.mode_t }{
        .{ .name = "a", .mode = 0o000 },
        .{ .name = "b", .mode = 0o300 },
        .{ .name = "c", .mode = 0o600 },
        .{ .name = "d/g", .mode = 0o000 },
    };

    fn create(self: *LockedTree) !void {
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        self.root_len = try self.tmp.dir.realPath(io, &self.root_buf);
        try self.tmp.dir.createDirPath(io, "a/sub");
        try self.tmp.dir.createDirPath(io, "b");
        try self.tmp.dir.createDirPath(io, "c");
        try self.tmp.dir.createDirPath(io, "d");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "a/sub/f", .data = "x" ** 9000 });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "b/f", .data = "x" ** 9000 });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "c/f", .data = "x" ** 9000 });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "d/f", .data = "x" ** 5000 });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "d/g", .data = "x" ** 3000 });
        for (locked) |l| try self.setMode(l.name, l.mode);
    }

    fn setMode(self: *LockedTree, name: []const u8, mode: std.c.mode_t) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ self.root(), name });
        try std.testing.expectEqual(@as(c_int, 0), chmod(p, mode));
    }

    fn root(self: *const LockedTree) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    fn sub(self: *const LockedTree, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root(), name });
    }

    fn destroy(self: *LockedTree) void {
        for (locked) |l| self.setMode(l.name, 0o755) catch {};
        self.tmp.cleanup();
    }
};

test "parity: unreadable subdirectories warn and still print the total" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    var tree: LockedTree = .{ .tmp = undefined };
    try tree.create();
    defer tree.destroy();
    const r = tree.root();

    try assertErrorParity(allocator, &.{ dush_bin, "-k", r }, &.{ "du", "-sk", r });
    try assertErrorParity(allocator, &.{ dush_bin, "-A", "-k", r }, &.{ "du", "-A", "-sk", r });
    try assertErrorParity(allocator, &.{ dush_bin, r }, &.{ "du", "-sh", r });
    try assertErrorParity(allocator, &.{ dush_bin, "-L", "-k", r }, &.{ "du", "-L", "-sk", r });

    var slash_buf: [std.fs.max_path_bytes]u8 = undefined;
    const slashed = try std.fmt.bufPrint(&slash_buf, "{s}/", .{r});
    try assertErrorParity(allocator, &.{ dush_bin, "-k", slashed }, &.{ "du", "-sk", slashed });
}

test "parity: unreadable root arguments print no line" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    var tree: LockedTree = .{ .tmp = undefined };
    try tree.create();
    defer tree.destroy();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a", "b", "a/sub", "c/f" }) |name| {
        const p = try tree.sub(&buf, name);
        try assertErrorParity(allocator, &.{ dush_bin, "-k", p }, &.{ "du", "-sk", p });
    }
    const searchable_only = try tree.sub(&buf, "c");
    try assertErrorParity(allocator, &.{ dush_bin, "-k", searchable_only }, &.{ "du", "-sk", searchable_only });
}

test "parity: missing and unreadable arguments among several (-c)" {
    const allocator = std.testing.allocator;
    const dush_bin = getDushBin();

    var tree: LockedTree = .{ .tmp = undefined };
    try tree.create();
    defer tree.destroy();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try tree.sub(&a_buf, "a");
    var d_buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = try tree.sub(&d_buf, "d");
    var nope_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nope = try tree.sub(&nope_buf, "nope");
    const r = tree.root();

    try assertErrorParity(allocator, &.{ dush_bin, "-k", "-c", r, nope, a, d }, &.{ "du", "-sk", "-c", r, nope, a, d });
    try assertErrorParity(allocator, &.{ dush_bin, "-k", "-c", nope }, &.{ "du", "-sk", "-c", nope });
    try assertErrorParity(allocator, &.{ dush_bin, "-c", nope, d, a }, &.{ "du", "-sh", "-c", nope, d, a });
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

test "parity: errors from a summary walk come out in du's order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();

    var tmp = std.testing.tmpDir(.{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var names: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (names.items) |n| {
            _ = chmod(n, 0o755);
            allocator.free(n);
        }
        names.deinit(allocator);
        tmp.cleanup();
    }
    for (0..6) |i| {
        for (0..5) |j| {
            var rel_buf: [64]u8 = undefined;
            const rel = try std.fmt.bufPrint(&rel_buf, "p{d}/w{d}/q{d}", .{ i, j, j });
            try tmp.dir.createDirPath(io, rel);
            var file_buf: [80]u8 = undefined;
            try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&file_buf, "{s}/f", .{rel}), .data = "x" ** 5000 });
            try names.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root, rel }, 0));
        }
    }
    for (names.items) |n| try std.testing.expectEqual(@as(c_int, 0), chmod(n, 0o000));

    for (0..5) |_| {
        const r1 = try runCmd(allocator, &.{ dush_bin, "-k", root });
        defer r1.deinit(allocator);
        const r2 = try runCmd(allocator, &.{ "du", "-sk", root });
        defer r2.deinit(allocator);
        try std.testing.expectEqual(r2.term, r1.term);
        try assertOutputParity(allocator, r1.stdout, r2.stdout);
        const got = try std.mem.replaceOwned(u8, allocator, r1.stderr, "dush: ", "du: ");
        defer allocator.free(got);
        try std.testing.expectEqualStrings(r2.stderr, got);
    }
}

fn assertExactParity(allocator: std.mem.Allocator, dush_argv: []const []const u8, du_argv: []const []const u8) !void {
    const r1 = try runCmd(allocator, dush_argv);
    defer r1.deinit(allocator);
    const r2 = try runCmd(allocator, du_argv);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(r2.term, r1.term);
    try std.testing.expectEqualStrings(r2.stdout, r1.stdout);
    const got = try std.mem.replaceOwned(u8, allocator, r1.stderr, "dush: ", "du: ");
    defer allocator.free(got);
    try std.testing.expectEqualStrings(r2.stderr, got);
}

fn sizedTree(io: std.Io, dir: std.Io.Dir, names: []const []const u8) !void {
    try dir.createDirPath(io, "dd/ee");
    for (names) |n| try dir.writeFile(io, .{ .sub_path = n, .data = "x" ** 3000 });
}

test "parity: a negative threshold with -A and a scale prints no directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try sizedTree(io, tmp.dir, &.{ "dd/ff", "dd/ee/gg" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    for ([_][]const u8{ "-k", "-m", "-g" }) |unit| {
        for ([_][]const u8{ "-1", "-512", "-4096", "-1048576" }) |t| {
            try assertExactParity(allocator, &.{ dush_bin, "-A", unit, "-t", t, root }, &.{ "du", "-s", "-A", unit, "-t", t, root });
        }
    }
}

test "parity: an empty operand is reported in place and the rest still walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try sizedTree(io, tmp.dir, &.{ "dd/ff", "dd/ee/gg" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try assertExactParity(allocator, &.{ dush_bin, "-k", "" }, &.{ "du", "-sk", "" });
    try assertExactParity(allocator, &.{ dush_bin, "-k", "-c", root, "", "/nonexistent-dush-test", root }, &.{ "du", "-sk", "-c", root, "", "/nonexistent-dush-test", root });
}

test "parity: -I masks match in the caller's locale" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dush_bin = getDushBin();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try sizedTree(io, tmp.dir, &.{ "dd/\xc3\xa9", "dd/ee/gg", "dd/ab" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    for ([_][]const u8{ "LC_ALL=en_US.UTF-8", "LC_ALL=C" }) |env| {
        try assertExactParity(allocator, &.{ "env", env, dush_bin, "-k", "-I", "?", root }, &.{ "env", env, "du", "-sk", "-I", "?", root });
    }
}
