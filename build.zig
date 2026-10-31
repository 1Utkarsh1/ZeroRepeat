const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1" },
    });
    if (target.result.os.tag == .linux) sqlite.root_module.linkSystemLibrary("m", .{});
    const core = b.addModule("zerorepeat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.linkLibrary(sqlite);
    const exe = b.addExecutable(.{
        .name = "zerorepeat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zerorepeat", .module = core }},
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run ZeroRepeat").dependOn(&run.step);
    const core_testbin = b.addTest(.{ .root_module = core });
    const tests = b.addRunArtifact(core_testbin);
    tests.has_side_effects = true;
    const test_step = b.step("test", "Run native unit and regression tests");
    test_step.dependOn(&tests.step);
    const cli_testbin = b.addTest(.{ .root_module = exe.root_module });
    const cli_tests = b.addRunArtifact(cli_testbin);
    cli_tests.has_side_effects = true;
    test_step.dependOn(&cli_tests.step);
    const cli_options = b.addOptions();
    cli_options.addOptionPath("executable", exe.getEmittedBin());
    const integration_testbin = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cli_options", .module = cli_options.createModule() }},
        }),
    });
    const integration_tests = b.addRunArtifact(integration_testbin);
    integration_tests.has_side_effects = true;
    test_step.dependOn(&integration_tests.step);
    const crash_fixture = b.addExecutable(.{
        .name = "repository-crash-fixture",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/repository_crash_fixture.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    crash_fixture.root_module.linkLibrary(sqlite);
    const network_fixture = b.addExecutable(.{
        .name = "execution-network-fixture",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/execution_network_fixture.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    const test_paths = b.addOptions();
    test_paths.addOptionPath("crash_fixture", crash_fixture.getEmittedBin());
    test_paths.addOptionPath("network_fixture", network_fixture.getEmittedBin());
    test_paths.addOption([]const u8, "zig_executable", b.graph.zig_exe);
    const process_testbin = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/repository_process_tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "zerorepeat", .module = core }, .{ .name = "test_paths", .module = test_paths.createModule() } } }),
    });
    const process_tests = b.addRunArtifact(process_testbin);
    process_tests.has_side_effects = true;
    test_step.dependOn(&process_tests.step);
    const test_build = b.step("test-build", "Build and install all test binaries without executing them");
    test_build.dependOn(b.getInstallStep());
    const artifacts = .{ core_testbin, cli_testbin, integration_testbin, process_testbin, crash_fixture, network_fixture };
    const names = .{ "core-tests", "cli-parser-tests", "cli-integration-tests", "repository-process-tests", "repository-crash-fixture", "execution-network-fixture" };
    inline for (artifacts, names) |artifact, name| test_build.dependOn(&b.addInstallArtifact(artifact, .{ .dest_sub_path = name }).step);
    const check = b.addRunArtifact(exe);
    check.addArgs(&.{ "continuity", "check" });
    b.step("check", "Check durable project records and coverage").dependOn(&check.step);
}
