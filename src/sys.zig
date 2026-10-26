const std = @import("std");
const builtin = @import("builtin");

pub const ATTR_BIT_MAP_COUNT: u16 = 5;
pub const ATTR_CMN_NAME: u32 = 0x00000001;
pub const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
pub const ATTR_CMN_FILEID: u32 = 0x02000000;
pub const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;

pub const ATTR_FILE_LINKCOUNT: u32 = 0x00000001;
pub const ATTR_FILE_TOTALSIZE: u32 = 0x00000002;
pub const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;
pub const ATTR_FILE_DATALENGTH: u32 = 0x00000200;

pub const ATTR_DIR_LINKCOUNT: u32 = 0x00000001;
pub const ATTR_DIR_ALLOCSIZE: u32 = 0x00000008;
pub const ATTR_DIR_DATALENGTH: u32 = 0x00000020;

pub const VREG: u32 = 1;
pub const VDIR: u32 = 2;
pub const VLNK: u32 = 5;

pub const AttrList = extern struct {
    bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

pub const AttrReference = extern struct {
    attr_dataoffset: i32,
    attr_length: u32,
};

pub extern "c" fn getattrlistbulk(
    dirfd: c_int,
    attrList: *const AttrList,
    attrBuf: *anyopaque,
    attrBufSize: usize,
    options: u64,
) c_int;

pub extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn __error() *c_int;
pub extern "c" fn strerror(errnum: c_int) [*:0]const u8;
pub extern "c" fn dup(fd: c_int) c_int;
pub extern "c" fn dup2(fd: c_int, fd2: c_int) c_int;

pub const EACCES: c_int = 13;
pub const ENOENT: c_int = 2;
pub const ERANGE: c_int = 34;
pub const ELOOP: c_int = 62;
pub const ENOTSUP: c_int = 45;
pub const EINVAL: c_int = 22;

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }

    pub fn unlock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const rc = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }

    pub fn broadcast(self: *Condition) void {
        const rc = std.c.pthread_cond_broadcast(&self.inner);
        std.debug.assert(@intFromEnum(rc) == 0);
    }
};

const inode64 = if (builtin.cpu.arch == .x86_64) "$INODE64" else "";

pub const FTS_COMFOLLOW: c_int = 0x001;
pub const FTS_LOGICAL: c_int = 0x002;
pub const FTS_NOCHDIR: c_int = 0x004;
pub const FTS_PHYSICAL: c_int = 0x010;
pub const FTS_XDEV: c_int = 0x040;

pub const FTS_D: u16 = 1;
pub const FTS_DC: u16 = 2;
pub const FTS_DNR: u16 = 4;
pub const FTS_DP: u16 = 6;
pub const FTS_ERR: u16 = 7;
pub const FTS_NS: u16 = 10;
pub const FTS_SLNONE: u16 = 13;

pub const FTS_SKIP: c_int = 4;

pub const FTS = opaque {};

pub const FTSENT = extern struct {
    fts_cycle: ?*FTSENT,
    fts_parent: *FTSENT,
    fts_link: ?*FTSENT,
    fts_number: i64,
    fts_pointer: ?*anyopaque,
    fts_accpath: [*:0]u8,
    fts_path: [*:0]u8,
    fts_errno: c_int,
    fts_symfd: c_int,
    fts_pathlen: u16,
    fts_namelen: u16,
    fts_ino: u64,
    fts_dev: i32,
    fts_nlink: u16,
    fts_level: i16,
    fts_info: u16,
    fts_flags: u16,
    fts_instr: u16,
    fts_statp: *std.c.Stat,
    fts_name: [1]u8,
};

comptime {
    if (builtin.os.tag.isDarwin()) {
        std.debug.assert(@offsetOf(FTSENT, "fts_number") == 24);
        std.debug.assert(@offsetOf(FTSENT, "fts_ino") == 72);
        std.debug.assert(@offsetOf(FTSENT, "fts_info") == 88);
        std.debug.assert(@offsetOf(FTSENT, "fts_statp") == 96);
        std.debug.assert(@offsetOf(FTSENT, "fts_name") == 104);
    }
}

pub const FtsArgv = [*:null]const ?[*:0]const u8;

pub const fts_open = @extern(*const fn (FtsArgv, c_int, ?*const anyopaque) callconv(.c) ?*FTS, .{ .name = "fts_open" ++ inode64 });
pub const fts_read = @extern(*const fn (*FTS) callconv(.c) ?*FTSENT, .{ .name = "fts_read" ++ inode64 });
pub const fts_set = @extern(*const fn (*FTS, *FTSENT, c_int) callconv(.c) c_int, .{ .name = "fts_set" ++ inode64 });

pub const statfs_fstypename_offset = 72;
pub const StatfsBuf = [2168]u8;
pub const statfs = @extern(*const fn ([*:0]const u8, *align(8) StatfsBuf) callconv(.c) c_int, .{ .name = "statfs" ++ inode64 });

pub const Option = extern struct {
    name: ?[*:0]const u8,
    has_arg: c_int,
    flag: ?*c_int,
    val: c_int,
};

pub const no_argument: c_int = 0;
pub const required_argument: c_int = 1;

pub extern "c" fn getopt_long(argc: c_int, argv: [*]const ?[*:0]u8, optstring: [*:0]const u8, longopts: [*]const Option, longindex: ?*c_int) c_int;
pub extern "c" var optarg: ?[*:0]u8;
pub extern "c" var optind: c_int;

pub extern "c" fn getbsize(headerlenp: *c_int, blocksizep: *c_long) ?[*:0]u8;
pub extern "c" fn expand_number(buf: [*:0]const u8, num: *u64) c_int;
pub extern "c" fn humanize_number(buf: [*]u8, len: usize, number: i64, suffix: [*:0]const u8, scale: c_int, flags: c_int) c_int;
pub const HN_DECIMAL: c_int = 0x01;
pub const HN_NOSPACE: c_int = 0x02;
pub const HN_B: c_int = 0x04;
pub const HN_DIVISOR_1000: c_int = 0x08;
pub const HN_AUTOSCALE: c_int = 0x20;

pub extern "c" fn fnmatch(pattern: [*:0]const u8, string: [*:0]const u8, flags: c_int) c_int;
pub const FNM_NOMATCH: c_int = 1;
pub const UF_NODUMP: u32 = 0x00000001;

pub extern "c" fn getattrlist(path: [*:0]const u8, attrList: *const AttrList, attrBuf: *anyopaque, attrBufSize: usize, options: c_ulong) c_int;
pub extern "c" fn getattrlistat(fd: c_int, path: [*:0]const u8, attrList: *const AttrList, attrBuf: *anyopaque, attrBufSize: usize, options: c_ulong) c_int;

pub extern "c" fn compat_mode(function: [*:0]const u8, mode: [*:0]const u8) bool;
pub extern "c" fn getprogname() [*:0]const u8;
pub extern "c" fn warnx(fmt: [*:0]const u8, ...) void;
pub extern "c" fn errx(code: c_int, fmt: [*:0]const u8, ...) noreturn;
pub extern "c" fn err(code: c_int, fmt: [*:0]const u8, ...) noreturn;
pub extern "c" fn fprintf(stream: *anyopaque, fmt: [*:0]const u8, ...) c_int;
pub extern "c" fn fflush(stream: ?*anyopaque) c_int;
pub extern "c" fn ferror(stream: *anyopaque) c_int;
pub extern "c" var __stdoutp: *anyopaque;
pub extern "c" var __stderrp: *anyopaque;
pub extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*anyopaque;
pub const SIGINFO: c_int = 29;
pub const EX_USAGE: u8 = 64;
pub const FSOPT_NOFOLLOW: c_ulong = 0x1;
pub const fstatfs = @extern(*const fn (c_int, *align(8) StatfsBuf) callconv(.c) c_int, .{ .name = "fstatfs" ++ inode64 });
