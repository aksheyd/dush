const std = @import("std");

const token = "ALLOW-FROZEN-EDIT";

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const event = env.get("GITHUB_EVENT_NAME") orelse "";
    if (!std.mem.eql(u8, event, "pull_request")) {
        std.debug.print("freeze: skipped outside a pull request\n", .{});
        return 0;
    }
    const base_ref = env.get("GITHUB_BASE_REF") orelse return error.MissingBaseRef;
    const base = try std.fmt.allocPrint(alloc, "origin/{s}", .{base_ref});
    const range = try std.fmt.allocPrint(alloc, "{s}...HEAD", .{base});
    const edited = try git(alloc, io, &.{ "git", "diff", "--name-only", "--no-renames", "--diff-filter=a", range, "--", "frozen" });
    if (edited.len == 0) {
        std.debug.print("freeze: no edits to existing frozen files\n", .{});
        return 0;
    }
    std.debug.print("freeze: this pull request edits existing frozen files:\n{s}", .{edited});
    const log_range = try std.fmt.allocPrint(alloc, "{s}..HEAD", .{base});
    const messages = try git(alloc, io, &.{ "git", "log", "--format=%B", log_range });
    if (std.mem.indexOf(u8, messages, token) != null) {
        std.debug.print("freeze: allowed by {s} in a commit message\n", .{token});
        return 0;
    }
    std.debug.print("freeze: frozen files change only to fix a glaring bug in the suite itself; a commit message must contain {s}\n", .{token});
    return 1;
}

fn git(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s}", .{res.stderr});
        return error.GitFailed;
    }
    return res.stdout;
}
