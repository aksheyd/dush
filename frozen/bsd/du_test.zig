const std = @import("std");

const timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .{ .nanoseconds = 60 * std.time.ns_per_s },
} };

const freebsd_blocksize: ?[]const u8 = "K";
const apple_blocksize: ?[]const u8 = null;

const Out = struct {
    status: i32,
    stdout: []u8,
    stderr: []u8,
};

const Step = struct {
    cwd: []const u8 = "",
    sorted: bool = false,
};

fn status(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| code,
        else => -1,
    };
}

fn sortedLines(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(alloc, line);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (list.items) |line| {
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.items;
}

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    dush: []const u8,
    name: []const u8,
    failed: usize,
    ran: usize,

    fn init(h: *Harness, name: []const u8, blocksize: ?[]const u8) !void {
        h.arena_state = .init(std.testing.allocator);
        errdefer h.arena_state.deinit();
        const alloc = h.arena_state.allocator();
        const io = std.testing.io;
        h.env = try std.testing.environ.createMap(alloc);
        for ([_][]const u8{ "BLOCKSIZE", "BLOCK_SIZE", "DU_BLOCK_SIZE", "POSIXLY_CORRECT" }) |key| {
            _ = h.env.swapRemove(key);
        }
        try h.env.put("COMMAND_MODE", "legacy");
        try h.env.put("LC_ALL", "C");
        if (blocksize) |b| try h.env.put("BLOCKSIZE", b);
        const bin = h.env.get("DUSH_BIN") orelse "./dush";
        h.dush = if (std.fs.path.isAbsolute(bin)) bin else try std.Io.Dir.cwd().realPathFileAlloc(io, bin, alloc);
        h.tmp = std.testing.tmpDir(.{});
        const len = try h.tmp.dir.realPath(io, &h.root_buf);
        h.root = h.root_buf[0..len];
        h.name = name;
        h.failed = 0;
        h.ran = 0;
    }

    fn deinit(h: *Harness) void {
        h.tmp.cleanup();
        h.arena_state.deinit();
    }

    fn arena(h: *Harness) std.mem.Allocator {
        return h.arena_state.allocator();
    }

    fn mkdir(h: *Harness, sub: []const u8) !void {
        try h.tmp.dir.createDirPath(std.testing.io, sub);
    }

    fn truncate(h: *Harness, sub: []const u8, len: u64) !void {
        const io = std.testing.io;
        var f = try h.tmp.dir.createFile(io, sub, .{});
        defer f.close(io);
        try f.setLength(io, len);
    }

    fn symlink(h: *Harness, target: []const u8, sub: []const u8) !void {
        try h.tmp.dir.symLink(std.testing.io, target, sub, .{});
    }

    fn hardlink(h: *Harness, from: []const u8, to: []const u8) !void {
        try std.Io.Dir.hardLink(h.tmp.dir, from, h.tmp.dir, to, std.testing.io, .{});
    }

    fn cwdPath(h: *Harness, cwd: []const u8) ![]const u8 {
        if (cwd.len == 0) return h.root;
        return std.fs.path.join(h.arena(), &.{ h.root, cwd });
    }

    fn sh(h: *Harness, cwd: []const u8, script: []const u8) !Out {
        const res = try std.process.run(h.arena(), std.testing.io, .{
            .argv = &.{ "/bin/sh", "-c", script },
            .cwd = .{ .path = try h.cwdPath(cwd) },
            .environ_map = &h.env,
            .timeout = timeout,
        });
        return .{ .status = status(res.term), .stdout = res.stdout, .stderr = res.stderr };
    }

    fn requireSparse(h: *Harness) !void {
        const out = try h.sh("", "getconf MIN_HOLE_SIZE .");
        if (out.status != 0) {
            std.debug.print("SKIP {s}: getconf MIN_HOLE_SIZE failed, sparse files probably unsupported\n", .{h.name});
            return error.SkipZigTest;
        }
    }

    fn exec(h: *Harness, bin: []const u8, args: []const []const u8, cwd: []const u8) !Out {
        const argv = try std.mem.concat(h.arena(), []const u8, &.{ &.{bin}, args });
        const res = try std.process.run(h.arena(), std.testing.io, .{
            .argv = argv,
            .cwd = .{ .path = try h.cwdPath(cwd) },
            .environ_map = &h.env,
            .timeout = timeout,
        });
        return .{ .status = status(res.term), .stdout = res.stdout, .stderr = res.stderr };
    }

    fn render(h: *Harness, args: []const []const u8) ![]const u8 {
        return std.mem.join(h.arena(), " ", args);
    }

    fn parity(h: *Harness, args: []const []const u8, step: Step) !void {
        h.ran += 1;
        const du = try h.exec("/usr/bin/du", args, step.cwd);
        const dush = try h.exec(h.dush, args, step.cwd);
        const du_text = if (step.sorted) try sortedLines(h.arena(), du.stdout) else du.stdout;
        const dush_text = if (step.sorted) try sortedLines(h.arena(), dush.stdout) else dush.stdout;
        const same = du.status == dush.status and
            std.mem.eql(u8, du_text, dush_text) and
            (du.stderr.len == 0) == (dush.stderr.len == 0);
        const cmd = try h.render(args);
        if (same) {
            std.debug.print("PASS {s}: du {s}\n", .{ h.name, cmd });
            return;
        }
        h.failed += 1;
        std.debug.print(
            "FAIL {s}: du {s}\n  du   exit {d} stdout:\n{s}  du   stderr: {s}\n  dush exit {d} stdout:\n{s}  dush stderr: {s}\n",
            .{ h.name, cmd, du.status, du.stdout, du.stderr, dush.status, dush.stdout, dush.stderr },
        );
    }

    fn selfSame(h: *Harness, a: []const []const u8, b: []const []const u8, cwd: []const u8) !void {
        h.ran += 1;
        const x = try h.exec(h.dush, a, cwd);
        const y = try h.exec(h.dush, b, cwd);
        const ca = try h.render(a);
        const cb = try h.render(b);
        if (x.status == 0 and y.status == 0 and std.mem.eql(u8, x.stdout, y.stdout)) {
            std.debug.print("PASS {s}: dush {s} == dush {s}\n", .{ h.name, ca, cb });
            return;
        }
        h.failed += 1;
        std.debug.print(
            "FAIL {s}: dush {s} == dush {s}\n  first exit {d}:\n{s}{s}  second exit {d}:\n{s}{s}\n",
            .{ h.name, ca, cb, x.status, x.stdout, x.stderr, y.status, y.stdout, y.stderr },
        );
    }

    fn done(h: *Harness) !void {
        std.debug.print("{s} {s}: {d}/{d} steps match du\n", .{ if (h.failed == 0) "OK" else "MISMATCH", h.name, h.ran - h.failed, h.ran });
        if (h.failed != 0) return error.ParityMismatch;
    }
};

const kib = 1024;
const mib = 1024 * kib;
const gib = 1024 * mib;
const tib = 1024 * gib;

fn aFlagCase(h: *Harness) !void {
    try h.requireSparse();
    try h.truncate("sparse.file", 10 * gib);
    try h.parity(&.{ "-g", "sparse.file" }, .{});
    try h.parity(&.{ "-A", "-g", "sparse.file" }, .{});
}

fn hFlagUpperCase(h: *Harness) !void {
    try h.mkdir("testdir/A");
    try h.truncate("testdir/A/B", 0);
    try h.symlink("A", "testdir/C");
    try h.parity(&.{ "-aAH", "testdir" }, .{});
    try h.parity(&.{ "-aAH", "testdir/C" }, .{});
}

fn iFlagCase(h: *Harness) !void {
    const sans = [_][]const u8{ "a/motley/fool/of/sorts", "fool/parts/with/their/cache", "bar", "baz" };
    const named = [_][]const u8{ "foo", "foobar" };
    for (sans ++ named) |p| try h.mkdir(try std.fs.path.join(h.arena(), &.{ "testdir", p }));
    const plain = [_][]const u8{"-s"} ++ sans;
    const ignored = [_][]const u8{ "-I", "*foo*", "-s" } ++ sans ++ named;
    try h.parity(&plain, .{ .cwd = "testdir" });
    try h.parity(&ignored, .{ .cwd = "testdir" });
    try h.selfSame(&plain, &ignored, "testdir");
}

fn symlinkTree(h: *Harness) !void {
    try h.mkdir("testdir1");
    try h.truncate("testdir1/A", 8192);
    try h.symlink("A", "testdir1/B");
}

fn lFlagUpperCase(h: *Harness) !void {
    try symlinkTree(h);
    try h.parity(&.{ "-A", "testdir1" }, .{});
    try h.parity(&.{ "-AL", "testdir1" }, .{});
}

fn pFlagCase(h: *Harness) !void {
    try symlinkTree(h);
    try h.parity(&.{ "-A", "testdir1" }, .{});
    try h.parity(&.{ "-AP", "testdir1" }, .{});
}

fn aFlagLowerCase(h: *Harness) !void {
    try h.mkdir("testdir1");
    try h.truncate("testdir1/A", 0);
    try h.parity(&.{ "-A", "testdir1" }, .{});
    try h.parity(&.{ "-Aa", "testdir1" }, .{});
}

fn cFlagCase(h: *Harness, size: u64) !void {
    try h.truncate("foo", size);
    try h.truncate("bar", size);
    try h.parity(&.{ "-A", "foo", "bar" }, .{});
    try h.parity(&.{ "-Ac", "foo", "bar" }, .{});
}

fn dFlagCase(h: *Harness) !void {
    try h.mkdir("d0/d1/d2");
    for ([_][]const u8{ "0", "1", "2", "3" }) |depth| {
        try h.parity(&.{ "-A", "-d", depth, "d0" }, .{});
    }
}

fn abcd(h: *Harness, with_tib: bool) !void {
    try h.truncate("A", kib);
    try h.truncate("B", mib);
    try h.truncate("C", gib);
    if (with_tib) try h.truncate("D", tib);
}

fn gFlagCase(h: *Harness) !void {
    try h.requireSparse();
    try abcd(h, true);
    try h.parity(&.{ "-Ag", "A", "B", "C", "D" }, .{});
}

fn hFlagLowerCase(h: *Harness) !void {
    try h.requireSparse();
    try abcd(h, true);
    try h.parity(&.{ "-Ah", "A", "B", "C", "D" }, .{});
}

fn kFlagCase(h: *Harness) !void {
    try h.truncate("A", kib);
    try h.truncate("B", mib);
    try h.parity(&.{ "-Ak", "A", "B" }, .{});
}

fn lFlagLowerCase(h: *Harness) !void {
    try h.truncate("A", 0);
    try h.hardlink("A", "B");
    try h.parity(&.{ "-A", "A", "B" }, .{});
    try h.parity(&.{ "-Al", "A", "B" }, .{});
}

fn mFlagCase(h: *Harness) !void {
    try abcd(h, false);
    try h.parity(&.{ "-Am", "A", "B", "C" }, .{});
}

fn nFlagCase(h: *Harness) !void {
    try h.truncate("A", 0);
    try h.truncate("B", 0);
    try h.parity(&.{ "-An", "A", "B" }, .{});
    const flagged = try h.sh("", "chflags nodump B");
    if (flagged.status != 0) {
        std.debug.print("chflags nodump B failed: {s}\n", .{flagged.stderr});
        return error.SetupFailed;
    }
    try h.parity(&.{ "-An", "A", "B" }, .{});
}

fn sFlagCase(h: *Harness) !void {
    try h.mkdir("testdir1/testdir2");
    try h.truncate("testdir1/A", 0);
    try h.truncate("testdir1/testdir2/B", 0);
    for ([_][]const u8{ "testdir1", "testdir1/A", "testdir1/testdir2", "testdir1/testdir2/B" }) |p| {
        try h.parity(&.{ "-As", p }, .{});
    }
}

fn siFlagCase(h: *Harness) !void {
    try h.truncate("A", 1500000);
    try h.truncate("B", 1572864);
    try h.parity(&.{ "-Ah", "A", "B" }, .{});
    try h.parity(&.{ "-A", "--si", "A", "B" }, .{});
}

fn tFlagCase(h: *Harness) !void {
    try h.mkdir("testdir1/testdir2");
    try h.truncate("testdir1/A", 8192);
    try h.truncate("testdir1/testdir2/B", 8192);
    try h.parity(&.{ "-At", "10240", "testdir1" }, .{});
    try h.parity(&.{ "-At", "-10240", "testdir1" }, .{});
    try h.parity(&.{ "-Aat", "9216", "testdir1" }, .{});
    try h.parity(&.{ "-Aat", "-9216", "testdir1" }, .{ .sorted = true });
}

const pipe_script =
    \\mkfifo fifo || exit 2
    \\: <fifo &
    \\{
    \\  wait
    \\  trap "" PIPE
    \\  "$1" 2>stderr
    \\  echo $? >rc
    \\} >fifo
;

fn brokenPipe(h: *Harness, bin: []const u8, sub: []const u8) !struct { rc: []const u8, stdout_named: bool } {
    const io = std.testing.io;
    try h.mkdir(sub);
    const res = try std.process.run(h.arena(), io, .{
        .argv = &.{ "/bin/sh", "-c", pipe_script, "sh", bin },
        .cwd = .{ .path = try h.cwdPath(sub) },
        .environ_map = &h.env,
        .timeout = timeout,
    });
    if (status(res.term) != 0) {
        std.debug.print("broken pipe harness failed for {s}: {s}\n", .{ bin, res.stderr });
        return error.SetupFailed;
    }
    const rc = try h.tmp.dir.readFileAlloc(io, try std.fs.path.join(h.arena(), &.{ sub, "rc" }), h.arena(), .limited(64));
    const err = try h.tmp.dir.readFileAlloc(io, try std.fs.path.join(h.arena(), &.{ sub, "stderr" }), h.arena(), .limited(64 * 1024));
    return .{ .rc = std.mem.trim(u8, rc, " \n"), .stdout_named = std.mem.indexOf(u8, err, "stdout") != null };
}

fn stdoutCase(h: *Harness) !void {
    h.ran += 1;
    const du = try brokenPipe(h, "/usr/bin/du", "du");
    const dush = try brokenPipe(h, h.dush, "dush");
    if (std.mem.eql(u8, du.rc, dush.rc) and du.stdout_named == dush.stdout_named) {
        std.debug.print("PASS {s}: write to a closed pipe exits {s}, stderr names stdout: {}\n", .{ h.name, du.rc, du.stdout_named });
        return;
    }
    h.failed += 1;
    std.debug.print(
        "FAIL {s}: write to a closed pipe\n  du   exit {s}, stderr names stdout: {}\n  dush exit {s}, stderr names stdout: {}\n",
        .{ h.name, du.rc, du.stdout_named, dush.rc, dush.stdout_named },
    );
}

fn runCase(name: []const u8, blocksize: ?[]const u8, body: anytype, extra: anytype) !void {
    var h: Harness = undefined;
    try h.init(name, blocksize);
    defer h.deinit();
    try @call(.auto, body, .{&h} ++ extra);
    try h.done();
}

test "freebsd A_flag" {
    try runCase("freebsd/A_flag", freebsd_blocksize, aFlagCase, .{});
}

test "freebsd H_flag" {
    try runCase("freebsd/H_flag", freebsd_blocksize, hFlagUpperCase, .{});
}

test "freebsd I_flag" {
    try runCase("freebsd/I_flag", freebsd_blocksize, iFlagCase, .{});
}

test "freebsd L_flag" {
    try runCase("freebsd/L_flag", freebsd_blocksize, lFlagUpperCase, .{});
}

test "freebsd P_flag" {
    try runCase("freebsd/P_flag", freebsd_blocksize, pFlagCase, .{});
}

test "freebsd a_flag" {
    try runCase("freebsd/a_flag", freebsd_blocksize, aFlagLowerCase, .{});
}

test "freebsd c_flag" {
    try runCase("freebsd/c_flag", freebsd_blocksize, cFlagCase, .{@as(u64, 8192)});
}

test "freebsd d_flag" {
    try runCase("freebsd/d_flag", freebsd_blocksize, dFlagCase, .{});
}

test "freebsd g_flag" {
    try runCase("freebsd/g_flag", freebsd_blocksize, gFlagCase, .{});
}

test "freebsd h_flag" {
    try runCase("freebsd/h_flag", freebsd_blocksize, hFlagLowerCase, .{});
}

test "freebsd k_flag" {
    try runCase("freebsd/k_flag", freebsd_blocksize, kFlagCase, .{});
}

test "freebsd l_flag" {
    try runCase("freebsd/l_flag", freebsd_blocksize, lFlagLowerCase, .{});
}

test "freebsd m_flag" {
    try runCase("freebsd/m_flag", freebsd_blocksize, mFlagCase, .{});
}

test "freebsd n_flag" {
    try runCase("freebsd/n_flag", freebsd_blocksize, nFlagCase, .{});
}

test "freebsd s_flag" {
    try runCase("freebsd/s_flag", freebsd_blocksize, sFlagCase, .{});
}

test "freebsd si_flag" {
    try runCase("freebsd/si_flag", freebsd_blocksize, siFlagCase, .{});
}

test "freebsd t_flag" {
    try runCase("freebsd/t_flag", freebsd_blocksize, tFlagCase, .{});
}

test "freebsd stdout" {
    try runCase("freebsd/stdout", freebsd_blocksize, stdoutCase, .{});
}

test "apple A_flag" {
    try runCase("apple/A_flag", apple_blocksize, aFlagCase, .{});
}

test "apple H_flag" {
    try runCase("apple/H_flag", apple_blocksize, hFlagUpperCase, .{});
}

test "apple I_flag" {
    try runCase("apple/I_flag", apple_blocksize, iFlagCase, .{});
}

test "apple c_flag" {
    try runCase("apple/c_flag", apple_blocksize, cFlagCase, .{@as(u64, 0)});
}

test "apple g_flag" {
    try runCase("apple/g_flag", apple_blocksize, gFlagCase, .{});
}

test "apple h_flag" {
    try runCase("apple/h_flag", apple_blocksize, hFlagLowerCase, .{});
}

test "apple k_flag" {
    try runCase("apple/k_flag", apple_blocksize, kFlagCase, .{});
}

test "apple m_flag" {
    try runCase("apple/m_flag", apple_blocksize, mFlagCase, .{});
}

test "apple si_flag" {
    try runCase("apple/si_flag", apple_blocksize, siFlagCase, .{});
}
