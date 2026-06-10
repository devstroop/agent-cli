const std = @import("std");
const tool = @import("tool.zig");
const llm = @import("llm.zig");

/// Build a JSON-RPC 2.0 request body string.
fn buildRequestBody(allocator: std.mem.Allocator, method: []const u8, params: ?[]const u8) ![]u8 {
    if (params) |p| {
        return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, p });
    }
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\"}}", .{method});
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    server_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8, server_name: []const u8) Client {
        return Client{
            .allocator = allocator,
            .io = io,
            .url = allocator.dupe(u8, url) catch unreachable,
            .server_name = allocator.dupe(u8, server_name) catch unreachable,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.url);
        self.allocator.free(self.server_name);
    }

    fn sendRequest(self: *Client, method: []const u8, params_json: ?[]const u8, resp_arena: std.mem.Allocator) !std.json.Value {
        const body = try buildRequestBody(self.allocator, method, params_json);
        defer self.allocator.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(self.url);
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
        const root = parsed.value;
        if (root != .object) return error.McpInvalidResponse;

        if (root.object.get("error")) |err_val| {
            if (err_val == .object) return error.McpError;
        }

        return root.object.get("result") orelse return error.McpInvalidResponse;
    }

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

        if (result != .object) {
            return tool.Result{ .stdout = "", .stderr = "Invalid MCP response", .exit_code = 1 };
        }

        const content_arr = result.object.get("content") orelse {
            return tool.Result{ .stdout = "", .stderr = "MCP response missing content", .exit_code = 1 };
        };

        if (content_arr != .array) {
            return tool.Result{ .stdout = "", .stderr = "MCP content is not an array", .exit_code = 1 };
        }

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

        const out = try output.toOwnedSlice(allocator);
        return tool.Result{ .stdout = out, .stderr = "", .exit_code = 0 };
    }
};

fn readBody(response: *std.http.Client.Response, max_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var transfer_buf: [4096]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    return try reader.allocRemaining(allocator, std.Io.Limit.limited(max_size));
}
