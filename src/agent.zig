const std = @import("std");

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

/// List all built-in primary agent names.
pub fn listPrimary(allocator: std.mem.Allocator) ![][]const u8 {
    const names = [_][]const u8{ "build", "plan", "ask", "review", "summary", "title", "compaction" };
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

test "listPrimary: returns 7 names" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const list = try listPrimary(allocator);
    defer {
        for (list) |n| allocator.free(n);
        allocator.free(list);
    }
    try testing.expectEqual(list.len, 7);
    try testing.expectEqualStrings(list[0], "build");
}
