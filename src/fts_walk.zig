const std = @import("std");
const sys = @import("sys.zig");
const errors = @import("errors.zig");
const Config = @import("cli.zig").Config;
const Printer = @import("format.zig").Printer;
const InodeSet = @import("inodes.zig").InodeSet;

var info_requested = std.atomic.Value(bool).init(false);

fn onSiginfo(_: c_int) callconv(.c) void {
    info_requested.store(true, .monotonic);
}

pub const Links = struct {
    files: InodeSet,
    dirs: InodeSet,
};

fn isDir(st: *const std.c.Stat) bool {
    return (st.mode & 0o170000) == 0o040000;
}

pub fn onDevfsFd(st: *const std.c.Stat, name: []const u8, accpath: [*:0]const u8) bool {
    if (!isDir(st) or !std.mem.eql(u8, name, "fd")) return false;
    var buf: sys.StatfsBuf align(8) = undefined;
    if (sys.statfs(accpath, &buf) < 0) return false;
    const fstype = std.mem.sliceTo(buf[sys.statfs_fstypename_offset..][0..16], 0);
    return std.mem.eql(u8, fstype, "devfs");
}

fn ignored(cfg: *const Config, p: *sys.FTSENT) bool {
    const name: [*:0]const u8 = @ptrCast(&p.fts_name);
    if (onDevfsFd(p.fts_statp, std.mem.span(name), p.fts_accpath)) return true;
    if (cfg.nodump and (p.fts_statp.flags & sys.UF_NODUMP) != 0) return true;
    for (cfg.ignores) |mask| {
        if (sys.fnmatch(mask, name, 0) != sys.FNM_NOMATCH) return true;
    }
    return false;
}

pub fn dirLinkCount(path: [*:0]const u8) ?u32 {
    var attrs: sys.AttrList = .{ .dirattr = sys.ATTR_DIR_LINKCOUNT };
    var buf: extern struct { size: u32, linkcount: u32 } = undefined;
    if (sys.getattrlist(path, &attrs, &buf, @sizeOf(@TypeOf(buf)), 0) == -1) return null;
    return buf.linkcount;
}

pub fn dirSeen(links: *InodeSet, st: *const std.c.Stat, linkcount: ?u32) bool {
    const n = linkcount orelse return false;
    if (n == 1) return false;
    return links.visit(@bitCast(@as(i64, st.dev)), st.ino, n);
}

pub fn run(cfg: *const Config, links: *Links, out: Printer) u8 {
    _ = sys.signal(sys.SIGINFO, onSiginfo);
    const unix2003 = sys.compat_mode("bin/du", "unix2003");

    const fts = sys.fts_open(cfg.operands, cfg.ftsOptions(), null) orelse sys.err(1, "fts_open");
    var rval: u8 = 0;
    var saved: i64 = 0;

    while (true) {
        sys.__error().* = 0;
        const p = sys.fts_read(fts) orelse break;
        const st = p.fts_statp;
        switch (p.fts_info) {
            sys.FTS_D => {
                if (ignored(cfg, p) or dirSeen(&links.dirs, st, dirLinkCount(p.fts_path)))
                    _ = sys.fts_set(fts, p, sys.FTS_SKIP);
            },
            sys.FTS_DP => {
                if (!ignored(cfg, p)) {
                    const cur = cfg.scale.entryBlocks(st.size, st.blocks);
                    p.fts_number += cur;
                    p.fts_parent.fts_number += p.fts_number;
                    if (p.fts_level <= cfg.depth and cfg.scale.passes(cfg.threshold, p.fts_number))
                        out.line(p.fts_number, p.fts_path);
                    if (info_requested.swap(false, .monotonic))
                        _ = std.c.printf("\t%s\n", p.fts_path);
                }
            },
            sys.FTS_DC => {
                if (unix2003) sys.errx(1, "Can't follow symlink cycle from %s to %s", p.fts_path, p.fts_cycle.?.fts_path);
            },
            sys.FTS_DNR, sys.FTS_ERR, sys.FTS_NS => {
                sys.warnx("%s: %s", p.fts_path, sys.strerror(p.fts_errno));
                rval = 1;
            },
            else => {
                if (p.fts_info == sys.FTS_SLNONE and unix2003) {
                    var sb: std.c.Stat = undefined;
                    if (std.c.fstatat(std.posix.AT.FDCWD, p.fts_path, &sb, 0) < 0 and sys.__error().* == sys.ELOOP)
                        sys.errx(1, "Too many symlinks at %s", p.fts_path);
                }
                if (!ignored(cfg, p)) {
                    const skip = !cfg.count_links and st.nlink > 1 and
                        links.files.visit(@bitCast(@as(i64, st.dev)), st.ino, st.nlink);
                    if (!skip) {
                        const cur = cfg.scale.entryBlocks(st.size, st.blocks);
                        if (cfg.all or p.fts_level == 0) out.line(cur, p.fts_path);
                        p.fts_parent.fts_number += cur;
                    }
                }
            },
        }
        saved = p.fts_parent.fts_number;
    }
    if (sys.__error().* != 0) sys.err(1, "fts_read");

    if (cfg.grand_total) out.line(saved, "total");
    return rval;
}
