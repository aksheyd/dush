const std = @import("std");

fn exeMod(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag.isDarwin()) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) }); // a non-native target skips SDK detection
        mod.linkSystemLibrary("util", .{});
    }
    return mod;
}

pub fn build(b: *std.Build) void {
    const macos_11: std.Target.Query = .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } } }; // match /usr/bin/du: libc fts keeps d//1 only for minos < 26
    const target = b.standardTargetOptions(.{ .default_target = if (b.graph.host.result.os.tag == .macos) macos_11 else .{} });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dush",
        .root_module = exeMod(b, target, optimize, "src/main.zig"),
    });
    b.installArtifact(exe);

    const unit_mod = exeMod(b, target, optimize, "tests/unit/unit_test.zig");
    unit_mod.addImport("dush", exeMod(b, target, optimize, "src/root.zig"));
    const unit_tests = b.addTest(.{
        .root_module = unit_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const parity_tests = b.addTest(.{
        .root_module = exeMod(b, target, optimize, "tests/parity/test_dush.zig"),
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const test_step = b.step("test", "Run unit and parity tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_parity_tests.step);

    const gen_fixture = b.addExecutable(.{
        .name = "generate-fixture",
        .root_module = exeMod(b, target, .ReleaseFast, "bench/generate_fixture.zig"),
    });
    b.installArtifact(gen_fixture);

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
