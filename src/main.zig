const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const llm = @import("llm.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const permission_mod = @import("permission.zig");
const tool = @import("tool.zig");
const processor = @import("processor.zig");
const persistence = @import("persistence.zig");
const context = @import("context.zig");
const share = @import("share.zig");

fn runExec(cmd: *cli.Cmd) !void {
    const message = cmd.flag("message", []const u8);
    const model_str = cmd.flag("model", []const u8);
    const agent_name = cmd.flag("agent", []const u8);
    const format = cmd.flag("format", []const u8);
    const title_flag = cmd.flag("title", []const u8);
    const project_dir = cmd.flag("dir", []const u8);
    const dangerously_skip_perms = cmd.flag("dangerously-skip-permissions", bool);
    const cont_flag = cmd.flag("continue", bool);
    const session_id = cmd.flag("session", []const u8);
    const fork_flag = cmd.flag("fork", bool);
    const variant_str = cmd.flag("variant", []const u8);
    const thinking = cmd.flag("thinking", bool);
    const max_tokens_raw = cmd.flag("max-tokens", i32);
    const temperature_str = cmd.flag("temperature", []const u8);
    const top_p_str = cmd.flag("top-p", []const u8);

    const max_tokens: ?u64 = if (max_tokens_raw > 0) @as(u64, @intCast(max_tokens_raw)) else null;
    const temperature: ?f64 = if (temperature_str.len > 0) std.fmt.parseFloat(f64, temperature_str) catch null else null;
    const top_p: ?f64 = if (top_p_str.len > 0) std.fmt.parseFloat(f64, top_p_str) catch null else null;

    const allocator = cmd.allocator;
    const format_json = std.mem.eql(u8, format, "json");

    // 1. Load config
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
    defer config.deinit(allocator);

    // 2. Resolve provider + model
    var resolved = try resolveModelProvider(allocator, &config, model_str);
    defer {
        allocator.free(resolved.provider_id);
        allocator.free(resolved.model_id);
        if (resolved.api_key) |k| allocator.free(k);
        if (resolved.owned_prov_cfg) resolved.prov_cfg.deinit(allocator);
    }

    // 3. Resolve agent
    var agent = try resolveAgent(allocator, config.agents, agent_name);
    defer agent.deinit(allocator);

    // 4. Load or create session
    var loaded_from_disk = false;
    var session = if (session_id.len > 0) blk: {
        const s = try persistence.loadSession(cmd.io, allocator, session_id);
        loaded_from_disk = true;
        break :blk s;
    } else if (cont_flag) blk: {
        if (try persistence.loadLatestSession(cmd.io, allocator)) |s| {
            loaded_from_disk = true;
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
    defer session.deinit();

    // 5. Fork: copy session under new ID
    if (fork_flag) {
        session.id = try persistence.generateId(cmd.io, allocator);
        session.slug = try allocator.dupe(u8, session.id);
    }

    // 7. Build user message from --message, positional arg, or stdin pipe
    const from_stdin = message.len == 0 and cmd.positional.items.len == 0;
    const prompt_text = if (message.len > 0) message else if (cmd.positional.items.len > 0) cmd.positional.items[0] else blk: {
        if (readStdinPipe(cmd.reader, allocator)) |p| {
            if (p) |content| break :blk content;
        } else |_| {}
        break :blk "";
    };
    defer if (from_stdin and prompt_text.len > 0) allocator.free(prompt_text);

    // Set default title from prompt if no --title given
    if (title_flag.len == 0 and prompt_text.len > 0 and !loaded_from_disk) {
        allocator.free(session.title);
        const truncated = if (prompt_text.len > 100) prompt_text[0..100] else prompt_text;
        session.title = try std.fmt.allocPrint(allocator, "Non-interactive: {s}", .{truncated});
    }

    // 8. Build context and add messages to session
    if (!loaded_from_disk) {
        const ctx_text = try context.render(cmd.io, allocator, if (project_dir.len > 0) project_dir else null);
        try session.addMessage(.{ .role = try allocator.dupe(u8, "system"), .content = ctx_text });
        try session.addMessage(.{ .role = try allocator.dupe(u8, "system"), .content = try allocator.dupe(u8, agent.system_prompt) });
    }
    if (prompt_text.len > 0) {
        try session.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, prompt_text) });
    }

    // 9. Attach files (--file / -f)
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

    // 9. Print banner
    if (!format_json) {
        const aname = session.agent orelse "default";
        try cmd.writer.print("> {s} \xc2\xb7 {s}\n", .{ aname, resolved.model_id });
        try cmd.writer.flush();
    }

    // 10. Handle --command (slash command)
    const command_str = cmd.flag("command", []const u8);
    if (command_str.len > 0) {
        if (try handleCommand(allocator, cmd.io, cmd.writer, &session, &resolved, &agent, config.agents, command_str, format_json)) |result| {
            try persistence.saveSession(cmd.io, allocator, &session);
            try persistence.saveLatestSession(cmd.io, allocator, session.id);
            if (format_json) {
                try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
            }
            return;
        }
    }

    // 11. Create provider and run processor loop
    var provider = llm.Provider.init(allocator, cmd.io, resolved.prov_cfg, resolved.api_key);
    const reader = if (dangerously_skip_perms) null else cmd.reader;
    const result = try processor.processTurn(allocator, cmd.io, &provider, &session, resolved.model_id, dangerously_skip_perms, format_json, thinking, cmd.writer, reader, temperature, max_tokens, top_p, if (variant_str.len > 0) variant_str else null);
    defer result.deinit(allocator);

    // 11b. Save session
    try persistence.saveSession(cmd.io, allocator, &session);
    try persistence.saveLatestSession(cmd.io, allocator, session.id);

    // 12. Share if requested
    const share_flag = cmd.flag("share", bool);
    if (share_flag) {
        const share_url = share.shareSession(allocator, cmd.io, session.id, session.title) catch {
            try cmd.writer.print("(sharing failed — opencode.ai may be unreachable)\n", .{});
            return;
        };
        defer allocator.free(share_url);
        if (format_json) {
            try writeJsonLine(cmd.writer, allocator, .{ .type = "share", .url = share_url });
        } else {
            try cmd.writer.print("Share: {s}\n", .{share_url});
        }
    }

    if (format_json) {
        try writeJsonLine(cmd.writer, allocator, .{ .type = "stop", .finish_reason = result.exit_reason, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens });
    }
}

const ModelResolution = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    prov_cfg: config_mod.ProviderConfig,
    /// If true, prov_cfg's strings were heap-allocated and must be freed.
    owned_prov_cfg: bool,
};

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

fn resolveModelProvider(allocator: std.mem.Allocator, config: *const config_mod.Config, model_str: []const u8) !ModelResolution {
    if (model_str.len > 0) {
        // Parse "providerID/modelID" format
        const slash = std.mem.indexOfScalar(u8, model_str, '/') orelse {
            return error.InvalidModel;
        };
        const provider_id = model_str[0..slash];
        const model_id = model_str[slash + 1 ..];

        // Built-in opencode.ai provider — no config file needed
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

    // No model specified — try opencode.ai big-pickle as default fallback
    if (config.provider == null or config.provider.?.count() == 0) {
        return builtinOpencodeProvider(allocator, "big-pickle");
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
    // Fallback to opencode.ai if no models found in config
    return builtinOpencodeProvider(allocator, "big-pickle");
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

fn resolveAgent(allocator: std.mem.Allocator, config_agents: ?std.StringHashMap(config_mod.AgentConfig), name: []const u8) !agent_mod.Agent {
    if (name.len > 0) {
        // Check config agents first
        if (config_agents) |agents| {
            if (agents.get(name)) |cfg| {
                return agent_mod.Agent{
                    .name = try allocator.dupe(u8, name),
                    .mode = .primary,
                    .description = try allocator.dupe(u8, cfg.description),
                    .system_prompt = try allocator.dupe(u8, cfg.systemPrompt),
                };
            }
        }
        // Fall back to built-in
        if (try agent_mod.getBuiltin(allocator, name)) |a| {
            return a;
        }
        std.log.err("agent '{s}' not found", .{name});
        return error.UnknownAgent;
    }
    // Default to "build" agent
    return (try agent_mod.getBuiltin(allocator, "build")).?;
}

fn readStdinPipe(reader: *Io.Reader, allocator: std.mem.Allocator) !?[]const u8 {
    const native_os = @import("builtin").os.tag;
    const stdin_fd: std.c.fd_t = if (native_os == .windows)
        std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE)
    else
        std.posix.STDIN_FILENO;
    if (std.c.isatty(stdin_fd) != 0) return null;
    var list = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer list.deinit(allocator);
    try reader.appendRemainingUnlimited(allocator, &list);
    if (list.items.len == 0) return null;
    return try allocator.dupe(u8, list.items);
}

fn writeJsonLine(writer: *Io.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .minified });
    defer allocator.free(json);
    try writer.print("{s}\n", .{json});
    try writer.flush();
}

fn handleCommand(allocator: std.mem.Allocator, io: std.Io, writer: *Io.Writer, session: *session_mod.Session, resolved: *ModelResolution, agent: *agent_mod.Agent, config_agents: ?std.StringHashMap(config_mod.AgentConfig), command: []const u8, format_json: bool) !?processor.ProcessResult {
    _ = io;
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
            agent.* = try resolveAgent(allocator, config_agents, args);
            allocator.free(session.agent.?);
            session.agent = try allocator.dupe(u8, args);
            try writer.print("Agent set to {s}\n", .{args});
        }
        return processor.ProcessResult{ .text = "", .exit_reason = "command", .input_tokens = 0, .output_tokens = 0 };
    }

    try writer.print("Unknown command: /{s}\n", .{cmd});
    return processor.ProcessResult{ .text = "", .exit_reason = "command", .input_tokens = 0, .output_tokens = 0 };
}

fn sessionExec(_: *cli.Cmd) !void {}

fn sessionListExec(cmd: *cli.Cmd) !void {
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

fn sessionShowExec(cmd: *cli.Cmd) !void {
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

fn modelsExec(cmd: *cli.Cmd) !void {
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
        try cmd.writer.print("(default) opencode/big-pickle — set OPENCODE_API_KEY\n", .{});
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var wbuf: [4096]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [4096]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    const root = try cli.Cmd.init(gpa, io, stdout, stdin, .{
        .name = "agent",
        .description = "A lightweight CLI client for OpenCode",
        .version = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 0 },
    }, struct {
        fn exec(_: *cli.Cmd) !void {}
    }.exec);

    defer {
        root.deinit();
        gpa.destroy(root);
    }

    const run_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{
        .name = "run",
        .description = "Send a prompt to an LLM and print the response",
    }, runExec);

    try run_cmd.addFlag(.{ .name = "message", .description = "The prompt message", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "model", .description = "Model to use (provider/model)", .shortcut = "m", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "agent", .description = "Agent type to use", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "dir", .description = "Project directory", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "format", .description = "Output format: default or json", .type = .String, .default_value = .{ .String = "default" } });
    try run_cmd.addFlag(.{ .name = "thinking", .description = "Show reasoning/thinking blocks", .type = .Bool, .default_value = .{ .Bool = false } });
    try run_cmd.addFlag(.{ .name = "dangerously-skip-permissions", .description = "Auto-approve all permissions (use with caution)", .type = .Bool, .default_value = .{ .Bool = false } });
    try run_cmd.addFlag(.{ .name = "title", .description = "Session title", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "variant", .description = "Model variant (reasoning effort)", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "command", .description = "Slash command to execute", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "file", .description = "File(s) to attach", .shortcut = "f", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "continue", .description = "Continue the last session", .shortcut = "c", .type = .Bool, .default_value = .{ .Bool = false } });
    try run_cmd.addFlag(.{ .name = "session", .description = "Session ID to resume", .shortcut = "s", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "fork", .description = "Fork session before continuing", .type = .Bool, .default_value = .{ .Bool = false } });
    try run_cmd.addFlag(.{ .name = "share", .description = "Create a shareable link for the session", .type = .Bool, .default_value = .{ .Bool = false } });
    try run_cmd.addFlag(.{ .name = "config", .description = "Path to agent config.jsonc", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "max-tokens", .description = "Maximum output tokens", .type = .Int, .default_value = .{ .Int = 0 } });
    try run_cmd.addFlag(.{ .name = "temperature", .description = "Sampling temperature (0.0-2.0)", .type = .String, .default_value = .{ .String = "" } });
    try run_cmd.addFlag(.{ .name = "top-p", .description = "Nucleus sampling parameter (0.0-1.0)", .type = .String, .default_value = .{ .String = "" } });

    try root.addSub(run_cmd);

    // session subcommands
    {
        const session_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{
            .name = "session",
            .description = "Manage sessions",
        }, sessionExec);

        const list_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{
            .name = "list",
            .description = "List all sessions",
        }, sessionListExec);
        try session_cmd.addSub(list_cmd);

        const show_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{
            .name = "show",
            .description = "Show a session by ID",
        }, sessionShowExec);
        try show_cmd.addFlag(.{ .name = "id", .description = "Session ID", .type = .String, .default_value = .{ .String = "" } });
        try session_cmd.addSub(show_cmd);

        try root.addSub(session_cmd);
    }

    // models command
    {
        const models_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{
            .name = "models",
            .description = "List available models from config",
        }, modelsExec);
        try models_cmd.addFlags(&[_]cli.FlagDef{
            .{ .name = "config", .type = .String, .description = "Path to config file", .default_value = .{ .String = "" } },
        });
        try root.addSub(models_cmd);
    }

    var args_iter = try std.process.Args.iterateAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    try root.execute(&args_iter);
}
