const std = @import("std");
const tool = @import("tool.zig");

/// Built-in agent definitions.
pub const Mode = enum {
    primary,
    subagent,
};

pub const Agent = struct {
    name: []const u8,
    mode: Mode,
    description: []const u8,
    system_prompt: []const u8,
    /// Default model (providerID/modelID) if not overridden.
    default_model: ?[]const u8 = null,

    pub fn deinit(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.system_prompt);
        if (self.default_model) |m| allocator.free(m);
    }
};

/// Case-insensitive substring check.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Detect model family from a model ID string (case-insensitive).
pub fn detectModelFamily(model_id: []const u8) []const u8 {
    if (containsIgnoreCase(model_id, "claude")) return "claude";
    if (containsIgnoreCase(model_id, "anthropic")) return "claude";
    if (containsIgnoreCase(model_id, "gpt")) return "openai";
    if (containsIgnoreCase(model_id, "o1")) return "openai";
    if (containsIgnoreCase(model_id, "o3")) return "openai";
    if (containsIgnoreCase(model_id, "gemini")) return "gemini";
    return "default";
}

/// Get model-family-specific additions to a system prompt.
pub fn modelFamilySuffix(model_family: []const u8) []const u8 {
    if (std.mem.eql(u8, model_family, "claude")) {
        return " You operate in an agentic loop with tool calls. Think step by step before each tool use.";
    }
    if (std.mem.eql(u8, model_family, "openai")) {
        return " You have access to a set of tools. When you need information or want to perform actions, call the appropriate tool.";
    }
    if (std.mem.eql(u8, model_family, "gemini")) {
        return " You can use tools to help complete tasks. Be thorough and methodical in your approach.";
    }
    return "";
}

/// Get the system prompt for a built-in agent.
fn systemPrompt(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "build")) {
        return "You are a helpful assistant that can execute tasks. When asked to perform actions, use the available tools to complete them. Be concise and direct in your responses.";
    }
    if (std.mem.eql(u8, name, "plan")) {
        return "You are a planning assistant. Break down complex tasks into clear, actionable steps. Focus on creating efficient and thorough plans. Your response should be a structured plan that can be saved as PLAN.md.";
    }
    if (std.mem.eql(u8, name, "review")) {
        return "You are a review assistant. Analyze the given conversation history and provide a concise assessment. Focus on: what was accomplished, what decisions were made, what issues remain, and any suggestions for improvement.";
    }
    if (std.mem.eql(u8, name, "ask")) {
        return "You are a helpful assistant. Answer questions directly and concisely. You do not have access to tools — respond with your knowledge alone.";
    }
    if (std.mem.eql(u8, name, "edit")) {
        return "You are an editing assistant. You have access to read, write, editFile, glob, and grep tools. Make targeted, precise edits to files. You do NOT have access to bash, web search, or MCP tools. Focus on the specific file(s) the user asked you to modify.";
    }
    if (std.mem.eql(u8, name, "summary")) {
        return "You are a summarization assistant. Provide clear, concise summaries of the given content, capturing key points and decisions.";
    }
    if (std.mem.eql(u8, name, "title")) {
        return "Generate a short, descriptive title (max 50 characters) for the following conversation or content.";
    }
    if (std.mem.eql(u8, name, "compaction")) {
        return "You are a context compaction assistant. Compress the given conversation history into a concise summary, preserving all important context and decisions.";
    }
    return "You are a helpful assistant.";
}

/// Look up a built-in agent definition.
pub fn getBuiltin(allocator: std.mem.Allocator, name: []const u8) !?Agent {
    const agents = comptime [_]struct { name: []const u8, mode: Mode, desc: []const u8 }{
        .{ .name = "build", .mode = .primary, .desc = "The default agent. Executes tools based on configured permissions." },
        .{ .name = "plan", .mode = .primary, .desc = "Planning agent for breaking down tasks." },
        .{ .name = "ask", .mode = .primary, .desc = "Quick answer agent — no tools, just knowledge." },
        .{ .name = "edit", .mode = .primary, .desc = "Editing agent — read/write/search tools, no bash/MCP/web." },
        .{ .name = "review", .mode = .primary, .desc = "Review agent for analyzing sessions and providing assessment." },
        .{ .name = "summary", .mode = .primary, .desc = "Summarization agent." },
        .{ .name = "title", .mode = .primary, .desc = "Title generation agent." },
        .{ .name = "compaction", .mode = .primary, .desc = "Context compaction agent." },
        .{ .name = "explore", .mode = .subagent, .desc = "Codebase exploration agent." },
        .{ .name = "general", .mode = .subagent, .desc = "General-purpose subagent." },
    };

    inline for (agents) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            return Agent{
                .name = try allocator.dupe(u8, a.name),
                .mode = a.mode,
                .description = try allocator.dupe(u8, a.desc),
                .system_prompt = try allocator.dupe(u8, comptime systemPrompt(a.name)),
            };
        }
    }
    return null;
}

const AgentFrontmatter = struct {
    name: []const u8,
    description: []const u8,
    mode: []const u8, // "primary" or "subagent"
};

/// Parse YAML frontmatter from markdown content.
/// Returns null if no frontmatter found.
fn parseFrontmatter(content: []const u8) ?AgentFrontmatter {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;
    const end_marker = std.mem.indexOf(u8, content[4..], "\n---") orelse return null;
    const yaml_block = content[4 .. 4 + end_marker];

    var fm = AgentFrontmatter{ .name = "", .description = "", .mode = "primary" };
    var lines = std.mem.splitScalar(u8, yaml_block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            fm.name = std.mem.trim(u8, trimmed["name:".len..], " \t\"");
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            fm.description = std.mem.trim(u8, trimmed["description:".len..], " \t\"");
        } else if (std.mem.startsWith(u8, trimmed, "mode:")) {
            fm.mode = std.mem.trim(u8, trimmed["mode:".len..], " \t\"");
        }
    }

    if (fm.name.len == 0) return null;
    return fm;
}

/// Load custom agents from .agent/custom/*.md files.
pub fn loadAgentFiles(allocator: std.mem.Allocator, io: std.Io) ![]Agent {
    const dir = ".agent/custom";
    const cmd = try std.fmt.allocPrint(allocator, "ls -1 '{s}'/*.md 2>/dev/null", .{dir});
    defer allocator.free(cmd);

    const ls_result = tool.bash(allocator, io, cmd) catch return &.{};
    defer ls_result.deinit(allocator);

    const trimmed_out = std.mem.trim(u8, ls_result.stdout, " \t\r\n");
    if (trimmed_out.len == 0) return &.{};

    var agents = std.ArrayList(Agent).initCapacity(allocator, 8) catch unreachable;
    var lines = std.mem.splitScalar(u8, trimmed_out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, line, allocator, std.Io.Limit.limited(65536)) catch continue;
        defer allocator.free(content);

        const fm = parseFrontmatter(content) orelse continue;

        const body_start = if (std.mem.indexOf(u8, content, "\n---")) |idx| blk: {
            const rest = content[idx + 4 ..];
            break :blk if (std.mem.startsWith(u8, rest, "\n")) rest[1..] else rest;
        } else content;

        const mode: Mode = if (std.mem.eql(u8, fm.mode, "subagent")) .subagent else .primary;
        try agents.append(allocator, .{
            .name = try allocator.dupe(u8, fm.name),
            .mode = mode,
            .description = try allocator.dupe(u8, fm.description),
            .system_prompt = try allocator.dupe(u8, std.mem.trim(u8, body_start, " \t\r\n")),
        });
    }
    return agents.toOwnedSlice(allocator);
}

/// List all built-in primary agent names.
pub fn listPrimary(allocator: std.mem.Allocator) ![][]const u8 {
    const names = [_][]const u8{ "build", "plan", "ask", "edit", "review", "summary", "title", "compaction" };
    var result = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |n, i| {
        result[i] = try allocator.dupe(u8, n);
    }
    return result;
}

test "getBuiltin: found" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const agent = (try getBuiltin(allocator, "build")).?;
    defer agent.deinit(allocator);
    try testing.expectEqualStrings(agent.name, "build");
    try testing.expectEqual(agent.mode, .primary);
    try testing.expect(agent.system_prompt.len > 0);
}

test "getBuiltin: not found returns null" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const agent = try getBuiltin(allocator, "nonexistent");
    try testing.expect(agent == null);
}

test "getBuiltin: all agents" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const names = [_][]const u8{ "build", "plan", "summary", "title", "compaction", "explore", "general" };
    for (names) |name| {
        const agent = (try getBuiltin(allocator, name)).?;
        defer agent.deinit(allocator);
        try testing.expectEqualStrings(agent.name, name);
    }
}

test "detectModelFamily: claude detection" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(detectModelFamily("anthropic/claude-sonnet-4-20250514"), "claude");
    try testing.expectEqualStrings(detectModelFamily("claude-3-opus-20240229"), "claude");
    try testing.expectEqualStrings(detectModelFamily("Claude-Opus"), "claude");
}

test "detectModelFamily: openai detection" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(detectModelFamily("openai/gpt-4o"), "openai");
    try testing.expectEqualStrings(detectModelFamily("gpt-4.1"), "openai");
    try testing.expectEqualStrings(detectModelFamily("o1-mini"), "openai");
}

test "detectModelFamily: gemini detection" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(detectModelFamily("google/gemini-2.0-flash"), "gemini");
    try testing.expectEqualStrings(detectModelFamily("Gemini-Pro"), "gemini");
}

test "detectModelFamily: default for unknown" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(detectModelFamily("unknown-model"), "default");
    try testing.expectEqualStrings(detectModelFamily(""), "default");
}

test "modelFamilySuffix: claude" {
    const testing = @import("std").testing;
    const suff = modelFamilySuffix("claude");
    try testing.expect(suff.len > 0);
    try testing.expect(std.mem.indexOf(u8, suff, "agentic") != null);
}

test "modelFamilySuffix: default returns empty" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(modelFamilySuffix("default"), "");
    try testing.expectEqualStrings(modelFamilySuffix("unknown"), "");
}

test "containsIgnoreCase: basic" {
    const testing = @import("std").testing;
    try testing.expect(containsIgnoreCase("Hello World", "hello"));
    try testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try testing.expect(!containsIgnoreCase("Hello World", "xyz"));
    try testing.expect(containsIgnoreCase("Claude-Opus", "claude"));
}

test "listPrimary: returns 8 names" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const list = try listPrimary(allocator);
    defer {
        for (list) |n| allocator.free(n);
        allocator.free(list);
    }
    try testing.expectEqual(list.len, 8);
    try testing.expectEqualStrings(list[0], "build");
}
