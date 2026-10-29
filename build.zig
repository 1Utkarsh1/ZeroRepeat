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
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = core }));
    tests.has_side_effects = true;
    const test_step = b.step("test", "Run native unit and regression tests");
    test_step.dependOn(&tests.step);
    const cli_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    cli_tests.has_side_effects = true;
    test_step.dependOn(&cli_tests.step);
    const cli_options = b.addOptions();
    cli_options.addOptionPath("executable", exe.getEmittedBin());
    const integration_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cli_options", .module = cli_options.createModule() }},
        }),
    }));
    integration_tests.has_side_effects = true;
    test_step.dependOn(&integration_tests.step);
    const check = b.addRunArtifact(exe);
    check.addArgs(&.{ "continuity", "check" });
    b.step("check", "Check durable project records and coverage").dependOn(&check.step);
}
