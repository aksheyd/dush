const std = @import("std");
const sys = @import("sys.zig");

pub fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

pub fn writeErr(path: []const u8, msg: []const u8) void {
    writeErrIn(path, "", msg);
}

pub fn writeErrIn(dir: []const u8, name: []const u8, msg: []const u8) void {
    var buf: [3 * std.fs.max_path_bytes]u8 = undefined;
    const sep = if (name.len == 0 or (dir.len == 1 and dir[0] == '/')) "" else "/";
    const line = std.fmt.bufPrint(&buf, "dush: {s}{s}{s}: {s}\n", .{ dir, sep, name, msg }) catch return;
    writeAll(std.posix.STDERR_FILENO, line);
}

pub fn errnoMessage() []const u8 {
    return std.mem.span(sys.strerror(sys.__error().*));
}
