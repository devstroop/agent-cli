const std = @import("std");
const json = std.json;
const session_mod = @import("session.zig");
const llm = @import("llm.zig");

const SESSION_DIR_REL = ".config/agent/sessions";

pub fn sessionDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.span(home), SESSION_DIR_REL });
}

fn sessionFilePath(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, id });
}

fn latestFilePath(allocator: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/latest.json", .{dir});
}

pub fn generateId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    return std.fmt.allocPrint(allocator, "{d}", .{@as(u64, @intCast(ts.nanoseconds))});
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);
}

pub fn saveSession(io: std.Io, allocator: std.mem.Allocator, session: *const session_mod.Session) !void {
    const dir_path = try sessionDir(allocator);
    defer allocator.free(dir_path);
    try ensureDir(io, dir_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ja = arena.allocator();

    var root = try json.ObjectMap.init(ja, &.{}, &.{});
    try root.put(ja, "id", .{ .string = session.id });
    try root.put(ja, "title", .{ .string = session.title });
    if (session.agent) |a| try root.put(ja, "agent", .{ .string = a });

    var model_obj = try json.ObjectMap.init(ja, &.{}, &.{});
    if (session.provider_id) |pid| try model_obj.put(ja, "providerID", .{ .string = pid });
    if (session.model_id) |mid| try model_obj.put(ja, "id", .{ .string = mid });
    try root.put(ja, "model", .{ .object = model_obj });

    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    try root.put(ja, "created", .{ .integer = now });
    try root.put(ja, "updated", .{ .integer = now });

    var msgs_arr = json.Array.init(ja);
    for (session.messages.items) |msg| {
        var msg_obj = try json.ObjectMap.init(ja, &.{}, &.{});
        try msg_obj.put(ja, "role", .{ .string = msg.role });
        try msg_obj.put(ja, "content", .{ .string = msg.content });
        if (msg.tool_call_id) |tcid| {
            try msg_obj.put(ja, "tool_call_id", .{ .string = tcid });
        }
        if (msg.tool_calls) |tcs| {
            var tc_arr = json.Array.init(ja);
            for (tcs) |tc| {
                var tc_obj = try json.ObjectMap.init(ja, &.{}, &.{});
                try tc_obj.put(ja, "id", .{ .string = tc.id });
                try tc_obj.put(ja, "type", .{ .string = "function" });
                var func_obj = try json.ObjectMap.init(ja, &.{}, &.{});
                try func_obj.put(ja, "name", .{ .string = tc.name });
                try func_obj.put(ja, "arguments", .{ .string = tc.arguments });
                try tc_obj.put(ja, "function", .{ .object = func_obj });
                try tc_arr.append(.{ .object = tc_obj });
            }
            try msg_obj.put(ja, "tool_calls", .{ .array = tc_arr });
        }
        try msgs_arr.append(.{ .object = msg_obj });
    }
    try root.put(ja, "messages", .{ .array = msgs_arr });

    var tokens_obj = try json.ObjectMap.init(ja, &.{}, &.{});
    try tokens_obj.put(ja, "input", .{ .integer = @as(i64, @intCast(session.total_input_tokens)) });
    try tokens_obj.put(ja, "output", .{ .integer = @as(i64, @intCast(session.total_output_tokens)) });
    try root.put(ja, "tokens", .{ .object = tokens_obj });

    const json_val = json.Value{ .object = root };
    const json_str = try json.Stringify.valueAlloc(allocator, json_val, .{ .whitespace = .minified });
    defer allocator.free(json_str);

    const file_path = try sessionFilePath(allocator, dir_path, session.id);
    defer allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = file_path, .data = json_str });
}

pub fn loadSession(io: std.Io, allocator: std.mem.Allocator, id: []const u8) !session_mod.Session {
    const dir_path = try sessionDir(allocator);
    defer allocator.free(dir_path);

    const file_path = try sessionFilePath(allocator, dir_path, id);
    defer allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(content);

    return parseSession(allocator, content);
}

pub fn loadLatestSession(io: std.Io, allocator: std.mem.Allocator) !?session_mod.Session {
    const dir_path = try sessionDir(allocator);
    defer allocator.free(dir_path);

    const lpath = try latestFilePath(allocator, dir_path);
    defer allocator.free(lpath);

    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, lpath, allocator, std.Io.Limit.limited(65536)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const last_id = root.object.get("session_id") orelse return null;
    if (last_id != .string) return null;

    return try loadSession(io, allocator, last_id.string);
}

pub fn saveLatestSession(io: std.Io, allocator: std.mem.Allocator, id: []const u8) !void {
    const dir_path = try sessionDir(allocator);
    defer allocator.free(dir_path);
    try ensureDir(io, dir_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ja = arena.allocator();

    var root = try json.ObjectMap.init(ja, &.{}, &.{});
    try root.put(ja, "session_id", .{ .string = id });
    try root.put(ja, "updated", .{ .integer = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000))) });

    const json_val = json.Value{ .object = root };
    const json_str = try json.Stringify.valueAlloc(allocator, json_val, .{ .whitespace = .minified });
    defer allocator.free(json_str);

    const lpath = try latestFilePath(allocator, dir_path);
    defer allocator.free(lpath);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = lpath, .data = json_str });
}

fn parseSession(allocator: std.mem.Allocator, content: []const u8) !session_mod.Session {
    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidSession;

    const obj = root.object;

    const id = try allocator.dupe(u8, getString(obj, "id") orelse return error.InvalidSession);
    const title = try allocator.dupe(u8, getString(obj, "title") orelse "New session");
    const agent = if (getString(obj, "agent")) |a| try allocator.dupe(u8, a) else null;

    var provider_id: ?[]const u8 = null;
    var model_id: ?[]const u8 = null;
    if (obj.get("model")) |m| {
        if (m == .object) {
            provider_id = if (getString(m.object, "providerID")) |p| try allocator.dupe(u8, p) else null;
            model_id = if (getString(m.object, "id")) |mid| try allocator.dupe(u8, mid) else null;
        }
    }

    var messages = try std.ArrayList(llm.Message).initCapacity(allocator, 0);
    errdefer {
        for (messages.items) |*msg| msg.deinit(allocator);
        messages.deinit(allocator);
    }

    if (obj.get("messages")) |msgs_val| {
        if (msgs_val == .array) {
            for (msgs_val.array.items) |item| {
                if (item != .object) continue;
                const mo = item.object;
                const role = try allocator.dupe(u8, getString(mo, "role") orelse "user");
                const content_str = try allocator.dupe(u8, getString(mo, "content") orelse "");

                var tool_calls: ?[]llm.ToolCall = null;
                if (mo.get("tool_calls")) |tcs_val| {
                    if (tcs_val == .array and tcs_val.array.items.len > 0) {
                        const tcs = try allocator.alloc(llm.ToolCall, tcs_val.array.items.len);
                        for (tcs_val.array.items, 0..) |tc_item, i| {
                            if (tc_item != .object) {
                                for (0..i) |j| tcs[j].deinit(allocator);
                                allocator.free(tcs);
                                return error.InvalidSession;
                            }
                            const tc_obj = tc_item.object;
                            const func_val = tc_obj.get("function") orelse return error.InvalidSession;
                            if (func_val != .object) return error.InvalidSession;
                            const func_obj = func_val.object;
                            tcs[i] = .{
                                .id = try allocator.dupe(u8, getString(tc_obj, "id") orelse ""),
                                .name = try allocator.dupe(u8, getString(func_obj, "name") orelse ""),
                                .arguments = try allocator.dupe(u8, getString(func_obj, "arguments") orelse ""),
                            };
                        }
                        tool_calls = tcs;
                    }
                }

                const tool_call_id = if (getString(mo, "tool_call_id")) |tcid| try allocator.dupe(u8, tcid) else null;

                try messages.append(allocator, .{
                    .role = role,
                    .content = content_str,
                    .tool_calls = tool_calls,
                    .tool_call_id = tool_call_id,
                });
            }
        }
    }

    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    if (obj.get("tokens")) |tokens_val| {
        if (tokens_val == .object) {
            if (tokens_val.object.get("input")) |v| {
                if (v == .integer) total_input_tokens = @intCast(@as(u64, @intCast(v.integer)));
            }
            if (tokens_val.object.get("output")) |v| {
                if (v == .integer) total_output_tokens = @intCast(@as(u64, @intCast(v.integer)));
            }
        }
    }

    return session_mod.Session{
        .allocator = allocator,
        .id = id,
        .slug = try allocator.dupe(u8, id),
        .title = title,
        .agent = agent,
        .model_id = model_id,
        .provider_id = provider_id,
        .messages = messages,
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
    };
}

fn getString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

test "parseSession round-trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{
        \\  "id": "test-123",
        \\  "title": "Test Session",
        \\  "agent": "build",
        \\  "model": { "providerID": "opencode", "id": "deepseek-v4-flash-free" },
        \\  "created": 1718000000,
        \\  "updated": 1718000500,
        \\  "messages": [
        \\    { "role": "system", "content": "You are a helpful assistant." },
        \\    { "role": "user", "content": "Hello!" },
        \\    { "role": "assistant", "content": "", "tool_calls": [{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}] },
        \\    { "role": "tool", "content": "file1.txt", "tool_call_id": "call_1" }
        \\  ],
        \\  "tokens": { "input": 100, "output": 50 }
        \\}
    ;

    const session = try parseSession(allocator, json_text);
    defer session.deinit();

    try testing.expectEqualStrings(session.id, "test-123");
    try testing.expectEqualStrings(session.title, "Test Session");
    try testing.expectEqualStrings(session.agent.?, "build");
    try testing.expectEqualStrings(session.provider_id.?, "opencode");
    try testing.expectEqualStrings(session.model_id.?, "deepseek-v4-flash-free");
    try testing.expectEqual(session.messages.items.len, 4);
    try testing.expectEqualStrings(session.messages.items[0].role, "system");
    try testing.expectEqualStrings(session.messages.items[0].content, "You are a helpful assistant.");
    try testing.expectEqualStrings(session.messages.items[1].role, "user");
    try testing.expectEqualStrings(session.messages.items[1].content, "Hello!");
    try testing.expectEqualStrings(session.messages.items[2].role, "assistant");
    try testing.expect(session.messages.items[2].tool_calls != null);
    try testing.expectEqual(session.messages.items[2].tool_calls.?.len, 1);
    try testing.expectEqualStrings(session.messages.items[2].tool_calls.?[0].name, "bash");
    try testing.expectEqualStrings(session.messages.items[3].role, "tool");
    try testing.expectEqualStrings(session.messages.items[3].content, "file1.txt");
    try testing.expectEqualStrings(session.messages.items[3].tool_call_id.?, "call_1");
    try testing.expectEqual(session.total_input_tokens, 100);
    try testing.expectEqual(session.total_output_tokens, 50);
}

test "parseSession minimal" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{ "id": "minimal", "title": "", "messages": [] }
    ;

    const session = try parseSession(allocator, json_text);
    defer session.deinit();
    try testing.expectEqualStrings(session.id, "minimal");
    try testing.expectEqual(session.messages.items.len, 0);
    try testing.expect(session.agent == null);
}
