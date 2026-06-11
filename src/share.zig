const std = @import("std");
const sdk = @import("agent-sdk");

const session_mod = sdk.session;
const a2a = sdk.a2a;
const llm = sdk.llm;

const SHARES_DIR_REL = ".config/agent/shares";

fn getHomeDir() ?[]const u8 {
    if (std.c.getenv("HOME")) |h| return std.mem.span(h);
    if (std.c.getenv("USERPROFILE")) |h| return std.mem.span(h);
    return null;
}

/// Returns the shares directory path (~/.config/agent/shares).
pub fn sharesDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = getHomeDir() orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, SHARES_DIR_REL });
}

fn shareFilePath(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ dir, id });
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);
}

/// Convert a Session into an A2A SubAgentTask for interoperability.
pub fn sessionToTask(allocator: std.mem.Allocator, session: *const session_mod.Session) !a2a.SubAgentTask {
    const task_id = try allocator.dupe(u8, session.id);
    errdefer allocator.free(task_id);

    const history = try allocator.alloc(llm.Message, session.messages.items.len);
    errdefer allocator.free(history);

    for (session.messages.items, 0..) |*msg, i| {
        history[i] = .{
            .role = try allocator.dupe(u8, msg.role),
            .content = try allocator.dupe(u8, msg.content),
            .tool_calls = if (msg.tool_calls) |tcs| blk: {
                const arr = try allocator.alloc(llm.ToolCall, tcs.len);
                for (tcs, 0..) |*tc, j| {
                    arr[j] = .{
                        .id = try allocator.dupe(u8, tc.id),
                        .name = try allocator.dupe(u8, tc.name),
                        .arguments = try allocator.dupe(u8, tc.arguments),
                    };
                }
                break :blk arr;
            } else null,
            .tool_call_id = if (msg.tool_call_id) |tcid| try allocator.dupe(u8, tcid) else null,
        };
    }

    return a2a.SubAgentTask{
        .id = task_id,
        .status = .{
            .state = .completed,
            .message = if (session.title.len > 0) try allocator.dupe(u8, session.title) else null,
        },
        .artifacts = &.{},
        .history = history,
    };
}

/// Render a session as a readable Markdown file with YAML frontmatter containing
/// the A2A SubAgentTask JSON for machine interoperability.
pub fn renderShareMarkdown(allocator: std.mem.Allocator, session: *const session_mod.Session) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Convert to A2A task for frontmatter
    const task = try sessionToTask(allocator, session);
    defer task.deinit(allocator);

    // YAML frontmatter with SubAgentTask JSON
    const task_json = try std.fmt.allocPrint(allocator, "{}", .{std.json.fmt(task, .{})});
    defer allocator.free(task_json);

    try appendStr(&buf, allocator, "---\n");
    try appendStr(&buf, allocator, task_json);
    try appendStr(&buf, allocator, "\n---\n\n");

    // Header
    try appendFmt(&buf, allocator, "# Session: {s}\n\n", .{session.title});
    try appendFmt(&buf, allocator, "**ID:** `{s}`", .{session.id});
    if (session.model_id) |m| try appendFmt(&buf, allocator, " | **Model:** `{s}`", .{m});
    if (session.agent) |a| try appendFmt(&buf, allocator, " | **Agent:** `{s}`", .{a});
    try appendFmt(&buf, allocator, " | **Tokens:** {d} in / {d} out\n\n---\n\n", .{ session.total_input_tokens, session.total_output_tokens });

    // Render each message
    for (session.messages.items) |*msg| {
        const role_label = roleLabel(msg);
        try appendFmt(&buf, allocator, "### {s}\n\n", .{role_label});

        // Show tool calls before assistant content
        if (msg.tool_calls) |tcs| {
            for (tcs) |*tc| {
                try appendFmt(&buf, allocator, "**Tool call:** `{s}({s})`\n\n", .{ tc.name, tc.arguments });
            }
        }

        if (msg.content.len > 0) {
            // Content may already contain markdown — render as-is
            try appendStr(&buf, allocator, msg.content);
            try appendStr(&buf, allocator, "\n\n");
        }

        if (msg.tool_call_id) |tcid| {
            try appendFmt(&buf, allocator, "*tool call id: `{s}`*\n\n", .{tcid});
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn appendStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

fn appendFmt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt_str, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn roleLabel(msg: *const llm.Message) []const u8 {
    if (std.mem.eql(u8, msg.role, "system")) return "System";
    if (std.mem.eql(u8, msg.role, "user")) return "User";
    if (std.mem.eql(u8, msg.role, "assistant")) return "Assistant";
    if (std.mem.eql(u8, msg.role, "tool")) return "Tool";
    return msg.role;
}

/// Write the session as a Markdown share file and return the path.
/// Caller owns the returned path (must free).
pub fn shareSession(allocator: std.mem.Allocator, io: std.Io, session: *const session_mod.Session) ![]const u8 {
    const dir_path = try sharesDir(allocator);
    defer allocator.free(dir_path);
    try ensureDir(io, dir_path);

    const md = try renderShareMarkdown(allocator, session);
    defer allocator.free(md);

    const file_path = try shareFilePath(allocator, dir_path, session.id);
    errdefer allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = file_path, .data = md });

    return file_path;
}
