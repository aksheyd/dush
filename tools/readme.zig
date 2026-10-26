const std = @import("std");

const results_path = "bench/results.json";
const readme_path = "README.md";
const hyperfine_path = ".bench/results.md";
const start_needle = "matches `du -sh` output byte-for-byte";
const end_needle = "### How it works";

const Row = struct {
    command: []const u8,
    mean: []const u8,
    min: []const u8,
    max: []const u8,
    vs: []const u8,
    format: []const u8,
    emphasize: bool,
};

const Results = struct {
    diskus_url: []const u8,
    measured: []const u8,
    also: []const u8,
    rows: []Row,
};

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(alloc);
    const cmd = if (args.len > 1) args[1] else "check";

    const results = try std.json.parseFromSliceLeaky(Results, alloc, try read(alloc, io, results_path), .{});
    if (std.mem.eql(u8, cmd, "record")) {
        try applyHyperfine(alloc, try read(alloc, io, hyperfine_path), results.rows);
        const json = try std.json.Stringify.valueAlloc(alloc, results, .{ .whitespace = .indent_2 });
        try dir.writeFile(io, .{ .sub_path = results_path, .data = try std.mem.concat(alloc, u8, &.{ json, "\n" }) });
    } else if (!std.mem.eql(u8, cmd, "check") and !std.mem.eql(u8, cmd, "render")) {
        std.debug.print("usage: readme.zig [check|render|record]\n", .{});
        return 1;
    }

    const readme = try read(alloc, io, readme_path);
    const rendered = try render(alloc, results, readme);
    if (!std.mem.eql(u8, cmd, "check")) {
        try dir.writeFile(io, .{ .sub_path = readme_path, .data = rendered });
        std.debug.print("readme: wrote {s} from {s}\n", .{ readme_path, results_path });
        return 0;
    }
    if (!std.mem.eql(u8, rendered, readme)) {
        std.debug.print("readme: the benchmark section does not match {s}; run `zig run tools/readme.zig -- render`\n", .{results_path});
        return 1;
    }
    if (try mainChangedWithoutReadme(alloc, io, init.environ_map)) {
        std.debug.print("readme: src/ changed against the base but README.md did not\n", .{});
        return 1;
    }
    std.debug.print("readme: ok\n", .{});
    return 0;
}

fn render(alloc: std.mem.Allocator, results: Results, readme: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, readme, start_needle) orelse return error.MissingBenchmarkStart;
    const line_start = if (std.mem.lastIndexOfScalar(u8, readme[0..start], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.indexOfPos(u8, readme, start, end_needle) orelse return error.MissingBenchmarkEnd;

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.writeAll(readme[0..line_start]);
    try w.print(
        "`dush` matches `du -sh` output byte-for-byte, but runs **{s} faster than `du -sh`** and **{s} faster than [`diskus`]({s})**:\n\n",
        .{ vsFor(results.rows, "du -sh"), vsFor(results.rows, "diskus"), results.diskus_url },
    );
    try w.writeAll("| Command | Mean | Min … Max | vs `dush` | Output Format |\n");
    try w.writeAll("| :--- | :---: | :---: | :---: | :--- |\n");
    for (results.rows) |row| {
        if (row.emphasize) {
            try w.print("| **`{s}`** | **{s}** | {s} … {s} ms | **{s}** | `{s}` |\n", .{ row.command, row.mean, row.min, row.max, row.vs, row.format });
        } else {
            try w.print("| `{s}` | {s} | {s} … {s} ms | {s} | `{s}` |\n", .{ row.command, row.mean, row.min, row.max, row.vs, row.format });
        }
    }
    try w.print("\n*{s}*\n\n{s}\n\n", .{ results.measured, results.also });
    try w.writeAll(readme[end..]);
    return out.toOwnedSlice();
}

fn vsFor(rows: []const Row, command: []const u8) []const u8 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.command, command)) return row.vs;
    }
    return "";
}

fn applyHyperfine(alloc: std.mem.Allocator, markdown: []const u8, rows: []Row) !void {
    var unit: []const u8 = "ms";
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Mean [")) |at| {
            const close = std.mem.indexOfScalarPos(u8, line, at, ']') orelse continue;
            unit = line[at + "Mean [".len .. close];
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|") or std.mem.indexOf(u8, line, "---") != null) continue;
        var cols: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, '|');
        while (it.next()) |col| : (n += 1) {
            if (n == cols.len) break;
            cols[n] = std.mem.trim(u8, col, " \t`");
        }
        if (n < cols.len) continue;
        for (rows) |*row| {
            if (!std.mem.eql(u8, row.command, cols[1])) continue;
            row.mean = try std.fmt.allocPrint(alloc, "{s} {s}", .{ firstToken(cols[2]), unit });
            row.min = firstToken(cols[3]);
            row.max = firstToken(cols[4]);
            row.vs = try std.fmt.allocPrint(alloc, "{s}x", .{firstToken(cols[5])});
        }
    }
}

fn firstToken(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    return it.next() orelse text;
}

fn mainChangedWithoutReadme(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !bool {
    const base = try std.fmt.allocPrint(alloc, "origin/{s}...HEAD", .{baseBranch(env.get("GITHUB_BASE_REF"))});
    const committed = try git(alloc, io, &.{ "git", "diff", "--name-only", base, "--", "src", readme_path });
    const uncommitted = try git(alloc, io, &.{ "git", "diff", "--name-only", "HEAD", "--", "src", readme_path });
    const changed = try std.mem.concat(alloc, u8, &.{ committed, uncommitted });
    return hasSrcLine(changed) and !hasLine(changed, readme_path);
}

pub fn baseBranch(ref: ?[]const u8) []const u8 {
    const r = ref orelse return "main";
    return if (r.len == 0) "main" else r;
}

fn hasSrcLine(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "src/")) return true;
    }
    return false;
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}

fn git(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s}", .{res.stderr});
        return error.GitFailed;
    }
    return res.stdout;
}

fn read(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024));
}

test "a push build sets GITHUB_BASE_REF to empty and compares against main" {
    try std.testing.expectEqualStrings("main", baseBranch(null));
    try std.testing.expectEqualStrings("main", baseBranch(""));
    try std.testing.expectEqualStrings("akshey/x", baseBranch("akshey/x"));
}
