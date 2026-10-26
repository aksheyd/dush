const std = @import("std");
const sys = @import("sys.zig");
const errors = @import("errors.zig");
const accounting = @import("accounting.zig");
const Units = @import("format.zig").Units;

extern "c" fn atoi(s: [*:0]const u8) c_int;

pub const VERSION = "1.1.0";

pub const Mode = enum { du, dush };

pub const Follow = enum { physical, cli, logical };

pub const Config = struct {
    mode: Mode,
    follow: Follow = .physical,
    xdev: bool = false,
    all: bool = false,
    depth: i64 = std.math.maxInt(c_int),
    grand_total: bool = false,
    units: Units = .blocks,
    count_links: bool = false,
    nodump: bool = false,
    ignores: []const [*:0]const u8 = &.{},
    scale: accounting.Scale = .{ .apparent = false, .cblocksize = 1, .blocksize = 1 },
    threshold: u64 = 0,
    num_threads: usize = 1,
    operands: sys.FtsArgv = undefined,

    pub fn ftsOptions(self: Config) c_int {
        var o: c_int = sys.FTS_PHYSICAL | sys.FTS_NOCHDIR;
        if (self.follow == .cli) o |= sys.FTS_COMFOLLOW;
        if (self.follow == .logical) o = (o & ~sys.FTS_PHYSICAL) | sys.FTS_LOGICAL;
        if (self.xdev) o |= sys.FTS_XDEV;
        return o;
    }

    pub fn fastPathEligible(self: Config) bool {
        return self.depth == 0 and !self.all and self.follow != .logical and !self.xdev and
            !self.count_links and !self.nodump and self.ignores.len == 0 and self.scale.fastPathCompatible();
    }
};

pub fn modeFor(prog: []const u8) Mode {
    return if (std.mem.eql(u8, prog, "du")) .du else .dush;
}

const du_usage = "usage: du [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] [-a | -s | -d depth] [-B blocksize] [-I mask] [-t threshold] [file ...]\n";
const dush_usage = "usage: dush [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] [-a | -s | -d depth] [-B blocksize] [-I mask] [-t threshold] [-j threads] [file ...]\n";

pub fn usage(mode: Mode) noreturn {
    _ = sys.fprintf(sys.__stderrp, if (mode == .du) du_usage else dush_usage);
    std.c.exit(sys.EX_USAGE);
}

pub fn printHelp() void {
    const txt = dush_usage ++
        \\
        \\dush is a parallel du for macOS. Every flag means what it means to du(1).
        \\Invoked as `du` (a symlink or a copy named du) it behaves exactly like
        \\/usr/bin/du. Invoked as `dush`, two defaults differ: -s applies unless
        \\-a, -d or -s is given, and sizes are human-readable (-h) unless -k, -m,
        \\-g or --si is given.
        \\
        \\  -A          apparent size instead of disk usage
        \\  -B size     count in blocks of this many bytes
        \\  -H, -L, -P  follow symlinks on the command line, all, or none (default)
        \\  -I mask     ignore entries whose name matches the fnmatch(3) mask
        \\  -a          print every file, not just directories
        \\  -c          print a grand total
        \\  -d depth    print directories at most depth levels down
        \\  -g, -k, -m  1 GiB, 1 KiB, 1 MiB blocks
        \\  -h, --si    human-readable sizes, base 1024 or 1000
        \\  -l          count hard-linked files once per link
        \\  -n          ignore files and directories with the nodump flag
        \\  -r          accepted and ignored, as in du
        \\  -s          print only a total for each operand
        \\  -t size     print only entries of at least this size
        \\  -x          stay on the operand's file system
        \\  -j N, --threads=N
        \\              worker threads (default: performance cores on Apple
        \\              Silicon, else logical CPUs; DUSH_THREADS overrides)
        \\  -b, --apparent-size, --total, --summarize, --human-readable
        \\              aliases for -A, -c, -s and -h, kept from earlier dush
        \\  --help, -v, --version
        \\
    ;
    errors.writeAll(std.posix.STDOUT_FILENO, txt);
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

const opt_si: c_int = 256;
const opt_threads: c_int = 257;
const opt_help: c_int = 258;
const opt_version: c_int = 259;
const opt_apparent: c_int = 260;
const opt_total: c_int = 261;
const opt_summarize: c_int = 262;
const opt_human: c_int = 263;

const du_longopts = [_]sys.Option{
    .{ .name = "si", .has_arg = sys.no_argument, .flag = null, .val = opt_si },
    .{ .name = null, .has_arg = 0, .flag = null, .val = 0 },
};

const dush_longopts = [_]sys.Option{
    .{ .name = "si", .has_arg = sys.no_argument, .flag = null, .val = opt_si },
    .{ .name = "threads", .has_arg = sys.required_argument, .flag = null, .val = opt_threads },
    .{ .name = "help", .has_arg = sys.no_argument, .flag = null, .val = opt_help },
    .{ .name = "version", .has_arg = sys.no_argument, .flag = null, .val = opt_version },
    .{ .name = "apparent-size", .has_arg = sys.no_argument, .flag = null, .val = opt_apparent },
    .{ .name = "total", .has_arg = sys.no_argument, .flag = null, .val = opt_total },
    .{ .name = "summarize", .has_arg = sys.no_argument, .flag = null, .val = opt_summarize },
    .{ .name = "summary", .has_arg = sys.no_argument, .flag = null, .val = opt_summarize },
    .{ .name = "human-readable", .has_arg = sys.no_argument, .flag = null, .val = opt_human },
    .{ .name = null, .has_arg = 0, .flag = null, .val = 0 },
};

fn parseThreads(text: [*:0]const u8) ?usize {
    const t = std.fmt.parseInt(usize, std.mem.span(text), 10) catch return null;
    if (t < 1 or t > 128) return null;
    return t;
}

pub const ParseResult = union(enum) {
    run: Config,
    exit: u8,
};

pub fn parse(allocator: std.mem.Allocator, argv: []?[*:0]u8, mode: Mode) !ParseResult {
    var cfg = Config{ .mode = mode, .num_threads = defaultThreads() };
    if (std.c.getenv("DUSH_THREADS")) |env| {
        if (parseThreads(env)) |t| cfg.num_threads = t;
    }
    var ignores: std.ArrayListUnmanaged([*:0]const u8) = .empty;

    var aflag = false;
    var sflag = false;
    var dflag = false;
    var apparent = false;
    var cblocksize: i64 = accounting.sector;
    var blocksize: c_long = 0;
    var threshold: u64 = 0;
    var units: Units = if (mode == .dush) .binary else .blocks;
    var units_given = false;
    var bflag = false;

    const optstring: [*:0]const u8 = if (mode == .du) "+AB:HI:LPasd:cghklmnrt:x" else "+AB:HI:LPabsd:cghj:klmnrt:vx";
    const longopts: [*]const sys.Option = if (mode == .du) &du_longopts else &dush_longopts;
    const argc: c_int = @intCast(argv.len - 1);

    while (true) {
        const ch = sys.getopt_long(argc, argv.ptr, optstring, longopts, null);
        if (ch == -1) break;
        const arg = sys.optarg;
        switch (ch) {
            'A', 'b', opt_apparent => apparent = true,
            'B' => {
                bflag = true;
                sys.__error().* = 0;
                cblocksize = atoi(arg.?);
                if (sys.__error().* == sys.ERANGE or cblocksize <= 0) {
                    sys.warnx("invalid argument to option B: %s", arg.?);
                    usage(mode);
                }
            },
            'H' => cfg.follow = .cli,
            'I' => try ignores.append(allocator, arg.?),
            'L' => cfg.follow = .logical,
            'P' => cfg.follow = .physical,
            'a' => aflag = true,
            's', opt_summarize => sflag = true,
            'd' => {
                dflag = true;
                sys.__error().* = 0;
                cfg.depth = atoi(arg.?);
                if (sys.__error().* == sys.ERANGE or cfg.depth < 0) {
                    sys.warnx("invalid argument to option d: %s", arg.?);
                    usage(mode);
                }
            },
            'c', opt_total => cfg.grand_total = true,
            'g' => {
                units = .blocks;
                units_given = true;
                blocksize = 1073741824;
            },
            'h', opt_human => {
                units = .binary;
                units_given = true;
            },
            'k' => {
                units = .blocks;
                units_given = true;
                blocksize = 1024;
            },
            'l' => cfg.count_links = true,
            'm' => {
                units = .blocks;
                units_given = true;
                blocksize = 1048576;
            },
            'n' => cfg.nodump = true,
            'r' => {},
            't' => {
                if (sys.expand_number(arg.?, &threshold) != 0 or threshold == 0) {
                    sys.warnx("invalid threshold: %s", arg.?);
                    usage(mode);
                }
            },
            'x' => cfg.xdev = true,
            'j', opt_threads => {
                cfg.num_threads = parseThreads(arg.?) orelse {
                    sys.warnx("invalid argument to option threads: %s", arg.?);
                    usage(mode);
                };
            },
            opt_si => {
                units = .si;
                units_given = true;
            },
            opt_help => {
                printHelp();
                return .{ .exit = 0 };
            },
            'v', opt_version => {
                errors.writeAll(std.posix.STDOUT_FILENO, "dush " ++ VERSION ++ "\n");
                return .{ .exit = 0 };
            },
            else => usage(mode),
        }
    }

    if (mode == .dush and bflag and !units_given) units = .blocks; // explicit -B beats dush's implicit -h
    if (mode == .dush and !aflag and !dflag and !sflag) sflag = true;
    if (@as(u8, @intFromBool(aflag)) + @intFromBool(dflag) + @intFromBool(sflag) > 1) usage(mode);
    if (sflag) cfg.depth = 0;
    cfg.all = aflag;
    cfg.units = units;
    cfg.ignores = try ignores.toOwnedSlice(allocator);

    const first: usize = @intCast(sys.optind);
    if (first >= argv.len - 1) {
        const dot = try allocator.alloc(?[*:0]const u8, 2);
        dot[0] = ".";
        dot[1] = null;
        cfg.operands = @ptrCast(dot.ptr);
    } else {
        cfg.operands = @ptrCast(argv[first..].ptr);
    }

    if (blocksize == 0) {
        var notused: c_int = 0;
        _ = sys.getbsize(&notused, &blocksize);
    }
    cfg.scale = accounting.Scale.init(apparent, cblocksize, blocksize);
    cfg.threshold = cfg.scale.threshold(threshold);
    return .{ .run = cfg };
}
