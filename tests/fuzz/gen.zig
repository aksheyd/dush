const std = @import("std");
const builtin = @import("builtin");
const case = @import("case.zig");
const Op = case.Op;
const Env = case.Env;

const Group = []const []const u8;

const sizes = [_]u64{ 0, 1, 2, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097, 8191, 8192, 8193, 65536, 131072, 1048575 };
const unicode = [_][]const u8{ "\xc3\xa9", "e\xcc\x81", "\xe6\x97\xa5\xe6\x9c\xac", "\xf0\x9f\x93\x81", "\xd0\xb4\xd0\xb8\xd1\x80", "\xc3\x85ngstr\xc3\xb6m", "\xe2\x80\x8bzw" };
const special = [_][]const u8{ "sp ace", "-dash", "--", "star*", "q?", "[br]", "back\\slash", "trail ", ".hidden", "..dots", "nl\nline", "tab\tx", "%s%n", "'quote", "\"dq", "$var", "colon:x", "a.b.c" };
const blocksizes = [_][]const u8{ "512", "1024", "1k", "1K", "2048", "4096", "1m", "1M", "1g", "1G", "100", "1000", "513", "0", "-1", "bogus", "1t", "", "1024k", "10000000000" };
const thresholds = [_][]const u8{ "0", "1", "511", "512", "4096", "1k", "4K", "8k", "1M", "-1", "-512", "-4096", "-8k", "-1M", "abc", "1x", "" };
const bvals = [_][]const u8{ "512", "1024", "1000", "1", "4096", "1k", "1M", "513", "0", "-1", "x" };
const depths = [_][]const u8{ "0", "1", "2", "3", "5", "-1", "x", "" };
const dir_modes = [_]u16{ 0o000, 0o300, 0o600, 0o500, 0o100, 0o200, 0o400 };
const file_modes = [_]u16{ 0o000, 0o200, 0o444, 0o111 };

pub const Gen = struct {
    a: std.mem.Allocator,
    r: std.Random,
    ops: std.ArrayList(Op) = .empty,
    dirs: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    syms: std.ArrayList([]const u8) = .empty,
    counter: usize = 0,

    fn pct(g: *Gen, p: u32) bool {
        return g.r.uintLessThan(u32, 100) < p;
    }

    fn pick(g: *Gen, comptime T: type, xs: []const T) T {
        return xs[g.r.uintLessThan(usize, xs.len)];
    }

    fn name(g: *Gen) ![]const u8 {
        const roll = g.r.uintLessThan(u32, 100);
        g.counter += 1;
        const base: []const u8 = if (roll < 55)
            g.pick([]const u8, &.{ "a", "b", "c", "d", "e", "f", "x", "y", "z", "sub", "dir", "file" })
        else if (roll < 65)
            g.pick([]const u8, &.{ "x.txt", "f.log", "a.c", "b.h", "img.png" })
        else if (roll < 72) blk: {
            const n = 100 + g.r.uintLessThan(usize, 156);
            const s = try g.a.alloc(u8, n);
            @memset(s, 'L');
            break :blk s;
        } else if (roll < 82)
            g.pick([]const u8, &unicode)
        else if (roll < 94)
            g.pick([]const u8, &special)
        else
            g.pick([]const u8, &.{ "1", "007", "1e3", "0x10" });
        if (base.len >= 250 or g.pct(50)) return base;
        return std.fmt.allocPrint(g.a, "{s}{d}", .{ base, g.counter });
    }

    fn join(g: *Gen, dir: []const u8, base: []const u8) ![]const u8 {
        if (dir.len == 0) return base;
        return std.mem.concat(g.a, u8, &.{ dir, "/", base });
    }

    fn shallow(g: *Gen, xs: []const []const u8) ?[]const u8 {
        var tries: usize = 0;
        while (tries < 8 and xs.len != 0) : (tries += 1) {
            const p = g.pick([]const u8, xs);
            if (p.len < 600) return p;
        }
        return null;
    }

    fn dirFor(g: *Gen) []const u8 {
        return g.shallow(g.dirs.items) orelse "";
    }

    fn up(g: *Gen, dir: []const u8) ![]const u8 {
        var s: std.ArrayList(u8) = .empty;
        for (0..case.depth(dir)) |_| try s.appendSlice(g.a, "../");
        return s.items;
    }

    fn rel(g: *Gen, from_dir: []const u8, target: []const u8) ![]const u8 {
        const prefix = try g.up(from_dir);
        if (target.len == 0) return if (prefix.len == 0) "." else prefix[0 .. prefix.len - 1];
        return std.mem.concat(g.a, u8, &.{ prefix, target });
    }

    fn addDir(g: *Gen) !void {
        const p = try g.join(g.dirFor(), try g.name());
        try g.ops.append(g.a, .{ .kind = .dir, .path = p });
        try g.dirs.append(g.a, p);
    }

    fn fileSize(g: *Gen) u64 {
        const roll = g.r.uintLessThan(u32, 100);
        if (roll < 75) return g.pick(u64, &sizes);
        if (roll < 95) return g.r.uintLessThan(u64, 300000);
        return (1 << 20) + g.r.uintLessThan(u64, 3 << 20);
    }

    fn addFile(g: *Gen) !void {
        const p = try g.join(g.dirFor(), try g.name());
        try g.ops.append(g.a, .{ .kind = .file, .path = p, .size = g.fileSize() });
        try g.files.append(g.a, p);
    }

    fn addSparse(g: *Gen) !void {
        const p = try g.join(g.dirFor(), try g.name());
        const size = g.pick(u64, &.{ 1 << 20, 10 << 20, 1 << 30, 5 << 30, 4097, 65537 });
        const data = g.pick(u64, &.{ 0, 1, 512, 4096, 65536 });
        try g.ops.append(g.a, .{ .kind = .sparse, .path = p, .size = size, .data = @min(data, size) });
        try g.files.append(g.a, p);
    }

    fn addHard(g: *Gen) !void {
        const to_sym = g.syms.items.len != 0 and g.pct(10);
        const pool = if (to_sym) g.syms.items else g.files.items;
        const src = g.shallow(pool) orelse return g.addFile();
        const dir = if (to_sym) std.fs.path.dirname(src) orelse "" else g.dirFor();
        const p = try g.join(dir, try g.name());
        try g.ops.append(g.a, .{ .kind = .hard, .path = p, .target = src });
        try (if (to_sym) &g.syms else &g.files).append(g.a, p);
    }

    fn addSym(g: *Gen) !void {
        const dir = g.dirFor();
        const base = try g.name();
        const p = try g.join(dir, base);
        const roll = g.r.uintLessThan(u32, 100);
        var target: []const u8 = undefined;
        if (roll < 25 and g.files.items.len != 0) {
            target = try g.rel(dir, g.shallow(g.files.items) orelse "");
        } else if (roll < 45) {
            target = try g.rel(dir, g.dirFor());
        } else if (roll < 55) {
            const t = g.dirFor();
            target = if (t.len == 0) case.root_mark else try std.mem.concat(g.a, u8, &.{ case.root_mark, "/", t });
        } else if (roll < 65) {
            target = g.pick([]const u8, &.{ "missing", "nowhere/x", "/nonexistent-dush-fuzz", "" });
        } else if (roll < 72) {
            target = base;
        } else if (roll < 80) {
            const other = try g.join(dir, try g.name());
            target = std.fs.path.basename(other);
            try g.ops.append(g.a, .{ .kind = .sym, .path = other, .target = base });
            try g.syms.append(g.a, other);
        } else if (roll < 90 and g.syms.items.len != 0) {
            target = try g.rel(dir, g.shallow(g.syms.items) orelse "");
        } else if (case.depth(dir) >= 1 and g.pct(50)) {
            target = "..";
        } else {
            target = ".";
        }
        if (target.len == 0 and !g.pct(10)) target = "missing";
        try g.ops.append(g.a, .{ .kind = .sym, .path = p, .target = target });
        try g.syms.append(g.a, p);
    }

    fn addChmod(g: *Gen) !void {
        if (g.files.items.len != 0 and g.pct(35)) {
            try g.ops.append(g.a, .{ .kind = .chmod, .path = g.pick([]const u8, g.files.items), .mode = g.pick(u16, &file_modes) });
            return;
        }
        if (g.dirs.items.len <= 1) return g.addDir();
        const d = g.dirs.items[1 + g.r.uintLessThan(usize, g.dirs.items.len - 1)];
        try g.ops.append(g.a, .{ .kind = .chmod, .path = d, .mode = g.pick(u16, &dir_modes) });
    }

    fn addNodump(g: *Gen) !void {
        if (builtin.os.tag != .macos) return g.addFile();
        const pool = if (g.pct(50) and g.dirs.items.len > 1) g.dirs.items[1..] else g.files.items;
        if (pool.len == 0) return g.addFile();
        try g.ops.append(g.a, .{ .kind = .nodump, .path = g.pick([]const u8, pool) });
    }

    fn addDeep(g: *Gen) !void {
        var p: []const u8 = g.dirFor();
        const n = 4 + g.r.uintLessThan(usize, 4);
        for (0..n) |_| {
            const s = try g.a.alloc(u8, 180 + g.r.uintLessThan(usize, 70));
            @memset(s, 'D');
            p = try g.join(p, s);
            try g.ops.append(g.a, .{ .kind = .dir, .path = p });
        }
        try g.ops.append(g.a, .{ .kind = .file, .path = try g.join(p, "deep"), .size = g.pick(u64, &sizes) });
    }

    fn tree(g: *Gen) !void {
        try g.dirs.append(g.a, "");
        const roll = g.r.uintLessThan(u32, 100);
        const steps = if (roll < 50) 1 + g.r.uintLessThan(usize, 12) else if (roll < 85) 12 + g.r.uintLessThan(usize, 30) else 40 + g.r.uintLessThan(usize, 110);
        for (0..steps) |_| {
            const k = g.r.uintLessThan(u32, 100);
            if (k < 24) try g.addDir() else if (k < 52) try g.addFile() else if (k < 56) try g.addSparse() else if (k < 67) try g.addHard() else if (k < 83) try g.addSym() else if (k < 93) try g.addChmod() else if (k < 95) try g.addNodump() else if (k < 97) try g.addDeep() else try g.addFile();
        }
    }

    fn valued(g: *Gen, name_: []const u8, value: []const u8) !Group {
        if (value.len != 0 and g.pct(35)) {
            const one = try g.a.alloc([]const u8, 1);
            one[0] = try std.mem.concat(g.a, u8, &.{ name_, value });
            return one;
        }
        const two = try g.a.alloc([]const u8, 2);
        two[0] = name_;
        two[1] = value;
        return two;
    }

    fn single(g: *Gen, tok: []const u8) !Group {
        const one = try g.a.alloc([]const u8, 1);
        one[0] = tok;
        return one;
    }

    fn pattern(g: *Gen) ![]const u8 {
        if (g.pct(50) and g.ops.items.len != 0) {
            const op = g.pick(Op, g.ops.items);
            return std.fs.path.basename(op.path);
        }
        return g.pick([]const u8, &.{ "*", "a*", "*.txt", "?", "[ab]*", "x", "sub*", "*L*", "" });
    }

    fn flag(g: *Gen, groups: *std.ArrayList(Group), mode: *u8) !void {
        while (true) {
            const k = g.r.uintLessThan(u32, 20);
            const exclusive: u8 = switch (k) {
                0 => 'a',
                14 => 's',
                2 => 'd',
                else => 0,
            };
            if (exclusive != 0 and mode.* != 0 and mode.* != exclusive and !g.pct(10)) continue;
            if (exclusive != 0) mode.* = exclusive;
            const grp: Group = switch (k) {
                0 => try g.single("-a"),
                1 => try g.single("-c"),
                2 => try g.valued("-d", g.pick([]const u8, &depths)),
                3 => try g.single("-g"),
                4 => try g.single("-H"),
                5 => try g.single("-h"),
                6 => try g.valued("-I", try g.pattern()),
                7 => try g.single("-k"),
                8 => try g.single("-L"),
                9 => try g.single("-l"),
                10 => try g.single("-m"),
                11 => try g.single("-n"),
                12 => try g.single("-P"),
                13 => try g.single("-r"),
                14 => try g.single("-s"),
                15 => try g.valued("-t", g.pick([]const u8, &thresholds)),
                16 => try g.single("-x"),
                17 => try g.single("-A"),
                18 => try g.single("--si"),
                else => try g.valued("-B", g.pick([]const u8, &bvals)),
            };
            try groups.append(g.a, grp);
            return;
        }
    }

    fn bundle(g: *Gen, groups: []const Group) ![]const Group {
        var out: std.ArrayList(Group) = .empty;
        for (groups) |grp| {
            const simple = grp.len == 1 and grp[0].len == 2 and grp[0][0] == '-' and grp[0][1] != '-';
            if (simple and out.items.len != 0) {
                const last = out.items[out.items.len - 1];
                const last_simple = last.len == 1 and last[0].len >= 2 and last[0][0] == '-' and last[0][1] != '-' and std.mem.indexOfAny(u8, last[0][1..], "dItB") == null;
                if (last_simple and g.pct(40)) {
                    out.items[out.items.len - 1] = try g.single(try std.mem.concat(g.a, u8, &.{ last[0], grp[0][1..] }));
                    continue;
                }
            }
            try out.append(g.a, grp);
        }
        return out.items;
    }

    fn operand(g: *Gen, prev: []const Group) ![]const u8 {
        const roll = g.r.uintLessThan(u32, 100);
        if (roll < 8 and prev.len != 0) return prev[g.r.uintLessThan(usize, prev.len)][0];
        if (roll < 15) return ".";
        if (roll < 17) return g.pick([]const u8, &.{ "nope", "nope/", "missing/x" });
        if (roll < 18) return "";
        var p: []const u8 = undefined;
        const kind = g.r.uintLessThan(u32, 100);
        if (kind < 45 or g.ops.items.len == 0) {
            p = g.dirFor();
            if (p.len == 0) p = ".";
        } else if (kind < 75 and g.files.items.len != 0) {
            p = g.shallow(g.files.items) orelse ".";
        } else if (g.syms.items.len != 0) {
            p = g.shallow(g.syms.items) orelse ".";
        } else {
            p = g.pick(Op, g.ops.items).path;
        }
        if (g.pct(15)) p = try std.mem.concat(g.a, u8, &.{ p, if (g.pct(80)) "/" else "//" });
        if (g.pct(8) and !std.mem.eql(u8, p, ".")) p = try std.mem.concat(g.a, u8, &.{ "./", p });
        if (g.pct(10)) p = if (std.mem.eql(u8, p, ".")) case.root_mark else try std.mem.concat(g.a, u8, &.{ case.root_mark, "/", p });
        return p;
    }

    fn args(g: *Gen) ![]const Group {
        var groups: std.ArrayList(Group) = .empty;
        const roll = g.r.uintLessThan(u32, 100);
        const nflags: usize = if (roll < 15) 0 else if (roll < 45) 1 else if (roll < 75) 2 else if (roll < 92) 3 else 4 + g.r.uintLessThan(usize, 3);
        var mode: u8 = 0;
        for (0..nflags) |_| try g.flag(&groups, &mode);
        const flags = try g.bundle(groups.items);
        var ops: std.ArrayList(Group) = .empty;
        const oroll = g.r.uintLessThan(u32, 100);
        const nops: usize = if (oroll < 25) 0 else if (oroll < 70) 1 else 2 + g.r.uintLessThan(usize, 3);
        for (0..nops) |_| try ops.append(g.a, try g.single(try g.operand(ops.items)));
        var out: std.ArrayList(Group) = .empty;
        try out.appendSlice(g.a, flags);
        if (ops.items.len != 0 and (g.pct(5) or startsDash(ops.items[0][0]))) try out.append(g.a, try g.single("--"));
        try out.appendSlice(g.a, ops.items);
        if (ops.items.len != 0 and g.pct(5)) try g.flag(&out, &mode);
        return out.items;
    }

    fn envs(g: *Gen) ![]const Env {
        var out: std.ArrayList(Env) = .empty;
        if (g.pct(35)) try out.append(g.a, .{ .name = "BLOCKSIZE", .value = g.pick([]const u8, &blocksizes) });
        if (g.pct(20)) try out.append(g.a, .{ .name = "COMMAND_MODE", .value = g.pick([]const u8, &.{ "legacy", "unix2003", "bogus" }) });
        if (g.pct(5)) try out.append(g.a, .{ .name = "POSIXLY_CORRECT", .value = "1" });
        if (g.pct(10)) try out.append(g.a, .{ .name = "LC_ALL", .value = "en_US.UTF-8" });
        return out.items;
    }
};

fn startsDash(s: []const u8) bool {
    return s.len != 0 and s[0] == '-';
}

pub fn generate(a: std.mem.Allocator, seed: u64) !case.Case {
    var prng = std.Random.DefaultPrng.init(seed);
    var g: Gen = .{ .a = a, .r = prng.random() };
    try g.tree();
    const args = try g.args();
    const env = try g.envs();
    return .{ .seed = seed, .ops = g.ops.items, .args = args, .env = env };
}
