const std = @import("std");
const case = @import("case.zig");
const tree = @import("tree.zig");
const Op = case.Op;

const W = *std.ArrayList(u8);

fn print(a: std.mem.Allocator, out: W, comptime f: []const u8, args: anytype) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, f, args));
}

fn quote(a: std.mem.Allocator, out: W, s: []const u8) !void {
    if (std.mem.startsWith(u8, s, case.root_mark)) {
        try out.appendSlice(a, "\"$T\"");
        const rest = s[case.root_mark.len..];
        if (rest.len == 0) return;
        return quote(a, out, rest);
    }
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
}

fn at(a: std.mem.Allocator, out: W, path: []const u8, cmd: []const u8, tail: []const u8) !void {
    if (path.len <= 700) {
        try out.appendSlice(a, cmd);
        try quote(a, out, path);
        try out.appendSlice(a, tail);
        try out.append(a, '\n');
        return;
    }
    try out.appendSlice(a, "( ");
    var it = std.mem.splitScalar(u8, std.fs.path.dirname(path) orelse "", '/');
    while (it.next()) |comp| {
        try out.appendSlice(a, "cd -- ");
        try quote(a, out, comp);
        try out.appendSlice(a, " && ");
    }
    try out.appendSlice(a, cmd);
    try quote(a, out, std.fs.path.basename(path));
    try out.appendSlice(a, tail);
    try out.appendSlice(a, " )\n");
}

fn opLine(a: std.mem.Allocator, out: W, op: Op) !void {
    switch (op.kind) {
        .dir => try at(a, out, op.path, "mkdir -- ", ""),
        .file => {
            if (op.size == 0) return at(a, out, op.path, ": > ", "");
            const cmd = try std.fmt.allocPrint(a, "head -c {d} /dev/zero | tr '\\000' x > ", .{op.size});
            try at(a, out, op.path, cmd, "");
        },
        .sparse => {
            const cmd = try std.fmt.allocPrint(a, "dd if=/dev/zero bs=1 count=0 seek={d} 2>/dev/null of=", .{op.size});
            try at(a, out, op.path, cmd, "");
            if (op.data != 0) {
                const fill = try std.fmt.allocPrint(a, "head -c {d} /dev/zero | tr '\\000' x | dd conv=notrunc 2>/dev/null of=", .{op.data});
                try at(a, out, op.path, fill, "");
            }
        },
        .hard => {
            var cmd: std.ArrayList(u8) = .empty;
            try cmd.appendSlice(a, "ln -P -- \"$T\"/");
            try quote(a, &cmd, op.target);
            try cmd.append(a, ' ');
            try at(a, out, op.path, cmd.items, "");
        },
        .sym => {
            var cmd: std.ArrayList(u8) = .empty;
            try cmd.appendSlice(a, "ln -s -- ");
            try quote(a, &cmd, op.target);
            try cmd.append(a, ' ');
            try at(a, out, op.path, cmd.items, "");
        },
        .chmod => try at(a, out, op.path, try std.fmt.allocPrint(a, "chmod {o:0>3} ", .{op.mode}), ""),
        .nodump => try at(a, out, op.path, "chflags nodump ", ""),
    }
}

fn runLine(a: std.mem.Allocator, out: W, c: case.Case, tag: []const u8, prog: []const u8) !void {
    try out.appendSlice(a, "env -i PATH=/usr/bin:/bin LC_ALL=C");
    for (c.env) |e| {
        try out.appendSlice(a, " ");
        try out.appendSlice(a, e.name);
        try out.append(a, '=');
        try quote(a, out, e.value);
    }
    try out.appendSlice(a, " ");
    try out.appendSlice(a, prog);
    for (c.args) |group| for (group) |tok| {
        try out.append(a, ' ');
        try quote(a, out, tok);
    };
    try print(a, out, " >\"$W/{s}.out\" 2>\"$W/{s}.err\"; echo $? >\"$W/{s}.code\"\n", .{ tag, tag, tag });
}

pub fn render(a: std.mem.Allocator, c: case.Case, extra_target_env: []const case.Env) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\#!/bin/sh
        \\set -u
        \\DUSH=${DUSH:-./dush}
        \\REF=${REF:-/usr/bin/du}
        \\case $DUSH in /*) ;; *) DUSH=$(cd "$(dirname "$DUSH")" && pwd -P)/$(basename "$DUSH") ;; esac
        \\[ -x "$DUSH" ] || { echo "set DUSH to a dush binary" >&2; exit 2; }
        \\umask 022
        \\T=$(mktemp -d "${TMPDIR:-/tmp}/dush-repro.XXXXXX") || exit 2
        \\W=$(mktemp -d "${TMPDIR:-/tmp}/dush-repro-out.XXXXXX") || exit 2
        \\trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T" "$W"' EXIT
        \\ln -s "$DUSH" "$W/du"
        \\cd "$T" || exit 2
        \\
    );
    try print(a, &out, "echo 'dush-fuzz seed {d}'\n", .{c.seed});
    for (try tree.ordered(a, c.ops)) |op| try opLine(a, &out, op);
    try runLine(a, &out, c, "want", "\"$REF\"");
    if (extra_target_env.len != 0) {
        var tc = c;
        var env: std.ArrayList(case.Env) = .empty;
        try env.appendSlice(a, c.env);
        try env.appendSlice(a, extra_target_env);
        tc.env = env.items;
        try runLine(a, &out, tc, "got", "\"$W/du\"");
    } else try runLine(a, &out, c, "got", "\"$W/du\"");
    try out.appendSlice(a,
        \\sed 's/^dush: /du: /' "$W/got.err" >"$W/got.nerr"
        \\mv "$W/got.nerr" "$W/got.err"
        \\st=0
        \\for s in out code err; do
        \\  if ! cmp -s "$W/want.$s" "$W/got.$s"; then
        \\    echo "MISMATCH $s (- /usr/bin/du, + dush)"
        \\    diff -u "$W/want.$s" "$W/got.$s" | tail -n +3
        \\    st=1
        \\  fi
        \\done
        \\[ $st = 0 ] && echo "match"
        \\exit $st
        \\
    );
    return out.items;
}
