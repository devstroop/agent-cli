const std = @import("std");
const Io = std.Io;

const sdk = @import("agent-sdk");
const cli = @import("cli.zig");
const config_mod = sdk.config;
const llm = sdk.llm;
const session_mod = sdk.session;
const agent_mod = sdk.agent;
const permission_mod = sdk.permission;
const tool = sdk.tool;
const processor = sdk.processor;
const a2a_mod = sdk.a2a;
const persistence = @import("persistence.zig");
const context = @import("context.zig");
const share = @import("share.zig");
const wizard = @import("wizard.zig");
const markdown = @import("markdown.zig");

/// Adapter: Markdown renderer → llm.OnToken callback.
fn mdOnTokenFeed(ptr: *anyopaque, text: []const u8) void {
    const r: *markdown.MdRenderer = @ptrCast(@alignCast(ptr));
    r.feed(text) catch {};
}

/// Shared state extracted from CLI flags for mode exec functions.
pub const ExecState = struct {
    mode: []const u8,
    config: config_mod.Config,
    resolved: ModelResolution,
    agent: agent_mod.Agent,
    session: session_mod.Session,
    prompt_text: []const u8,
    prompt_allocated: bool,
    format_json: bool,
    raw: bool,
    skip_perms: bool,
    project_dir: []const u8,
    temperature: ?f64,
    max_tokens: ?u64,
    top_p: ?f64,
    variant: ?[]const u8,

    pub fn deinit(self: *ExecState, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        allocator.free(self.resolved.provider_id);
        allocator.free(self.resolved.model_id);
        if (self.resolved.api_key) |k| allocator.free(k);
        if (self.resolved.owned_prov_cfg) self.resolved.prov_cfg.deinit(allocator);
        self.agent.deinit(allocator);
        self.session.deinit();
        if (self.prompt_allocated and self.prompt_text.len > 0) allocator.free(self.prompt_text);
        if (self.project_dir.len > 0) allocator.free(self.project_dir);
    }
};

pub const ModelResolution = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    prov_cfg: config_mod.ProviderConfig,
    /// If true, prov_cfg's strings were heap-allocated and must be freed.
    owned_prov_cfg: bool,
};

pub fn setupExec(cmd: *cli.Cmd, mode: []const u8, agent_name: []const u8) !ExecState {
    const message = cmd.flag("message", []const u8);
    const model_str = cmd.flag("model", []const u8);
    const format = cmd.flag("format", []const u8);
    const title_flag = cmd.flag("title", []const u8);
    const project_dir = cmd.flag("dir", []const u8);
    const skip_perms = cmd.flag("skip-permissions", bool);
    const cont_flag = cmd.flag("continue", bool);
    const session_id = cmd.flag("session", []const u8);
    const fork_flag = cmd.flag("fork", bool);
    const variant_str = cmd.flag("variant", []const u8);
    const max_tokens_raw = cmd.flag("max-tokens", i32);
    const temperature_str = cmd.flag("temperature", []const u8);
    const top_p_str = cmd.flag("top-p", []const u8);
    const raw = cmd.flag("raw", bool);

    const max_tokens: ?u64 = if (max_tokens_raw > 0) @as(u64, @intCast(max_tokens_raw)) else null;
    const temperature: ?f64 = if (temperature_str.len > 0) std.fmt.parseFloat(f64, temperature_str) catch null else null;
    const top_p: ?f64 = if (top_p_str.len > 0) std.fmt.parseFloat(f64, top_p_str) catch null else null;

    const allocator = cmd.allocator;
    const format_json = std.mem.eql(u8, format, "json");

    // Load config
    const config_path = cmd.flag("config", []const u8);
    var config = if (config_path.len > 0) blk: {
        const result = config_mod.loadFile(cmd.io, allocator, config_path) catch |err| {
            try cmd.writer.print("Error: could not load config '{s}': {}\n", .{ config_path, err });
            return error.BadConfig;
        };
        break :blk result orelse {
            try cmd.writer.print("Error: config file '{s}' not found\n", .{config_path});
            return error.BadConfig;
        };
    } else (try config_mod.find(cmd.io, allocator, if (project_dir.len > 0) project_dir else null)) orelse blk: {
        break :blk config_mod.Config.empty();
    };

    // Resolve provider + model
    const resolved = try resolveModelProvider(allocator, &config, model_str);

    // Resolve agent
    const agent = try resolveAgent(allocator, cmd.io, config.agents, agent_name);

    // Create session
    var session = if (session_id.len > 0) blk: {
        break :blk try persistence.loadSession(cmd.io, allocator, session_id);
    } else if (cont_flag) blk: {
        if (try persistence.loadLatestSession(cmd.io, allocator)) |s| {
            break :blk s;
        }
        try cmd.writer.print("Warning: no previous session found, starting fresh\n", .{});
        break :blk try session_mod.Session.init(allocator, .{ .agent = agent.name });
    } else blk: {
        break :blk try session_mod.Session.init(allocator, .{
            .title = if (title_flag.len > 0) title_flag else null,
            .agent = agent.name,
            .model_id = resolved.model_id,
            .provider_id = resolved.provider_id,
        });
    };

    if (fork_flag) {
        session.id = try persistence.generateId(cmd.io, allocator);
        session.slug = try allocator.dupe(u8, session.id);
    }

    // Build user message
    var prompt_allocated = false;
    const prompt_text = if (message.len > 0) message else if (cmd.positional.items.len > 0) cmd.positional.items[0] else blk: {
        prompt_allocated = true;
        if (readStdinPipe(cmd.reader, allocator)) |p| {
            if (p) |content| break :blk content;
        } else |_| {}
        break :blk "";
    };

    // Set default title from prompt
    if (title_flag.len == 0 and prompt_text.len > 0) {
        allocator.free(session.title);
        const truncated = if (prompt_text.len > 100) prompt_text[0..100] else prompt_text;
        session.title = try std.fmt.allocPrint(allocator, "Non-interactive: {s}", .{truncated});
    }

    // Build context and add messages
    {
        const ctx_text = try context.render(cmd.io, allocator, if (project_dir.len > 0) project_dir else null);
        try session.addMessage(.{ .role = try allocator.dupe(u8, "system"), .content = ctx_text });
        // Inject available skills list
        {
            const skill_result = tool.skillList(allocator, cmd.io) catch null;
            if (skill_result) |sr| {
                defer sr.deinit(allocator);
                if (sr.stdout.len > 0 and sr.exit_code == 0) {
                    const skill_ctx = try std.fmt.allocPrint(allocator, "Available skills (call the `skill` tool to load full instructions):\n{s}", .{sr.stdout});
                    try session.addMessage(.{ .role = try allocator.dupe(u8, "system"), .content = skill_ctx });
                }
            }
        }
        // Append model-family-specific suffix to agent prompt
        const model_family = agent_mod.detectModelFamily(resolved.model_id);
        const suffix = agent_mod.modelFamilySuffix(model_family);
        // Expand ! commands in system prompt
        const expanded_prompt = try context.expandBangCommands(allocator, cmd.io, agent.system_prompt);
        const full_prompt = if (suffix.len > 0) blk: {
            const fp = try std.fmt.allocPrint(allocator, "{s}{s}", .{ expanded_prompt, suffix });
            allocator.free(expanded_prompt);
            break :blk fp;
        } else expanded_prompt;
        try session.addMessage(.{ .role = try allocator.dupe(u8, "system"), .content = full_prompt });
    }
    if (prompt_text.len > 0) {
        try session.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, prompt_text) });
    }

    // Attach files (--file / -f)
    {
        const file_flag = cmd.flag("file", []const u8);
        if (file_flag.len > 0) {
            var file_iter = std.mem.splitScalar(u8, file_flag, ',');
            while (file_iter.next()) |fpath| {
                if (fpath.len == 0) continue;
                const content = tool.readFile(cmd.io, allocator, fpath) catch |err| {
                    try cmd.writer.print("Warning: could not read file '{s}': {}\n", .{ fpath, err });
                    continue;
                };
                const msg = try std.fmt.allocPrint(allocator, "File '{s}':\n```\n{s}\n```", .{ fpath, content });
                allocator.free(content);
                try session.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = msg });
            }
        }
    }

    if (session.messages.items.len == 0) {
        try cmd.writer.print("Error: no messages to process (use --message or pipe content)\n", .{});
        return error.NoPrompt;
    }

    return ExecState{
        .mode = mode,
        .config = config,
        .resolved = resolved,
        .agent = agent,
        .session = session,
        .prompt_text = prompt_text,
        .prompt_allocated = prompt_allocated,
        .format_json = format_json,
        .raw = raw,
        .skip_perms = skip_perms,
        .project_dir = try allocator.dupe(u8, project_dir),
        .temperature = temperature,
        .max_tokens = max_tokens,
        .top_p = top_p,
        .variant = if (variant_str.len > 0) variant_str else null,
    };
}

pub fn printBanner(writer: *Io.Writer, mode: []const u8, model_id: []const u8, format_json: bool) !void {
    if (!format_json) {
        try writer.print("> {s} · {s}\n", .{ mode, model_id });
        try writer.flush();
    }
}

pub fn saveAndShare(cmd: *cli.Cmd, allocator: std.mem.Allocator, session: *session_mod.Session, format_json: bool) !void {
    try persistence.saveSession(cmd.io, allocator, session);
    try persistence.saveLatestSession(cmd.io, allocator, session.id);

    const share_flag = cmd.flag("share", bool);
    if (share_flag) {
        const share_path = share.shareSession(allocator, cmd.io, session) catch {
            try cmd.writer.print("(sharing failed -- could not write share file)\n", .{});
            return;
        };
        defer allocator.free(share_path);
        if (format_json) {
            try writeJsonLine(cmd.writer, allocator, .{ .type = "share", .path = share_path });
        } else {
            try cmd.writer.print("Share: file://{s}\n", .{share_path});
        }
    }
}

fn writeJsonLine(writer: *Io.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .minified });
    defer allocator.free(json);
    try writer.print("{s}\n", .{json});
    try writer.flush();
}

// ── Exec functions ──────────────────────────────────────────────────────────

pub fn askExec(cmd: *cli.Cmd) !void {
    const allocator = cmd.allocator;
    var state = try setupExec(cmd, "ask", "ask");
    defer state.deinit(allocator);

    try printBanner(cmd.writer, state.mode, state.resolved.model_id, state.format_json);

    var md_renderer: ?markdown.MdRenderer = null;
    const on_token: ?llm.OnToken = if (!state.raw and !state.format_json) blk: {
        md_renderer = markdown.MdRenderer.init(allocator, cmd.writer);
        break :blk llm.OnToken{ .context = @ptrCast(&md_renderer.?), .callback = mdOnTokenFeed };
    } else null;
    defer if (md_renderer) |*r| r.deinit();

    var provider = llm.Provider.init(allocator, cmd.io, state.resolved.prov_cfg, state.resolved.api_key);
    const result = processor.processAsk(allocator, cmd.io, &provider, &state.session, state.resolved.model_id, state.format_json, on_token, cmd.writer, state.temperature, state.max_tokens, state.top_p, state.variant) catch |err| {
        if (err == error.LlmError) {
            try cmd.writer.print("\n\x1b[31mError:\x1b[0m API request failed (rate limited or server error). Try again later.\n", .{});
            return;
        }
        return err;
    };
    defer result.deinit(allocator);

    if (md_renderer) |*r| try r.flush();
    try saveAndShare(cmd, allocator, &state.session, state.format_json);

    if (state.format_json) {
        try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
    }
}

pub fn planExec(cmd: *cli.Cmd) !void {
    const allocator = cmd.allocator;
    var state = try setupExec(cmd, "plan", "plan");
    defer state.deinit(allocator);

    try printBanner(cmd.writer, state.mode, state.resolved.model_id, state.format_json);

    var params_arena = std.heap.ArenaAllocator.init(allocator);
    defer params_arena.deinit();
    const plan_tools = [_][]const u8{ "read", "glob", "grep", "webfetch" };
    const tools = try processor.buildToolDefsFiltered(allocator, params_arena.allocator(), &plan_tools);
    defer {
        for (tools) |*t| t.deinit(allocator);
        allocator.free(tools);
    }

    var md_renderer: ?markdown.MdRenderer = null;
    const on_token: ?llm.OnToken = if (!state.raw and !state.format_json) blk: {
        md_renderer = markdown.MdRenderer.init(allocator, cmd.writer);
        break :blk llm.OnToken{ .context = @ptrCast(&md_renderer.?), .callback = mdOnTokenFeed };
    } else null;
    defer if (md_renderer) |*r| r.deinit();

    var provider = llm.Provider.init(allocator, cmd.io, state.resolved.prov_cfg, state.resolved.api_key);
    const reader = if (state.skip_perms) null else cmd.reader;
    var sa_ctx = SubAgentCtx{ .writer = cmd.writer };
    const result = processor.processTurnWithTools(allocator, cmd.io, &provider, &state.session, state.resolved.model_id, state.skip_perms, state.format_json, on_token, false, cmd.writer, reader, state.temperature, state.max_tokens, state.top_p, state.variant, tools, &.{}, sa_ctx.callback(), 25) catch |err| {
        if (err == error.LlmError) {
            try cmd.writer.print("\n\x1b[31mError:\x1b[0m API request failed (rate limited or server error). Try again later.\n", .{});
            return;
        }
        return err;
    };
    defer result.deinit(allocator);

    if (md_renderer) |*r| try r.flush();

    if (result.text.len > 0) {
        var plan_result = tool.plan(allocator, cmd.io, result.text) catch null;
        if (plan_result) |*pr| {
            pr.deinit(allocator);
        }
        if (!state.format_json) {
            try cmd.writer.print("\nPlan written to \x1b[1mPLAN.md\x1b[0m\n", .{});
        }
    }

    try saveAndShare(cmd, allocator, &state.session, state.format_json);

    if (state.format_json) {
        try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
    }
}

pub fn reviewExec(cmd: *cli.Cmd) !void {
    const allocator = cmd.allocator;
    const session_id = cmd.flag("session", []const u8);
    if (session_id.len == 0) {
        try cmd.writer.print("Usage: agent review --session <session-id>\n", .{});
        return;
    }

    var target_session = persistence.loadSession(cmd.io, allocator, session_id) catch |err| {
        try cmd.writer.print("Error: cannot load session '{s}': {}\n", .{ session_id, err });
        return;
    };
    defer target_session.deinit();

    var state = try setupExec(cmd, "review", "review");
    defer state.deinit(allocator);

    var sb = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;
    defer sb.deinit(allocator);
    try sb.appendSlice(allocator, "Review the following conversation session and provide a concise assessment:\n\n");
    for (target_session.messages.items) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) continue;
        try sb.appendSlice(allocator, msg.role);
        try sb.appendSlice(allocator, ": ");
        if (msg.content.len > 200) {
            try sb.appendSlice(allocator, msg.content[0..200]);
        } else {
            try sb.appendSlice(allocator, msg.content);
        }
        try sb.appendSlice(allocator, "\n");
    }
    const analysis_text = try sb.toOwnedSlice(allocator);
    defer allocator.free(analysis_text);
    try state.session.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = analysis_text });

    var params_arena = std.heap.ArenaAllocator.init(allocator);
    defer params_arena.deinit();
    const review_tools = [_][]const u8{ "read", "glob", "grep", "webfetch", "snapshot" };
    const tools = try processor.buildToolDefsFiltered(allocator, params_arena.allocator(), &review_tools);
    defer {
        for (tools) |*t| t.deinit(allocator);
        allocator.free(tools);
    }

    var md_renderer: ?markdown.MdRenderer = null;
    const on_token: ?llm.OnToken = if (!state.raw and !state.format_json) blk: {
        md_renderer = markdown.MdRenderer.init(allocator, cmd.writer);
        break :blk llm.OnToken{ .context = @ptrCast(&md_renderer.?), .callback = mdOnTokenFeed };
    } else null;
    defer if (md_renderer) |*r| r.deinit();

    var provider = llm.Provider.init(allocator, cmd.io, state.resolved.prov_cfg, state.resolved.api_key);
    const reader = if (state.skip_perms) null else cmd.reader;
    var sa_ctx = SubAgentCtx{ .writer = cmd.writer };
    const result = processor.processTurnWithTools(allocator, cmd.io, &provider, &state.session, state.resolved.model_id, state.skip_perms, state.format_json, on_token, false, cmd.writer, reader, state.temperature, state.max_tokens, state.top_p, state.variant, tools, &.{}, sa_ctx.callback(), 25) catch |err| {
        if (err == error.LlmError) {
            try cmd.writer.print("\n\x1b[31mError:\x1b[0m API request failed (rate limited or server error). Try again later.\n", .{});
            return;
        }
        return err;
    };
    defer result.deinit(allocator);

    if (md_renderer) |*r| try r.flush();
    try saveAndShare(cmd, allocator, &state.session, state.format_json);
}

pub fn editExec(cmd: *cli.Cmd) !void {
    const allocator = cmd.allocator;
    var state = try setupExec(cmd, "edit", "edit");
    defer state.deinit(allocator);

    try printBanner(cmd.writer, state.mode, state.resolved.model_id, state.format_json);

    var params_arena = std.heap.ArenaAllocator.init(allocator);
    defer params_arena.deinit();
    const edit_tools = [_][]const u8{ "read", "write", "editFile", "glob", "grep" };
    const tools = try processor.buildToolDefsFiltered(allocator, params_arena.allocator(), &edit_tools);
    defer {
        for (tools) |*t| t.deinit(allocator);
        allocator.free(tools);
    }

    var md_renderer: ?markdown.MdRenderer = null;
    const on_token: ?llm.OnToken = if (!state.raw and !state.format_json) blk: {
        md_renderer = markdown.MdRenderer.init(allocator, cmd.writer);
        break :blk llm.OnToken{ .context = @ptrCast(&md_renderer.?), .callback = mdOnTokenFeed };
    } else null;
    defer if (md_renderer) |*r| r.deinit();

    var provider = llm.Provider.init(allocator, cmd.io, state.resolved.prov_cfg, state.resolved.api_key);
    const reader = if (state.skip_perms) null else cmd.reader;
    var sa_ctx = SubAgentCtx{ .writer = cmd.writer };
    const result = processor.processTurnWithTools(allocator, cmd.io, &provider, &state.session, state.resolved.model_id, state.skip_perms, state.format_json, on_token, false, cmd.writer, reader, state.temperature, state.max_tokens, state.top_p, state.variant, tools, &.{}, sa_ctx.callback(), 25) catch |err| {
        if (err == error.LlmError) {
            try cmd.writer.print("\n\x1b[31mError:\x1b[0m API request failed (rate limited or server error). Try again later.\n", .{});
            return;
        }
        return err;
    };
    defer result.deinit(allocator);

    if (md_renderer) |*r| try r.flush();
    try saveAndShare(cmd, allocator, &state.session, state.format_json);

    if (state.format_json) {
        try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
    }
}

pub fn runExec(cmd: *cli.Cmd) !void {
    const allocator = cmd.allocator;
    var state = try setupExec(cmd, "run", "build");
    defer state.deinit(allocator);

    const show_thinking = cmd.flag("thinking", bool);

    try printBanner(cmd.writer, state.mode, state.resolved.model_id, state.format_json);

    const command_str = cmd.flag("command", []const u8);
    if (command_str.len > 0) {
        if (try handleCommand(allocator, cmd.io, cmd.writer, &state.session, &state.resolved, &state.agent, state.config.agents, command_str, state.format_json)) |result| {
            try persistence.saveSession(cmd.io, allocator, &state.session);
            try persistence.saveLatestSession(cmd.io, allocator, state.session.id);
            if (state.format_json) {
                try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
            }
            return;
        }
    }

    var md_renderer: ?markdown.MdRenderer = null;
    const on_token: ?llm.OnToken = if (!state.raw and !state.format_json) blk: {
        md_renderer = markdown.MdRenderer.init(allocator, cmd.writer);
        break :blk llm.OnToken{ .context = @ptrCast(&md_renderer.?), .callback = mdOnTokenFeed };
    } else null;
    defer if (md_renderer) |*r| r.deinit();

    var provider = llm.Provider.init(allocator, cmd.io, state.resolved.prov_cfg, state.resolved.api_key);
    const reader = if (state.skip_perms) null else cmd.reader;
    var sa_ctx = SubAgentCtx{ .writer = cmd.writer };
    const result = processor.processTurnWithConfig(allocator, cmd.io, &provider, &state.session, state.resolved.model_id, state.skip_perms, state.format_json, on_token, show_thinking, cmd.writer, reader, state.temperature, state.max_tokens, state.top_p, state.variant, &state.config, sa_ctx.callback(), 25) catch |err| {
        if (err == error.LlmError) {
            try cmd.writer.print("\n\x1b[31mError:\x1b[0m API request failed (rate limited or server error). Try again later.\n", .{});
            return;
        }
        return err;
    };
    defer result.deinit(allocator);

    if (md_renderer) |*r| try r.flush();
    try saveAndShare(cmd, allocator, &state.session, state.format_json);

    if (state.format_json) {
        try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
    }
}

fn handleCommand(allocator: std.mem.Allocator, io: std.Io, writer: *Io.Writer, session: *session_mod.Session, resolved: *ModelResolution, agent: *agent_mod.Agent, config_agents: ?std.StringHashMap(config_mod.AgentConfig), command: []const u8, format_json: bool) !?processor.ProcessResult {
    _ = format_json;
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;

    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const cmd = if (space) |s| trimmed[1..s] else trimmed[1..];
    const args = if (space) |s| std.mem.trim(u8, trimmed[s + 1 ..], " \t\r\n") else "";

    if (std.mem.eql(u8, cmd, "model")) {
        if (args.len == 0) {
            try writer.print("Current model: {s}\n", .{resolved.model_id});
        } else {
            const slash = std.mem.indexOfScalar(u8, args, '/') orelse {
                try writer.print("Usage: /model <providerID>/<modelID>\n", .{});
                return error.InvalidModel;
            };
            allocator.free(resolved.model_id);
            resolved.model_id = try allocator.dupe(u8, args);
            allocator.free(resolved.provider_id);
            resolved.provider_id = try allocator.dupe(u8, args[0..slash]);
            allocator.free(session.model_id.?);
            session.model_id = try allocator.dupe(u8, args);
            allocator.free(session.provider_id.?);
            session.provider_id = try allocator.dupe(u8, args[0..slash]);
            try writer.print("Model set to {s}\n", .{args});
        }
        return processor.ProcessResult{ .text = "", .exit_reason = "command", .input_tokens = 0, .output_tokens = 0 };
    }

    if (std.mem.eql(u8, cmd, "agent")) {
        if (args.len == 0) {
            try writer.print("Current agent: {s}\n", .{agent.name});
        } else {
            agent.deinit(allocator);
            agent.* = try resolveAgent(allocator, io, config_agents, args);
            allocator.free(session.agent.?);
            session.agent = try allocator.dupe(u8, args);
            try writer.print("Agent set to {s}\n", .{args});
        }
        return processor.ProcessResult{ .text = "", .exit_reason = "command", .input_tokens = 0, .output_tokens = 0 };
    }

    try writer.print("Unknown command: /{s}\n", .{cmd});
    return processor.ProcessResult{ .text = "", .exit_reason = "command", .input_tokens = 0, .output_tokens = 0 };
}

// ── Session management commands ─────────────────────────────────────────────

pub fn sessionExec(cmd: *cli.Cmd) !void {
    try cmd.writer.print(
        \\Usage: agent session <subcommand>
        \\
        \\Subcommands:
        \\  list    List all saved sessions
        \\  show    Show a session by ID (requires --id)
        \\
        \\Examples:
        \\  agent session list
        \\  agent session show --id abc123
        \\
    , .{});
}

pub fn sessionListExec(cmd: *cli.Cmd) !void {
    const dir_path = persistence.sessionDir(cmd.allocator) catch |err| {
        try cmd.writer.print("Error: cannot find session directory: {}\n", .{err});
        return;
    };
    defer cmd.allocator.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(cmd.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try cmd.writer.print("(no sessions found)\n", .{});
            return;
        },
        else => {
            try cmd.writer.print("Error: cannot open sessions dir: {}\n", .{err});
            return;
        },
    };
    defer dir.close(cmd.io);

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next(cmd.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, "latest.json")) continue;
        const session_id = entry.name[0 .. entry.name.len - 5];
        try cmd.writer.print("{s}\n", .{session_id});
        count += 1;
    }
    if (count == 0) {
        try cmd.writer.print("(no sessions found)\n", .{});
    }
}

pub fn sessionShowExec(cmd: *cli.Cmd) !void {
    const id = cmd.flag("id", []const u8);
    if (id.len == 0) {
        try cmd.writer.print("Usage: agent session show --id <session-id>\n", .{});
        return;
    }
    var session = persistence.loadSession(cmd.io, cmd.allocator, id) catch |err| {
        try cmd.writer.print("Error: cannot load session '{s}': {}\n", .{ id, err });
        return;
    };
    defer session.deinit();

    try cmd.writer.print("ID: {s}\n", .{session.id});
    try cmd.writer.print("Title: {s}\n", .{session.title});
    if (session.agent) |a| try cmd.writer.print("Agent: {s}\n", .{a});
    if (session.model_id) |m| try cmd.writer.print("Model: {s}\n", .{m});
    try cmd.writer.print("Messages: {d}\n", .{session.messages.items.len});
    try cmd.writer.print("Tokens: {d} in / {d} out\n", .{ session.total_input_tokens, session.total_output_tokens });
    try cmd.writer.print("\n--- Messages ---\n", .{});
    for (session.messages.items) |msg| {
        const preview = if (msg.content.len > 80) msg.content[0..80] else msg.content;
        try cmd.writer.print("[{s}] {s}\n", .{ msg.role, preview });
    }
}

// ── Models command ──────────────────────────────────────────────────────────

pub fn modelsExec(cmd: *cli.Cmd) !void {
    const config_path = cmd.flag("config", []const u8);
    var config = if (config_path.len > 0) blk: {
        const result = config_mod.loadFile(cmd.io, cmd.allocator, config_path) catch |err| {
            try cmd.writer.print("Error: cannot load config '{s}': {}\n", .{ config_path, err });
            return;
        };
        break :blk result orelse {
            try cmd.writer.print("Error: config file '{s}' not found\n", .{config_path});
            return;
        };
    } else (config_mod.find(cmd.io, cmd.allocator, null) catch null) orelse {
        try cmd.writer.print("(default) opencode/deepseek-v4-flash-free -- set OPENCODE_API_KEY\n", .{});
        return;
    };
    defer config.deinit(cmd.allocator);

    if (config.provider) |providers| {
        var iter = providers.iterator();
        while (iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            const pcfg = entry.value_ptr.*;
            try cmd.writer.print("{s} ({s})\n  baseURL: {s}\n", .{ pid, pcfg.name, pcfg.options.baseURL });
            if (pcfg.models) |models| {
                var miter = models.iterator();
                while (miter.next()) |me| {
                    try cmd.writer.print("  - {s}\n", .{me.key_ptr.*});
                }
            }
        }
    } else {
        try cmd.writer.print("(no providers configured)\n", .{});
    }
}

// ── Config init command ─────────────────────────────────────────────────────

pub fn configInitExec(cmd: *cli.Cmd) !void {
    try wizard.run(cmd.allocator, cmd.io, cmd.writer, cmd.reader);
}

// ── Model resolution ────────────────────────────────────────────────────────

fn builtinOpencodeProvider(allocator: std.mem.Allocator, model_id: []const u8) ModelResolution {
    const prov_cfg = config_mod.ProviderConfig{
        .name = allocator.dupe(u8, "OpenCode Zen") catch unreachable,
        .npm = allocator.dupe(u8, "@ai-sdk/openai-compatible") catch unreachable,
        .options = .{
            .baseURL = allocator.dupe(u8, "https://opencode.ai/zen/v1") catch unreachable,
        },
        .models = null,
    };
    const api_key_env = std.c.getenv("OPENCODE_API_KEY");
    const api_key = if (api_key_env) |k|
        (allocator.dupe(u8, std.mem.span(k)) catch null)
    else
        null;
    return ModelResolution{
        .provider_id = allocator.dupe(u8, "opencode") catch unreachable,
        .model_id = allocator.dupe(u8, model_id) catch unreachable,
        .api_key = api_key,
        .prov_cfg = prov_cfg,
        .owned_prov_cfg = true,
    };
}

pub fn resolveModelProvider(allocator: std.mem.Allocator, config: *const config_mod.Config, model_str: []const u8) !ModelResolution {
    if (model_str.len > 0) {
        const slash = std.mem.indexOfScalar(u8, model_str, '/') orelse {
            return error.InvalidModel;
        };
        const provider_id = model_str[0..slash];
        const model_id = model_str[slash + 1 ..];

        if (std.mem.eql(u8, provider_id, "opencode")) {
            return builtinOpencodeProvider(allocator, model_id);
        }

        const providers = config.provider orelse return error.NoProviders;
        const prov_cfg_ptr = providers.get(provider_id) orelse {
            std.log.err("provider '{s}' not found in config", .{provider_id});
            return error.UnknownProvider;
        };

        const api_key = try resolveApiKey(allocator, provider_id);
        return ModelResolution{
            .provider_id = try allocator.dupe(u8, provider_id),
            .model_id = try allocator.dupe(u8, model_id),
            .api_key = api_key,
            .prov_cfg = prov_cfg_ptr,
            .owned_prov_cfg = false,
        };
    }

    if (config.provider == null or config.provider.?.count() == 0) {
        return builtinOpencodeProvider(allocator, "deepseek-v4-flash-free");
    }

    const providers = config.provider.?;
    var iter = providers.iterator();
    while (iter.next()) |entry| {
        const pid = entry.key_ptr.*;
        const pcfg = entry.value_ptr.*;
        if (pcfg.models) |models| {
            if (models.count() > 0) {
                var miter = models.iterator();
                const first = miter.next().?;
                const api_key = try resolveApiKey(allocator, pid);
                const model_id = try allocator.dupe(u8, first.key_ptr.*);
                return ModelResolution{
                    .provider_id = try allocator.dupe(u8, pid),
                    .model_id = model_id,
                    .api_key = api_key,
                    .prov_cfg = pcfg,
                    .owned_prov_cfg = false,
                };
            }
        }
    }
    return builtinOpencodeProvider(allocator, "deepseek-v4-flash-free");
}

fn resolveApiKey(allocator: std.mem.Allocator, provider_id: []const u8) !?[]const u8 {
    const env_name = try config_mod.apiKeyEnvVar(provider_id, allocator);
    defer allocator.free(env_name);
    const envz = try allocator.dupeZ(u8, env_name);
    defer allocator.free(envz);
    if (std.c.getenv(envz)) |val| {
        return try allocator.dupe(u8, std.mem.span(val));
    }
    return null;
}

fn resolveAgent(allocator: std.mem.Allocator, io: std.Io, config_agents: ?std.StringHashMap(config_mod.AgentConfig), name: []const u8) !agent_mod.Agent {
    if (name.len > 0) {
        if (config_agents) |agents| {
            if (agents.get(name)) |cfg| {
                return agent_mod.Agent{
                    .name = try allocator.dupe(u8, name),
                    .mode = .primary,
                    .description = try allocator.dupe(u8, cfg.description),
                    .system_prompt = try allocator.dupe(u8, cfg.systemPrompt),
                    .capabilities = agent_mod.CapabilitySet.full(),
                };
            }
        }
        if (agent_mod.loadAgentFiles(allocator, io)) |custom_agents| {
            defer {
                var idx: usize = 0;
                while (idx < custom_agents.len) : (idx += 1) {
                    (&custom_agents[idx]).deinit(allocator);
                }
                allocator.free(custom_agents);
            }
            for (custom_agents) |a| {
                if (std.mem.eql(u8, a.name, name)) {
                    return agent_mod.Agent{
                        .name = try allocator.dupe(u8, a.name),
                        .mode = a.mode,
                        .description = try allocator.dupe(u8, a.description),
                        .system_prompt = try allocator.dupe(u8, a.system_prompt),
                        .default_model = if (a.default_model) |m| try allocator.dupe(u8, m) else null,
                        .capabilities = a.capabilities,
                        .skills = if (a.skills.len > 0) blk: {
                            const s = try allocator.alloc(agent_mod.SkillTag, a.skills.len);
                            @memcpy(s, a.skills);
                            break :blk s;
                        } else &.{},
                    };
                }
            }
        } else |_| {}
        if (try agent_mod.getBuiltin(allocator, name)) |a| {
            return a;
        }
        std.log.err("agent '{s}' not found", .{name});
        return error.UnknownAgent;
    }
    return (try agent_mod.getBuiltin(allocator, "build")).?;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

const SubAgentCtx = struct {
    writer: *Io.Writer,
    fn onStatus(ctx: *anyopaque, _: []const u8, state: a2a_mod.TaskState, message: ?[]const u8) void {
        const self: *SubAgentCtx = @ptrCast(@alignCast(ctx));
        const prefix = switch (state) {
            .submitted => "",
            .working => "\x1b[36m…\x1b[0m ",
            .completed => "\x1b[32m✓\x1b[0m ",
            .failed, .rejected => "\x1b[31m✗\x1b[0m ",
            .cancelled => "\x1b[33m◼\x1b[0m ",
            .input_required => "\x1b[35m?\x1b[0m ",
        };
        if (message) |msg| {
            self.writer.print("{s}{s}\n", .{ prefix, msg }) catch {};
        }
    }
    fn onArtifact(ctx: *anyopaque, _: []const u8, artifact: *const a2a_mod.Artifact) void {
        const self: *SubAgentCtx = @ptrCast(@alignCast(ctx));
        if (artifact.name) |n| {
            self.writer.print("  \x1b[90m📎 {s}\x1b[0m\n", .{n}) catch {};
        }
    }
    fn onToken(ctx: *anyopaque, text: []const u8) void {
        const self: *SubAgentCtx = @ptrCast(@alignCast(ctx));
        _ = self.writer.write(text) catch {};
    }

    fn callback(self: *SubAgentCtx) a2a_mod.SubAgentCallback {
        return a2a_mod.SubAgentCallback{
            .context = @ptrCast(self),
            .onStatusChange = onStatus,
            .onArtifact = onArtifact,
            .onToken = .{ .context = @ptrCast(self), .callback = onToken },
        };
    }
};

fn readStdinPipe(reader: *Io.Reader, allocator: std.mem.Allocator) !?[]const u8 {
    if (stdinIsTty()) return null;
    var list = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer list.deinit(allocator);
    try reader.appendRemainingUnlimited(allocator, &list);
    if (list.items.len == 0) return null;
    return try allocator.dupe(u8, list.items);
}

fn stdinIsTty() bool {
    const native_os = @import("builtin").os.tag;
    if (native_os == .windows) {
        const handle = Win32Console.GetStdHandle(Win32Console.STD_INPUT_HANDLE) orelse return false;
        var mode: u32 = 0;
        return Win32Console.GetConsoleMode(handle, &mode) != 0;
    }
    return std.c.isatty(std.posix.STDIN_FILENO) != 0;
}

/// Windows console TTY detection via raw kernel32 externs.
const Win32Console = struct {
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.winapi) i32;
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
};
