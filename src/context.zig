const std = @import("std");
const tool = @import("agent-sdk").tool;

/// Expand !command patterns in a string.
/// Each `!command` (at start of line or after whitespace) is replaced
/// with the trimmed stdout of running `command` via bash.
/// Use `\!` to escape a literal `!`.
pub fn expandBangCommands(allocator: std.mem.Allocator, io: std.Io, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len + 4096);

    var i: usize = 0;
    while (i < input.len) {
        // Handle escaped \!
        if (input[i] == '\\' and i + 1 < input.len and input[i + 1] == '!') {
            try result.append(allocator, '!');
            i += 2;
            continue;
        }
        if (input[i] == '!' and (i == 0 or input[i - 1] == '\n' or input[i - 1] == ' ' or input[i - 1] == '\t')) {
            i += 1;
            const cmd_start = i;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            const cmd = input[cmd_start..i];

            const command = try std.fmt.allocPrint(allocator, "{s} 2>/dev/null", .{cmd});
            defer allocator.free(command);
            const exec_result = tool.bash(allocator, io, command) catch {
                try result.appendSlice(allocator, "(command failed)");
                continue;
            };
            defer exec_result.deinit(allocator);
            try result.appendSlice(allocator, std.mem.trim(u8, exec_result.stdout, " \t\r\n"));
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn addSection(writer: *std.Io.Writer, title: []const u8, content: []const u8) !void {
    try writer.print("## {s}\n{s}\n\n", .{ title, content });
}

pub fn render(io: std.Io, allocator: std.mem.Allocator, workspace_dir: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    errdefer w.deinit();
    const wr = &w.writer;

    // 1. Date
    {
        const ts = std.Io.Timestamp.now(io, .real);
        const secs = @divFloor(ts.nanoseconds, 1_000_000_000);
        var date_buf: [32]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d}", .{secs}) catch "timestamp";
        try addSection(wr, "Date", date_str);
    }

    // 2. OS info
    {
        const result = tool.bash(allocator, io, "uname -a 2>/dev/null | head -1") catch {
            try addSection(wr, "OS", "unknown");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        const os_str = if (result.stdout.len > 0) std.mem.trim(u8, result.stdout, " \t\r\n") else "unknown";
        try addSection(wr, "OS", os_str);
    }

    // 3. Workspace directory listing
    if (workspace_dir) |dir| {
        const cmd = try std.fmt.allocPrint(allocator, "ls -1 '{s}' 2>/dev/null | head -50", .{dir});
        defer allocator.free(cmd);
        const result = tool.bash(allocator, io, cmd) catch {
            try addSection(wr, "Workspace", "(unavailable)");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        if (result.stdout.len > 0) {
            const section = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ dir, std.mem.trim(u8, result.stdout, " \t\r\n") });
            defer allocator.free(section);
            try addSection(wr, "Workspace", section);
        }
    }

    // 4. Git status
    {
        const result = tool.bash(allocator, io, "git status --porcelain 2>/dev/null | head -100") catch {
            try addSection(wr, "Git Status", "(n/a)");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        if (result.stdout.len > 0) {
            try addSection(wr, "Git Status", std.mem.trim(u8, result.stdout, " \t\r\n"));
        }
    }

    // 5. Git diff
    {
        const result = tool.bash(allocator, io, "git diff HEAD 2>/dev/null | head -500") catch {
            try addSection(wr, "Git Diff", "(n/a)");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        if (result.stdout.len > 0) {
            try addSection(wr, "Git Diff", result.stdout);
        }
    }

    // 6. Project config files
    {
        const result = tool.bash(allocator, io, "cat package.json Cargo.toml pyproject.toml go.mod 2>/dev/null | head -200") catch {
            try addSection(wr, "Project Config", "(none found)");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        if (result.stdout.len > 0) {
            try addSection(wr, "Project Config", result.stdout);
        }
    }

    // 7. Instructions
    {
        const result = tool.bash(allocator, io, "cat .agent/instructions.md AGENTS.md 2>/dev/null | head -200") catch {
            try addSection(wr, "Instructions", "(none)");
            return w.toOwnedSlice();
        };
        defer result.deinit(allocator);
        if (result.stdout.len > 0) {
            try addSection(wr, "Instructions", result.stdout);
        }
    }

    return w.toOwnedSlice();
}
