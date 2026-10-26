const std = @import("std");
const Options = @import("cli.zig").Options;
const writeAll = @import("errors.zig").writeAll;
const accounting = @import("accounting.zig");

pub fn humanize(out: *[5]u8, bytes: i64) []const u8 {
    const divisor: i64 = 1024;
    const cut: i64 = 973; // ceil(0.95 * 1024)
    const maxscale: usize = 6;
    const prefixes = "B\x00\x00K\x00\x00M\x00\x00G\x00\x00T\x00\x00P\x00\x00E";

    var quotient = bytes;
    var remainder: i64 = 0;
    var sign: i64 = 1;
    var baselen: usize = 1;
    if (quotient < 0) {
        sign = -1;
        quotient = -quotient;
        baselen += 2;
    } else {
        baselen += 1;
    }

    var max: i64 = 1;
    var i: i64 = @intCast(5 - baselen);
    while (true) {
        const left = i;
        i -= 1;
        if (!(left > 0 and max <= @divTrunc(std.math.maxInt(i64), 10))) break;
        max *= 10;
    }

    var scale: usize = 0;
    while (((quotient >= max) or
        (quotient == max - 1 and
            (remainder >= cut or remainder >= @divTrunc(divisor, 2)))) and
        scale < maxscale) : (scale += 1)
    {
        remainder = @rem(quotient, divisor);
        quotient = @divTrunc(quotient, divisor);
    }

    const p: u8 = prefixes[scale * 3];
    if (((quotient == 9 and remainder < cut) or quotient < 9) and scale > 0) {
        const t = @divTrunc(remainder * 10 + @divTrunc(divisor, 2), divisor);
        const s1 = quotient + @divTrunc(t, 10);
        const s2 = @rem(t, 10);
        return std.fmt.bufPrint(out, "{d}.{d}{c}", .{ sign * s1, s2, p }) catch out[0..0];
    } else {
        const v = sign * (quotient + @divTrunc(remainder + @divTrunc(divisor, 2), divisor));
        return std.fmt.bufPrint(out, "{d}{c}", .{ v, p }) catch out[0..0];
    }
}

pub fn printResult(bytes: i64, label: []const u8, opts: *const Options) void {
    var line_buf: [2048]u8 = undefined;

    if (opts.block_size > 0) {
        const blocks = accounting.toBlocks(bytes, opts.block_size);
        const line = std.fmt.bufPrint(&line_buf, "{d}\t{s}\n", .{ blocks, label }) catch return;
        writeAll(std.posix.STDOUT_FILENO, line);
    } else {
        var hbuf: [5]u8 = undefined;
        const h = humanize(&hbuf, bytes);
        var pad: [4]u8 = "    ".*;
        const pad_len = if (h.len < 4) 4 - h.len else 0;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}\t{s}\n", .{ pad[0..pad_len], h, label }) catch return;
        writeAll(std.posix.STDOUT_FILENO, line);
    }
}
