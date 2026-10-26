const std = @import("std");

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
