const std = @import("std");
const errors = @import("errors.zig");
const writeAll = errors.writeAll;
const writeErr = errors.writeErr;

pub const VERSION = "1.0.0";

pub const FollowMode = enum { none, cli, all };

pub const Options = struct {
    apparent: bool = false, // -A, -b
    grand_total: bool = false, // -c
    block_size: i64 = 0, // 0 = human-readable, else 1024 (-k), 1048576 (-m), etc.
    follow: FollowMode = .none, // -P (default), -H, -L
    num_threads: usize = 8,
};

pub fn printUsage(prog: []const u8) void {
    var buf: [4096]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf,
        \\dush {s} - Ultra-fast du -sh replacement for macOS
        \\
        \\USAGE:
        \\    {s} [OPTIONS] [FILE/DIR ...]
        \\
        \\DESCRIPTION:
        \\    dush calculates directory disk usage identically to `du -sh` but
        \\    significantly faster using macOS getattrlistbulk(2) syscalls and
        \\    parallel work-stealing. On Apple Silicon the default worker count is the
        \\    performance-core count; elsewhere it is the logical CPU count.
        \\
        \\OPTIONS:
        \\    -s, --summary       Display only a summary for each specified file/dir (default)
        \\    -h, --human-readable
        \\                        Print sizes in human-readable format (e.g., 1.5K, 24M, 10G) (default)
        \\    -c, --total         Produce a grand total
        \\    -A, -b, --apparent-size
        \\                        Display apparent size instead of disk usage
        \\    -k                  Display block counts in 1024-byte (1 KiB) blocks
        \\    -m                  Display block counts in 1048576-byte (1 MiB) blocks
        \\    -g                  Display block counts in 1073741824-byte (1 GiB) blocks
        \\    -H                  Follow symlinks specified on the command line
        \\    -L                  Follow all symbolic links
        \\    -P                  Do not follow any symbolic links (default)
        \\    -t, --threads <N>   Number of worker threads (default: performance cores on Apple Silicon, else logical CPUs)
        \\    -v, --version       Display version information
        \\        --help          Display this help message
        \\
    , .{ VERSION, prog }) catch return;
    writeAll(std.posix.STDOUT_FILENO, txt);
}

pub fn defaultThreadCount(perf_cores: ?usize, logical_cpus: usize) usize {
    const logical = if (logical_cpus == 0) 1 else logical_cpus;
    const chosen = if (perf_cores) |perf| blk: {
        if (perf >= 1 and perf < logical) break :blk perf;
        break :blk logical;
    } else logical;
    return @min(@max(chosen, 1), 64);
}

fn performanceCoreCount() ?usize {
    var n: c_int = 0;
    var len: usize = @sizeOf(c_int);
    const rc = std.c.sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, null, 0);
    if (rc != 0 or n < 1) return null;
    return @intCast(n);
}

pub fn defaultThreads() usize {
    const logical = std.Thread.getCpuCount() catch 8;
    return defaultThreadCount(performanceCoreCount(), logical);
}

pub fn parse(allocator: std.mem.Allocator, it: anytype, prog: []const u8, opts: *Options, targets: *std.ArrayListUnmanaged([]const u8)) ?u8 {
    var end_opts = false;

    while (it.next()) |arg| {
        if (!end_opts and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                end_opts = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage(prog);
                return @as(u8, 0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeAll(std.posix.STDOUT_FILENO, "dush " ++ VERSION ++ "\n");
                return @as(u8, 0);
            } else if (std.mem.eql(u8, arg, "--total")) {
                opts.grand_total = true;
            } else if (std.mem.eql(u8, arg, "--apparent-size")) {
                opts.apparent = true;
            } else if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "--human-readable")) {} else if (std.mem.eql(u8, arg, "--threads")) {
                if (it.next()) |val| {
                    if (std.fmt.parseInt(usize, val, 10)) |t| {
                        if (t >= 1 and t <= 128) opts.num_threads = t;
                    } else |_| {}
                }
            } else if (arg[1] == '-') {
                writeErr(arg, "invalid option");
                return @as(u8, 1);
            } else {
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        's' => {},
                        'h' => opts.block_size = 0,
                        'c' => opts.grand_total = true,
                        'A', 'b' => opts.apparent = true,
                        'k' => opts.block_size = 1024,
                        'm' => opts.block_size = 1048576,
                        'g' => opts.block_size = 1073741824,
                        'P' => opts.follow = .none,
                        'H' => opts.follow = .cli,
                        'L' => opts.follow = .all,
                        'v' => {
                            writeAll(std.posix.STDOUT_FILENO, "dush " ++ VERSION ++ "\n");
                            return @as(u8, 0);
                        },
                        't' => {
                            if (j + 1 < arg.len) {
                                if (std.fmt.parseInt(usize, arg[j + 1 ..], 10)) |t| {
                                    if (t >= 1 and t <= 128) opts.num_threads = t;
                                } else |_| {}
                                j = arg.len;
                            } else if (it.next()) |val| {
                                if (std.fmt.parseInt(usize, val, 10)) |t| {
                                    if (t >= 1 and t <= 128) opts.num_threads = t;
                                } else |_| {}
                            }
                        },
                        else => {
                            writeErr(arg[j .. j + 1], "invalid option");
                            return @as(u8, 1);
                        },
                    }
                }
            }
        } else {
            targets.append(allocator, arg) catch {
                writeErr("dush", "out of memory");
                return @as(u8, 1);
            };
        }
    }

    return null;
}
