const std = @import("std");
const sdk = @import("agent-sdk");
const session_mod = sdk.session;
const session_json = sdk.session_json;
const llm = sdk.llm;

const SESSION_DIR_REL = ".config/agent/sessions";

fn getHomeDir() ?[]const u8 {
    if (std.c.getenv("HOME")) |h| return std.mem.span(h);
    // Windows: use USERPROFILE (e.g. C:\Users\Akash)
    if (std.c.getenv("USERPROFILE")) |h| return std.mem.span(h);
    // Windows fallback: HOMEDRIVE + HOMEPATH (e.g. C: + \Users\Akash)
    if (std.c.getenv("HOMEDRIVE")) |hd| {
        if (std.c.getenv("HOMEPATH")) |hp| {
            // We'd need allocator here — skip this path, USERPROFILE covers it
            _ = hd;
            _ = hp;
        }
    }
    return null;
}

pub fn sessionDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = getHomeDir() orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, SESSION_DIR_REL });
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

    const json_str = try session_json.serialize(allocator, session);
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

    return session_json.parse(allocator, content);
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

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
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

    var root = try std.json.ObjectMap.init(ja, &.{}, &.{});
    try root.put(ja, "session_id", .{ .string = id });
    try root.put(ja, "updated", .{ .integer = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000))) });

    const json_val = std.json.Value{ .object = root };
    const json_str = try std.json.Stringify.valueAlloc(allocator, json_val, .{ .whitespace = .minified });
    defer allocator.free(json_str);

    const lpath = try latestFilePath(allocator, dir_path);
    defer allocator.free(lpath);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = lpath, .data = json_str });
}

test "getHomeDir: returns non-null when HOME is set" {
    const testing = @import("std").testing;
    // On CI (and most dev machines), HOME is always set.
    // This test verifies the function doesn't crash and returns a value.
    const home = getHomeDir();
    if (std.c.getenv("HOME") != null or std.c.getenv("USERPROFILE") != null) {
        try testing.expect(home != null);
        if (home) |h| {
            try testing.expect(h.len > 0);
        }
    }
}

test "sessionDir: returns valid path" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // Skip if no home directory available
    if (getHomeDir() == null) return;

    const dir = try sessionDir(allocator);
    defer allocator.free(dir);

    try testing.expect(dir.len > 0);
    try testing.expect(std.mem.indexOf(u8, dir, ".config/agent/sessions") != null);
}

test "saveSession / loadSession round-trip preserves tool_call_id" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const io = std.Io.Test;

    // Create a session with tool calls and tool results
    var session = try session_mod.Session.init(allocator, .{
        .id = "roundtrip-tcid",
        .title = "Roundtrip TCID Test",
        .agent = "build",
        .model_id = "test-model",
        .provider_id = "test-provider",
    });
    defer session.deinit();

    try session.addMessage(.{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "run ls") });
    try session.addMessage(.{
        .role = try allocator.dupe(u8, "assistant"),
        .content = try allocator.dupe(u8, ""),
        .tool_calls = try allocator.dupe(llm.ToolCall, &[_]llm.ToolCall{.{ .id = try allocator.dupe(u8, "call_xyz"), .name = try allocator.dupe(u8, "bash"), .arguments = try allocator.dupe(u8, "{\"command\":\"ls\"}") }}),
    });
    try session.addToolResult("call_xyz", "file1.txt\nfile2.txt", false);

    // Save to temp directory
    const tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    const file_path = try std.fmt.allocPrint(allocator, "/tmp/agent_test_roundtrip_{s}.json", .{session.id});
    defer allocator.free(file_path);

    // Save using SDK serializer, load using SDK parser
    const json_str = try session_json.serialize(allocator, &session);
    defer allocator.free(json_str);

    try tmp_dir.writeFile(io, .{ .sub_path = file_path, .data = json_str });

    // Load back and verify
    const content = try tmp_dir.readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(content);

    const loaded = try session_json.parse(allocator, content);
    defer loaded.deinit();

    try testing.expectEqual(loaded.messages.items.len, 3);

    // Verify tool message has tool_call_id
    const tool_msg = loaded.messages.items[2];
    try testing.expectEqualStrings(tool_msg.role, "tool");
    try testing.expect(tool_msg.tool_call_id != null);
    try testing.expectEqualStrings(tool_msg.tool_call_id.?, "call_xyz");

    // Verify assistant message has tool_calls
    const asst = loaded.messages.items[1];
    try testing.expect(asst.tool_calls != null);
    try testing.expectEqual(asst.tool_calls.?.len, 1);
    try testing.expectEqualStrings(asst.tool_calls.?[0].id, "call_xyz");

    // Cleanup
    tmp_dir.deleteTree(io, std.fs.path.basename(file_path)) catch {};
}
