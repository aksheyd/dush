const std = @import("std");

pub const Run = struct {
    code: ?u8,
    stdout: []const u8,
    stderr: []const u8,
};

pub const Cwd = ?[]const u8;

const timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .{ .nanoseconds = 120 * std.time.ns_per_s },
} };

pub const Ctx = struct {
    arena_state: std.heap.ArenaAllocator,
    io: std.Io,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    root: []const u8,
    dush: []const u8,
    failures: usize,

    pub fn init(self: *Ctx) !void {
        self.arena_state = .init(std.testing.allocator);
        self.io = std.testing.io;
        const a = self.arena_state.allocator();
        self.env = try std.testing.environ.createMap(a);
        for ([_][]const u8{ "BLOCKSIZE", "BLOCK_SIZE", "DU_BLOCK_SIZE", "POSIXLY_CORRECT" }) |key| {
            _ = self.env.swapRemove(key);
        }
        try self.env.put("COMMAND_MODE", "legacy");
        try self.env.put("LC_ALL", "C");
        self.failures = 0;
        self.tmp = std.testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(self.io, &buf);
        self.root = try a.dupe(u8, buf[0..n]);
        const bin = self.env.get("DUSH_BIN") orelse "./dush";
        if (std.fs.path.isAbsolute(bin)) {
            self.dush = bin;
        } else {
            const here = try std.process.currentPathAlloc(self.io, a);
            self.dush = try std.fs.path.resolve(a, &.{ here, bin });
        }
    }

    pub fn deinit(self: *Ctx) void {
        _ = self.exec(&.{ "/bin/chmod", "-R", "u+rwx", self.root }, null, null) catch {};
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    pub fn alloc(self: *Ctx) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn flag(self: *Ctx, name: []const u8) bool {
        const v = self.env.get(name) orelse return false;
        return v.len != 0 and !std.mem.eql(u8, v, "0");
    }

    pub fn p(self: *Ctx, rel: []const u8) []const u8 {
        if (rel.len == 0 or std.mem.eql(u8, rel, ".")) return self.root;
        return std.fs.path.join(self.alloc(), &.{ self.root, rel }) catch @panic("oom");
    }

    pub fn fmt(self: *Ctx, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.alloc(), f, args) catch @panic("oom");
    }

    pub fn mkdir(self: *Ctx, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(self.io, rel);
    }

    pub fn file(self: *Ctx, rel: []const u8, n: usize) !void {
        const data = try self.alloc().alloc(u8, n);
        @memset(data, 'x');
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = rel, .data = data });
    }

    pub fn sparse(self: *Ctx, rel: []const u8, n: u64) !void {
        var f = try self.tmp.dir.createFile(self.io, rel, .{});
        defer f.close(self.io);
        try f.setLength(self.io, n);
    }

    pub fn sym(self: *Ctx, target: []const u8, rel: []const u8) !void {
        try self.tmp.dir.symLink(self.io, target, rel, .{});
    }

    pub fn hard(self: *Ctx, from: []const u8, to: []const u8) !void {
        try std.Io.Dir.hardLink(self.tmp.dir, from, self.tmp.dir, to, self.io, .{});
    }

    pub fn chmod(self: *Ctx, mode: []const u8, rel: []const u8) !void {
        try self.must(&.{ "/bin/chmod", mode, self.p(rel) });
    }

    pub fn must(self: *Ctx, argv: []const []const u8) !void {
        const r = try self.exec(argv, null, null);
        if (r.code == null or r.code.? != 0) {
            std.debug.print("setup failed: {s}\n{s}", .{ argv[0], r.stderr });
            return error.SetupFailed;
        }
    }

    pub fn exec(self: *Ctx, argv: []const []const u8, cwd: Cwd, env: ?*const std.process.Environ.Map) !Run {
        const res = try std.process.run(self.alloc(), self.io, .{
            .argv = argv,
            .environ_map = env,
            .timeout = timeout,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        });
        return .{
            .code = if (res.term == .exited) res.term.exited else null,
            .stdout = res.stdout,
            .stderr = res.stderr,
        };
    }

    pub fn du(self: *Ctx, args: []const []const u8, cwd: Cwd) !Run {
        const argv = try std.mem.concat(self.alloc(), []const u8, &.{ &.{"/usr/bin/du"}, args });
        return self.exec(argv, cwd, &self.env);
    }

    pub fn dushRun(self: *Ctx, args: []const []const u8, cwd: Cwd) !Run {
        const argv = try std.mem.concat(self.alloc(), []const u8, &.{ &.{self.dush}, args });
        return self.exec(argv, cwd, null);
    }

    pub fn same(self: *Ctx, label: []const u8, dush_args: []const []const u8, du_args: []const []const u8, cwd: Cwd) !void {
        const want = try self.du(du_args, cwd);
        const got = try self.dushRun(dush_args, cwd);
        self.note(check(label, got, want.stdout, want.code, want.stderr.len != 0, want.stderr));
    }

    pub fn expect(self: *Ctx, label: []const u8, dush_args: []const []const u8, stdout: []const u8, code: u8, cwd: Cwd) !void {
        const got = try self.dushRun(dush_args, cwd);
        self.note(check(label, got, stdout, code, code != 0, ""));
    }

    pub fn sameLocked(self: *Ctx, label: []const u8, locked: []const u8, dush_args: []const []const u8, du_args: []const []const u8) !void {
        const want = try self.exec(try self.lockedArgv(locked, du_args, "/usr/bin/du"), null, &self.env);
        try self.chmod("u+rwx", locked);
        const got = try self.exec(try self.lockedArgv(locked, dush_args, self.dush), null, null);
        try self.chmod("u+rwx", locked);
        self.note(check(label, got, want.stdout, want.code, want.stderr.len != 0, want.stderr));
    }

    pub fn note(self: *Ctx, ok: bool) void {
        if (!ok) self.failures += 1;
    }

    pub fn done(self: *Ctx) !void {
        if (self.failures != 0) return error.Mismatch;
    }

    fn lockedArgv(self: *Ctx, locked: []const u8, args: []const []const u8, prog: []const u8) ![]const []const u8 {
        const script = "cd \"$1\" && /bin/chmod 0 . && shift && exec \"$@\"";
        return std.mem.concat(self.alloc(), []const u8, &.{ &.{ "/bin/sh", "-c", script, "sh", self.p(locked), prog }, args });
    }

    pub fn duTotal(self: *Ctx, args: []const []const u8) !u64 {
        const r = try self.du(args, self.root);
        var fields = std.mem.tokenizeAny(u8, r.stdout, " \t\n");
        return std.fmt.parseInt(u64, fields.next() orelse return error.NoTotal, 10);
    }
};

fn check(label: []const u8, got: Run, stdout: []const u8, code: ?u8, want_err: bool, want_stderr: []const u8) bool {
    const ok_out = std.mem.eql(u8, got.stdout, stdout);
    const ok_code = std.meta.eql(got.code, code);
    const ok_err = (got.stderr.len != 0) == want_err;
    if (ok_out and ok_code and ok_err) {
        std.debug.print("ok {s}\n", .{label});
        return true;
    }
    std.debug.print(
        "MISMATCH {s}\n  exit dush={?d} want={?d}\n  dush stdout: {f}\n  want stdout: {f}\n  dush stderr: {f}\n  want stderr: {f}\n",
        .{ label, got.code, code, std.zig.fmtString(got.stdout), std.zig.fmtString(stdout), std.zig.fmtString(got.stderr), std.zig.fmtString(want_stderr) },
    );
    return false;
}
