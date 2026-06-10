const std = @import("std");

pub const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn bash(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !Result {
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "bash", "-c", command },
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const term = try child.wait(io);
    const exit_code: u32 = switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u32, @intCast(@intFromEnum(sig))),
        .stopped => 1,
        .unknown => 1,
    };

    var out_buf: [64 * 1024]u8 = .{0} ** (64 * 1024);
    var err_buf: [64 * 1024]u8 = .{0} ** (64 * 1024);

    const stdout_slice = if (child.stdout) |f| blk: {
        var reader = f.readerStreaming(io, &out_buf);
        const out_slice = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(out_buf.len));
        break :blk out_slice;
    } else try allocator.dupe(u8, "");

    const stderr_slice = if (child.stderr) |f| blk: {
        var reader = f.readerStreaming(io, &err_buf);
        const err_slice = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(err_buf.len));
        break :blk err_slice;
    } else try allocator.dupe(u8, "");

    return Result{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .exit_code = exit_code,
    };
}

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dir = std.Io.Dir.cwd();
    return std.Io.Dir.readFileAlloc(dir, io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
}

pub fn writeFile(io: std.Io, contents: []const u8, path: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = path, .data = contents });
}

pub fn globSearch(allocator: std.mem.Allocator, io: std.Io, pattern: []const u8, search_path: []const u8) !Result {
    const arg = try std.fmt.allocPrint(allocator, "find {s} -name '{s}' 2>/dev/null | head -100", .{ search_path, pattern });
    defer allocator.free(arg);
    return bash(allocator, io, arg);
}

pub fn grepSearch(allocator: std.mem.Allocator, io: std.Io, pattern: []const u8, search_path: []const u8, include: []const u8) !Result {
    const arg = if (include.len > 0)
        try std.fmt.allocPrint(allocator, "rg --json -n '{s}' --include '{s}' {s} 2>/dev/null | head -200", .{ pattern, include, search_path })
    else
        try std.fmt.allocPrint(allocator, "rg --json -n '{s}' {s} 2>/dev/null | head -200", .{ pattern, search_path });
    defer allocator.free(arg);
    return bash(allocator, io, arg);
}

pub fn webFetch(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !Result {
    const arg = try std.fmt.allocPrint(allocator, "curl -sL '{s}' 2>/dev/null | head -c 65536", .{url});
    defer allocator.free(arg);
    return bash(allocator, io, arg);
}

pub fn question(allocator: std.mem.Allocator, _: std.Io, prompt: []const u8, stdin_content: []const u8) !Result {
    const out = try std.fmt.allocPrint(allocator, "Q: {s}\nA: {s}", .{ prompt, stdin_content });
    return Result{ .stdout = out, .stderr = "", .exit_code = 0 };
}

pub fn todoWrite(allocator: std.mem.Allocator, io: std.Io, todos: []const u8) !Result {
    const dir = std.Io.Dir.cwd();
    const content = dir.readFileAlloc(io, "TODO.md", allocator, std.Io.Limit.limited(1024 * 1024)) catch "";
    defer if (content.len > 0) allocator.free(content);
    var list = try std.ArrayList(u8).initCapacity(allocator, content.len + todos.len + 4);
    defer list.deinit(allocator);
    if (content.len > 0) {
        try list.appendSlice(allocator, content);
        try list.appendSlice(allocator, "\n");
    }
    try list.appendSlice(allocator, todos);
    try dir.writeFile(io, .{ .sub_path = "TODO.md", .data = list.items });
    return Result{ .stdout = "TODO.md updated", .stderr = "", .exit_code = 0 };
}

pub fn skill(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !Result {
    const home = std.c.getenv("HOME") orelse return Result{ .stdout = "", .stderr = "No HOME", .exit_code = 1 };
    const home_span = std.mem.span(home);
    const paths = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}/.config/agent/skills/{s}.md", .{ home_span, name }),
        try std.fmt.allocPrint(allocator, "{s}/.config/agent/skills/{s}.json", .{ home_span, name }),
        try std.fmt.allocPrint(allocator, ".agent/skills/{s}.md", .{name}),
        try std.fmt.allocPrint(allocator, ".agent/skills/{s}.json", .{name}),
    };
    for (paths) |p| {
        defer allocator.free(p);
        const content = std.Io.Dir.cwd().readFileAlloc(io, p, allocator, std.Io.Limit.limited(65536)) catch continue;
        return Result{ .stdout = content, .stderr = "", .exit_code = 0 };
    }
    const err = try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{name});
    return Result{ .stdout = "", .stderr = err, .exit_code = 1 };
}

/// List available skills with their descriptions (metadata only).
/// Scans ~/.config/agent/skills/ and .agent/skills/ for .md files,
/// extracting the first `# Heading` as the description.
pub fn skillList(allocator: std.mem.Allocator, io: std.Io) !Result {
    const home = std.c.getenv("HOME") orelse return Result{ .stdout = "", .stderr = "No HOME", .exit_code = 1 };
    const home_span = std.mem.span(home);

    var buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;

    const paths = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}/.config/agent/skills", .{home_span}),
        try std.fmt.allocPrint(allocator, ".agent/skills", .{}),
    };
    defer for (paths) |p| allocator.free(p);

    for (paths) |path| {
        const cmd = try std.fmt.allocPrint(allocator, "ls -1 '{s}'/*.md 2>/dev/null", .{path});
        defer allocator.free(cmd);
        const ls_result = bash(allocator, io, cmd) catch continue;
        defer ls_result.deinit(allocator);

        const trimmed_out = std.mem.trim(u8, ls_result.stdout, " \t\r\n");
        if (trimmed_out.len == 0) continue;

        var lines = std.mem.splitScalar(u8, trimmed_out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Extract filename stem
            const stem = std.fs.path.stem(line);
            // Read first heading as description
            const content = std.Io.Dir.cwd().readFileAlloc(io, line, allocator, std.Io.Limit.limited(256)) catch continue;
            defer allocator.free(content);
            var desc: []const u8 = "(no description)";
            var content_lines = std.mem.splitScalar(u8, content, '\n');
            while (content_lines.next()) |cl| {
                var start: usize = 0;
                while (start < cl.len and (cl[start] == ' ' or cl[start] == '\t')) : (start += 1) {}
                if (start + 1 < cl.len and cl[start] == '#' and cl[start + 1] == ' ') {
                    desc = cl[start + 2 ..];
                    break;
                }
            }
            const line_str = try std.fmt.allocPrint(allocator, "- {s}: {s}\n", .{ stem, desc });
            try buf.appendSlice(allocator, line_str);
            allocator.free(line_str);
        }
    }

    const out = try buf.toOwnedSlice(allocator);
    return Result{ .stdout = out, .stderr = "", .exit_code = 0 };
}

pub fn plan(allocator: std.mem.Allocator, io: std.Io, plan_text: []const u8) !Result {
    const content = try std.fmt.allocPrint(allocator, "# Plan\n\n{s}\n", .{plan_text});
    const dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{ .sub_path = "PLAN.md", .data = content }) catch {};
    return Result{ .stdout = content, .stderr = "", .exit_code = 0 };
}

pub fn webSearch(allocator: std.mem.Allocator, io: std.Io, query: []const u8) !Result {
    const arg = try std.fmt.allocPrint(allocator, "curl -sL 'https://api.duckduckgo.com/?q={s}&format=json' 2>/dev/null | head -c 32768", .{query});
    defer allocator.free(arg);
    return bash(allocator, io, arg);
}

pub fn snapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Result {
    const cmd = if (path.len > 0)
        try std.fmt.allocPrint(allocator, "cd '{s}' && git diff --no-color 2>/dev/null || echo '(no git diff available)'", .{path})
    else
        try std.fmt.allocPrint(allocator, "git diff --no-color 2>/dev/null || echo '(no git diff available)'", .{});
    defer allocator.free(cmd);
    return bash(allocator, io, cmd);
}

pub fn editFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, old_string: []const u8, new_string: []const u8) !Result {
    const dir = std.Io.Dir.cwd();
    const content = std.Io.Dir.readFileAlloc(dir, io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Error reading file '{s}': {}", .{ file_path, err });
        return Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
    };
    defer allocator.free(content);

    const idx = std.mem.indexOf(u8, content, old_string) orelse {
        const err_msg = try std.fmt.allocPrint(allocator, "Could not find old_string in '{s}'", .{file_path});
        return Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
    };

    var result = try std.ArrayList(u8).initCapacity(allocator, content.len + new_string.len - old_string.len);
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, content[0..idx]);
    try result.appendSlice(allocator, new_string);
    try result.appendSlice(allocator, content[idx + old_string.len ..]);

    try dir.writeFile(io, .{ .sub_path = file_path, .data = result.items });
    result.deinit(allocator);

    return Result{ .stdout = "File updated successfully", .stderr = "", .exit_code = 0 };
}
