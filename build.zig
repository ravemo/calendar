const std = @import("std");

pub fn buildGUI(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const exe = b.addExecutable(.{
        .name = "Calendar",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("rt");
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_image");
    exe.linkSystemLibrary("SDL2_ttf");
    exe.linkSystemLibrary("SDL2_mixer");
    exe.linkSystemLibrary("pcre");
    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    return run_cmd;
}

pub fn buildCLI(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const regex_package = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    const regex_module = regex_package.module("regex");

    const linenoise_package = b.dependency("linenoise", .{
        .target = target,
        .optimize = optimize,
    });
    const linenoise_module = linenoise_package.module("linenoise");
    const exe = b.addExecutable(.{
        .name = "CalendarCLI",
        .root_source_file = b.path("src/main_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("regex", regex_module);
    exe.root_module.addImport("linenoise", linenoise_module);
    exe.linkLibC();
    exe.linkSystemLibrary("pcre");
    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    return run_cmd;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    var run_cmd = buildGUI(b, target, optimize);
    var run_cli_cmd = buildCLI(b, target, optimize);

    // Build steps
    // GUI Run step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // CLI Run step
    const run_cli_step = b.step("run-cli", "Run the CLI app");
    run_cli_step.dependOn(&run_cli_cmd.step);

    // Test step
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
