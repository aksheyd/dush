const std = @import("std");
const case = @import("case.zig");
const tree = @import("tree.zig");
const run = @import("run.zig");
const Config = @import("main.zig").Config;

pub const Opts = struct {
    threads: usize = 0,
    iterations: usize = 3,
    files: usize = 40000,
    dirs: usize = 3000,
    thread_arg: []const u8 = "--threads={}",
    du_runs: usize = 5,
    mutate_runs: usize = 60,
    tree_seed: u64 = 1,
};

pub fn parseArg(o: *Opts, arg: []const u8, val: []const u8) !?usize {
    const num = struct {
        fn f(v: []const u8) !usize {
            return std.fmt.parseInt(usize, v, 10);
        }
    }.f;
    if (std.mem.eql(u8, arg, "--threads-max")) o.threads = try num(val) else if (std.mem.eql(u8, arg, "--iterations")) o.iterations = try num(val) else if (std.mem.eql(u8, arg, "--files")) o.files = try num(val) else if (std.mem.eql(u8, arg, "--dirs")) o.dirs = try num(val) else if (std.mem.eql(u8, arg, "--thread-arg")) o.thread_arg = val else if (std.mem.eql(u8, arg, "--du-runs")) o.du_runs = try num(val) else if (std.mem.eql(u8, arg, "--mutate-runs")) o.mutate_runs = try num(val) else if (std.mem.eql(u8, arg, "--tree-seed")) o.tree_seed = try num(val) else return null;
    return 1;
}

fn bigTree(a: std.mem.Allocator, o: Opts) ![]const case.Op {
    var prng = std.Random.DefaultPrng.init(o.tree_seed);
    const r = prng.random();
    var ops: std.ArrayList(case.Op) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    try dirs.append(a, "");
    for (0..o.dirs) |i| {
        const p = dirs.items[r.uintLessThan(usize, dirs.items.len)];
        const name = try std.fmt.allocPrint(a, "d{d}", .{i});
        const path = if (p.len == 0) name else try std.mem.concat(a, u8, &.{ p, "/", name });
        try ops.append(a, .{ .kind = .dir, .path = path });
        try dirs.append(a, path);
    }
    const sizes = [_]u64{ 0, 1, 511, 512, 513, 4095, 4096, 4097, 10000, 70000 };
    for (0..o.files) |i| {
        const p = dirs.items[r.uintLessThan(usize, dirs.items.len)];
        const name = try std.fmt.allocPrint(a, "f{d}", .{i});
        const path = if (p.len == 0) name else try std.mem.concat(a, u8, &.{ p, "/", name });
        const roll = r.uintLessThan(u32, 100);
        if (roll < 4 and files.items.len != 0) {
            try ops.append(a, .{ .kind = .hard, .path = path, .target = files.items[r.uintLessThan(usize, files.items.len)] });
        } else if (roll < 6) {
            const t = dirs.items[r.uintLessThan(usize, dirs.items.len)];
            try ops.append(a, .{ .kind = .sym, .path = path, .target = if (t.len == 0) case.root_mark else try std.mem.concat(a, u8, &.{ case.root_mark, "/", t }) });
        } else {
            const size = if (r.uintLessThan(u32, 100) < 90) sizes[r.uintLessThan(usize, sizes.len)] else r.uintLessThan(u64, 1 << 20);
            try ops.append(a, .{ .kind = .file, .path = path, .size = size });
            try files.append(a, path);
        }
    }
    for (0..3) |k| {
        const d = dirs.items[1 + r.uintLessThan(usize, dirs.items.len - 1)];
        try ops.append(a, .{ .kind = .chmod, .path = d, .mode = if (k == 0) 0o000 else if (k == 1) 0o300 else 0o600 });
    }
    if (files.items.len != 0) try ops.append(a, .{ .kind = .chmod, .path = files.items[0], .mode = 0o000 });
    return ops.items;
}

fn words(a: std.mem.Allocator, flags: []const []const u8) ![]const u8 {
    if (flags.len == 0) return "(none)";
    return std.mem.join(a, " ", flags);
}

fn threadArg(a: std.mem.Allocator, tmpl: []const u8, n: usize) ![]const u8 {
    const i = std.mem.indexOf(u8, tmpl, "{}") orelse return std.fmt.allocPrint(a, "{s}{d}", .{ tmpl, n });
    return std.fmt.allocPrint(a, "{s}{d}{s}", .{ tmpl[0..i], n, tmpl[i + 2 ..] });
}

fn sameOutcome(x: run.Outcome, y: run.Outcome) bool {
    return std.meta.eql(x.code, y.code) and x.hang == y.hang and x.signal == y.signal and std.mem.eql(u8, x.stdout, y.stdout) and std.mem.eql(u8, x.stderr, y.stderr);
}

fn show(o: run.Outcome) void {
    std.debug.print("    exit={?d} hang={} signal={d} stdout={f} stderr={f}\n", .{ o.code, o.hang, o.sig, std.zig.fmtString(o.stdout[0..@min(o.stdout.len, 300)]), std.zig.fmtString(o.stderr[0..@min(o.stderr.len, 300)]) });
}

const Mutator = struct {
    dir: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    ops: std.atomic.Value(u64) = .init(0),

    fn loop(m: *Mutator) void {
        var prng = std.Random.DefaultPrng.init(7);
        const r = prng.random();
        var buf: [512]u8 = undefined;
        var buf2: [512]u8 = undefined;
        const c = std.c;
        while (!m.stop.load(.monotonic)) {
            const i = r.uintLessThan(u32, 64);
            const j = r.uintLessThan(u32, 64);
            const p = std.fmt.bufPrintZ(&buf, "{s}/n{d}", .{ m.dir, i }) catch continue;
            const q = std.fmt.bufPrintZ(&buf2, "{s}/n{d}", .{ m.dir, j }) catch continue;
            switch (r.uintLessThan(u32, 7)) {
                0 => _ = c.mkdir(p, 0o755),
                1 => _ = c.rmdir(p),
                2 => {
                    const fd = c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
                    if (fd >= 0) {
                        var data: [8192]u8 = @splat('m');
                        _ = c.write(fd, &data, r.uintLessThan(usize, data.len));
                        _ = c.close(fd);
                    }
                },
                3 => _ = c.unlink(p),
                4 => _ = c.rename(p, q),
                5 => _ = c.symlink(q, p),
                else => {
                    const sub = std.fmt.bufPrintZ(&buf2, "{s}/n{d}/s{d}", .{ m.dir, i, j }) catch continue;
                    _ = c.mkdir(sub, 0o755);
                },
            }
            _ = m.ops.fetchAdd(1, .monotonic);
        }
    }
};

pub fn main(a: std.mem.Allocator, io: std.Io, cfg: Config, o: Opts, work: []const u8) !u8 {
    const cpus = std.Thread.getCpuCount() catch 4;
    const tmax = if (o.threads != 0) o.threads else 2 * cpus;
    const root = try std.fmt.allocPrint(a, "{s}/stress", .{work});
    std.debug.print("stress: building tree ({d} dirs, {d} entries, seed {d}) at {s}\n", .{ o.dirs, o.files, o.tree_seed, root });
    _ = try tree.build(a, root, try bigTree(a, o));
    defer tree.remove(a, io, root) catch {};
    var env = try run.environ(a, &.{}, &.{});
    var tenv = try run.environ(a, &.{}, cfg.target_env);
    var failures: usize = 0;

    const sets = [_][]const []const u8{ &.{}, &.{"-A"}, &.{"-c"}, &.{"-L"} };
    for (sets) |flags| {
        var first: ?run.Outcome = null;
        var runs: usize = 0;
        var bad: usize = 0;
        var t: usize = 1;
        while (t <= tmax) : (t += 1) for (0..o.iterations) |_| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, cfg.target);
            try argv.append(a, try threadArg(a, o.thread_arg, t));
            try argv.appendSlice(a, flags);
            const out = try run.exec(a, io, argv.items, root, &tenv, 120);
            runs += 1;
            if (first) |f| {
                if (!sameOutcome(f, out)) {
                    bad += 1;
                    if (bad <= 3) {
                        std.debug.print("  RACE flags={s} threads={d} differs from threads=1:\n", .{ try words(a, flags), t });
                        show(f);
                        show(out);
                    }
                }
            } else first = out;
        };
        failures += bad;
        std.debug.print("stress threads 1..{d} x{d} flags={s}: {d} runs, {d} differ from threads=1; first: exit={?d} stdout={f}\n", .{ tmax, o.iterations, try words(a, flags), runs, bad, first.?.code, std.zig.fmtString(first.?.stdout[0..@min(first.?.stdout.len, 120)]) });
    }

    const du_sets = [_][]const []const u8{ &.{"-s"}, &.{"-a"}, &.{ "-d", "2" }, &.{ "-c", "-k" }, &.{ "-A", "-s" }, &.{ "-L", "-s" }, &.{ "-l", "-s" } };
    for (du_sets) |flags| {
        var rargv: std.ArrayList([]const u8) = .empty;
        try rargv.append(a, cfg.ref);
        try rargv.appendSlice(a, flags);
        const want = try run.exec(a, io, rargv.items, root, &env, 120);
        var targv: std.ArrayList([]const u8) = .empty;
        try targv.append(a, cfg.link);
        try targv.appendSlice(a, flags);
        var first: ?run.Outcome = null;
        var unstable: usize = 0;
        var differ: usize = 0;
        for (0..o.du_runs) |_| {
            const got = try run.exec(a, io, targv.items, root, &tenv, 120);
            if (first) |f| {
                if (!sameOutcome(f, got)) unstable += 1;
            } else first = got;
            if ((try run.compare(a, want, cfg.ref, got, cfg.link)).any()) differ += 1;
        }
        failures += unstable;
        std.debug.print("stress du-mode flags={s}: {d} runs, {d} unstable between runs, {d} differ from /usr/bin/du\n", .{ try words(a, flags), o.du_runs, unstable, differ });
    }

    if (o.mutate_runs != 0) {
        const churn = try std.fmt.allocPrint(a, "{s}/churn", .{root});
        _ = std.c.mkdir(try a.dupeZ(u8, churn), 0o755);
        var m: Mutator = .{ .dir = churn };
        const th = try std.Thread.spawn(.{}, Mutator.loop, .{&m});
        var prng = std.Random.DefaultPrng.init(11);
        var bad: usize = 0;
        var codes: [3]usize = .{ 0, 0, 0 };
        for (0..o.mutate_runs) |k| {
            var argv: std.ArrayList([]const u8) = .empty;
            const use_du = k % 2 == 1;
            try argv.append(a, if (use_du) cfg.link else cfg.target);
            if (use_du) try argv.append(a, "-a") else try argv.append(a, try threadArg(a, o.thread_arg, 1 + prng.random().uintLessThan(usize, tmax)));
            try argv.append(a, ".");
            const out = try run.exec(a, io, argv.items, root, &tenv, 60);
            const ok_code = if (out.code) |cd| cd <= 1 else false;
            if (out.code) |cd| codes[@min(cd, 2)] += 1;
            const ok_out = out.stdout.len != 0 and out.stdout[out.stdout.len - 1] == '\n';
            if (out.hang or out.signal or !ok_code or !ok_out) {
                bad += 1;
                if (bad <= 3) {
                    std.debug.print("  MUTATE failure run {d}:\n", .{k});
                    show(out);
                }
            }
        }
        m.stop.store(true, .monotonic);
        th.join();
        failures += bad;
        std.debug.print("stress mutate: {d} runs during {d} concurrent tree changes, {d} hangs/crashes/bad exits (exit 0: {d}, exit 1: {d}, other: {d})\n", .{ o.mutate_runs, m.ops.raw, bad, codes[0], codes[1], codes[2] });
    }
    std.debug.print("stress: {s}\n", .{if (failures == 0) "ok" else "FAILED"});
    return if (failures == 0) 0 else 1;
}
