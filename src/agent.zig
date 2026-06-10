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

/// Get the system prompt for a built-in agent.
fn systemPrompt(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "build")) {
        return "You are a helpful assistant that can execute tasks. When asked to perform actions, use the available tools to complete them. Be concise and direct in your responses.";
    }
    if (std.mem.eql(u8, name, "plan")) {
        return "You are a planning assistant. Break down complex tasks into clear, actionable steps. Focus on creating efficient and thorough plans.";
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
    const names = [_][]const u8{ "build", "plan", "summary", "title", "compaction" };
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

test "listPrimary: returns 5 names" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const list = try listPrimary(allocator);
    defer {
        for (list) |n| allocator.free(n);
        allocator.free(list);
    }
    try testing.expectEqual(list.len, 5);
    try testing.expectEqualStrings(list[0], "build");
}
