const std = @import("std");

pub const Path = struct {
    bytes: [:0]u8,

    pub fn deinit(self: Path, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    pub fn slice(self: Path) []const u8 {
        return self.bytes;
    }

    pub fn z(self: Path) [*:0]const u8 {
        return self.bytes.ptr;
    }
};

pub fn joinPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) !Path {
    const slash = !(parent.len == 0 or (parent.len == 1 and parent[0] == '/'));
    const total_len = parent.len + (if (slash) @as(usize, 1) else 0) + child.len;
    const buf = try allocator.allocSentinel(u8, total_len, 0);
    @memcpy(buf[0..parent.len], parent);
    var offset = parent.len;
    if (slash) {
        buf[offset] = '/';
        offset += 1;
    }
    @memcpy(buf[offset..][0..child.len], child);
    return .{ .bytes = buf };
}

pub fn dupePathZ(allocator: std.mem.Allocator, s: []const u8) !Path {
    const buf = try allocator.dupeZ(u8, s);
    return .{ .bytes = buf };
}
