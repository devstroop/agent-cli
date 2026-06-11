const std = @import("std");
const config_mod = @import("config.zig");

/// Known provider presets for quick setup.
const ProviderPreset = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    env_var: []const u8,
    models: []const ModelPreset,
};

const ModelPreset = struct {
    id: []const u8,
    name: []const u8,
};

const PRESETS = [_]ProviderPreset{
    .{
        .id = "opencode",
        .name = "OpenCode Zen (free tier)",
        .base_url = "https://opencode.ai/zen/v1",
        .env_var = "OPENCODE_API_KEY",
        .models = &.{
            .{ .id = "deepseek-v4-flash-free", .name = "DeepSeek V4 Flash (free)" },
            .{ .id = "big-pickle", .name = "Big Pickle" },
            .{ .id = "gpt-5-mini", .name = "GPT-5 Mini" },
        },
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .env_var = "OPENAI_API_KEY",
        .models = &.{
            .{ .id = "gpt-4o", .name = "GPT-4o" },
            .{ .id = "gpt-4o-mini", .name = "GPT-4o Mini" },
        },
    },
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .env_var = "ANTHROPIC_API_KEY",
        .models = &.{
            .{ .id = "claude-sonnet-4-20250514", .name = "Claude Sonnet 4" },
            .{ .id = "claude-haiku-3-5-20250514", .name = "Claude Haiku 3.5" },
        },
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .env_var = "DEEPSEEK_API_KEY",
        .models = &.{
            .{ .id = "deepseek-v4-flash", .name = "DeepSeek V4 Flash" },
            .{ .id = "deepseek-v4", .name = "DeepSeek V4" },
        },
    },
};

/// Read a trimmed line from the reader. Returns "" on EOF.
fn promptLine(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]const u8 {
    const raw = (try reader.takeDelimiter('\n')) orelse return "";
    // trim trailing \r if present (Windows line endings)
    const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    return try allocator.dupe(u8, trimmed);
}

/// Write the generated config to ~/.config/agent/config.jsonc.
/// Creates the directory if it doesn't exist.
fn writeConfig(allocator: std.mem.Allocator, io: std.Io, jsonc: []const u8) !void {
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    const home_span = std.mem.span(home);

    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/agent", .{home_span});
    defer allocator.free(config_dir);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, config_dir);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.jsonc", .{config_dir});
    defer allocator.free(config_path);

    try cwd.writeFile(io, .{ .sub_path = config_path, .data = jsonc });
}

/// Interactive config wizard. Walks the user through provider, API key, and model setup.
pub fn run(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, reader: *std.Io.Reader) !void {
    try writer.print("\n\x1b[1m\x1b[96m⚡ Agent Config Wizard\x1b[0m\n\n", .{});

    // Check for existing config
    const home = std.c.getenv("HOME") orelse {
        try writer.print("\x1b[31mError: HOME not set\x1b[0m\n", .{});
        return error.NoHome;
    };
    const home_span = std.mem.span(home);

    const existing_path = try std.fmt.allocPrint(allocator, "{s}/.config/agent/config.jsonc", .{home_span});
    defer allocator.free(existing_path);

    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, existing_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |content| {
        allocator.free(content);
        try writer.print("\x1b[33m⚠  Existing config found at ~/.config/agent/config.jsonc\x1b[0m\n", .{});
        try writer.print("Overwrite? [y/N]: ", .{});
        try writer.flush();
        const answer = try promptLine(reader, allocator);
        defer allocator.free(answer);
        if (!std.mem.eql(u8, answer, "y") and !std.mem.eql(u8, answer, "Y") and !std.mem.eql(u8, answer, "yes")) {
            try writer.print("Aborted.\n", .{});
            return;
        }
    }

    // ── Provider selection ──
    try writer.print("\n\x1b[1mProviders:\x1b[0m\n", .{});
    for (PRESETS, 0..) |p, i| {
        try writer.print("  {d}. {s}\n", .{ i + 1, p.name });
    }
    try writer.print("  {d}. Custom (enter base URL)\n", .{PRESETS.len + 1});

    try writer.print("\nSelect provider [1-{d}]: ", .{PRESETS.len + 1});
    try writer.flush();

    const raw_choice = try promptLine(reader, allocator);
    defer allocator.free(raw_choice);
    const choice = std.fmt.parseInt(usize, raw_choice, 10) catch 0;

    if (choice == 0 or choice > PRESETS.len + 1) {
        try writer.print("\x1b[31mInvalid choice. Aborting.\x1b[0m\n", .{});
        return error.InvalidInput;
    }

    const is_custom = choice == PRESETS.len + 1;
    var provider_id: []const u8 = "";
    var base_url: []const u8 = "";
    var env_var: []const u8 = "";
    var models: []const ModelPreset = &.{};

    if (!is_custom) {
        const preset = PRESETS[choice - 1];
        provider_id = try allocator.dupe(u8, preset.id);
        base_url = try allocator.dupe(u8, preset.base_url);
        env_var = try allocator.dupe(u8, preset.env_var);
        models = preset.models;
    } else {
        try writer.print("Provider ID (e.g. 'my-llm'): ", .{});
        try writer.flush();
        provider_id = try promptLine(reader, allocator);
        if (provider_id.len == 0) {
            try writer.print("\x1b[31mProvider ID required. Aborting.\x1b[0m\n", .{});
            return error.InvalidInput;
        }

        try writer.print("Base URL (e.g. 'https://api.example.com/v1'): ", .{});
        try writer.flush();
        base_url = try promptLine(reader, allocator);
        if (base_url.len == 0) {
            try writer.print("\x1b[31mBase URL required. Aborting.\x1b[0m\n", .{});
            return error.InvalidInput;
        }

        env_var = try config_mod.apiKeyEnvVar(provider_id, allocator);
    }
    defer {
        if (provider_id.len > 0) allocator.free(provider_id);
        if (base_url.len > 0) allocator.free(base_url);
        if (env_var.len > 0) allocator.free(env_var);
    }

    // ── API key ──
    const envz = try allocator.dupeZ(u8, env_var);
    defer allocator.free(envz);
    var api_key: []const u8 = "";

    if (std.c.getenv(envz)) |val| {
        try writer.print("\n\x1b[32m✓ Found {s} in environment\x1b[0m\n", .{env_var});
        api_key = try allocator.dupe(u8, std.mem.span(val));
    } else {
        try writer.print("\n{s} not set in environment.\n", .{env_var});
        try writer.print("Enter API key (or press Enter to skip, set later): ", .{});
        try writer.flush();
        api_key = try promptLine(reader, allocator);
    }
    defer if (api_key.len > 0) allocator.free(api_key);

    // ── Model selection ──
    var model_id: []const u8 = "";
    if (models.len > 0) {
        try writer.print("\n\x1b[1mAvailable models for {s}:\x1b[0m\n", .{provider_id});
        for (models, 0..) |m, i| {
            try writer.print("  {d}. {s} ({s})\n", .{ i + 1, m.name, m.id });
        }
        try writer.print("  {d}. Enter custom model ID\n", .{models.len + 1});

        try writer.print("\nSelect default model [1-{d}]: ", .{models.len + 1});
        try writer.flush();

        const m_choice_raw = try promptLine(reader, allocator);
        defer allocator.free(m_choice_raw);
        const m_choice = std.fmt.parseInt(usize, m_choice_raw, 10) catch 0;

        if (m_choice == 0 or m_choice > models.len + 1) {
            try writer.print("\x1b[31mInvalid choice. Aborting.\x1b[0m\n", .{});
            return error.InvalidInput;
        }

        if (m_choice <= models.len) {
            model_id = try allocator.dupe(u8, models[m_choice - 1].id);
        } else {
            try writer.print("Model ID: ", .{});
            try writer.flush();
            model_id = try promptLine(reader, allocator);
            if (model_id.len == 0) {
                try writer.print("\x1b[31mModel ID required. Aborting.\x1b[0m\n", .{});
                return error.InvalidInput;
            }
        }
    } else {
        try writer.print("\nEnter default model ID: ", .{});
        try writer.flush();
        model_id = try promptLine(reader, allocator);
        if (model_id.len == 0) {
            try writer.print("\x1b[31mModel ID required. Aborting.\x1b[0m\n", .{});
            return error.InvalidInput;
        }
    }
    defer if (model_id.len > 0) allocator.free(model_id);

    // ── Generate config ──
    const jsonc = try std.fmt.allocPrint(allocator,
        \\// Agent CLI configuration
        \\// Generated by: agent config init
        \\// See README.md for full documentation.
        \\
        \\{{
        \\  "provider": {{
        \\    "{s}": {{
        \\      "name": "{s}",
        \\      "options": {{
        \\        "baseURL": "{s}"
        \\      }},
        \\      "models": {{
        \\        "{s}": {{
        \\          "id": "{s}",
        \\          "name": "{s}"
        \\        }}
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ provider_id, provider_id, base_url, model_id, model_id, model_id });
    defer allocator.free(jsonc);

    // ── Write file ──
    try writeConfig(allocator, io, jsonc);

    try writer.print("\n\x1b[32m\x1b[1m✓ Config written to ~/.config/agent/config.jsonc\x1b[0m\n", .{});
    try writer.print("  Provider: \x1b[1m{s}\x1b[0m\n", .{provider_id});
    try writer.print("  Model:    \x1b[1m{s}/{s}\x1b[0m\n", .{ provider_id, model_id });

    if (api_key.len == 0) {
        try writer.print("\n\x1b[33m⚠  Set {s} in your environment to authenticate.\x1b[0m\n", .{env_var});
    }

    try writer.print("\nTry it: \x1b[1magent run --message \"Hello!\"\x1b[0m\n\n", .{});
}
