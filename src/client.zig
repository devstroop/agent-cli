const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");

/// Simple URL encoding — encodes special characters for query parameters.
fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var len: usize = 0;
    for (input) |ch| {
        len += switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => 1,
            else => 3,
        };
    }
    const result = try allocator.alloc(u8, len);
    var i: usize = 0;
    const hex = "0123456789ABCDEF";
    for (input) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => {
                result[i] = ch;
                i += 1;
            },
            else => {
                result[i] = '%';
                result[i + 1] = hex[ch >> 4];
                result[i + 2] = hex[ch & 0xF];
                i += 3;
            },
        }
    }
    return result;
}

/// HTTP client for the OpenCode server API.
///
/// Connects to a running OpenCode server and provides methods
/// for session management, prompting, and event streaming.
pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    http: std.http.Client,
    auth_header: ?[]const u8,
    directory: ?[]const u8,

    /// Initialize a new client. The server URL should be like
    /// "http://localhost:4096" (no trailing slash).
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_url: []const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        directory: ?[]const u8,
    ) !Client {
        var auth: ?[]const u8 = null;
        if (password) |p| {
            const user = username orelse "opencode";
            const creds = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, p });
            defer allocator.free(creds);
            const encoded_len = std.base64.standard.Encoder.calcSize(creds.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, creds);
            auth = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
        }

        return Client{
            .allocator = allocator,
            .base_url = base_url,
            .http = std.http.Client{ .allocator = allocator, .io = io },
            .auth_header = auth,
            .directory = directory,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.auth_header) |h| self.allocator.free(h);
        self.http.deinit();
    }

    /// Owned URI — keeps the URL allocation alive alongside the parsed Uri.
    const OwnedUri = struct {
        uri: std.Uri,
        url: []const u8,

        pub fn deinit(self: *const OwnedUri, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
        }
    };

    /// Build a full URI for the given path, appending the directory query
    /// parameter if set. Caller must call result.deinit(allocator) after use.
    fn uri(self: *const Client, comptime path_fmt: []const u8, args: anytype) !OwnedUri {
        const has_query = comptime has: {
            for (path_fmt) |c| if (c == '?') break :has true;
            break :has false;
        };

        const full_url = if (self.directory) |dir| blk: {
            const encoded = try urlEncode(self.allocator, dir);
            defer self.allocator.free(encoded);
            if (has_query) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}" ++ path_fmt ++ "&directory={s}", .{self.base_url} ++ args ++ .{encoded});
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}" ++ path_fmt ++ "?directory={s}", .{self.base_url} ++ args ++ .{encoded});
            }
        } else try std.fmt.allocPrint(self.allocator, "{s}" ++ path_fmt, .{self.base_url} ++ args);

        return OwnedUri{
            .uri = try std.Uri.parse(full_url),
            .url = full_url,
        };
    }

    /// Set authorization header on request options if available.
    fn setAuth(self: *const Client, headers: *std.http.Client.Request.Headers) void {
        if (self.auth_header) |auth| {
            headers.authorization = .{ .override = auth };
        }
    }

    /// Read the full response body into a buffer and return as a slice.
    fn readBody(self: *const Client, response: *std.http.Client.Response, max_size: usize) ![]const u8 {
        var transfer_buf: [4096]u8 = undefined;
        var reader = response.reader(&transfer_buf);
        return try reader.allocRemaining(self.allocator, std.Io.Limit.limited(max_size));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Session API
    // ═══════════════════════════════════════════════════════════════════

    /// Create a new session. Returns the Session object.
    pub fn createSession(self: *Client, req: types.SessionCreateRequest) !types.Session {
        const target = try self.uri("/session", .{});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ja = arena.allocator();

        var obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
        if (req.title) |t| try obj.put(ja, "title", .{ .string = t });
        if (req.agent) |a| try obj.put(ja, "agent", .{ .string = a });
        if (req.variant) |v| try obj.put(ja, "variant", .{ .string = v });
        if (req.model) |m| {
            var model_obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
            try model_obj.put(ja, "providerID", .{ .string = m.providerID });
            try model_obj.put(ja, "id", .{ .string = m.id });
            if (m.variant) |v| try model_obj.put(ja, "variant", .{ .string = v });
            try obj.put(ja, "model", .{ .object = model_obj });
        }

        const val = std.json.Value{ .object = obj };
        const body = try std.json.Stringify.valueAlloc(self.allocator, val, .{ .whitespace = .minified });
        defer self.allocator.free(body);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodyComplete(body);
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            std.log.err("createSession failed: {d} {s} (body={s})", .{ @intFromEnum(response.head.status), resp_body, body });
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(types.Session, self.allocator, resp_body, .{});
        defer parsed.deinit();
        return try parsed.value.clone(self.allocator);
    }

    /// Get a session by ID.
    pub fn getSession(self: *Client, session_id: []const u8) !types.Session {
        const target = try self.uri("/session/{s}", .{session_id});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        self.setAuth(&headers);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.GET, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(types.Session, self.allocator, resp_body, .{});
        defer parsed.deinit();
        return try parsed.value.clone(self.allocator);
    }

    /// Fork a session. Returns the new forked session.
    pub fn forkSession(self: *Client, req: types.ForkRequest) !types.Session {
        const target = try self.uri("/session/{s}/fork", .{req.sessionID});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        const body = try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(body);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodyComplete(body);
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(types.Session, self.allocator, resp_body, .{});
        defer parsed.deinit();
        return try parsed.value.clone(self.allocator);
    }

    /// List sessions. The query_fmt should include query params
    /// (e.g. "/session?roots=true&limit=1").
    pub fn listSessions(self: *Client, comptime query_fmt: []const u8, query_args: anytype) ![]types.Session {
        const target = try self.uri(query_fmt, query_args);
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        self.setAuth(&headers);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.GET, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice([]types.Session, self.allocator, resp_body, .{});
        defer parsed.deinit();
        const src = parsed.value;
        var result = try self.allocator.alloc(types.Session, src.len);
        for (src, 0..) |s, i| {
            result[i] = try s.clone(self.allocator);
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Agent / App API
    // ═══════════════════════════════════════════════════════════════════

    /// List available agents from the server.
    pub fn listAgents(self: *Client) ![]types.AgentInfo {
        const target = try self.uri("/agent", .{});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        self.setAuth(&headers);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.GET, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice([]types.AgentInfo, self.allocator, resp_body, .{});
        defer parsed.deinit();
        const src = parsed.value;
        var result = try self.allocator.alloc(types.AgentInfo, src.len);
        for (src, 0..) |a, i| {
            result[i] = try a.clone(self.allocator);
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Prompt API
    // ═══════════════════════════════════════════════════════════════════

    /// Send a prompt to a session.
    /// Returns the response body (owned, caller must free).
    /// The response is a JSON object with `info` (AssistantMessage) and `parts` (Array<Part>).
    pub fn prompt(self: *Client, req: types.PromptRequest) ![]const u8 {
        const target = try self.uri("/session/{s}/message", .{req.sessionID});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ja = arena.allocator();

        var body_obj = try std.json.ObjectMap.init(ja, &.{}, &.{});

        var parts_arr = std.json.Array.init(ja);
        for (req.parts) |part| {
            switch (part) {
                .text => |t| {
                    var part_obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
                    try part_obj.put(ja, "type", .{ .string = "text" });
                    try part_obj.put(ja, "text", .{ .string = t.text });
                    try parts_arr.append(.{ .object = part_obj });
                },
                .file => |f| {
                    var part_obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
                    try part_obj.put(ja, "type", .{ .string = "file" });
                    try part_obj.put(ja, "url", .{ .string = f.url });
                    try part_obj.put(ja, "filename", .{ .string = f.filename });
                    try part_obj.put(ja, "mime", .{ .string = f.mime });
                    try parts_arr.append(.{ .object = part_obj });
                },
            }
        }
        try body_obj.put(ja, "parts", .{ .array = parts_arr });

        if (req.thinking) |t| try body_obj.put(ja, "thinking", .{ .bool = t });
        if (req.agent) |a| try body_obj.put(ja, "agent", .{ .string = a });
        if (req.variant) |v| try body_obj.put(ja, "variant", .{ .string = v });
        if (req.model) |m| {
            var model_obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
            try model_obj.put(ja, "providerID", .{ .string = m.providerID });
            try model_obj.put(ja, "modelID", .{ .string = m.id });
            try body_obj.put(ja, "model", .{ .object = model_obj });
        }

        const body_val = std.json.Value{ .object = body_obj };
        const body = try std.json.Stringify.valueAlloc(self.allocator, body_val, .{ .whitespace = .minified });
        defer self.allocator.free(body);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodyComplete(body);
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            const resp_body = try self.readBody(&response, 65536);
            defer self.allocator.free(resp_body);
            std.log.err("prompt failed: {d} {s} (sent: {s})", .{ @intFromEnum(response.head.status), resp_body, body });
            return error.ApiError;
        }

        return try self.readBody(&response, 10 * 1024 * 1024);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Command API
    // ═══════════════════════════════════════════════════════════════════

    /// Execute a slash command on a session.
    pub fn command(self: *Client, req: types.CommandRequest) !void {
        const target = try self.uri("/session/{s}/command", .{req.sessionID});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ja = arena.allocator();

        var obj = try std.json.ObjectMap.init(ja, &.{}, &.{});
        try obj.put(ja, "sessionID", .{ .string = req.sessionID });
        try obj.put(ja, "command", .{ .string = req.command });
        try obj.put(ja, "arguments", .{ .string = req.arguments });
        if (req.agent) |a| try obj.put(ja, "agent", .{ .string = a });
        if (req.model) |m| try obj.put(ja, "model", .{ .string = m });
        if (req.variant) |v| try obj.put(ja, "variant", .{ .string = v });

        const val = std.json.Value{ .object = obj };
        const body = try std.json.Stringify.valueAlloc(self.allocator, val, .{ .whitespace = .minified });
        defer self.allocator.free(body);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodyComplete(body);
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            const resp_body = try self.readBody(&response, 65536);
            defer self.allocator.free(resp_body);
            std.log.err("command failed: {d} {s} (sent: {s})", .{ @intFromEnum(response.head.status), resp_body, body });
            return error.ApiError;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Share API
    // ═══════════════════════════════════════════════════════════════════

    /// Share a session. Returns the full Session with a share URL.
    pub fn shareSession(self: *Client, session_id: []const u8) !types.Session {
        const target = try self.uri("/session/{s}/share", .{session_id});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        const empty_body = try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(empty_body);
        try request.sendBodyComplete(empty_body);
        var response = try request.receiveHead(&redirect_buf);

        const resp_body = try self.readBody(&response, 1024 * 1024);
        defer self.allocator.free(resp_body);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(types.Session, self.allocator, resp_body, .{});
        defer parsed.deinit();
        return try parsed.value.clone(self.allocator);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Permission API
    // ═══════════════════════════════════════════════════════════════════

    /// Reply to a permission request.
    pub fn permissionReply(self: *Client, req: types.PermissionReplyRequest) !void {
        const target = try self.uri("/permission/reply", .{});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };
        self.setAuth(&headers);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"sessionID\":\"{s}\",\"requestID\":\"{s}\",\"action\":\"{s}\"}}", .{ req.sessionID, req.requestID, req.action });
        defer self.allocator.free(body);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.POST, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodyComplete(body);
        const response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.ApiError;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // SSE Event Stream
    // ═══════════════════════════════════════════════════════════════════

    /// Subscribe to the SSE event stream and call callback for each event.
    /// Blocks until the stream ends or the callback returns an error.
    /// The context is passed through to the callback.
    pub fn subscribeEvents(
        self: *Client,
        context: anytype,
        callback: fn (@TypeOf(context), types.GlobalEvent) anyerror!void,
    ) !void {
        const target = try self.uri("/event", .{});
        defer target.deinit(self.allocator);
        var headers: std.http.Client.Request.Headers = .{};
        self.setAuth(&headers);

        var redirect_buf: [4096]u8 = undefined;
        var request = try self.http.request(.GET, target.uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.ApiError;
        }

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var sse_buf: [8192]u8 = undefined;
        try sse.parseEvents(self.allocator, reader, &sse_buf, context, callback);
    }
};
