const std = @import("std");
const sys = @import("sys.zig");
const accounting = @import("accounting.zig");

pub const Units = enum(u8) { blocks = 0, binary = 1, si = 2 };

pub fn humanize(out: *[5]u8, units: Units, bytes: i64) []const u8 {
    var flags: c_int = sys.HN_B | sys.HN_NOSPACE | sys.HN_DECIMAL;
    if (units == .si) flags |= sys.HN_DIVISOR_1000;
    @memset(out, 0);
    _ = sys.humanize_number(out, out.len, bytes, "", sys.HN_AUTOSCALE, flags);
    return std.mem.sliceTo(out, 0);
}

pub const Printer = struct {
    scale: accounting.Scale,
    units: Units,

    pub fn line(self: Printer, n: i64, label: [*:0]const u8) void {
        if (self.units != .blocks) {
            var buf: [5]u8 = undefined;
            _ = humanize(&buf, self.units, self.scale.humanBytes(n));
            var z: [6:0]u8 = undefined;
            @memcpy(z[0..5], &buf);
            z[5] = 0;
            _ = std.c.printf("%4s", &z);
            _ = std.c.printf("\t%s\n", label);
        } else {
            _ = std.c.printf("%jd\t%s\n", @as(i64, self.scale.display(n)), label);
        }
    }
};
