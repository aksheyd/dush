const std = @import("std");
const sys = @import("sys.zig");
const cli = @import("cli.zig");
const format = @import("format.zig");
const walk = @import("walk.zig");
const fts_walk = @import("fts_walk.zig");
const InodeSet = @import("inodes.zig").InodeSet;
const errors = @import("errors.zig");

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;

fn preventMaterialization() void {
    const one: c_int = 1;
    _ = sysctlbyname("vfs.nspace.prevent_materialization", null, null, &one, @sizeOf(c_int));
}

fn hasEmptyOperand(operands: sys.FtsArgv) bool {
    var i: usize = 0;
    while (operands[i]) |op| : (i += 1) {
        if (op[0] == 0) return true;
    }
    return false;
}

const Line = struct { blocks: i64, label: [*:0]const u8 };

fn runFast(allocator: std.mem.Allocator, cfg: *const cli.Config, links: *fts_walk.Links, out: format.Printer) ?u8 {
    if (hasEmptyOperand(cfg.operands)) return null;
    errors.deferring = true;
    defer errors.deferring = false;
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    defer lines.deinit(allocator);
    var total: i64 = 0;
    var i: usize = 0;
    while (cfg.operands[i]) |op| : (i += 1) {
        const r = walk.scanTarget(allocator, op, cfg, links);
        if (r.err or errors.deferred.load(.monotonic)) return null;
        if (r.counted) total += r.blocks;
        if (r.printable) lines.append(allocator, .{ .blocks = r.blocks, .label = op }) catch return null;
    }
    for (lines.items) |l| out.line(l.blocks, l.label);
    if (cfg.grand_total) out.line(total, "total");
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const allocator = std.heap.c_allocator;

    _ = sys.setlocale(sys.LC_ALL, "");
    preventMaterialization();

    const vec = init.minimal.args.vector;
    const argv: []?[*:0]u8 = @as([*]?[*:0]u8, @ptrCast(@constCast(vec.ptr)))[0 .. vec.len + 1];
    const mode = cli.modeFor(std.mem.span(sys.getprogname()));
    const cfg = switch (cli.parse(allocator, argv, mode) catch sys.errx(1, "out of memory")) {
        .exit => |code| return code,
        .run => |c| c,
    };

    var links = fts_walk.Links{ .files = InodeSet.init(allocator), .dirs = InodeSet.init(allocator) };
    const out = format.Printer{ .scale = cfg.scale, .units = cfg.units };

    const fast = if (cfg.fastPathEligible()) runFast(allocator, &cfg, &links, out) else null;
    const rval = fast orelse blk: {
        if (cfg.fastPathEligible()) {
            links.files.deinit();
            links.dirs.deinit();
            links = .{ .files = InodeSet.init(allocator), .dirs = InodeSet.init(allocator) };
        }
        break :blk fts_walk.run(&cfg, &links, out);
    };

    if (rval == 0 and (sys.ferror(sys.__stdoutp) != 0 or sys.fflush(sys.__stdoutp) != 0)) sys.err(1, "stdout");
    return rval;
}
