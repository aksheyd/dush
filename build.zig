const std = @import("std");

fn exeMod(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dush",
        .root_module = exeMod(b, target, optimize, "src/main.zig"),
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = exeMod(b, target, optimize, "src/main.zig"),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark always uses a ReleaseFast binary so numbers are meaningful
    // regardless of the -Doptimize flag passed to `zig build bench`.
    const bench_step = b.step("bench", "Benchmark dush against du -sh on a generated fixture");
    const rel_exe = b.addExecutable(.{
        .name = "dush",
        .root_module = exeMod(b, target, .ReleaseFast, "src/main.zig"),
    });
    const run_bench = b.addSystemCommand(&.{ "sh", "bench/bench.sh" });
    run_bench.addArtifactArg(rel_exe);
    if (b.args) |args| run_bench.addArgs(args); // `zig build bench -- --cold`
    bench_step.dependOn(&run_bench.step);
}
