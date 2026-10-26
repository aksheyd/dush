const std = @import("std");
const case = @import("case.zig");
const gen = @import("gen.zig");
const tree = @import("tree.zig");
const run = @import("run.zig");
const script = @import("script.zig");
const stress = @import("stress.zig");

const usage =
    \\usage: fuzz [run|replay|stress] --target PATH [options]
    \\  run      --seeds FIRST:COUNT | --seconds N [--random] [--seed-base N]
    \\  replay   --seed N          print one case and write its repro
    \\  stress   see tests/fuzz/README.md
    \\options: --ref PATH (default /usr/bin/du), --jobs N, --work DIR, --failures DIR,
    \\  --timeout SECONDS, --per-bucket N, --shrink-budget N, --target-env K=V,
    \\  --expect-mismatch (succeed only if a mismatch is found), --no-shrink
    \\
;

pub const Config = struct {
    ref: []const u8 = "/usr/bin/du",
    target: []const u8 = "",
    link: []const u8 = "",
    target_env: []const case.Env = &.{},
    timeout: u64 = 10,
};

const Opts = struct {
    cfg: Config = .{},
    first: u64 = 1,
    count: u64 = 0,
    seconds: u64 = 0,
    random: bool = false,
    seed_base: ?u64 = null,
    seed: u64 = 1,
    jobs: usize = 0,
    work: []const u8 = "",
    failures: []const u8 = "fuzz-failures",
    per_bucket: usize = 2,
    shrink_budget: usize = 300,
    shrink: bool = true,
    expect_mismatch: bool = false,
    stress: stress.Opts = .{},
};

pub const Result = struct {
    built: []const case.Op,
    want: run.Outcome,
    got: run.Outcome,
    diff: run.Diff,
    ref_unstable: bool = false,
    target_unstable: bool = false,
};

pub fn runCase(a: std.mem.Allocator, io: std.Io, cfg: Config, root: []const u8, c: case.Case) !Result {
    try tree.remove(a, io, root);
    const built = try tree.build(a, root, c.ops);
    defer tree.remove(a, io, root) catch {};
    var env = try run.environ(a, c.env, &.{});
    var tenv = try run.environ(a, c.env, cfg.target_env);
    const want = try run.exec(a, io, try c.argv(a, cfg.ref, root), root, &env, cfg.timeout);
    const got = try run.exec(a, io, try c.argv(a, cfg.link, root), root, &tenv, cfg.timeout);
    var diff = try run.compare(a, want, cfg.ref, got, cfg.link);
    if (want.hang) diff = .{};
    if (!diff.any()) return .{ .built = built, .want = want, .got = got, .diff = diff };
    return retryTarget(a, io, cfg, root, c, try rerunRef(a, io, cfg, root, c, built, &env, want, got, diff));
}

fn rerunRef(a: std.mem.Allocator, io: std.Io, cfg: Config, root: []const u8, c: case.Case, built: []const case.Op, env: *const std.process.Environ.Map, want: run.Outcome, got: run.Outcome, first: run.Diff) !Result {
    var diff = first;
    const again = try run.exec(a, io, try c.argv(a, cfg.ref, root), root, env, cfg.timeout);
    if (std.meta.eql(want.code, again.code) and want.hang == again.hang and std.mem.eql(u8, want.stdout, again.stdout) and std.mem.eql(u8, want.stderr, again.stderr))
        return .{ .built = built, .want = want, .got = got, .diff = diff };
    diff = if (again.hang) .{} else try run.compare(a, again, cfg.ref, got, cfg.link);
    return .{ .built = built, .want = again, .got = got, .diff = diff, .ref_unstable = true };
}

fn retryTarget(a: std.mem.Allocator, io: std.Io, cfg: Config, root: []const u8, c: case.Case, r: Result) !Result {
    if (!r.diff.any()) return r;
    var env = try run.environ(a, c.env, cfg.target_env);
    const again = try run.exec(a, io, try c.argv(a, cfg.link, root), root, &env, cfg.timeout);
    const d = try run.compare(a, r.want, cfg.ref, again, cfg.link);
    if (d.any()) return r;
    var out = r;
    out.target_unstable = true;
    return out;
}

const Bucket = struct {
    count: usize = 0,
    written: usize = 0,
    examples: std.ArrayList([]const u8) = .empty,
};

const Shared = struct {
    io: std.Io,
    opts: Opts,
    root_base: []const u8,
    deadline: ?i96,
    base: u64,
    next: std.atomic.Value(u64),
    cases: std.atomic.Value(u64) = .init(0),
    mismatches: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    ref_hangs: std.atomic.Value(u64) = .init(0),
    ref_unstable: std.atomic.Value(u64) = .init(0),
    target_unstable: std.atomic.Value(u64) = .init(0),
    mutex: std.Io.Mutex = .init,
    quick: std.StringArrayHashMapUnmanaged(usize) = .empty,
    buckets: std.StringArrayHashMapUnmanaged(Bucket) = .empty,
    unstable: std.ArrayList([]const u8) = .empty,
};

const gpa = std.heap.smp_allocator;

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn mix(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn flagNames(a: std.mem.Allocator, c: case.Case) ![]const u8 {
    var set: [128]bool = @splat(false);
    var si = false;
    var dashdash = false;
    for (c.args) |group| {
        const tok = group[0];
        if (dashdash or tok.len < 2 or tok[0] != '-') continue;
        if (std.mem.eql(u8, tok, "--")) {
            dashdash = true;
            continue;
        }
        if (std.mem.eql(u8, tok, "--si")) {
            si = true;
            continue;
        }
        for (tok[1..]) |ch| {
            if (ch < 128) set[ch] = true;
            if (std.mem.indexOfScalar(u8, "dItB", ch) != null) break;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (set, 0..) |on, ch| if (on) {
        if (out.items.len != 0) try out.append(a, ' ');
        try out.append(a, '-');
        try out.append(a, @intCast(ch));
    };
    if (si) try out.appendSlice(a, if (out.items.len != 0) " --si" else "--si");
    if (out.items.len == 0) return "(no flags)";
    return out.items;
}

fn envNames(a: std.mem.Allocator, c: case.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c.env) |e| {
        if (out.items.len != 0) try out.append(a, ' ');
        try out.appendSlice(a, e.name);
    }
    if (out.items.len == 0) return "(default env)";
    return out.items;
}

fn opKinds(a: std.mem.Allocator, ops: []const case.Op) ![]const u8 {
    var seen: [@typeInfo(case.Kind).@"enum".fields.len]bool = @splat(false);
    for (ops) |op| seen[@intFromEnum(op.kind)] = true;
    var out: std.ArrayList(u8) = .empty;
    inline for (@typeInfo(case.Kind).@"enum".fields, 0..) |f, i| if (seen[i]) {
        if (out.items.len != 0) try out.append(a, ',');
        try out.appendSlice(a, f.name);
    };
    if (out.items.len == 0) return "(empty tree)";
    return out.items;
}

fn quickKey(a: std.mem.Allocator, c: case.Case, d: run.Diff) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} | {s}", .{ try d.label(a), try flagNames(a, c) });
}

fn bucketKey(a: std.mem.Allocator, c: case.Case, d: run.Diff) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} | {s} | {s} | {s}", .{ try d.label(a), try flagNames(a, c), try envNames(a, c), try opKinds(a, c.ops) });
}

fn slug(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (key) |ch| {
        const ok = std.ascii.isAlphanumeric(ch);
        if (ok) {
            try out.append(a, ch);
            dash = false;
        } else if (!dash and out.items.len != 0) {
            try out.append(a, '-');
            dash = true;
        }
        if (out.items.len > 90) break;
    }
    return out.items;
}

const Shrinker = struct {
    a: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    root: []const u8,
    want: run.Diff,
    attempts: usize = 0,
    budget: usize,

    fn holds(s: *Shrinker, c: *case.Case) !bool {
        if (s.attempts >= s.budget) return false;
        s.attempts += 1;
        const r = try runCase(s.a, s.io, s.cfg, s.root, c.*);
        if (!r.diff.any() or !r.diff.same(s.want)) return false;
        c.ops = r.built;
        return true;
    }

    fn without(s: *Shrinker, comptime T: type, xs: []const T, i: usize, n: usize) ![]const T {
        return std.mem.concat(s.a, T, &.{ xs[0..i], xs[i + n ..] });
    }

    fn shrink(s: *Shrinker, start: case.Case) !case.Case {
        var cur = start;
        var changed = true;
        while (changed and s.attempts < s.budget) {
            changed = false;
            var i: usize = cur.env.len;
            while (i > 0) {
                i -= 1;
                var cand = cur;
                cand.env = try s.without(case.Env, cur.env, i, 1);
                if (try s.holds(&cand)) {
                    cur = cand;
                    changed = true;
                }
            }
            i = cur.args.len;
            while (i > 0) {
                i -= 1;
                var cand = cur;
                cand.args = try s.without([]const []const u8, cur.args, i, 1);
                if (try s.holds(&cand)) {
                    cur = cand;
                    changed = true;
                }
            }
            var chunk = @max(cur.ops.len / 2, 1);
            while (cur.ops.len != 0) {
                var j: usize = 0;
                while (j < cur.ops.len) {
                    const n = @min(chunk, cur.ops.len - j);
                    var cand = cur;
                    cand.ops = try s.without(case.Op, cur.ops, j, n);
                    if (try s.holds(&cand)) {
                        cur = cand;
                        changed = true;
                    } else j += n;
                }
                if (chunk == 1) break;
                chunk /= 2;
            }
            for (cur.ops, 0..) |op, k| {
                if ((op.kind != .file or op.size == 0) and op.kind != .sparse) continue;
                const ops = try s.a.dupe(case.Op, cur.ops);
                ops[k].size = if (op.kind == .file) 0 else op.size;
                ops[k].data = 0;
                if (ops[k].size == op.size and ops[k].data == op.data) continue;
                var cand = cur;
                cand.ops = ops;
                if (try s.holds(&cand)) cur = cand;
            }
        }
        return cur;
    }
};

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn describe(a: std.mem.Allocator, c: case.Case, r: Result, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn p(al: std.mem.Allocator, o: *std.ArrayList(u8), comptime f: []const u8, args: anytype) !void {
            try o.appendSlice(al, try std.fmt.allocPrint(al, f, args));
        }
    }.p;
    try w(a, &out, "seed: {d}\nbucket: {s}\nargs:", .{ c.seed, key });
    for (c.args) |g| for (g) |t| try w(a, &out, " {f}", .{std.zig.fmtString(t)});
    try w(a, &out, "\nenv:", .{});
    for (c.env) |e| try w(a, &out, " {s}={f}", .{ e.name, std.zig.fmtString(e.value) });
    try w(a, &out, "\nops ({d}):\n", .{c.ops.len});
    for (c.ops) |op| try w(a, &out, "  {s} {f} target={f} size={d} data={d} mode={o}\n", .{ @tagName(op.kind), std.zig.fmtString(op.path), std.zig.fmtString(op.target), op.size, op.data, op.mode });
    if (r.ref_unstable) try w(a, &out, "reference changed output on rerun; the du lines below are from the rerun\n", .{});
    if (r.target_unstable) try w(a, &out, "target changed output on rerun and the rerun matched du; the dush lines below are from the first run\n", .{});
    try w(a, &out, "du   exit={?d} hang={} signal={d}\n  stdout: {f}\n  stderr: {f}\n", .{ r.want.code, r.want.hang, r.want.sig, std.zig.fmtString(r.want.stdout), std.zig.fmtString(r.want.stderr) });
    try w(a, &out, "dush exit={?d} hang={} signal={d}\n  stdout: {f}\n  stderr: {f}\n", .{ r.got.code, r.got.hang, r.got.sig, std.zig.fmtString(r.got.stdout), std.zig.fmtString(r.got.stderr) });
    return out.items;
}

fn writeRepro(a: std.mem.Allocator, io: std.Io, opts: Opts, dir: []const u8, c: case.Case, r: Result, key: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const sh = try std.fs.path.join(a, &.{ dir, "repro.sh" });
    try writeFile(io, sh, try script.render(a, c, opts.cfg.target_env));
    _ = std.c.chmod(try a.dupeZ(u8, sh), 0o755);
    try writeFile(io, try std.fs.path.join(a, &.{ dir, "case.txt" }), try describe(a, c, r, key));
}

fn one(sh: *Shared, a: std.mem.Allocator, root: []const u8, seed: u64) !void {
    const io = sh.io;
    const c = try gen.generate(a, seed);
    const r = try runCase(a, io, sh.opts.cfg, root, c);
    _ = sh.cases.fetchAdd(1, .monotonic);
    if (r.want.hang) _ = sh.ref_hangs.fetchAdd(1, .monotonic);
    if (r.ref_unstable) _ = sh.ref_unstable.fetchAdd(1, .monotonic);
    if (!r.diff.any()) return;
    if (r.target_unstable) {
        _ = sh.target_unstable.fetchAdd(1, .monotonic);
        const key = try bucketKey(a, c, r.diff);
        const dir = try std.fmt.allocPrint(a, "{s}/target-unstable/{s}/seed-{d}", .{ sh.opts.failures, try slug(a, key), seed });
        sh.mutex.lockUncancelable(io);
        defer sh.mutex.unlock(io);
        try sh.unstable.append(gpa, try gpa.dupe(u8, dir));
        try writeRepro(a, io, sh.opts, dir, c, r, key);
        std.debug.print("target unstable seed={d} [{s}] -> {s}\n", .{ seed, key, dir });
        return;
    }
    _ = sh.mismatches.fetchAdd(1, .monotonic);
    const qk = try quickKey(a, c, r.diff);
    var go = false;
    {
        sh.mutex.lockUncancelable(io);
        defer sh.mutex.unlock(io);
        const e = try sh.quick.getOrPut(gpa, qk);
        if (!e.found_existing) {
            e.key_ptr.* = try gpa.dupe(u8, qk);
            e.value_ptr.* = 0;
        }
        e.value_ptr.* += 1;
        go = e.value_ptr.* <= sh.opts.per_bucket;
    }
    if (!go) return;
    var small = c;
    small.ops = r.built;
    if (sh.opts.shrink) {
        var s: Shrinker = .{ .a = a, .io = io, .cfg = sh.opts.cfg, .root = root, .want = r.diff, .budget = sh.opts.shrink_budget };
        small = try s.shrink(small);
    }
    const fr = try runCase(a, io, sh.opts.cfg, root, small);
    const final = if (fr.diff.any()) fr else r;
    if (!fr.diff.any()) small = c;
    const key = try bucketKey(a, small, final.diff);
    sh.mutex.lockUncancelable(io);
    defer sh.mutex.unlock(io);
    const e = try sh.buckets.getOrPut(gpa, key);
    if (!e.found_existing) {
        e.key_ptr.* = try gpa.dupe(u8, key);
        e.value_ptr.* = .{};
    }
    e.value_ptr.count += 1;
    if (e.value_ptr.written >= sh.opts.per_bucket) return;
    e.value_ptr.written += 1;
    const dir = try std.fmt.allocPrint(gpa, "{s}/{s}/seed-{d}", .{ sh.opts.failures, try slug(a, key), seed });
    try e.value_ptr.examples.append(gpa, dir);
    try writeRepro(a, io, sh.opts, dir, small, final, key);
    std.debug.print("mismatch seed={d} [{s}] -> {s}\n", .{ seed, key, dir });
}

fn worker(sh: *Shared, id: usize) void {
    const root = std.fmt.allocPrint(gpa, "{s}/w{d}", .{ sh.root_base, id }) catch return;
    while (true) {
        if (sh.deadline) |d| if (now(sh.io) >= d) break;
        const idx = sh.next.fetchAdd(1, .monotonic);
        if (sh.opts.count != 0 and idx >= sh.opts.first + sh.opts.count) break;
        const seed = if (sh.opts.random) mix(sh.base +% idx) else idx;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        one(sh, arena.allocator(), root, seed) catch |err| {
            _ = sh.errors.fetchAdd(1, .monotonic);
            std.debug.print("harness error seed={d}: {s}\n", .{ seed, @errorName(err) });
        };
    }
}


fn summary(a: std.mem.Allocator, sh: *Shared, elapsed_ms: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn p(al: std.mem.Allocator, o: *std.ArrayList(u8), comptime f: []const u8, args: anytype) !void {
            try o.appendSlice(al, try std.fmt.allocPrint(al, f, args));
        }
    }.p;
    try w(a, &out, "target: {s}\nreference: {s}\ncases: {d}\nmismatches: {d}\nharness errors: {d}\nreference timeouts (skipped): {d}\nreference unstable on rerun (compared against the rerun): {d}\ntarget unstable on rerun (first run differed, rerun matched du): {d}\nelapsed: {d} ms\n", .{ sh.opts.cfg.target, sh.opts.cfg.ref, sh.cases.raw, sh.mismatches.raw, sh.errors.raw, sh.ref_hangs.raw, sh.ref_unstable.raw, sh.target_unstable.raw, elapsed_ms });
    for (sh.unstable.items) |d| try w(a, &out, "  target unstable: {s}/repro.sh\n", .{d});
    if (sh.opts.random) try w(a, &out, "seed base: {d}\n", .{sh.base});
    const Ctx = struct {
        m: *const std.StringArrayHashMapUnmanaged(usize),
        pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
            return ctx.m.values()[x] > ctx.m.values()[y];
        }
    };
    sh.quick.sort(Ctx{ .m = &sh.quick });
    try w(a, &out, "\nmismatches by difference and flags (all cases):\n", .{});
    for (sh.quick.keys(), sh.quick.values()) |k, v| try w(a, &out, "  {d:>6}  {s}\n", .{ v, k });
    const BCtx = struct {
        m: *const std.StringArrayHashMapUnmanaged(Bucket),
        pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
            return ctx.m.values()[x].count > ctx.m.values()[y].count;
        }
    };
    sh.buckets.sort(BCtx{ .m = &sh.buckets });
    try w(a, &out, "\nminimized buckets (difference | flags | env | tree ops):\n", .{});
    for (sh.buckets.keys(), sh.buckets.values()) |k, v| {
        try w(a, &out, "  {d:>4}  {s}\n", .{ v.count, k });
        for (v.examples.items) |ex| try w(a, &out, "          {s}/repro.sh\n", .{ex});
    }
    return out.items;
}

fn parseEnv(s: []const u8) !case.Env {
    const i = std.mem.indexOfScalar(u8, s, '=') orelse return error.BadEnv;
    return .{ .name = s[0..i], .value = s[i + 1 ..] };
}

fn abs(a: std.mem.Allocator, io: std.Io, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    const here = try std.process.currentPathAlloc(io, a);
    return std.fs.path.resolve(a, &.{ here, p });
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cmd = argv[1];
    var o: Opts = .{};
    var tenv: std.ArrayList(case.Env) = .empty;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const val = if (i + 1 < argv.len) argv[i + 1] else "";
        if (std.mem.eql(u8, arg, "--target")) {
            o.cfg.target = val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--ref")) {
            o.cfg.ref = val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            const colon = std.mem.indexOfScalar(u8, val, ':') orelse return error.BadSeeds;
            o.first = try std.fmt.parseInt(u64, val[0..colon], 10);
            o.count = try std.fmt.parseInt(u64, val[colon + 1 ..], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            o.seconds = try std.fmt.parseInt(u64, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--random")) {
            o.random = true;
        } else if (std.mem.eql(u8, arg, "--seed-base")) {
            o.seed_base = try std.fmt.parseInt(u64, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            o.seed = try std.fmt.parseInt(u64, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            o.jobs = try std.fmt.parseInt(usize, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--work")) {
            o.work = val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--failures")) {
            o.failures = val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            o.cfg.timeout = try std.fmt.parseInt(u64, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--per-bucket")) {
            o.per_bucket = try std.fmt.parseInt(usize, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--shrink-budget")) {
            o.shrink_budget = try std.fmt.parseInt(usize, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--target-env")) {
            try tenv.append(a, try parseEnv(val));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-shrink")) {
            o.shrink = false;
        } else if (std.mem.eql(u8, arg, "--expect-mismatch")) {
            o.expect_mismatch = true;
        } else if (try stress.parseArg(&o.stress, arg, val)) |used| {
            i += used;
        } else {
            std.debug.print("unknown option {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (o.cfg.target.len == 0) {
        std.debug.print("--target is required\n{s}", .{usage});
        return 2;
    }
    o.cfg.target = try abs(a, io, o.cfg.target);
    o.cfg.target_env = tenv.items;
    o.failures = try abs(a, io, o.failures);
    if (o.jobs == 0) o.jobs = @max(1, (std.Thread.getCpuCount() catch 2) / 2);

    const parent = if (o.work.len != 0) try abs(a, io, o.work) else init.environ_map.get("TMPDIR") orelse "/tmp";
    const work = try std.fmt.allocPrint(a, "{s}/dush-fuzz-{d}", .{ std.mem.trimEnd(u8, parent, "/"), std.c.getpid() });
    try std.Io.Dir.cwd().createDirPath(io, work);
    defer tree.remove(a, io, work) catch {};
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{work});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    o.cfg.link = try std.fmt.allocPrint(a, "{s}/du", .{bin});
    try std.Io.Dir.cwd().symLink(io, o.cfg.target, o.cfg.link, .{});

    if (std.mem.eql(u8, cmd, "stress")) return stress.main(a, io, o.cfg, o.stress, work);

    if (std.mem.eql(u8, cmd, "replay")) {
        const root = try std.fmt.allocPrint(a, "{s}/replay", .{work});
        const c = try gen.generate(a, o.seed);
        const r = try runCase(a, io, o.cfg, root, c);
        var small = c;
        small.ops = r.built;
        const key = try bucketKey(a, small, r.diff);
        std.debug.print("{s}", .{try describe(a, small, r, key)});
        const dir = try std.fmt.allocPrint(a, "{s}/replay/seed-{d}", .{ o.failures, o.seed });
        try writeRepro(a, io, o, dir, small, r, key);
        std.debug.print("repro: {s}/repro.sh\n", .{dir});
        return if (r.diff.any()) 1 else 0;
    }

    if (!std.mem.eql(u8, cmd, "run")) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    if (o.count == 0 and o.seconds == 0) o.count = 200;
    const start = now(io);
    const base = o.seed_base orelse @as(u64, @truncate(@as(u96, @bitCast(start)))) ^ @as(u64, @intCast(std.c.getpid()));
    var sh: Shared = .{
        .io = io,
        .opts = o,
        .root_base = work,
        .deadline = if (o.seconds != 0) start + @as(i96, o.seconds) * std.time.ns_per_s else null,
        .base = base,
        .next = .init(o.first),
    };
    const threads = try a.alloc(std.Thread, o.jobs);
    for (threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, worker, .{ &sh, id });
    for (threads) |t| t.join();
    const elapsed: i64 = @intCast(@divTrunc(now(io) - start, std.time.ns_per_ms));
    const text = try summary(a, &sh, elapsed);
    std.debug.print("\n{s}", .{text});
    if (sh.mismatches.raw != 0) {
        try std.Io.Dir.cwd().createDirPath(io, o.failures);
        try writeFile(io, try std.fs.path.join(a, &.{ o.failures, "summary.txt" }), text);
        std.debug.print("summary: {s}/summary.txt\n", .{o.failures});
    }
    if (sh.errors.raw != 0) return 2;
    if (o.expect_mismatch) return if (sh.mismatches.raw != 0) 0 else 1;
    return if (sh.mismatches.raw != 0) 1 else 0;
}
