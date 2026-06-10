const std = @import("std");
const llm = @import("llm.zig");
const session_mod = @import("session.zig");
const tool = @import("tool.zig");
const permission_mod = @import("permission.zig");
const agent_mod = @import("agent.zig");
const config_mod = @import("config.zig");
const mcp = @import("mcp.zig");

const ToolDispatch = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON schema as string
};

const dispatch_table = &[_]ToolDispatch{
    .{ .name = "bash", .description = "Execute a bash command and return its output", .parameters =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to run"}},"required":["command"]}
    },
    .{ .name = "read", .description = "Read the contents of a file", .parameters =
    \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"}},"required":["file_path"]}
    },
    .{ .name = "write", .description = "Write content to a file (creates or overwrites)", .parameters =
    \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"content":{"type":"string","description":"Content to write"}},"required":["file_path","content"]}
    },
    .{ .name = "glob", .description = "Search for files matching a glob pattern", .parameters =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. src/**/*.zig)"},"path":{"type":"string","description":"Directory to search in"}},"required":["pattern"]}
    },
    .{ .name = "grep", .description = "Search file contents using a regex pattern", .parameters =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern"},"path":{"type":"string","description":"Directory to search"},"include":{"type":"string","description":"File glob filter (e.g. *.zig)"}},"required":["pattern"]}
    },
    .{ .name = "webfetch", .description = "Fetch a URL and return its content as markdown", .parameters =
    \\{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch"}},"required":["url"]}
    },
    .{ .name = "edit", .description = "Edit a file by replacing exact text (search-and-replace). Use this instead of write when making targeted changes.", .parameters =
    \\{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"old_string":{"type":"string","description":"Exact text to search for and replace"},"new_string":{"type":"string","description":"Replacement text"}},"required":["file_path","old_string","new_string"]}
    },
    .{ .name = "question", .description = "Ask the user a question and get their answer. Use this when you need additional information or clarification from the user.", .parameters =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The question to ask the user"}},"required":["question"]}
    },
    .{ .name = "skill", .description = "Load a skill's instructions from the skills directory and inject them into context.", .parameters =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Name of the skill to load"}},"required":["name"]}
    },
    .{ .name = "todowrite", .description = "Write or update a TODO list in the workspace. Appends to TODO.md.", .parameters =
    \\{"type":"object","properties":{"todos":{"type":"string","description":"The TODO items to write"}},"required":["todos"]}
    },
    .{ .name = "plan", .description = "Create a structured plan as a markdown file (PLAN.md) in the workspace.", .parameters =
    \\{"type":"object","properties":{"plan_text":{"type":"string","description":"The plan content in markdown format"}},"required":["plan_text"]}
    },
    .{ .name = "websearch", .description = "Search the web for information. Returns results from DuckDuckGo.", .parameters =
    \\{"type":"object","properties":{"query":{"type":"string","description":"The search query"}},"required":["query"]}
    },
    .{ .name = "snapshot", .description = "Capture a git diff snapshot of the current workspace. Use this before and after making changes to show the diff.", .parameters =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Optional path to the git repository"}},"required":[]}
    },
    .{ .name = "task", .description = "Execute a task using a sub-agent. Spawns a new LLM call with the specified agent to complete a sub-task.", .parameters =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Sub-agent name (explore, general, etc.)"},"prompt":{"type":"string","description":"The task description for the sub-agent"}},"required":["name","prompt"]}
    },
};

pub const ProcessResult = struct {
    text: []const u8,
    exit_reason: []const u8,
    input_tokens: u64,
    output_tokens: u64,

    pub fn deinit(self: *const ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.exit_reason);
    }
};

/// Look up a tool definition from the dispatch table by name.
pub fn lookupToolDef(name: []const u8) ?*const ToolDispatch {
    for (dispatch_table) |*dt| {
        if (std.mem.eql(u8, dt.name, name)) return dt;
    }
    return null;
}

/// Validate tool call arguments against the dispatch table's JSON Schema.
/// Checks that all required properties are present with correct types.
/// This is a simplified validator — catches missing fields and basic type mismatches.
pub fn validateToolArgs(tc: llm.ToolCall) !void {
    const dt = lookupToolDef(tc.name) orelse return;
    const args_parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, tc.arguments, .{});
    defer args_parsed.deinit();
    const args = args_parsed.value;
    if (args != .object) return error.InvalidToolArgs;

    // Parse the schema to extract required fields
    const schema_parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, dt.parameters, .{});
    defer schema_parsed.deinit();
    const schema = schema_parsed.value;
    if (schema != .object) return;

    // Check required fields
    if (schema.object.get("required")) |req| {
        if (req == .array) {
            for (req.array.items) |field| {
                if (field == .string) {
                    if (args.object.get(field.string) == null) {
                        return error.MissingArg;
                    }
                }
            }
        }
    }
}

/// Build a filtered subset of the dispatch table containing only the named tools.
pub fn buildToolDefsFiltered(allocator: std.mem.Allocator, params_arena: std.mem.Allocator, allowed_names: []const []const u8) ![]llm.ToolDef {
    const result = try allocator.alloc(llm.ToolDef, allowed_names.len);
    var count: usize = 0;
    for (allowed_names) |name| {
        for (dispatch_table) |dt| {
            if (std.mem.eql(u8, dt.name, name)) {
                const params = try std.json.parseFromSlice(std.json.Value, params_arena, dt.parameters, .{});
                result[count] = .{
                    .name = try allocator.dupe(u8, dt.name),
                    .description = try allocator.dupe(u8, dt.description),
                    .parameters = params.value,
                };
                count += 1;
                break;
            }
        }
    }
    return result[0..count];
}

/// Simple one-turn LLM call with no tools. Streams response.
/// Used by ask, plan, and review modes.
pub fn processAsk(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *llm.Provider,
    session: *session_mod.Session,
    model_id: []const u8,
    format_json: bool,
    writer: *std.Io.Writer,
    temperature: ?f64,
    max_tokens: ?u64,
    top_p: ?f64,
    variant: ?[]const u8,
) !ProcessResult {
    _ = io;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;

    const msgs = session.buildMessages(null);
    const response = try provider.completeStream(
        .{
            .model = model_id,
            .messages = msgs,
            .temperature = temperature,
            .max_tokens = max_tokens,
            .top_p = top_p,
            .tools = null,
            .variant = variant,
        },
        writer,
        format_json,
    );
    defer response.deinit(allocator);

    input_tokens += response.input_tokens orelse 0;
    output_tokens += response.output_tokens orelse 0;

    // Store assistant response in session
    {
        var tc_list = try std.ArrayList(llm.ToolCall).initCapacity(allocator, 0);
        defer tc_list.deinit(allocator);
        for (response.tool_calls) |tc| {
            try tc_list.append(allocator, .{
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .arguments = try allocator.dupe(u8, tc.arguments),
            });
        }
        const assistant_msg = llm.Message{
            .role = try allocator.dupe(u8, "assistant"),
            .content = try allocator.dupe(u8, response.content),
            .tool_calls = try tc_list.toOwnedSlice(allocator),
        };
        try session.addMessage(assistant_msg);
    }

    if (!format_json) {
        try writer.print("\n", .{});
        try writer.flush();
    }

    const finish = response.finish_reason orelse "stop";
    return ProcessResult{
        .text = try allocator.dupe(u8, response.content),
        .exit_reason = try allocator.dupe(u8, finish),
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    };
}

/// Backward-compatible wrapper: builds all tool defs (no MCP).
pub fn processTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *llm.Provider,
    session: *session_mod.Session,
    model_id: []const u8,
    skip_perms: bool,
    format_json: bool,
    show_thinking: bool,
    writer: *std.Io.Writer,
    reader: ?*std.Io.Reader,
    temperature: ?f64,
    max_tokens: ?u64,
    top_p: ?f64,
    variant: ?[]const u8,
) !ProcessResult {
    var params_arena = std.heap.ArenaAllocator.init(allocator);
    defer params_arena.deinit();
    const tools = try buildToolDefs(allocator, params_arena.allocator());
    defer {
        for (tools) |*t| t.deinit(allocator);
        allocator.free(tools);
    }
    return processTurnWithTools(allocator, io, provider, session, model_id, skip_perms, format_json, show_thinking, writer, reader, temperature, max_tokens, top_p, variant, tools, &.{});
}

/// Like processTurn but accepts a config for MCP server discovery.
pub fn processTurnWithConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *llm.Provider,
    session: *session_mod.Session,
    model_id: []const u8,
    skip_perms: bool,
    format_json: bool,
    show_thinking: bool,
    writer: *std.Io.Writer,
    reader: ?*std.Io.Reader,
    temperature: ?f64,
    max_tokens: ?u64,
    top_p: ?f64,
    variant: ?[]const u8,
    config: ?*const config_mod.Config,
) !ProcessResult {
    var params_arena = std.heap.ArenaAllocator.init(allocator);
    defer params_arena.deinit();
    const pa = params_arena.allocator();

    // Build built-in tool defs
    const builtin = try buildToolDefs(allocator, pa);

    // Build MCP clients and discover their tools
    var mcp_clients = std.ArrayList(mcp.Client).initCapacity(allocator, 4) catch unreachable;
    defer {
        for (mcp_clients.items) |*c| c.deinit();
        mcp_clients.deinit(allocator);
    }

    var mcp_tool_list = std.ArrayList(llm.ToolDef).initCapacity(allocator, 16) catch unreachable;
    defer {
        for (mcp_tool_list.items) |t| {
            allocator.free(t.name);
            allocator.free(t.description);
        }
        mcp_tool_list.deinit(allocator);
    }

    if (config) |cfg| {
        if (cfg.mcp_servers) |servers| {
            var iter = servers.iterator();
            while (iter.next()) |entry| {
                var client = mcp.Client.init(allocator, io, entry.value_ptr.url, entry.key_ptr.*);
                const tools = client.listTools(allocator, pa) catch |err| {
                    std.log.warn("MCP '{s}' tool discovery failed: {}", .{ entry.key_ptr.*, err });
                    client.deinit();
                    continue;
                };
                for (tools) |t| {
                    try mcp_tool_list.append(allocator, t);
                }
                try mcp_clients.append(allocator, client);
            }
        }
    }

    // Merge built-in and MCP tool defs
    const total = builtin.len + mcp_tool_list.items.len;
    const all_tools = try allocator.alloc(llm.ToolDef, total);
    var ti: usize = 0;
    for (builtin) |t| {
        all_tools[ti] = t;
        ti += 1;
    }
    allocator.free(builtin);
    for (mcp_tool_list.items) |t| {
        all_tools[ti] = t;
        ti += 1;
    }
    mcp_tool_list.items.len = 0; // prevent defer from freeing (moved to all_tools)

    defer {
        for (all_tools) |*t| t.deinit(allocator);
        allocator.free(all_tools);
    }

    return processTurnWithTools(allocator, io, provider, session, model_id, skip_perms, format_json, show_thinking, writer, reader, temperature, max_tokens, top_p, variant, all_tools, mcp_clients.items);
}

pub fn processTurnWithTools(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *llm.Provider,
    session: *session_mod.Session,
    model_id: []const u8,
    skip_perms: bool,
    format_json: bool,
    show_thinking: bool,
    writer: *std.Io.Writer,
    reader: ?*std.Io.Reader,
    temperature: ?f64,
    max_tokens: ?u64,
    top_p: ?f64,
    variant: ?[]const u8,
    tools: []const llm.ToolDef,
    mcp_clients: []mcp.Client,
) !ProcessResult {
    _ = show_thinking; // reserved for reasoning block display

    var perm_manager = permission_mod.Manager.init(allocator);
    defer perm_manager.deinit();

    var turn: u32 = 0;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;

    while (true) {
        turn += 1;
        if (turn > 25) {
            if (format_json) try writeJsonLine(writer, allocator, .{ .type = "error", .message = "Too many turns" });
            return ProcessResult{ .text = try allocator.dupe(u8, ""), .exit_reason = try allocator.dupe(u8, "max_turns"), .input_tokens = input_tokens, .output_tokens = output_tokens };
        }

        // Compaction: if approaching token limit, summarize old messages
        if (session.estimatedTokens() > 8000) {
            const compact_agent_opt = try agent_mod.getBuiltin(allocator, "compaction");
            if (compact_agent_opt == null) return ProcessResult{ .text = try allocator.dupe(u8, ""), .exit_reason = try allocator.dupe(u8, "compaction_no_agent"), .input_tokens = input_tokens, .output_tokens = output_tokens };
            var compact_agent = compact_agent_opt.?;
            defer compact_agent.deinit(allocator);
            var compact_buf = std.ArrayList(u8).initCapacity(allocator, 65536) catch unreachable;
            defer compact_buf.deinit(allocator);
            var system_indices = std.ArrayList(usize).initCapacity(allocator, session.messages.items.len) catch unreachable;
            defer system_indices.deinit(allocator);
            for (session.messages.items, 0..) |msg, i| {
                if (std.mem.eql(u8, msg.role, "system")) {
                    try system_indices.append(allocator, i);
                } else {
                    try compact_buf.appendSlice(allocator, msg.role);
                    try compact_buf.appendSlice(allocator, ": ");
                    try compact_buf.appendSlice(allocator, msg.content);
                    try compact_buf.appendSlice(allocator, "\n");
                }
            }
            const compact_text = try compact_buf.toOwnedSlice(allocator);
            defer allocator.free(compact_text);
            var compact_msgs = try allocator.alloc(llm.Message, 2);
            defer allocator.free(compact_msgs);
            compact_msgs[0] = .{ .role = try allocator.dupe(u8, "system"), .content = try allocator.dupe(u8, compact_agent.system_prompt) };
            compact_msgs[1] = .{ .role = try allocator.dupe(u8, "user"), .content = compact_text };
            const compact_resp = provider.complete(.{ .model = model_id, .messages = compact_msgs[0..2] }) catch |err| {
                if (!format_json) try writer.print("\n[compaction failed: {}]\n", .{err});
                return ProcessResult{ .text = try allocator.dupe(u8, ""), .exit_reason = try allocator.dupe(u8, "compaction_failed"), .input_tokens = input_tokens, .output_tokens = output_tokens };
            };
            defer compact_resp.deinit(allocator);
            input_tokens += compact_resp.input_tokens orelse 0;
            output_tokens += compact_resp.output_tokens orelse 0;
            // Preserve system messages + summary + last user/assistant exchange
            var new_msgs = std.ArrayList(llm.Message).initCapacity(allocator, system_indices.items.len + 3) catch unreachable;
            for (system_indices.items) |idx| {
                const orig = &session.messages.items[idx];
                try new_msgs.append(allocator, .{ .role = try allocator.dupe(u8, orig.role), .content = try allocator.dupe(u8, orig.content) });
            }
            const summary_text = try std.fmt.allocPrint(allocator, "Previous conversation summary:\n{s}", .{compact_resp.content});
            try new_msgs.append(allocator, .{ .role = try allocator.dupe(u8, "system"), .content = summary_text });
            // Keep last two non-system messages (user + assistant exchange)
            var kept: usize = 0;
            var i: usize = session.messages.items.len;
            while (i > 0 and kept < 2) {
                i -= 1;
                const orig = &session.messages.items[i];
                if (!std.mem.eql(u8, orig.role, "system")) {
                    try new_msgs.append(allocator, .{ .role = try allocator.dupe(u8, orig.role), .content = try allocator.dupe(u8, orig.content) });
                    kept += 1;
                }
            }
            // Free old messages
            for (session.messages.items) |*msg| msg.deinit(allocator);
            session.messages.deinit(allocator);
            session.messages = new_msgs;
        }

        const msgs = session.buildMessages(null);
        const response = try provider.completeStream(
            .{
                .model = model_id,
                .messages = msgs,
                .temperature = temperature,
                .max_tokens = max_tokens,
                .top_p = top_p,
                .tools = tools,
                .tool_choice = "auto",
                .variant = variant,
            },
            writer,
            format_json,
        );
        defer response.deinit(allocator);

        input_tokens += response.input_tokens orelse 0;
        output_tokens += response.output_tokens orelse 0;

        // Store assistant response in session
        {
            var tc_list = try std.ArrayList(llm.ToolCall).initCapacity(allocator, 0);
            defer tc_list.deinit(allocator);
            for (response.tool_calls) |tc| {
                try tc_list.append(allocator, .{
                    .id = try allocator.dupe(u8, tc.id),
                    .name = try allocator.dupe(u8, tc.name),
                    .arguments = try allocator.dupe(u8, tc.arguments),
                });
            }
            const assistant_msg = llm.Message{
                .role = try allocator.dupe(u8, "assistant"),
                .content = try allocator.dupe(u8, response.content),
                .tool_calls = try tc_list.toOwnedSlice(allocator),
            };
            try session.addMessage(assistant_msg);
        }

        // Handle tool calls
        if (response.tool_calls.len > 0) {
            if (!format_json) {
                try writer.print("\n", .{});
                try writer.flush();
            }
            for (response.tool_calls) |tc| {
                if (!skip_perms) {
                    const action = perm_manager.evaluate(tc.name, tc.id);
                    const allowed = switch (action) {
                        .allow => true,
                        .deny => false,
                        .ask => try checkPermissionInteractive(allocator, &perm_manager, writer, reader, tc),
                    };
                    if (!allowed) {
                        try session.addToolResult(tc.id, "Permission denied by user", true);
                        return ProcessResult{ .text = try allocator.dupe(u8, ""), .exit_reason = try allocator.dupe(u8, "permission_denied"), .input_tokens = input_tokens, .output_tokens = output_tokens };
                    }
                }

                // Validate tool arguments before execution
                validateToolArgs(tc) catch |err| {
                    const err_msg = try std.fmt.allocPrint(allocator, "Invalid arguments for {s}: {}", .{ tc.name, err });
                    try session.addToolResult(tc.id, err_msg, true);
                    if (!format_json) {
                        try writer.print("  \x1b[33m! {s}\x1b[0m\n", .{err_msg});
                        try writer.flush();
                    }
                    continue;
                };

                // Execute tool
                var tool_result = try executeTool(allocator, io, writer, reader, provider, model_id, tc, mcp_clients);
                defer tool_result.deinit(allocator);
                const is_err = tool_result.exit_code != 0;

                try session.addToolResult(tc.id, tool_result.stdout, is_err);
            }
            continue;
        }

        // Finish
        if (response.finish_reason) |fr| {
            if (!format_json) {
                try writer.print("\n[{s}]\n", .{fr});
                try writer.flush();
            }
            return ProcessResult{
                .text = try allocator.dupe(u8, response.content),
                .exit_reason = try allocator.dupe(u8, fr),
                .input_tokens = input_tokens,
                .output_tokens = output_tokens,
            };
        }

        return ProcessResult{ .text = try allocator.dupe(u8, response.content), .exit_reason = try allocator.dupe(u8, "stop"), .input_tokens = input_tokens, .output_tokens = output_tokens };
    }
}

fn buildToolDefs(allocator: std.mem.Allocator, params_arena: std.mem.Allocator) ![]llm.ToolDef {
    const result = try allocator.alloc(llm.ToolDef, dispatch_table.len);
    for (dispatch_table, 0..) |dt, i| {
        const params = try std.json.parseFromSlice(std.json.Value, params_arena, dt.parameters, .{});
        result[i] = .{
            .name = try allocator.dupe(u8, dt.name),
            .description = try allocator.dupe(u8, dt.description),
            .parameters = params.value,
        };
    }
    return result;
}



fn executeTool(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, reader: ?*std.Io.Reader, provider: *llm.Provider, model_id: []const u8, tc: llm.ToolCall, mcp_clients: []mcp.Client) !tool.Result {
    const args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{});
    defer args_parsed.deinit();
    const args = args_parsed.value;
    const args_obj = if (args == .object) args.object else return error.InvalidToolArgs;

    if (std.mem.eql(u8, tc.name, "bash")) {
        const command = args_obj.get("command") orelse return error.MissingArg;
        return tool.bash(allocator, io, command.string);
    }
    if (std.mem.eql(u8, tc.name, "read")) {
        const file_path = args_obj.get("file_path") orelse return error.MissingArg;
        const content = try tool.readFile(io, allocator, file_path.string);
        return tool.Result{ .stdout = content, .stderr = "", .exit_code = 0 };
    }
    if (std.mem.eql(u8, tc.name, "write")) {
        const file_path = args_obj.get("file_path") orelse return error.MissingArg;
        const content = args_obj.get("content") orelse return error.MissingArg;
        try tool.writeFile(io, content.string, file_path.string);
        return tool.Result{ .stdout = "File written", .stderr = "", .exit_code = 0 };
    }
    if (std.mem.eql(u8, tc.name, "glob")) {
        const pattern = args_obj.get("pattern") orelse return error.MissingArg;
        const search_path = if (args_obj.get("path")) |p| p.string else ".";
        return tool.globSearch(allocator, io, pattern.string, search_path);
    }
    if (std.mem.eql(u8, tc.name, "grep")) {
        const pattern = args_obj.get("pattern") orelse return error.MissingArg;
        const search_path = if (args_obj.get("path")) |p| p.string else ".";
        const include = if (args_obj.get("include")) |i| i.string else "";
        return tool.grepSearch(allocator, io, pattern.string, search_path, include);
    }
    if (std.mem.eql(u8, tc.name, "webfetch")) {
        const url = args_obj.get("url") orelse return error.MissingArg;
        return tool.webFetch(allocator, io, url.string);
    }
    if (std.mem.eql(u8, tc.name, "edit")) {
        const file_path = args_obj.get("file_path") orelse return error.MissingArg;
        const old_string = args_obj.get("old_string") orelse return error.MissingArg;
        const new_string = args_obj.get("new_string") orelse return error.MissingArg;
        return tool.editFile(allocator, io, file_path.string, old_string.string, new_string.string);
    }
    if (std.mem.eql(u8, tc.name, "question")) {
        const q = args_obj.get("question") orelse return error.MissingArg;
        try writer.print("{s} ", .{q.string});
        try writer.flush();
        const stdin_content = if (reader) |rdr| (try rdr.takeDelimiter('\n')) orelse "" else "";
        return tool.question(allocator, io, q.string, stdin_content);
    }
    if (std.mem.eql(u8, tc.name, "skill")) {
        const name = args_obj.get("name") orelse return error.MissingArg;
        return tool.skill(allocator, io, name.string);
    }
    if (std.mem.eql(u8, tc.name, "todowrite")) {
        const todos = args_obj.get("todos") orelse return error.MissingArg;
        return tool.todoWrite(allocator, io, todos.string);
    }
    if (std.mem.eql(u8, tc.name, "plan")) {
        const plan_text = args_obj.get("plan_text") orelse return error.MissingArg;
        return tool.plan(allocator, io, plan_text.string);
    }
    if (std.mem.eql(u8, tc.name, "websearch")) {
        const query = args_obj.get("query") orelse return error.MissingArg;
        return tool.webSearch(allocator, io, query.string);
    }
    if (std.mem.eql(u8, tc.name, "snapshot")) {
        const path = if (args_obj.get("path")) |p| p.string else "";
        return tool.snapshot(allocator, io, path);
    }
    if (std.mem.eql(u8, tc.name, "task")) {
        const sub_name = args_obj.get("name") orelse return error.MissingArg;
        const prompt = args_obj.get("prompt") orelse return error.MissingArg;
        const sub_agent_opt = agent_mod.getBuiltin(allocator, sub_name.string) catch return tool.Result{ .stdout = "", .stderr = "Unknown sub-agent", .exit_code = 1 };
        if (sub_agent_opt == null) return tool.Result{ .stdout = "", .stderr = "Unknown sub-agent", .exit_code = 1 };
        var sub_agent = sub_agent_opt.?;
        defer sub_agent.deinit(allocator);
        const sub_msgs = try allocator.alloc(llm.Message, 2);
        defer allocator.free(sub_msgs);
        sub_msgs[0] = .{ .role = try allocator.dupe(u8, "system"), .content = try allocator.dupe(u8, sub_agent.system_prompt) };
        sub_msgs[1] = .{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, prompt.string) };
        const sub_resp = try provider.complete(.{ .model = model_id, .messages = sub_msgs[0..2] });
        defer sub_resp.deinit(allocator);
        return tool.Result{ .stdout = sub_resp.content, .stderr = "", .exit_code = 0 };
    }

    // MCP tool dispatch
    if (std.mem.startsWith(u8, tc.name, "mcp/")) {
        for (mcp_clients) |*mc| {
            const prefix = try std.fmt.allocPrint(allocator, "mcp/{s}/", .{mc.server_name});
            defer allocator.free(prefix);
            if (std.mem.startsWith(u8, tc.name, prefix)) {
                return mc.callTool(tc.name, tc.arguments, allocator);
            }
        }
        const err_msg = try std.fmt.allocPrint(allocator, "MCP server not found for tool: {s}", .{tc.name});
        return tool.Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
    }

    const err_msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tc.name});
    return tool.Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
}

fn checkPermissionInteractive(allocator: std.mem.Allocator, manager: *permission_mod.Manager, writer: *std.Io.Writer, reader: ?*std.Io.Reader, tc: llm.ToolCall) !bool {
    const rdr = reader orelse return true;
    try writer.print("Allow \x1b[1m{s}\x1b[0m(", .{tc.name});
    const args_parsed = std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{}) catch {
        try writer.print("...", .{});
        return true;
    };
    defer args_parsed.deinit();
    if (args_parsed.value == .object) {
        var first = true;
        var iter = args_parsed.value.object.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.print(", ", .{});
            first = false;
            if (entry.value_ptr.* == .string) {
                const val = entry.value_ptr.*.string;
                const truncated = if (val.len > 60) val[0..60] else val;
                try writer.print("{s}='{s}'", .{ entry.key_ptr.*, truncated });
            } else {
                try writer.print("{s}=...", .{entry.key_ptr.*});
            }
        }
    }
    try writer.print(")? [\x1b[1my\x1b[0m/\x1b[1mn\x1b[0m/\x1b[1ma\x1b[0mlways] ", .{});
    try writer.flush();

    const line = try rdr.takeDelimiter('\n');
    const input = if (line) |slice| std.mem.trim(u8, slice, " \t\r\n") else "";
    if (input.len == 0) return false;
    switch (input[0]) {
        'y', 'Y' => return true,
        'a', 'A' => {
            try manager.addRule(.{ .permission = try allocator.dupe(u8, tc.name), .pattern = try allocator.dupe(u8, "*"), .action = .allow });
            return true;
        },
        else => return false,
    }
}

fn writeJsonLine(writer: *std.Io.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .minified });
    defer allocator.free(json_str);
    try writer.print("{s}\n", .{json_str});
    try writer.flush();
}

test "permission manager: addRule and evaluate" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var man = permission_mod.Manager.init(allocator);
    defer man.deinit();

    try man.addRule(.{ .permission = "bash", .pattern = "*", .action = .allow });
    try testing.expectEqual(man.evaluate("bash", "echo anything"), .allow);
    try testing.expectEqual(man.evaluate("read", "/tmp/test.txt"), .ask);
}

test "lookupToolDef: finds existing tool" {
    const testing = @import("std").testing;
    const dt = lookupToolDef("bash");
    try testing.expect(dt != null);
    try testing.expectEqualStrings(dt.?.name, "bash");
}

test "lookupToolDef: returns null for unknown" {
    const testing = @import("std").testing;
    try testing.expect(lookupToolDef("nonexistent") == null);
}

test "buildToolDefsFiltered: returns only requested tools" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "read", "write", "edit" };
    const defs = try buildToolDefsFiltered(allocator, arena.allocator(), &names);
    defer {
        for (defs) |*t| t.deinit(allocator);
        allocator.free(defs);
    }
    try testing.expectEqual(defs.len, 3);
    try testing.expectEqualStrings(defs[0].name, "read");
    try testing.expectEqualStrings(defs[1].name, "write");
    try testing.expectEqualStrings(defs[2].name, "edit");
}

test "validateToolArgs: valid args pass" {
    const tc = llm.ToolCall{
        .id = "call_1",
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    };
    try validateToolArgs(tc);
}

test "validateToolArgs: missing required field fails" {
    const testing = @import("std").testing;
    const tc = llm.ToolCall{
        .id = "call_2",
        .name = "bash",
        .arguments = "{}",
    };
    testing.expectError(error.MissingArg, validateToolArgs(tc)) catch {};
}

test "validateToolArgs: unknown tool skips validation" {
    const tc = llm.ToolCall{
        .id = "call_3",
        .name = "nonexistent",
        .arguments = "{}",
    };
    try validateToolArgs(tc);
}

test "processTurn permission manager evaluate flow" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var man = permission_mod.Manager.init(allocator);
    defer man.deinit();

    try testing.expectEqual(man.evaluate("bash", "echo hi"), .ask);

    try man.addRule(.{ .permission = "bash", .pattern = "*", .action = .deny });
    try testing.expectEqual(man.evaluate("bash", "echo hi"), .deny);

    var man2 = permission_mod.Manager.init(allocator);
    defer man2.deinit();
    try man2.addRule(.{ .permission = "bash", .pattern = "*", .action = .allow });
    try man2.addRule(.{ .permission = "bash", .pattern = "rm *", .action = .deny });
    try testing.expectEqual(man2.evaluate("bash", "rm important.txt"), .allow);

    try testing.expectEqual(man2.evaluate("write", "/tmp/test"), .ask);
}
