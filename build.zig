const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server_exe = b.addExecutable(.{
        .name = "guardian-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const cli_exe = b.addExecutable(.{
        .name = "gd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(server_exe);
    b.installArtifact(cli_exe);

    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
    });
    const fmt_step = b.step("fmt", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);

    const e2e_cli = b.addSystemCommand(&.{"bash"});
    e2e_cli.addFileArg(b.path("scripts/e2e-cli.sh"));
    e2e_cli.setCwd(b.path("."));
    e2e_cli.step.dependOn(b.getInstallStep());

    const e2e_mcp = b.addSystemCommand(&.{"bash"});
    e2e_mcp.addFileArg(b.path("scripts/e2e-mcp.sh"));
    e2e_mcp.setCwd(b.path("."));
    e2e_mcp.step.dependOn(b.getInstallStep());

    const e2e_release = b.addSystemCommand(&.{"bash"});
    e2e_release.addFileArg(b.path("scripts/e2e-release-package.sh"));
    e2e_release.setCwd(b.path("."));
    e2e_release.step.dependOn(b.getInstallStep());

    const e2e_step = b.step("e2e", "Run CLI and MCP end-to-end checks");
    e2e_step.dependOn(&e2e_cli.step);
    e2e_step.dependOn(&e2e_mcp.step);
    e2e_step.dependOn(&e2e_release.step);

    const ci_step = b.step("ci", "Run formatting, unit tests, and end-to-end checks");
    ci_step.dependOn(&fmt.step);
    ci_step.dependOn(&run_tests.step);
    ci_step.dependOn(&e2e_cli.step);
    ci_step.dependOn(&e2e_mcp.step);
    ci_step.dependOn(&e2e_release.step);
}
