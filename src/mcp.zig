const std = @import("std");
const tool = @import("agent-sdk").tool;
const llm = @import("agent-sdk").llm;

/// Build a JSON-RPC 2.0 request body string.
fn buildRequestBody(allocator: std.mem.Allocator, method: []const u8, params: ?[]const u8) ![]u8 {
    if (params) |p| {
        return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, p });
    }
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\"}}", .{method});
}

/// Extract a JSON-RPC result from a parsed response object.
fn extractResult(root: std.json.Value) !std.json.Value {
    if (root != .object) return error.McpInvalidResponse;
    if (root.object.get("error")) |err_val| {
        if (err_val == .object) return error.McpError;
    }
    return root.object.get("result") orelse return error.McpInvalidResponse;
}

/// Parse MCP tool content array into a single string.
fn parseContent(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    if (result != .object) return error.McpInvalidResponse;
    const content_arr = result.object.get("content") orelse {
        return error.McpMissingContent;
    };
    if (content_arr != .array) return error.McpInvalidResponse;

    var output = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;
    for (content_arr.array.items) |item| {
        if (item != .object) continue;
        const ctype = item.object.get("type") orelse continue;
        if (ctype != .string) continue;
        if (std.mem.eql(u8, ctype.string, "text")) {
            if (item.object.get("text")) |text| {
                if (text == .string) {
                    try output.appendSlice(allocator, text.string);
                }
            }
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Read entire HTTP response body.
fn readBody(response: *std.http.Client.Response, max_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var transfer_buf: [4096]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    return try reader.allocRemaining(allocator, std.Io.Limit.limited(max_size));
}

// ── Transport-specific implementations ─────────────────────────────────────

/// Read a single line (up to \n) from an Io.Reader into an ArrayList.
/// Returns the line without the trailing \n. Null on EOF.
fn readLine(allocator: std.mem.Allocator, reader: *std.Io.Reader, buf: []u8) !?[]u8 {
    var line = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
    errdefer line.deinit(allocator);

    while (true) {
        const n = try reader.readSliceShort(buf);
        if (n == 0) {
            if (line.items.len == 0) return null;
            const owned = try line.toOwnedSlice(allocator);
            return owned;
        }
        for (buf[0..n]) |c| {
            if (c == '\n') {
                const owned = try line.toOwnedSlice(allocator);
                return owned;
            }
            try line.append(allocator, c);
        }
    }
}

/// Simple SSE event parser: reads until double-newline, returns (event_type, data).
fn readSseEvent(allocator: std.mem.Allocator, reader: *std.Io.Reader, buf: []u8) !?struct { event: ?[]const u8, data: ?[]const u8 } {
    var event_type: ?[]const u8 = null;
    var data: ?[]const u8 = null;

    while (true) {
        const line = try readLine(allocator, reader, buf) orelse return null;
        defer allocator.free(line);
        if (line.len == 0) {
            // Empty line = end of event
            if (data != null or event_type != null) {
                return .{ .event = event_type, .data = data };
            }
            // Skip empty keepalive
            continue;
        }
        if (line[0] == ':') continue; // comment
        if (std.mem.startsWith(u8, line, "event:")) {
            if (event_type) |et| allocator.free(et);
            event_type = try allocator.dupe(u8, std.mem.trim(u8, line["event:".len..], " \t"));
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            if (data) |d| {
                // Append to existing data with \n
                const merged = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ d, std.mem.trim(u8, line["data:".len..], " \t") });
                allocator.free(d);
                data = merged;
            } else {
                data = try allocator.dupe(u8, std.mem.trim(u8, line["data:".len..], " \t"));
            }
            continue;
        }
    }
}

// ── Client with transport dispatch ─────────────────────────────────────────

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server_name: []const u8,
    transport: Transport,
    /// Per-request ID counter for matching SSE responses
    request_id: u32 = 1,

    const Transport = union(enum) {
        http: []const u8, // URL
        stdio: StdioState,
        sse: SseState,
    };

    const StdioState = struct {
        command: []const u8,
        args: []const []const u8,
        env: ?std.StringHashMap([]const u8),
        child: ?std.process.Child,
        stdin_file: ?std.Io.File,
        stdout_file: ?std.Io.File,
    };

    const SseState = struct {
        base_url: []const u8, // original SSE endpoint URL
        endpoint_url: ?[]const u8, // discovered via `endpoint` event
        http_client: ?std.http.Client,
        sse_reader: ?*std.Io.Reader,
        sse_buf: [4096]u8,
        transfer_buf: [4096]u8,
    };

    // ── Factory methods per transport ───────────────────────────────────

    pub fn initHttp(allocator: std.mem.Allocator, io: std.Io, url: []const u8, server_name: []const u8) Client {
        return Client{
            .allocator = allocator,
            .io = io,
            .server_name = allocator.dupe(u8, server_name) catch unreachable,
            .transport = .{ .http = allocator.dupe(u8, url) catch unreachable },
        };
    }

    pub fn initStdio(allocator: std.mem.Allocator, io: std.Io, command: []const u8, args: []const []const u8, env: ?std.StringHashMap([]const u8), server_name: []const u8) Client {
        // Dup args array
        const args_copy = allocator.alloc([]const u8, args.len) catch unreachable;
        for (args, 0..) |arg, i| {
            args_copy[i] = allocator.dupe(u8, arg) catch unreachable;
        }
        return Client{
            .allocator = allocator,
            .io = io,
            .server_name = allocator.dupe(u8, server_name) catch unreachable,
            .transport = .{
                .stdio = .{
                    .command = allocator.dupe(u8, command) catch unreachable,
                    .args = args_copy,
                    .env = env, // owned by caller (config)
                    .child = null,
                    .stdin_file = null,
                    .stdout_file = null,
                },
            },
        };
    }

    pub fn initSse(allocator: std.mem.Allocator, io: std.Io, url: []const u8, server_name: []const u8) Client {
        return Client{
            .allocator = allocator,
            .io = io,
            .server_name = allocator.dupe(u8, server_name) catch unreachable,
            .transport = .{ .sse = .{
                .base_url = allocator.dupe(u8, url) catch unreachable,
                .endpoint_url = null,
                .http_client = null,
                .sse_reader = null,
                .sse_buf = undefined,
                .transfer_buf = undefined,
            } },
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.server_name);
        switch (self.transport) {
            .http => |url| self.allocator.free(url),
            .stdio => |*state| {
                // Kill child process if alive
                if (state.child) |*child| {
                    child.kill(self.io);
                }
                self.allocator.free(state.command);
                for (state.args) |a| self.allocator.free(a);
                self.allocator.free(state.args);
            },
            .sse => |*state| {
                self.allocator.free(state.base_url);
                if (state.endpoint_url) |eu| self.allocator.free(eu);
                if (state.http_client) |*hc| hc.deinit();
            },
        }
    }

    // ── sendRequest dispatches to transport-specific impl ───────────────

    fn sendRequest(self: *Client, method: []const u8, params_json: ?[]const u8, resp_arena: std.mem.Allocator) !std.json.Value {
        return switch (self.transport) {
            .http => self.sendRequestHttp(method, params_json, resp_arena),
            .stdio => self.sendRequestStdio(method, params_json, resp_arena),
            .sse => self.sendRequestSse(method, params_json, resp_arena),
        };
    }

    // ── HTTP transport (existing behavior) ─────────────────────────────

    fn sendRequestHttp(self: *Client, method: []const u8, params_json: ?[]const u8, resp_arena: std.mem.Allocator) !std.json.Value {
        const url = self.transport.http;
        const body = try buildRequestBody(self.allocator, method, params_json);
        defer self.allocator.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };

        var redirect_buf: [4096]u8 = undefined;
        var request = try client.request(.POST, uri, .{ .headers = headers });
        defer request.deinit();

        try request.sendBodyComplete(@constCast(body));
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.McpHttpError;
        }

        const resp_body = try readBody(&response, 10 * 1024 * 1024, self.allocator);
        defer self.allocator.free(resp_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, resp_arena, resp_body, .{});
        return extractResult(parsed.value);
    }

    // ── Stdio transport ────────────────────────────────────────────────

    fn ensureStdioSpawned(self: *Client) !void {
        const state = &self.transport.stdio;
        if (state.child != null) return;

        // Build argv: command + args
        const total_args = 1 + state.args.len;
        const argv = try self.allocator.alloc([]const u8, total_args);
        errdefer self.allocator.free(argv);
        argv[0] = state.command;
        for (state.args, 0..) |arg, i| {
            argv[i + 1] = arg;
        }

        const spawn_opts: std.process.SpawnOptions = .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        };

        // Env override not yet supported with SpawnOptions.environ_map
        _ = state.env;

        const child = try std.process.spawn(self.io, spawn_opts);
        state.stdin_file = child.stdin.?;
        state.stdout_file = child.stdout.?;
        state.child = child;
    }

    fn sendRequestStdio(self: *Client, method: []const u8, params_json: ?[]const u8, resp_arena: std.mem.Allocator) !std.json.Value {
        try self.ensureStdioSpawned();

        const body = try buildRequestBody(self.allocator, method, params_json);
        defer self.allocator.free(body);

        const state = &self.transport.stdio;
        var stdin_wbuf: [4096]u8 = undefined;
        var stdin_writer = state.stdin_file.?.writer(self.io, &stdin_wbuf);
        var stdout_rbuf: [4096]u8 = undefined;
        var stdout_reader = state.stdout_file.?.reader(self.io, &stdout_rbuf);

        // Write JSON-RPC request line
        try stdin_writer.interface.writeAll(body);
        try stdin_writer.interface.writeAll("\n");

        // Read response line
        var read_buf: [4096]u8 = undefined;
        const line = try readLine(self.allocator, &stdout_reader.interface, &read_buf) orelse {
            return error.McpStdioEof;
        };
        defer self.allocator.free(line);
        if (line.len == 0) return error.McpStdioEmpty;

        const parsed = try std.json.parseFromSlice(std.json.Value, resp_arena, line, .{});
        return extractResult(parsed.value);
    }

    // ── SSE transport ──────────────────────────────────────────────────

    fn ensureSseConnected(self: *Client) !void {
        const state = &self.transport.sse;
        if (state.endpoint_url != null) return;

        // 1. Connect SSE stream to discover endpoint
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        errdefer client.deinit();

        const uri = try std.Uri.parse(state.base_url);
        const headers: std.http.Client.Request.Headers = .{};

        var redirect_buf: [4096]u8 = undefined;
        var request = try client.request(.GET, uri, .{
            .headers = headers,
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.McpSseConnectError;
        }

        // 2. Parse SSE events to find the `endpoint` event
        const reader = response.reader(&state.transfer_buf);
        while (true) {
            const evt = try readSseEvent(self.allocator, reader, &state.sse_buf) orelse {
                return error.McpSseNoEndpoint;
            };
            defer {
                if (evt.event) |e| self.allocator.free(e);
                if (evt.data) |d| self.allocator.free(d);
            }
            if (evt.event) |et| {
                if (std.mem.eql(u8, et, "endpoint")) {
                    if (evt.data) |d| {
                        // Build absolute URL from base if needed
                        if (std.mem.startsWith(u8, d, "http://") or std.mem.startsWith(u8, d, "https://")) {
                            state.endpoint_url = try self.allocator.dupe(u8, d);
                        } else {
                            // Relative path — join with base
                            const separator = if (d.len > 0 and d[0] == '/') "" else "/";
                            // Extract scheme+host from base_url
                            const scheme_end = std.mem.indexOf(u8, state.base_url, "://") orelse return error.McpSseInvalidUrl;
                            const host_start = scheme_end + 3;
                            const path_start = std.mem.indexOfScalar(u8, state.base_url[host_start..], '/') orelse state.base_url.len;
                            const base_origin = state.base_url[0 .. host_start + path_start];
                            state.endpoint_url = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ base_origin, separator, d });
                        }
                        // Save the HTTP client for POST requests
                        state.http_client = client;
                        return;
                    }
                }
            }
        }
    }

    fn sendRequestSse(self: *Client, method: []const u8, params_json: ?[]const u8, resp_arena: std.mem.Allocator) !std.json.Value {
        try self.ensureSseConnected();

        const state = &self.transport.sse;
        const endpoint = state.endpoint_url orelse return error.McpSseNotConnected;

        const rid = self.request_id;
        self.request_id += 1;

        // Build request with unique ID
        const body = if (params_json) |p|
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ rid, method, p })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}", .{ rid, method });
        defer self.allocator.free(body);

        // POST to endpoint
        var client = state.http_client orelse return error.McpSseNotConnected;

        const uri = try std.Uri.parse(endpoint);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };

        var redirect_buf: [4096]u8 = undefined;
        var request = try client.request(.POST, uri, .{ .headers = headers });
        defer request.deinit();

        try request.sendBodyComplete(@constCast(body));
        var response = try request.receiveHead(&redirect_buf);

        // SSE transport: POST may return 202 (Accepted) with no body,
        // or 200 with the JSON-RPC response inline.
        if (response.head.status == .accepted) {
            // Response will come via SSE — read next message event
            const reader = response.reader(&state.transfer_buf);
            while (true) {
                const evt = try readSseEvent(self.allocator, reader, &state.sse_buf) orelse {
                    return error.McpSseDisconnected;
                };
                defer {
                    if (evt.event) |e| self.allocator.free(e);
                    if (evt.data) |d| self.allocator.free(d);
                }
                if (evt.event) |et| {
                    if (std.mem.eql(u8, et, "message")) {
                        if (evt.data) |d| {
                            const parsed = try std.json.parseFromSlice(std.json.Value, resp_arena, d, .{});
                            return extractResult(parsed.value);
                        }
                    }
                }
            }
        }

        if (response.head.status != .ok) {
            return error.McpSseHttpError;
        }

        // Response has body — parse directly
        const resp_body = try readBody(&response, 10 * 1024 * 1024, self.allocator);
        defer self.allocator.free(resp_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, resp_arena, resp_body, .{});
        return extractResult(parsed.value);
    }

    // ── High-level MCP operations ──────────────────────────────────────

    pub fn listTools(self: *Client, allocator: std.mem.Allocator, params_arena: std.mem.Allocator) ![]llm.ToolDef {
        const result = self.sendRequest("tools/list", null, params_arena) catch |err| {
            std.log.warn("MCP '{s}' tools/list failed: {}", .{ self.server_name, err });
            return &.{};
        };
        if (result != .object) return &.{};
        const tools_arr = result.object.get("tools") orelse return &.{};
        if (tools_arr != .array) return &.{};

        const prefix = try std.fmt.allocPrint(allocator, "mcp/{s}/", .{self.server_name});

        var defs = try std.ArrayList(llm.ToolDef).initCapacity(allocator, tools_arr.array.items.len);
        for (tools_arr.array.items) |item| {
            if (item != .object) continue;
            const name_val = item.object.get("name") orelse continue;
            if (name_val != .string or name_val.string.len == 0) continue;
            const desc_val = item.object.get("description") orelse continue;
            if (desc_val != .string) continue;
            const schema_val = item.object.get("inputSchema") orelse continue;

            const prefixed_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name_val.string });
            const full_desc = try std.fmt.allocPrint(allocator, "{s} (MCP server: {s})", .{ desc_val.string, self.server_name });

            try defs.append(allocator, .{
                .name = prefixed_name,
                .description = full_desc,
                .parameters = schema_val,
            });
        }
        allocator.free(prefix);
        return defs.toOwnedSlice(allocator);
    }

    pub fn callTool(self: *Client, tool_name: []const u8, arguments_json: []const u8, allocator: std.mem.Allocator) !tool.Result {
        const prefix_len = 4 + self.server_name.len + 1;
        const actual_name = tool_name[prefix_len..];

        // Build params JSON: {"name":"...","arguments":{...}}
        const params_json = if (arguments_json.len > 0 and arguments_json[0] == '{')
            try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ actual_name, arguments_json })
        else
            try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{actual_name});
        defer allocator.free(params_json);

        const result = self.sendRequest("tools/call", params_json, allocator) catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "MCP call '{s}/{s}' failed: {}", .{ self.server_name, actual_name, err });
            return tool.Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
        };

        const content = parseContent(allocator, result) catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "MCP parse failed: {}", .{err});
            return tool.Result{ .stdout = "", .stderr = err_msg, .exit_code = 1 };
        };
        return tool.Result{ .stdout = content, .stderr = "", .exit_code = 0, .owns_stderr = false };
    }
};
