const std = @import("std");
const case = @import("case.zig");

pub const Outcome = struct {
    code: ?u8 = null,
    signal: bool = false,
    sig: u32 = 0,
    hang: bool = false,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

pub const Diff = struct {
    stdout: bool = false,
    code: bool = false,
    stderr: bool = false,
    hang: bool = false,
    crash: bool = false,
    order_only: bool = false,

    pub fn any(d: Diff) bool {
        return d.stdout or d.code or d.stderr or d.hang or d.crash;
    }

    pub fn same(d: Diff, e: Diff) bool {
        return d.stdout == e.stdout and d.code == e.code and d.stderr == e.stderr and d.hang == e.hang and d.crash == e.crash;
    }

    pub fn label(d: Diff, a: std.mem.Allocator) ![]const u8 {
        var s: std.ArrayList(u8) = .empty;
        if (d.hang) try s.appendSlice(a, "hang+");
        if (d.crash) try s.appendSlice(a, "crash+");
        if (d.stdout) try s.appendSlice(a, if (d.order_only) "order+" else "stdout+");
        if (d.code) try s.appendSlice(a, "exit+");
        if (d.stderr) try s.appendSlice(a, "stderr+");
        if (s.items.len == 0) return "none";
        return s.items[0 .. s.items.len - 1];
    }
};

pub fn environ(a: std.mem.Allocator, extra: []const case.Env, more: []const case.Env) !std.process.Environ.Map {
    var m: std.process.Environ.Map = .init(a);
    try m.put("PATH", "/usr/bin:/bin");
    try m.put("LC_ALL", "C");
    for (extra) |e| try m.put(e.name, e.value);
    for (more) |e| try m.put(e.name, e.value);
    return m;
}

pub fn exec(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map, seconds: u64) !Outcome {
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = @intCast(seconds * std.time.ns_per_s) } } };
    const res = std.process.run(a, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .timeout = timeout,
        .stdout_limit = .limited(32 << 20),
        .stderr_limit = .limited(32 << 20),
    }) catch |err| switch (err) {
        error.Timeout => return .{ .hang = true },
        else => return err,
    };
    return switch (res.term) {
        .exited => |code| .{ .code = code, .stdout = res.stdout, .stderr = res.stderr },
        .signal, .stopped => |sg| .{ .signal = true, .sig = @intFromEnum(sg), .stdout = res.stdout, .stderr = res.stderr },
        .unknown => |u| .{ .signal = true, .sig = u, .stdout = res.stdout, .stderr = res.stderr },
    };
}

pub fn normalizeStderr(a: std.mem.Allocator, raw: []const u8, prog: []const u8) ![]const u8 {
    const s = if (prog.len == 0 or std.mem.eql(u8, prog, "du")) raw else try std.mem.replaceOwned(u8, a, raw, prog, "du");
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        if (std.mem.startsWith(u8, line, "dush: ")) {
            try out.appendSlice(a, "du: ");
            try out.appendSlice(a, line["dush: ".len..]);
        } else try out.appendSlice(a, line);
    }
    return out.items;
}

fn sortedLines(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(a, l);
    std.sort.pdq([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn sameLines(a: std.mem.Allocator, x: []const u8, y: []const u8) !bool {
    const sx = try sortedLines(a, x);
    const sy = try sortedLines(a, y);
    if (sx.len != sy.len) return false;
    for (sx, sy) |l, r| if (!std.mem.eql(u8, l, r)) return false;
    return true;
}

pub fn compare(a: std.mem.Allocator, want: Outcome, want_prog: []const u8, got: Outcome, got_prog: []const u8) !Diff {
    var d: Diff = .{};
    if (got.hang and !want.hang) d.hang = true;
    if (got.signal and !want.signal) d.crash = true;
    if (d.hang) return d;
    d.stdout = !std.mem.eql(u8, want.stdout, got.stdout);
    if (d.stdout) d.order_only = try sameLines(a, want.stdout, got.stdout);
    d.code = !std.meta.eql(want.code, got.code) and !d.crash;
    const we = try normalizeStderr(a, try normalizeStderr(a, want.stderr, want_prog), got_prog);
    const ge = try normalizeStderr(a, try normalizeStderr(a, got.stderr, got_prog), want_prog);
    d.stderr = !std.mem.eql(u8, we, ge);
    return d;
}
