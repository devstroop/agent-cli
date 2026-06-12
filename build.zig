const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Patch sdk/src/tool.zig: increase the bash subprocess output limit
    // from 64 KB to 4 MB to avoid error.StreamTooLong on large tool output.
    {
        const path = "sdk/src/tool.zig";
        const cwd = std.fs.cwd();
        const src = cwd.readFileAlloc(b.allocator, path, 1024 * 1024) catch unreachable;
        const new_limit = "allocRemaining(allocator, std.Io.Limit.limited(4 * 1024 * 1024))";
        const contexts = [_][]const u8{
            "allocRemaining(allocator, std.Io.Limit.limited(out_buf.len))",
            "allocRemaining(allocator, std.Io.Limit.limited(err_buf.len))",
        };
        var cur = src;
        for (contexts) |ctx| {
            const count = std.mem.count(u8, cur, ctx);
            if (count == 0) continue;
            const new_len = cur.len + count * (new_limit.len - ctx.len);
            const patched = b.allocator.alloc(u8, new_len) catch unreachable;
            _ = std.mem.replace(u8, cur, ctx, new_limit, patched);
            if (cur.ptr != src.ptr) b.allocator.free(cur);
            cur = patched;
        }
        if (cur.ptr != src.ptr) {
            var f = cwd.createFile(path, .{}) catch unreachable;
            defer f.close();
            f.writeAll(cur) catch unreachable;
        }
        b.allocator.free(cur);
    }

    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("./sdk/src/lib.zig"),
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
