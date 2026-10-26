const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    var bad: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and !skipped(entry.basename)) try walker.enter(io, entry);
        if (entry.kind != .file) continue;
        const marker = commentMarker(entry.path) orelse continue;
        const text = try dir.readFileAlloc(io, entry.path, alloc, .limited(8 * 1024 * 1024));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 1;
        while (lines.next()) |line| : (number += 1) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, marker)) continue;
            if (number == 1 and std.mem.startsWith(u8, trimmed, "#!")) continue;
            std.debug.print("{s}:{d}: full-line comment\n", .{ entry.path, number });
            bad += 1;
        }
    }
    if (bad != 0) return 1;
    std.debug.print("comments: none\n", .{});
    return 0;
}

fn skipped(name: []const u8) bool {
    for ([_][]const u8{ ".git", "zig-out", ".zig-cache", ".bench", "upstream" }) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn commentMarker(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "//";
    if (std.mem.endsWith(u8, path, ".sh")) return "#";
    if (std.mem.startsWith(u8, path, ".github/workflows/")) return "#";
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "justfile")) return "#";
    return null;
}
