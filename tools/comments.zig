const std = @import("std");

const Lang = enum { zig, hash, yaml, lean };

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    var bad: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and !skipped(entry.path)) try walker.enter(io, entry);
        if (entry.kind != .file) continue;
        const lang = langFor(entry.path) orelse continue;
        const text = try dir.readFileAlloc(io, entry.path, alloc, .limited(8 * 1024 * 1024));
        bad += report(entry.path, lang, text);
    }
    if (bad != 0) return 1;
    std.debug.print("comments: none\n", .{});
    return 0;
}

fn report(path: []const u8, lang: Lang, text: []const u8) usize {
    var bad: usize = 0;
    var quote: u8 = 0;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 1;
    while (lines.next()) |line| : (number += 1) {
        if (number == 1 and std.mem.startsWith(u8, line, "#!")) continue;
        if (lang == .yaml) quote = 0;
        const col = switch (lang) {
            .zig => zigComment(line),
            .hash, .yaml => hashComment(line, &quote),
            .lean => leanComment(line, &depth),
        } orelse continue;
        const kind = if (std.mem.trim(u8, line[0..col], " \t").len == 0) "full-line" else "trailing";
        std.debug.print("{s}:{d}: {s} comment\n", .{ path, number, kind });
        bad += 1;
    }
    return bad;
}

pub fn zigComment(line: []const u8) ?usize {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\")) return null;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return i;
        }
    }
    return null;
}

pub fn leanComment(line: []const u8, depth: *usize) ?usize {
    var found: ?usize = if (depth.* > 0) 0 else null;
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        const n: u8 = if (i + 1 < line.len) line[i + 1] else 0;
        if (depth.* > 0) {
            if (c == '/' and n == '-') {
                depth.* += 1;
                i += 1;
            } else if (c == '-' and n == '/') {
                depth.* -= 1;
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '\'' and i + 2 < line.len and line[i + 2] == '\'') {
            i += 2;
        } else if (c == '-' and n == '-') {
            return found orelse i;
        } else if (c == '/' and n == '-') {
            if (found == null) found = i;
            depth.* += 1;
            i += 1;
        }
    }
    return found;
}

pub fn hashComment(line: []const u8, quote: *u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote.* != 0) {
            if (c == '\\' and quote.* == '"') i += 1 else if (c == quote.*) quote.* = 0;
            continue;
        }
        switch (c) {
            '\\' => i += 1,
            '"', '\'' => if (opensQuote(line, i)) {
                quote.* = c;
            },
            '#' => if (i == 0 or wordBreak(line[i - 1])) return i,
            else => {},
        }
    }
    return null;
}

fn opensQuote(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    return !std.ascii.isAlphanumeric(line[i - 1]);
}

fn wordBreak(c: u8) bool {
    return switch (c) {
        ' ', '\t', ';', '|', '&', '(', ')' => true,
        else => false,
    };
}

fn skipped(path: []const u8) bool {
    for ([_][]const u8{ ".git", "zig-out", ".zig-cache", ".bench", "tests/frozen", "tests/upstream", "fuzz-failures", "proofs/.lake" }) |skip| {
        if (std.mem.eql(u8, path, skip)) return true;
    }
    return false;
}

fn langFor(path: []const u8) ?Lang {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".zig") or std.mem.eql(u8, base, "build.zig.zon")) return .zig;
    if (std.mem.endsWith(u8, base, ".lean")) return .lean;
    if (std.mem.endsWith(u8, base, ".yml") or std.mem.endsWith(u8, base, ".yaml")) return .yaml;
    for ([_][]const u8{ ".sh", ".pl", ".py", ".tape" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return .hash;
    }
    for ([_][]const u8{ "Makefile", "justfile", ".gitignore" }) |name| {
        if (std.mem.eql(u8, base, name)) return .hash;
    }
    return null;
}

test "trailing and full-line comments are both found" {
    try std.testing.expectEqual(@as(?usize, 0), zigComment("// x"));
    try std.testing.expectEqual(@as(?usize, 7), zigComment("a = 1; // x"));
    try std.testing.expectEqual(@as(?usize, null), zigComment("s = \"//x\";"));
    try std.testing.expectEqual(@as(?usize, null), zigComment("c = '\"'; s = \"a//\";"));
    try std.testing.expectEqual(@as(?usize, null), zigComment("    \\\\ // text"));
    var q: u8 = 0;
    try std.testing.expectEqual(@as(?usize, 5), hashComment("echo # x", &q));
    try std.testing.expectEqual(@as(?usize, null), hashComment("echo $# ${#a} \"#\" '#' a#b", &q));
    try std.testing.expectEqual(@as(?usize, null), hashComment("awk '", &q));
    try std.testing.expectEqual(@as(?usize, null), hashComment("  # inside quotes", &q));
    try std.testing.expectEqual(@as(?usize, 4), hashComment("' x # y", &q));
}

test "lean comments are found" {
    var d: usize = 0;
    try std.testing.expectEqual(@as(?usize, 11), leanComment("def x := 1 -- y", &d));
    try std.testing.expectEqual(@as(?usize, null), leanComment("def s := \"a--b /-\"", &d));
    try std.testing.expectEqual(@as(?usize, null), leanComment("def c := '-'", &d));
    try std.testing.expectEqual(@as(?usize, 0), leanComment("/-- doc", &d));
    try std.testing.expectEqual(@as(?usize, 0), leanComment("still doc -/", &d));
    try std.testing.expectEqual(@as(usize, 0), d);
    try std.testing.expectEqual(@as(?usize, 4), leanComment("def /- a /- b -/ -/ y", &d));
    try std.testing.expectEqual(@as(?usize, null), leanComment("theorem t : a - b = c := rfl", &d));
}
