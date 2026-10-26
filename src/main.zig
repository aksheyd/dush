const std = @import("std");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const format = @import("format.zig");
const walk = @import("walk.zig");
const InodeSet = @import("inodes.zig").InodeSet;
const Options = cli.Options;
const writeErr = errors.writeErr;
const printResult = format.printResult;
const scanTarget = walk.scanTarget;
const defaultThreads = cli.defaultThreads;

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    var opts = Options{ .num_threads = defaultThreads() };

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(allocator);

    var it = init.minimal.args.iterate();
    const prog = it.next() orelse "dush";

    if (cli.parse(allocator, &it, prog, &opts, &targets)) |code| return code;

    if (targets.items.len == 0) {
        targets.append(allocator, ".") catch {
            writeErr("dush", "out of memory");
            return 1;
        };
    }

    var files = InodeSet.init(allocator);
    defer files.deinit();

    var exit_code: u8 = 0;
    var grand_total: i64 = 0;

    for (targets.items) |t| {
        const r = scanTarget(allocator, t, &opts, &files);
        if (r.err) exit_code = 1;
        if (r.printable) {
            printResult(r.bytes, t, &opts);
            grand_total += r.bytes;
        }
    }

    if (opts.grand_total) {
        printResult(grand_total, "total", &opts);
    }

    return exit_code;
}
