// Synthetic directory tree generator for dush benchmarking in Zig.
//
// Creates a deterministic directory tree with:
// - Multi-level directory hierarchies
// - Thousands of files with pseudo-random allocation sizes
// - Sparse files (zero-filled extents via ftruncate)
// - Deep directory recursion chains (path length & stack depth testing)
// - Hardlinked files (verifying inode deduplication)
// - Relative and dangling symbolic links (verifying symlink traversal rules)

const std = @import("std");

extern "c" fn mkdir(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: std.c.off_t) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn link(path1: [*:0]const u8, path2: [*:0]const u8) c_int;
extern "c" fn symlink(path1: [*:0]const u8, path2: [*:0]const u8) c_int;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const MODE_644: c_uint = 0o644;

const Lcg = struct {
    state: u64 = 0x12345678,

    pub fn next(self: *Lcg, mod: u64) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state % mod;
    }
};

fn makeDirZ(path_z: [*:0]const u8) void {
    _ = mkdir(path_z, 0o755);
}

fn makeDirP(path: []const u8) !void {
    var iter = std.mem.splitScalar(u8, path, '/');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var len: usize = 0;

    if (path.len > 0 and path[0] == '/') {
        buf[0] = '/';
        len = 1;
    }

    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (len > 0 and buf[len - 1] != '/') {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len .. len + part.len], part);
        len += part.len;
        buf[len] = 0;
        makeDirZ(@ptrCast(buf[0..len]));
    }
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    var it = init.minimal.args.iterate();

    _ = it.next(); // skip exe name
    const dest = it.next() orelse ".bench/tree";

    var top_dirs: usize = 128;
    var files_per_top: usize = 64;
    var sub_per_top: usize = 4;
    var files_per_sub: usize = 16;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--top-dirs")) {
            if (it.next()) |val| top_dirs = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--files-per-top")) {
            if (it.next()) |val| files_per_top = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--sub-per-top")) {
            if (it.next()) |val| sub_per_top = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--files-per-sub")) {
            if (it.next()) |val| files_per_sub = try std.fmt.parseInt(usize, val, 10);
        }
    }

    // Clean existing destination
    const rm_res = std.process.run(allocator, init.io, .{
        .argv = &.{ "rm", "-rf", dest },
    }) catch null;
    if (rm_res) |res| {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    try makeDirP(dest);

    var lcg = Lcg{};
    var total_files: usize = 0;
    var total_dirs: usize = 0;

    var sparse_buf: [4096]u8 = undefined;
    @memset(&sparse_buf, 'x');

    // 1. Broad directory hierarchy
    var i: usize = 0;
    while (i < top_dirs) : (i += 1) {
        var top_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const top_dir = try std.fmt.bufPrint(&top_dir_buf, "{s}/d{d:0>3}", .{ dest, i });
        top_dir_buf[top_dir.len] = 0;
        const top_dir_z: [*:0]const u8 = @ptrCast(top_dir_buf[0..top_dir.len]);
        makeDirZ(top_dir_z);
        total_dirs += 1;

        var j: usize = 0;
        while (j < files_per_top) : (j += 1) {
            var file_buf: [std.fs.max_path_bytes]u8 = undefined;
            const file_p = try std.fmt.bufPrint(&file_buf, "{s}/f{d:0>4}", .{ top_dir, j });
            file_buf[file_p.len] = 0;
            const file_z: [*:0]const u8 = @ptrCast(file_buf[0..file_p.len]);

            const size: std.c.off_t = @intCast(512 + lcg.next(32 * 1024));
            const fd = open(file_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
            if (fd >= 0) {
                if ((i + j) % 31 == 0) {
                    const write_len = @min(@as(usize, 4096), @as(usize, @intCast(size)));
                    _ = write(fd, &sparse_buf, write_len);
                }
                _ = ftruncate(fd, size);
                _ = close(fd);
                total_files += 1;
            }
        }

        var s: usize = 0;
        while (s < sub_per_top) : (s += 1) {
            var sub_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const sub_dir = try std.fmt.bufPrint(&sub_dir_buf, "{s}/s{d}", .{ top_dir, s });
            sub_dir_buf[sub_dir.len] = 0;
            const sub_dir_z: [*:0]const u8 = @ptrCast(sub_dir_buf[0..sub_dir.len]);
            makeDirZ(sub_dir_z);
            total_dirs += 1;

            var g: usize = 0;
            while (g < files_per_sub) : (g += 1) {
                var sub_file_buf: [std.fs.max_path_bytes]u8 = undefined;
                const sub_file_p = try std.fmt.bufPrint(&sub_file_buf, "{s}/g{d:0>4}", .{ sub_dir, g });
                sub_file_buf[sub_file_p.len] = 0;
                const sub_file_z: [*:0]const u8 = @ptrCast(sub_file_buf[0..sub_file_p.len]);

                const size: std.c.off_t = @intCast(512 + lcg.next(16 * 1024));
                const fd = open(sub_file_z, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
                if (fd >= 0) {
                    _ = ftruncate(fd, size);
                    _ = close(fd);
                    total_files += 1;
                }
            }
        }
    }

    // 2. Deep recursion (25 levels deep)
    var cur_deep_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_deep_len = (try std.fmt.bufPrint(&cur_deep_buf, "{s}/deep", .{dest})).len;
    cur_deep_buf[cur_deep_len] = 0;
    makeDirZ(@ptrCast(cur_deep_buf[0..cur_deep_len]));
    total_dirs += 1;

    var depth: usize = 0;
    while (depth < 25) : (depth += 1) {
        const next_p = try std.fmt.bufPrint(cur_deep_buf[cur_deep_len..], "/sub_{d}", .{depth});
        cur_deep_len += next_p.len;
        cur_deep_buf[cur_deep_len] = 0;
        makeDirZ(@ptrCast(cur_deep_buf[0..cur_deep_len]));
        total_dirs += 1;

        var dummy_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dummy_p = try std.fmt.bufPrint(&dummy_buf, "{s}/dummy.txt", .{cur_deep_buf[0..cur_deep_len]});
        dummy_buf[dummy_p.len] = 0;
        const fd = open(@ptrCast(dummy_buf[0..dummy_p.len]), O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
        if (fd >= 0) {
            _ = write(fd, "depth file content\n", 19);
            _ = close(fd);
            total_files += 1;
        }
    }

    // 3. Hardlink edge case
    var hl_src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hl_src = try std.fmt.bufPrint(&hl_src_buf, "{s}/d000/f0000", .{dest});
    hl_src_buf[hl_src.len] = 0;

    var hl_dst_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hl_dst = try std.fmt.bufPrint(&hl_dst_buf, "{s}/d000/hardlink_to_f0000", .{dest});
    hl_dst_buf[hl_dst.len] = 0;

    if (link(@ptrCast(hl_src_buf[0..hl_src.len]), @ptrCast(hl_dst_buf[0..hl_dst.len])) == 0) {
        total_files += 1;
    }

    // 4. Symlinks
    var sym_dir_src: [std.fs.max_path_bytes]u8 = undefined;
    const sds = try std.fmt.bufPrint(&sym_dir_src, "{s}/d001", .{dest});
    sym_dir_src[sds.len] = 0;
    var sym_dir_dst: [std.fs.max_path_bytes]u8 = undefined;
    const sdd = try std.fmt.bufPrint(&sym_dir_dst, "{s}/link_to_dir", .{dest});
    sym_dir_dst[sdd.len] = 0;
    _ = symlink(@ptrCast(sym_dir_src[0..sds.len]), @ptrCast(sym_dir_dst[0..sdd.len]));
    total_files += 1;

    var sym_file_src: [std.fs.max_path_bytes]u8 = undefined;
    const sfs = try std.fmt.bufPrint(&sym_file_src, "{s}/d002/f0001", .{dest});
    sym_file_src[sfs.len] = 0;
    var sym_file_dst: [std.fs.max_path_bytes]u8 = undefined;
    const sfd = try std.fmt.bufPrint(&sym_file_dst, "{s}/link_to_file", .{dest});
    sym_file_dst[sfd.len] = 0;
    _ = symlink(@ptrCast(sym_file_src[0..sfs.len]), @ptrCast(sym_file_dst[0..sfd.len]));
    total_files += 1;

    var sym_dang_src: [std.fs.max_path_bytes]u8 = undefined;
    const sdngs = try std.fmt.bufPrint(&sym_dang_src, "{s}/nonexistent", .{dest});
    sym_dang_src[sdngs.len] = 0;
    var sym_dang_dst: [std.fs.max_path_bytes]u8 = undefined;
    const sdngd = try std.fmt.bufPrint(&sym_dang_dst, "{s}/dangling", .{dest});
    sym_dang_dst[sdngd.len] = 0;
    _ = symlink(@ptrCast(sym_dang_src[0..sdngs.len]), @ptrCast(sym_dang_dst[0..sdngd.len]));
    total_files += 1;

    var msg_buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Fixture ready: {d} files across {d} directories.\n", .{ total_files, total_dirs });
    _ = write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);
    return 0;
}
