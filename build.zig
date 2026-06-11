const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("../agent-sdk/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "agent-sdk", .module = sdk_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "agent",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the agent CLI");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "agent-sdk", .module = sdk_mod },
        },
    });

    const test_exe = b.addTest(.{
        .name = "agent-tests",
        .root_module = test_mod,
    });
    const test_step = b.step("test", "Run agent tests");
    test_step.dependOn(&test_exe.step);
}
