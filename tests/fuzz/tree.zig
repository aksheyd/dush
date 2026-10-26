const std = @import("std");
const builtin = @import("builtin");
const case = @import("case.zig");
const Op = case.Op;
const c = std.c;

extern "c" fn fchflags(fd: c_int, flags: c_uint) c_int;

const uf_nodump: c_uint = 1;

pub fn ordered(a: std.mem.Allocator, ops: []const Op) ![]const Op {
    var out: std.ArrayList(Op) = .empty;
    for (ops) |op| if (op.kind != .chmod and op.kind != .nodump) try out.append(a, op);
    for (ops) |op| if (op.kind == .nodump) try out.append(a, op);
    const start = out.items.len;
    for (ops) |op| if (op.kind == .chmod) try out.append(a, op);
    std.sort.insertion(Op, out.items[start..], {}, deeperFirst);
    return out.items;
}

fn deeperFirst(_: void, x: Op, y: Op) bool {
    return case.depth(x.path) > case.depth(y.path);
}

const Parent = struct {
    fd: c_int,
    base: [:0]const u8,
    root: c_int,

    fn close(p: Parent) void {
        if (p.fd != p.root) _ = c.close(p.fd);
    }
};

fn parent(a: std.mem.Allocator, root: c_int, path: []const u8) !Parent {
    var fd = root;
    errdefer if (fd != root) {
        _ = c.close(fd);
    };
    var rest = path;
    while (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        const comp = try a.dupeZ(u8, rest[0..i]);
        rest = rest[i + 1 ..];
        const next = c.openat(fd, comp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd != root) _ = c.close(fd);
        fd = root;
        if (next < 0) return error.Open;
        fd = next;
    }
    return .{ .fd = fd, .base = try a.dupeZ(u8, rest), .root = root };
}

fn fill(fd: c_int, n: u64) !void {
    var buf: [65536]u8 = undefined;
    @memset(&buf, 'x');
    var left = n;
    var off: u64 = 0;
    while (left != 0) {
        const chunk: usize = @intCast(@min(left, buf.len));
        const w = c.pwrite(fd, &buf, chunk, @intCast(off));
        if (w <= 0) return error.Write;
        left -= @intCast(w);
        off += @intCast(w);
    }
}

fn one(a: std.mem.Allocator, root_fd: c_int, root: []const u8, op: Op) !void {
    const p = try parent(a, root_fd, op.path);
    defer p.close();
    switch (op.kind) {
        .dir => if (c.mkdirat(p.fd, p.base, 0o755) != 0) return error.Op,
        .file, .sparse => {
            const fd = c.openat(p.fd, p.base, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o644));
            if (fd < 0) return error.Op;
            defer _ = c.close(fd);
            if (op.kind == .file) return fill(fd, op.size);
            if (c.ftruncate(fd, @intCast(op.size)) != 0) return error.Op;
            try fill(fd, op.data);
        },
        .hard => {
            const s = try parent(a, root_fd, op.target);
            defer s.close();
            if (c.linkat(s.fd, s.base, p.fd, p.base, 0) != 0) return error.Op;
        },
        .sym => {
            const t = try a.dupeZ(u8, try case.expand(a, op.target, root));
            if (c.symlinkat(t, p.fd, p.base) != 0) return error.Op;
        },
        .chmod => {
            var lbuf: [8]u8 = undefined;
            if (c.readlinkat(p.fd, p.base, &lbuf, lbuf.len) >= 0) return error.Op;
            if (c.fchmodat(p.fd, p.base, op.mode, 0) != 0) return error.Op;
        },
        .nodump => {
            if (builtin.os.tag != .macos) return error.Op;
            const fd = c.openat(p.fd, p.base, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
            if (fd < 0) return error.Op;
            defer _ = c.close(fd);
            if (fchflags(fd, uf_nodump) != 0) return error.Op;
        },
    }
}

pub fn build(a: std.mem.Allocator, root: []const u8, ops: []const Op) ![]const Op {
    const rootz = try a.dupeZ(u8, root);
    _ = c.mkdir(rootz, 0o755);
    const root_fd = c.open(rootz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (root_fd < 0) return error.RootOpen;
    defer _ = c.close(root_fd);
    var done: std.ArrayList(Op) = .empty;
    for (try ordered(a, ops)) |op| {
        one(a, root_fd, root, op) catch continue;
        try done.append(a, op);
    }
    return done.items;
}

pub fn remove(a: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const res = std.process.run(a, io, .{ .argv = &.{ "/bin/chmod", "-R", "u+rwx", root } }) catch null;
    _ = res;
    try std.Io.Dir.cwd().deleteTree(io, root);
}
