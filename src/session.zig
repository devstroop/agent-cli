const std = @import("std");
const llm = @import("llm.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    slug: []const u8,
    title: []const u8,
    agent: ?[]const u8,
    model_id: ?[]const u8,
    provider_id: ?[]const u8,
    messages: std.ArrayList(llm.Message) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    /// Skills already loaded this session (prevents re-loading same skill body)
    loaded_skills: std.StringHashMap(void) = undefined,

    pub fn init(allocator: std.mem.Allocator, opts: CreateOptions) !Session {
        const id = if (opts.id) |sid|
            try allocator.dupe(u8, sid)
        else
            try allocator.dupe(u8, "agent-session");
        const slug = try allocator.dupe(u8, opts.slug orelse "agent-session");
        const title = try allocator.dupe(u8, opts.title orelse "New session");
        return Session{
            .allocator = allocator,
            .id = id,
            .slug = slug,
            .title = title,
            .agent = if (opts.agent) |a| try allocator.dupe(u8, a) else null,
            .model_id = if (opts.model_id) |m| try allocator.dupe(u8, m) else null,
            .provider_id = if (opts.provider_id) |p| try allocator.dupe(u8, p) else null,
            .loaded_skills = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        const a = self.allocator;
        a.free(self.id);
        a.free(self.slug);
        a.free(self.title);
        if (self.agent) |v| a.free(v);
        if (self.model_id) |v| a.free(v);
        if (self.provider_id) |v| a.free(v);
        // Free loaded_skills keys (values are void, no deinit needed)
        {
            var it = self.loaded_skills.keyIterator();
            while (it.next()) |key| a.free(key.*);
            self.loaded_skills.deinit();
        }
        for (self.messages.items) |*msg| msg.deinit(a);
        self.messages.deinit(a);
    }

    pub fn addMessage(self: *Session, msg: llm.Message) !void {
        try self.messages.append(self.allocator, msg);
    }

    pub fn addToolResult(self: *Session, call_id: []const u8, output: []const u8, is_error: bool) !void {
        const prefix = if (is_error) "Error: " else "";
        const full = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, output });
        const msg = llm.Message{
            .role = try self.allocator.dupe(u8, "tool"),
            .content = full,
            .tool_call_id = try self.allocator.dupe(u8, call_id),
        };
        try self.messages.append(self.allocator, msg);
    }

    pub fn buildMessages(self: *Session, max_tokens: ?u64) []const llm.Message {
        _ = max_tokens;
        return self.messages.items;
    }

    pub fn estimatedTokens(self: *const Session) u64 {
        var total: u64 = 0;
        for (self.messages.items) |msg| {
            total += @as(u64, @intCast(msg.role.len));
            total += @as(u64, @intCast(msg.content.len));
        }
        return total / 4;
    }
};

pub const CreateOptions = struct {
    id: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    title: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
};

test "init: all fields set" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{
        .id = "test-id",
        .slug = "test-slug",
        .title = "test-title",
        .agent = "test-agent",
        .model_id = "test-model",
        .provider_id = "test-provider",
    });
    defer s.deinit();
    try testing.expectEqualStrings(s.id, "test-id");
    try testing.expectEqualStrings(s.slug, "test-slug");
    try testing.expectEqualStrings(s.title, "test-title");
    try testing.expectEqualStrings(s.agent.?, "test-agent");
    try testing.expectEqualStrings(s.model_id.?, "test-model");
    try testing.expectEqualStrings(s.provider_id.?, "test-provider");
    try testing.expectEqual(s.messages.items.len, 0);
}

test "init: defaults" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{});
    defer s.deinit();
    try testing.expect(s.agent == null);
    try testing.expect(s.model_id == null);
    try testing.expect(s.provider_id == null);
    try testing.expectEqualStrings(s.title, "New session");
}

test "addMessage: appends and deinit cleans up" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{});
    defer s.deinit();
    try s.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "hello") });
    try s.addMessage(.{ .role = try allocator.dupe(u8, "assistant"), .content = try allocator.dupe(u8, "hi") });
    try testing.expectEqual(s.messages.items.len, 2);
    try testing.expectEqualStrings(s.messages.items[0].content, "hello");
    try testing.expectEqualStrings(s.messages.items[1].content, "hi");
}

test "addToolResult: formats output" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{});
    defer s.deinit();
    try s.addToolResult("call_1", "ls output", false);
    try testing.expectEqual(s.messages.items.len, 1);
    try testing.expectEqualStrings(s.messages.items[0].role, "tool");
    try testing.expectEqualStrings(s.messages.items[0].content, "ls output");
    try testing.expectEqualStrings(s.messages.items[0].tool_call_id.?, "call_1");
}

test "addToolResult: formats error" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{});
    defer s.deinit();
    try s.addToolResult("call_2", "command not found", true);
    try testing.expectEqualStrings(s.messages.items[0].content, "Error: command not found");
}

test "estimatedTokens: basic" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var s = try Session.init(allocator, .{});
    defer s.deinit();
    try s.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "four") });
    // role="user" (4) + content="four" (4) = 8 bytes / 4 = 2 tokens
    try testing.expectEqual(s.estimatedTokens(), 2);
}
