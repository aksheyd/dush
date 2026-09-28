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

    // 1. Unit Tests
    const unit_tests = b.addTest(.{
        .root_module = exeMod(b, target, optimize, "src/main.zig"),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // 2. End-to-End Parity Tests (compares dush against macOS du -sh)
    const parity_tests = b.addTest(.{
        .root_module = exeMod(b, target, optimize, "tests/test_dush.zig"),
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const test_step = b.step("test", "Run unit and parity tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_parity_tests.step);

    // 3. Benchmarking Fixture Generator
    const gen_fixture = b.addExecutable(.{
        .name = "generate-fixture",
        .root_module = exeMod(b, target, .ReleaseFast, "bench/generate_fixture.zig"),
    });
    b.installArtifact(gen_fixture);

    // 4. Benchmark Step (always uses ReleaseFast binaries)
    const bench_step = b.step("bench", "Benchmark dush against du -sh with hyperfine");
    const rel_exe = b.addExecutable(.{
        .name = "dush",
        .root_module = exeMod(b, target, .ReleaseFast, "src/main.zig"),
    });
    const run_bench = b.addSystemCommand(&.{ "sh", "bench/bench.sh" });
    run_bench.addArtifactArg(rel_exe);
    run_bench.addArtifactArg(gen_fixture);
    if (b.args) |args| run_bench.addArgs(args); // `zig build bench -- --cold`
    bench_step.dependOn(&run_bench.step);
}
