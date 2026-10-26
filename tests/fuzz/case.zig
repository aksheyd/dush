const std = @import("std");

pub const root_mark = "\x01ROOT";

pub const Kind = enum { dir, file, sparse, hard, sym, chmod, nodump };

pub const Op = struct {
    kind: Kind,
    path: []const u8,
    target: []const u8 = "",
    size: u64 = 0,
    data: u64 = 0,
    mode: u16 = 0,
};

pub const Env = struct {
    name: []const u8,
    value: []const u8,
};

pub const Case = struct {
    seed: u64,
    ops: []const Op,
    args: []const []const []const u8,
    env: []const Env,

    pub fn argv(c: Case, a: std.mem.Allocator, prog: []const u8, root: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(a, prog);
        for (c.args) |group| for (group) |tok| try out.append(a, try expand(a, tok, root));
        return out.items;
    }

    pub fn hasFlag(c: Case, flag: []const u8) bool {
        for (c.args) |group| {
            if (group.len == 0 or group[0].len < 2 or group[0][0] != '-') continue;
            if (std.mem.eql(u8, group[0], flag)) return true;
        }
        return false;
    }
};

pub fn expand(a: std.mem.Allocator, tok: []const u8, root: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, tok, root_mark)) return tok;
    return std.mem.concat(a, u8, &.{ root, tok[root_mark.len..] });
}

pub fn depth(path: []const u8) usize {
    if (path.len == 0) return 0;
    return std.mem.count(u8, path, "/") + 1;
}
