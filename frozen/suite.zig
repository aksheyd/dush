const std = @import("std");

const timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .{ .nanoseconds = 30 * std.time.ns_per_s },
} };

const Total = struct {
    ok: bool,
    total: ?u64,
    stdout: []u8,
    stderr: []u8,
};

fn run(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: ?*const std.process.Environ.Map) !Total {
    const res = try std.process.run(alloc, io, .{ .argv = argv, .environ_map = env, .timeout = timeout });
    return .{
        .ok = res.term == .exited and res.term.exited == 0,
        .total = lastTotal(res.stdout),
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

fn lastTotal(stdout: []const u8) ?u64 {
    var last: ?u64 = null;
    var lines = std.mem.tokenizeAny(u8, stdout, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        last = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch return null;
    }
    return last;
}

fn duEnviron(alloc: std.mem.Allocator) !std.process.Environ.Map {
    var map = try std.testing.environ.createMap(alloc);
    errdefer map.deinit();
    for ([_][]const u8{ "BLOCKSIZE", "BLOCK_SIZE", "DU_BLOCK_SIZE", "POSIXLY_CORRECT" }) |key| {
        _ = map.swapRemove(key);
    }
    try map.put("COMMAND_MODE", "legacy");
    try map.put("LC_ALL", "C");
    return map;
}

fn writeLen(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, sub: []const u8, n: usize) !void {
    const data = try alloc.alloc(u8, n);
    defer alloc.free(data);
    @memset(data, 0);
    try dir.writeFile(io, .{ .sub_path = sub, .data = data });
}

const Suite = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    root: []const u8,
    dush: []const u8,

    fn path(s: Suite, rel: []const u8) ![]const u8 {
        return std.fs.path.join(s.arena, &.{ s.root, rel });
    }

    fn compare(s: Suite, label: []const u8, rel: []const u8, dush_flags: []const []const u8, du_flags: []const []const u8, du_must_ok: bool) !u64 {
        const p = try s.path(rel);
        const dush = try run(s.arena, s.io, try std.mem.concat(s.arena, []const u8, &.{ &.{s.dush}, dush_flags, &.{p} }), null);
        const du = try run(s.arena, s.io, try std.mem.concat(s.arena, []const u8, &.{ &.{"/usr/bin/du"}, du_flags, &.{p} }), s.env);
        if (dush.total == null or du.total == null or dush.total.? != du.total.? or !dush.ok or (du_must_ok and !du.ok)) {
            std.debug.print("mismatch {s}\ndush stdout: {s}\ndu stdout: {s}\ndush stderr: {s}\ndu stderr: {s}\n", .{ label, dush.stdout, du.stdout, dush.stderr, du.stderr });
            return error.TotalMismatch;
        }
        std.debug.print("ok {s} {d}\n", .{ label, du.total.? });
        return du.total.?;
    }

    fn duHasApparent(s: Suite, rel: []const u8) !bool {
        return (try run(s.arena, s.io, &.{ "/usr/bin/du", "-A", "-sk", try s.path(rel) }, s.env)).ok;
    }
};

test "frozen du totals" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;
    var env = try duEnviron(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const s: Suite = .{
        .arena = alloc,
        .io = io,
        .env = &env,
        .root = root_buf[0..root_len],
        .dush = env.get("DUSH_BIN") orelse "./dush",
    };
    const d = tmp.dir;

    for (0..4) |i| {
        for (0..5) |j| {
            try d.createDirPath(io, try std.fmt.allocPrint(alloc, "generated/b{d}/l{d}/nested", .{ i, j }));
            try writeLen(io, d, alloc, try std.fmt.allocPrint(alloc, "generated/b{d}/l{d}/payload", .{ i, j }), (i + j + 1) * 1024);
            try writeLen(io, d, alloc, try std.fmt.allocPrint(alloc, "generated/b{d}/l{d}/nested/odd", .{ i, j }), 1000 + i * 10 + j);
        }
    }
    var deep: []const u8 = "generated/deep";
    for (0..12) |depth| {
        deep = try std.fmt.allocPrint(alloc, "{s}/d{d}", .{ deep, depth });
        try d.createDirPath(io, deep);
        try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}/marker", .{deep}), .data = "x\n" });
    }

    try d.createDirPath(io, "apparent/nested");
    var sparse = try d.createFile(io, "apparent/sparse", .{});
    defer sparse.close(io);
    try sparse.setLength(io, 8 * 1024 * 1024);
    try writeLen(io, d, alloc, "apparent/odd", 1000);
    try writeLen(io, d, alloc, "apparent/nested/odd2", 1500);
    try writeLen(io, d, alloc, "apparent/nested/dense", 7 * 1024);

    try d.createDirPath(io, "hard/sub");
    try d.createDirPath(io, "alone");
    try writeLen(io, d, alloc, "hard/sub/data", 64 * 1024);
    try std.Io.Dir.hardLink(d, "hard/sub/data", d, "hard/sub/link1", io, .{});
    try std.Io.Dir.hardLink(d, "hard/sub/data", d, "hard/top", io, .{});
    try writeLen(io, d, alloc, "hard/extra", 3 * 1024);
    try writeLen(io, d, alloc, "alone/data", 64 * 1024);

    try d.createDirPath(io, "sym/outside");
    try d.createDirPath(io, "sym/tree");
    try writeLen(io, d, alloc, "sym/outside/big", 128 * 1024);
    try writeLen(io, d, alloc, "sym/outside/note", 300);
    try writeLen(io, d, alloc, "sym/tree/local", 8 * 1024);
    try d.symLink(io, "../outside", "sym/tree/jump", .{ .is_directory = true });
    try d.symLink(io, "tree", "sym/cli", .{ .is_directory = true });

    try d.createDirPath(io, "cycle/sub");
    try writeLen(io, d, alloc, "cycle/payload", 4 * 1024);
    try writeLen(io, d, alloc, "cycle/sub/leaf", 900);
    try d.symLink(io, ".", "cycle/loop", .{ .is_directory = true });
    try d.symLink(io, "..", "cycle/sub/up", .{ .is_directory = true });

    const gen_p = try s.compare("generated -P", "generated", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    const gen_h = try s.compare("generated -H", "generated", &.{ "-k", "-H" }, &.{ "-sk", "-H" }, true);
    try std.testing.expectEqual(gen_p, gen_h);

    if (try s.duHasApparent("apparent")) {
        _ = try s.compare("apparent size -A", "apparent", &.{ "-A", "-k", "-P" }, &.{ "-A", "-sk", "-P" }, true);
    } else {
        const sparse_n = try s.compare("apparent sparse", "apparent/sparse", &.{ "-A", "-k", "-P" }, &.{ "--apparent-size", "-sk" }, true);
        const odd_n = try s.compare("apparent odd", "apparent/odd", &.{ "-A", "-k", "-P" }, &.{ "--apparent-size", "-sk" }, true);
        try std.testing.expect(sparse_n > odd_n);
    }

    const hard_n = try s.compare("hard links", "hard", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    const alone_n = try s.compare("hard link single copy", "alone", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    try std.testing.expect(alone_n > 0);
    try std.testing.expect(hard_n < alone_n * 2);

    const tree_p = try s.compare("symlink -P tree", "sym/tree", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    const tree_h = try s.compare("symlink -H tree", "sym/tree", &.{ "-k", "-H" }, &.{ "-sk", "-H" }, true);
    const tree_l = try s.compare("symlink -L tree", "sym/tree", &.{ "-k", "-L" }, &.{ "-sk", "-L" }, true);
    try std.testing.expectEqual(tree_p, tree_h);
    try std.testing.expect(tree_p != tree_l);

    const cli_p = try s.compare("symlink -P cli", "sym/cli", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    const cli_h = try s.compare("symlink -H cli", "sym/cli", &.{ "-k", "-H" }, &.{ "-sk", "-H" }, true);
    const cli_l = try s.compare("symlink -L cli", "sym/cli", &.{ "-k", "-L" }, &.{ "-sk", "-L" }, true);
    try std.testing.expect(cli_p != cli_h);
    try std.testing.expect(cli_h != cli_l);

    _ = try s.compare("symlink cycle -P", "cycle", &.{ "-k", "-P" }, &.{ "-sk", "-P" }, true);
    const cyc_l = try s.compare("symlink cycle -L", "cycle", &.{ "-k", "-L" }, &.{ "-sk", "-L" }, false);
    try std.testing.expect(cyc_l > 0);
}
