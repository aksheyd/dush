const std = @import("std");

test "gnu bind-mount-dir-cycle: dir bind-mounted inside itself [skipped: root + Linux mount --bind]" {
    std.debug.print("skip bind-mount-dir-cycle: needs root and mount --bind, which macOS lacks\n", .{});
    return error.SkipZigTest;
}

test "gnu bind-mount-dir-cycle-v2: ancestor bind-mounted two levels down [skipped: root + Linux mount --bind]" {
    std.debug.print("skip bind-mount-dir-cycle-v2: needs root and mount --bind, which macOS lacks\n", .{});
    return error.SkipZigTest;
}

test "gnu move-dir-while-traversing: dir renamed mid-walk [skipped: Linux inotify race]" {
    std.debug.print("skip move-dir-while-traversing: needs a Linux inotify hook to rename mid-walk\n", .{});
    return error.SkipZigTest;
}
