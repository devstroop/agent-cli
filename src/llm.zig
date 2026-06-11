const std = @import("std");
const builtin = @import("builtin");

const json = std.json;
const config_mod = @import("agent-sdk").config;
const flate = std.compress.flate;
const markdown = @import("markdown.zig");

fn sleep(ns: u64) void {
    if (comptime builtin.os.tag == .windows) {
        const interval: i64 = -@as(i64, @intCast(ns / 100));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    } else {
        const ts = std.c.timespec{
            .sec = @intCast(ns / 1_000_000_000),
            .nsec = @intCast(ns % 1_000_000_000),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: *const ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters: json.Value,

    pub fn deinit(self: *const ToolDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        // parameters is an arena-allocated json.Value, freed with its arena
    }
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn deinit(self: *const Message, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.tool_calls) |tcs| {
            for (tcs) |tc| tc.deinit(allocator);
            allocator.free(tcs);
        }
        if (self.tool_call_id) |id| allocator.free(id);
    }
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    top_p: ?f64 = null,
    tools: ?[]const ToolDef = null,
    tool_choice: ?[]const u8 = null,
    variant: ?[]const u8 = null,
};

pub const ChatResponse = struct {
    content: []const u8,
    tool_calls: []const ToolCall,
    finish_reason: ?[]const u8,
    input_tokens: ?u64,
    output_tokens: ?u64,

    pub fn deinit(self: *const ChatResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        for (self.tool_calls) |tc| tc.deinit(allocator);
        allocator.free(self.tool_calls);
        if (self.finish_reason) |f| allocator.free(f);
    }
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.ProviderConfig,
    api_key: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config_mod.ProviderConfig, api_key: ?[]const u8) Provider {
        return Provider{ .allocator = allocator, .io = io, .config = cfg, .api_key = api_key };
    }

    fn chatUrl(self: *const Provider) ![]const u8 {
        const base = self.config.options.baseURL;
        if (std.mem.endsWith(u8, base, "/")) {
            return try std.fmt.allocPrint(self.allocator, "{s}chat/completions", .{base});
        }
        return try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{base});
    }

    fn buildRequestBody(self: *Provider, req: ChatRequest, stream: bool, body_str: *?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ja = arena.allocator();

        var body_obj = try json.ObjectMap.init(ja, &.{}, &.{});
        try body_obj.put(ja, "model", .{ .string = req.model });
        if (stream) try body_obj.put(ja, "stream", .{ .bool = true });

        var msgs_arr = json.Array.init(ja);
        for (req.messages) |msg| {
            var msg_obj = try json.ObjectMap.init(ja, &.{}, &.{});
            try msg_obj.put(ja, "role", .{ .string = msg.role });
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
            try msg_obj.put(ja, "content", .{ .string = msg.content });
            try msgs_arr.append(.{ .object = msg_obj });
        }
        try body_obj.put(ja, "messages", .{ .array = msgs_arr });

        if (req.temperature) |t| try body_obj.put(ja, "temperature", .{ .float = t });
        if (req.max_tokens) |m| try body_obj.put(ja, "max_tokens", .{ .integer = @as(i64, @intCast(m)) });
        if (req.top_p) |p| try body_obj.put(ja, "top_p", .{ .float = p });
        if (req.variant) |v| try body_obj.put(ja, "reasoning_effort", .{ .string = v });

        if (req.tools) |tools| {
            var tools_arr = json.Array.init(ja);
            for (tools) |td| {
                var td_obj = try json.ObjectMap.init(ja, &.{}, &.{});
                try td_obj.put(ja, "type", .{ .string = "function" });
                var func_obj = try json.ObjectMap.init(ja, &.{}, &.{});
                try func_obj.put(ja, "name", .{ .string = td.name });
                try func_obj.put(ja, "description", .{ .string = td.description });
                try func_obj.put(ja, "parameters", td.parameters);
                try td_obj.put(ja, "function", .{ .object = func_obj });
                try tools_arr.append(.{ .object = td_obj });
            }
            try body_obj.put(ja, "tools", .{ .array = tools_arr });
            try body_obj.put(ja, "tool_choice", .{ .string = req.tool_choice orelse "auto" });
        }

        const body_val = json.Value{ .object = body_obj };
        const body = try json.Stringify.valueAlloc(self.allocator, body_val, .{ .whitespace = .minified });
        body_str.* = body;
    }

    pub fn complete(self: *Provider, req: ChatRequest) !ChatResponse {
        var last_err_body = std.ArrayList(u8).initCapacity(self.allocator, 512) catch unreachable;
        defer last_err_body.deinit(self.allocator);

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            if (attempt > 0) {
                // Exponential backoff: 1s, 2s, 4s
                const delay_ns: u64 = (@as(u64, 1) << @intCast(attempt - 1)) * 1_000_000_000;
                sleep(delay_ns);
            }
            const result = self.sendRequest(req, false, &last_err_body);
            if (result) |resp| return resp else |err| {
                if (err == error.RateLimited) continue;
                return err;
            }
        }
        // All retries exhausted — return structured error
        std.log.err("LLM request failed after 3 attempts: {s}", .{last_err_body.items});
        return error.LlmError;
    }

    /// Send a single HTTP request. Returns error.RateLimited for 429 so caller can retry.
    fn sendRequest(self: *Provider, req: ChatRequest, stream: bool, last_err_body: *std.ArrayList(u8)) !ChatResponse {
        const url = try self.chatUrl();
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };

        if (self.api_key) |key| {
            const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
            defer self.allocator.free(auth);
            headers.authorization = .{ .override = auth };
        }

        var body: ?[]const u8 = null;
        try self.buildRequestBody(req, stream, &body);
        defer if (body) |b| self.allocator.free(b);

        var redirect_buf: [4096]u8 = undefined;
        var request = try client.request(.POST, uri, .{ .headers = headers });
        defer request.deinit();

        try request.sendBodyComplete(@constCast(body.?));
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            const err_body = try readBody(&response, 65536, self.allocator);
            defer self.allocator.free(err_body);
            last_err_body.clearRetainingCapacity();
            last_err_body.appendSlice(self.allocator, err_body) catch {};
            const status_code = @intFromEnum(response.head.status);
            std.log.err("LLM request failed: {d} (body: {s})", .{ status_code, err_body });
            if (status_code == 429 or status_code >= 500) return error.RateLimited;
            return error.LlmError;
        }

        const resp_body = try readBody(&response, 10 * 1024 * 1024, self.allocator);
        defer self.allocator.free(resp_body);

        if (response.head.content_encoding == .gzip) {
            var in: std.Io.Reader = .fixed(resp_body);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var decompress: flate.Decompress = .init(&in, .gzip, &.{});
            _ = try decompress.reader.streamRemaining(&out.writer);
            const decompressed = out.written();
            const result = try self.allocator.dupe(u8, decompressed);
            defer self.allocator.free(result);
            return parseChatResponse(self.allocator, result);
        }

        return parseChatResponse(self.allocator, resp_body);
    }

    pub fn completeStream(
        self: *Provider,
        req: ChatRequest,
        writer: *std.Io.Writer,
        format_json: bool,
        md: ?*markdown.MdRenderer,
    ) !ChatResponse {
        var last_err_body = std.ArrayList(u8).initCapacity(self.allocator, 512) catch unreachable;
        defer last_err_body.deinit(self.allocator);

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ns: u64 = (@as(u64, 1) << @intCast(attempt - 1)) * 1_000_000_000;
                sleep(delay_ns);
            }
            const result = self.streamRequest(req, writer, format_json, md, &last_err_body);
            if (result) |resp| return resp else |err| {
                if (err == error.RateLimited) continue;
                return err;
            }
        }
        std.log.err("LLM streaming request failed after 3 attempts: {s}", .{last_err_body.items});
        return error.LlmError;
    }

    /// Send a single streaming HTTP request. Returns error.RateLimited for 429 so caller can retry.
    fn streamRequest(self: *Provider, req: ChatRequest, writer: *std.Io.Writer, format_json: bool, md: ?*markdown.MdRenderer, last_err_body: *std.ArrayList(u8)) !ChatResponse {
        const url = try self.chatUrl();
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var headers: std.http.Client.Request.Headers = .{};
        headers.content_type = .{ .override = "application/json" };

        if (self.api_key) |key| {
            const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
            defer self.allocator.free(auth);
            headers.authorization = .{ .override = auth };
        }

        var body: ?[]const u8 = null;
        try self.buildRequestBody(req, true, &body);
        defer if (body) |b| self.allocator.free(b);

        var redirect_buf: [4096]u8 = undefined;
        var request = try client.request(.POST, uri, .{ .headers = headers });
        defer request.deinit();

        try request.sendBodyComplete(@constCast(body.?));
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            const err_body = try readBody(&response, 65536, self.allocator);
            defer self.allocator.free(err_body);
            last_err_body.clearRetainingCapacity();
            last_err_body.appendSlice(self.allocator, err_body) catch {};
            const status_code = @intFromEnum(response.head.status);
            std.log.err("LLM streaming request failed: {d} (body: {s})", .{ status_code, err_body });
            if (status_code == 429 or status_code >= 500) return error.RateLimited;
            return error.LlmError;
        }

        // Read stream — arena for all per-event throwaway allocations.
        // json.parseFromSlice is the #1 alloc hot spot (called per SSE event).
        // The arena absorbs all temporary memory and is freed at the end of the request.
        var stream_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer stream_arena.deinit();
        const event_alloc = stream_arena.allocator();

        var reader_buf: [4096]u8 = undefined;
        const resp_reader = response.reader(&reader_buf);
        var chunk_buf: [4096]u8 = undefined;

        // Accumulate full response (must survive on self.allocator for ChatResponse)
        var content_buf = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch unreachable;
        defer content_buf.deinit(self.allocator);
        var tool_calls = std.ArrayList(ToolCallAccum).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            // id/name are arena-allocated — only free args (self.allocator)
            for (tool_calls.items) |*tc| tc.args.deinit(self.allocator);
            tool_calls.deinit(self.allocator);
        }
        var finish_reason: ?[]const u8 = null;
        var input_tokens: ?u64 = null;
        var output_tokens: ?u64 = null;

        // Fixed stack buffer for SSE lines (max 4KB, typical lines < 256 bytes).
        var sse_buf: [4096]u8 = undefined;
        var sse_len: usize = 0;

        while (true) {
            const n = std.Io.Reader.readSliceShort(resp_reader, &chunk_buf) catch |err| return err;
            if (n == 0) break;
            for (chunk_buf[0..n]) |ch| {
                if (ch == '\n') {
                    const line = sse_buf[0..sse_len];
                    if (std.mem.startsWith(u8, line, "data: ")) {
                        const data = line[6..];
                        if (std.mem.eql(u8, data, "[DONE]")) break;
                        try processSSEData(self.allocator, event_alloc, &content_buf, &tool_calls, &finish_reason, &input_tokens, &output_tokens, data, writer, format_json, md);
                    } else if (sse_len > 0 and line[0] == '{') {
                        try processSSEData(self.allocator, event_alloc, &content_buf, &tool_calls, &finish_reason, &input_tokens, &output_tokens, line, writer, format_json, md);
                    }
                    sse_len = 0;
                } else {
                    if (sse_len < sse_buf.len) {
                        sse_buf[sse_len] = ch;
                        sse_len += 1;
                    }
                }
            }
        }
        // Handle trailing line
        if (sse_len > 0) {
            const line = sse_buf[0..sse_len];
            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line[6..];
                if (!std.mem.eql(u8, data, "[DONE]")) {
                    try processSSEData(self.allocator, event_alloc, &content_buf, &tool_calls, &finish_reason, &input_tokens, &output_tokens, data, writer, format_json, md);
                }
            }
        }

        // Flush any remaining buffered markdown output.
        if (md) |r| try r.flush();

        // Build final tool_calls array — dupe arena-allocated id/name to main allocator.
        const tcs = try self.allocator.alloc(ToolCall, tool_calls.items.len);
        for (tool_calls.items, 0..) |*tc_acc, i| {
            tcs[i] = .{
                .id = try self.allocator.dupe(u8, tc_acc.id),
                .name = try self.allocator.dupe(u8, tc_acc.name),
                .arguments = tc_acc.args.toOwnedSlice(self.allocator) catch unreachable,
            };
        }

        // Dupe finish_reason from arena to main allocator.
        const finish_owned: ?[]const u8 = if (finish_reason) |fr| try self.allocator.dupe(u8, fr) else null;

        return ChatResponse{
            .content = content_buf.toOwnedSlice(self.allocator) catch unreachable,
            .tool_calls = tcs,
            .finish_reason = finish_owned,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
        };
    }
};

const ToolCallAccum = struct {
    /// Arena-allocated — freed when the stream arena is destroyed.
    id: []const u8,
    /// Arena-allocated — freed when the stream arena is destroyed.
    name: []const u8,
    /// Long-lived allocator (self.allocator) — freed in defer block after SSE loop.
    args: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !ToolCallAccum {
        const args = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
        return ToolCallAccum{ .id = id, .name = name, .args = args };
    }
};

fn processSSEData(
    /// Long-lived allocator for content_buf and tool_calls (survives the request).
    allocator: std.mem.Allocator,
    /// Arena allocator for per-event throwaways (JSON parse, dupes). Reset after the request.
    event_allocator: std.mem.Allocator,
    content_buf: *std.ArrayList(u8),
    tool_calls: *std.ArrayList(ToolCallAccum),
    finish_reason: *?[]const u8,
    input_tokens: *?u64,
    output_tokens: *?u64,
    data: []const u8,
    writer: *std.Io.Writer,
    format_json: bool,
    md: ?*markdown.MdRenderer,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, event_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    // Parse usage from final chunk (choices may be empty)
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) input_tokens.* = @intCast(@as(u64, @intCast(pt.integer)));
            }
            if (usage.object.get("completion_tokens")) |ct| {
                if (ct == .integer) output_tokens.* = @intCast(@as(u64, @intCast(ct.integer)));
            }
        }
    }

    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const first = choices.array.items[0];
    if (first != .object) return;
    const delta = first.object.get("delta") orelse return;
    if (delta != .object) return;

    // Text delta
    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            try content_buf.appendSlice(allocator, c.string);
            if (format_json) {
                const line = try std.json.Stringify.valueAlloc(event_allocator, .{ .type = "text", .text = c.string }, .{ .whitespace = .minified });
                try writer.print("{s}\n", .{line});
            } else {
                if (md) |renderer| {
                    try renderer.feed(c.string);
                } else {
                    try writer.print("{s}", .{c.string});
                }
            }
            try writer.flush();
        }
    }

    // Tool call deltas
    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs == .array) {
            for (tcs.array.items) |tc_item| {
                if (tc_item != .object) continue;
                const idx_val = tc_item.object.get("index");
                const idx: usize = if (idx_val != null and idx_val.? == .integer) @intCast(@as(i64, @intCast(idx_val.?.integer))) else 0;
                while (tool_calls.items.len <= idx) {
                    try tool_calls.append(allocator, try ToolCallAccum.init(allocator, "", ""));
                }
                if (tc_item.object.get("id")) |id_val| {
                    if (id_val == .string) {
                        tool_calls.items[idx].id = try event_allocator.dupe(u8, id_val.string);
                    }
                }
                if (tc_item.object.get("function")) |func_val| {
                    if (func_val == .object) {
                        if (func_val.object.get("name")) |name_val| {
                            if (name_val == .string and name_val.string.len > 0) {
                                tool_calls.items[idx].name = try event_allocator.dupe(u8, name_val.string);
                            }
                        }
                        if (func_val.object.get("arguments")) |args_val| {
                            if (args_val == .string and args_val.string.len > 0) {
                                try tool_calls.items[idx].args.appendSlice(allocator, args_val.string);
                            }
                        }
                    }
                }
            }
        }
    }

    // Finish reason (arena-allocated, duped to main allocator at end of stream)
    if (first.object.get("finish_reason")) |fr| {
        if (fr == .string and fr.string.len > 0) {
            finish_reason.* = try event_allocator.dupe(u8, fr.string);
        }
    }
}

fn readBody(response: *std.http.Client.Response, max_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var transfer_buf: [4096]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    return try reader.allocRemaining(allocator, std.Io.Limit.limited(max_size));
}

fn parseChatResponse(allocator: std.mem.Allocator, body: []const u8) !ChatResponse {
    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return error.InvalidResponse;

    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidResponse;

    const first = choices.array.items[0];
    if (first != .object) return error.InvalidResponse;

    const message = first.object.get("message") orelse first.object.get("delta") orelse return error.InvalidResponse;
    if (message != .object) return error.InvalidResponse;

    // Parse content (may be null for tool_call-only responses)
    const content_val = message.object.get("content") orelse json.Value{ .string = "" };
    const content_str = if (content_val == .string) content_val.string else "";
    const content = try allocator.dupe(u8, content_str);

    // Parse tool_calls
    const tool_calls_raw = message.object.get("tool_calls");
    const tool_calls = if (tool_calls_raw) |tc_val| blk: {
        if (tc_val != .array) break :blk try allocator.alloc(ToolCall, 0);
        const arr = tc_val.array.items;
        const result = try allocator.alloc(ToolCall, arr.len);
        for (arr, 0..) |item, i| {
            if (item != .object) return error.InvalidResponse;
            const obj = item.object;
            const id_val = obj.get("id") orelse return error.InvalidResponse;
            if (id_val != .string) return error.InvalidResponse;
            const fn_val = obj.get("function") orelse return error.InvalidResponse;
            if (fn_val != .object) return error.InvalidResponse;
            const fn_obj = fn_val.object;
            const name_val = fn_obj.get("name") orelse return error.InvalidResponse;
            if (name_val != .string) return error.InvalidResponse;
            const args_val = fn_obj.get("arguments") orelse return error.InvalidResponse;
            if (args_val != .string) return error.InvalidResponse;
            result[i] = ToolCall{
                .id = try allocator.dupe(u8, id_val.string),
                .name = try allocator.dupe(u8, name_val.string),
                .arguments = try allocator.dupe(u8, args_val.string),
            };
        }
        break :blk result;
    } else try allocator.alloc(ToolCall, 0);

    const finish = if (first.object.get("finish_reason")) |fr|
        if (fr == .string) try allocator.dupe(u8, fr.string) else null
    else
        null;

    const usage = root.object.get("usage");
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;
    if (usage) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) input_tokens = @intCast(@as(u64, @intCast(pt.integer)));
            }
            if (u.object.get("completion_tokens")) |ct| {
                if (ct == .integer) output_tokens = @intCast(@as(u64, @intCast(ct.integer)));
            }
        }
    }

    return ChatResponse{
        .content = content,
        .tool_calls = tool_calls,
        .finish_reason = finish,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    };
}

test "parseChatResponse basic" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "Hello!");
    try testing.expectEqual(resp.tool_calls.len, 0);
    try testing.expectEqualStrings(resp.finish_reason.?, "stop");
    try testing.expectEqual(resp.input_tokens.?, 10);
    try testing.expectEqual(resp.output_tokens.?, 5);
}

test "parseChatResponse with tool_calls" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-2","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":10}}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "");
    try testing.expectEqual(resp.tool_calls.len, 1);
    try testing.expectEqualStrings(resp.tool_calls[0].name, "bash");
    try testing.expectEqualStrings(resp.tool_calls[0].id, "call_1");
    try testing.expectEqualStrings(resp.tool_calls[0].arguments, "{\"command\":\"ls\"}");
    try testing.expectEqualStrings(resp.finish_reason.?, "tool_calls");
}

test "buildRequestBody: system and user messages" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = config_mod.ProviderConfig{
        .name = try allocator.dupe(u8, "test"),
        .npm = try allocator.dupe(u8, "@test/provider"),
        .options = .{ .baseURL = try allocator.dupe(u8, "https://example.com/v1") },
    };
    defer cfg.deinit(allocator);
    var provider = Provider.init(allocator, undefined, cfg, null);
    const req = ChatRequest{
        .model = "test-model",
        .messages = &.{
            .{ .role = "system", .content = "you are a bot" },
            .{ .role = "user", .content = "hello" },
        },
    };
    var body: ?[]const u8 = null;
    try provider.buildRequestBody(req, false, &body);
    defer if (body) |b| allocator.free(b);
    const parsed = try json.parseFromSlice(json.Value, allocator, body.?, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqualStrings(root.object.get("model").?.string, "test-model");
    try testing.expect(root.object.get("stream") == null);
    const msgs = root.object.get("messages").?.array.items;
    try testing.expectEqual(msgs.len, 2);
    try testing.expectEqualStrings(msgs[0].object.get("role").?.string, "system");
    try testing.expectEqualStrings(msgs[0].object.get("content").?.string, "you are a bot");
    try testing.expectEqualStrings(msgs[1].object.get("role").?.string, "user");
    try testing.expectEqualStrings(msgs[1].object.get("content").?.string, "hello");
}

test "buildRequestBody: stream flag" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = config_mod.ProviderConfig{
        .name = try allocator.dupe(u8, "test"),
        .npm = try allocator.dupe(u8, "@test/provider"),
        .options = .{ .baseURL = try allocator.dupe(u8, "https://example.com/v1") },
    };
    defer cfg.deinit(allocator);
    var provider = Provider.init(allocator, undefined, cfg, null);
    var body: ?[]const u8 = null;
    try provider.buildRequestBody(.{ .model = "m", .messages = &.{} }, true, &body);
    defer if (body) |b| allocator.free(b);
    const parsed = try json.parseFromSlice(json.Value, allocator, body.?, .{});
    defer parsed.deinit();
    try testing.expectEqual(parsed.value.object.get("stream").?.bool, true);
}

test "buildRequestBody: with tool calls" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = config_mod.ProviderConfig{
        .name = try allocator.dupe(u8, "test"),
        .npm = try allocator.dupe(u8, "@test/provider"),
        .options = .{ .baseURL = try allocator.dupe(u8, "https://example.com/v1") },
    };
    defer cfg.deinit(allocator);
    var provider = Provider.init(allocator, undefined, cfg, null);
    const req = ChatRequest{
        .model = "m",
        .messages = &.{
            .{
                .role = "assistant",
                .content = "",
                .tool_calls = &.{
                    .{ .id = "call_1", .name = "bash", .arguments = "ls" },
                },
            },
        },
    };
    var body: ?[]const u8 = null;
    try provider.buildRequestBody(req, false, &body);
    defer if (body) |b| allocator.free(b);
    const parsed = try json.parseFromSlice(json.Value, allocator, body.?, .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("messages").?.array.items[0];
    try testing.expectEqualStrings(msg.object.get("role").?.string, "assistant");
    const tcs = msg.object.get("tool_calls").?.array.items;
    try testing.expectEqual(tcs.len, 1);
    try testing.expectEqualStrings(tcs[0].object.get("id").?.string, "call_1");
    try testing.expectEqualStrings(tcs[0].object.get("function").?.object.get("name").?.string, "bash");
}

test "buildRequestBody: variant as reasoning_effort" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = config_mod.ProviderConfig{
        .name = try allocator.dupe(u8, "test"),
        .npm = try allocator.dupe(u8, "@test/provider"),
        .options = .{ .baseURL = try allocator.dupe(u8, "https://example.com/v1") },
    };
    defer cfg.deinit(allocator);
    var provider = Provider.init(allocator, undefined, cfg, null);
    var body: ?[]const u8 = null;
    try provider.buildRequestBody(.{ .model = "m", .messages = &.{}, .variant = "high" }, false, &body);
    defer if (body) |b| allocator.free(b);
    const parsed = try json.parseFromSlice(json.Value, allocator, body.?, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(parsed.value.object.get("reasoning_effort").?.string, "high");
}

test "processSSEData text delta" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer tool_calls_arr.deinit(allocator);
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const data = "{\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}";
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, data, undefined, false);

    try testing.expectEqualStrings(content_buf.items, "Hello");
    try testing.expect(finish_reason == null);
}

test "processSSEData finish_reason" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer tool_calls_arr.deinit(allocator);
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const data = "{\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, data, undefined, false);

    try testing.expectEqualStrings(finish_reason.?, "stop");
}

test "processSSEData usage" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer tool_calls_arr.deinit(allocator);
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const data = "{\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"choices\":[],\"usage\":{\"prompt_tokens\":15,\"completion_tokens\":7}}";
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, data, undefined, false);

    try testing.expectEqual(input_tokens.?, 15);
    try testing.expectEqual(output_tokens.?, 7);
}

test "buildRequestBody: assistant with tool_calls, empty content" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = config_mod.ProviderConfig{
        .name = try allocator.dupe(u8, "test"),
        .npm = try allocator.dupe(u8, "@test/provider"),
        .options = .{ .baseURL = try allocator.dupe(u8, "https://example.com/v1") },
    };
    defer cfg.deinit(allocator);
    var provider = Provider.init(allocator, undefined, cfg, null);
    const req = ChatRequest{
        .model = "m",
        .messages = &.{
            .{
                .role = "assistant",
                .content = "",
                .tool_calls = &.{
                    .{ .id = "call_x", .name = "bash", .arguments = "{\"command\":\"ls\"}" },
                },
            },
        },
    };
    var body: ?[]const u8 = null;
    try provider.buildRequestBody(req, false, &body);
    defer if (body) |b| allocator.free(b);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.?, .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("messages").?.array.items[0];
    try testing.expectEqualStrings(msg.object.get("content").?.string, "");
    try testing.expect(msg.object.get("tool_calls") != null);
}

test "processSSEData: tool call id from delta" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (tool_calls_arr.items) |*tc| tc.deinit(allocator);
        tool_calls_arr.deinit(allocator);
    }
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const data =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}
    ;
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, data, undefined, false);

    try testing.expectEqual(tool_calls_arr.items.len, 1);
    try testing.expectEqualStrings(tool_calls_arr.items[0].id, "call_abc123");
    try testing.expectEqualStrings(tool_calls_arr.items[0].name, "bash");
}

test "processSSEData: tool call name from separate chunk" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (tool_calls_arr.items) |*tc| tc.deinit(allocator);
        tool_calls_arr.deinit(allocator);
    }
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const chunk1 =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_xyz","type":"function","function":{"name":"","arguments":""}}]},"finish_reason":null}]}
    ;
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, chunk1, undefined, false);

    const chunk2 =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"read","arguments":""}}]},"finish_reason":null}]}
    ;
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, chunk2, undefined, false);

    try testing.expectEqual(tool_calls_arr.items.len, 1);
    try testing.expectEqualStrings(tool_calls_arr.items[0].id, "call_xyz");
    try testing.expectEqualStrings(tool_calls_arr.items[0].name, "read");
}

test "processSSEData: tool call arguments accumulated across chunks" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var content_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
    defer content_buf.deinit(allocator);
    var tool_calls_arr = std.ArrayList(ToolCallAccum).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (tool_calls_arr.items) |*tc| tc.deinit(allocator);
        tool_calls_arr.deinit(allocator);
    }
    var finish_reason: ?[]const u8 = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    const chunk1 =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\\"com"}}]},"finish_reason":null}]}
    ;
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, chunk1, undefined, false);

    const chunk2 =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mand\\\":\\\"ls\\\"}"}}]},"finish_reason":null}]}
    ;
    try processSSEData(allocator, &content_buf, &tool_calls_arr, &finish_reason, &input_tokens, &output_tokens, chunk2, undefined, false);

    try testing.expectEqual(tool_calls_arr.items.len, 1);
    const args = try tool_calls_arr.items[0].toOwnedSlice(allocator);
    defer allocator.free(args);
    try testing.expectEqualStrings(args, "{\"command\":\"ls\"}");
}

test "parseChatResponse null content field" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-3","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "");
    try testing.expectEqual(resp.tool_calls.len, 0);
}

test "parseChatResponse missing content field" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-4","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant"},"finish_reason":"stop"}]}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "");
    try testing.expectEqual(resp.tool_calls.len, 0);
}

test "parseChatResponse empty tool_calls array" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-5","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hi","tool_calls":[]},"finish_reason":"stop"}]}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "hi");
    try testing.expectEqual(resp.tool_calls.len, 0);
}

test "parseChatResponse no finish_reason" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-6","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}]}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqualStrings(resp.content, "ok");
    try testing.expectEqual(resp.finish_reason, null);
}

test "parseChatResponse no usage" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-7","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}
    ;

    const resp = try parseChatResponse(allocator, json_text);
    defer resp.deinit(allocator);

    try testing.expectEqual(resp.input_tokens, null);
    try testing.expectEqual(resp.output_tokens, null);
}

test "parseChatResponse missing choices returns error" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-8","object":"chat.completion"}
    ;

    const result = parseChatResponse(allocator, json_text);
    try testing.expectError(error.InvalidResponse, result);
}

test "parseChatResponse empty choices returns error" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"id":"chat-9","object":"chat.completion","choices":[]}
    ;

    const result = parseChatResponse(allocator, json_text);
    try testing.expectError(error.InvalidResponse, result);
}

test "ToolCallAccum.deinit frees owned fields" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var tc = try ToolCallAccum.init(allocator, try allocator.dupe(u8, "test_id"), try allocator.dupe(u8, "test_name"));
    defer tc.deinit(allocator);

    try testing.expectEqualStrings(tc.id, "test_id");
    try testing.expectEqualStrings(tc.name, "test_name");
}

test "buildRequestBody: tool messages have tool_call_id" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // Regression: DeepSeek 400 error "missing field `tool_call_id`"
    // when tool messages were serialized without tool_call_id.
    const provider = Provider.init(allocator, std.Io.Test, config_mod.ProviderConfig{
        .name = "test",
        .npm = "@test/provider",
        .options = .{ .baseURL = "http://localhost:8080/v1/" },
    }, null);

    const tcs = [_]ToolCall{
        .{ .id = "call_deepseek_1", .name = "bash", .arguments = "{\"command\":\"ls\"}" },
    };

    const msgs = [_]Message{
        .{ .role = "user", .content = "run ls" },
        .{ .role = "assistant", .content = "", .tool_calls = &tcs },
        .{ .role = "tool", .content = "file1.txt\nfile2.txt", .tool_call_id = "call_deepseek_1" },
    };

    const req = ChatRequest{
        .model = "test-model",
        .messages = &msgs,
        .tools = null,
    };

    var body: ?[]const u8 = null;
    try provider.buildRequestBody(req, false, &body);
    defer if (body) |b| allocator.free(b);

    try testing.expect(body != null);
    const body_str = body.?;

    // Parse the JSON body
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_str, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expect(root == .object);

    // Check messages array
    const msgs_arr = root.object.get("messages").?;
    try testing.expect(msgs_arr == .array);
    try testing.expectEqual(msgs_arr.array.items.len, 3);

    // Tool message (index 2) MUST have tool_call_id
    const tool_msg = msgs_arr.array.items[2];
    try testing.expect(tool_msg == .object);
    const tool_call_id = tool_msg.object.get("tool_call_id");
    try testing.expect(tool_call_id != null);
    try testing.expectEqualStrings(tool_call_id.?.string, "call_deepseek_1");

    // Assistant message (index 1) MUST have tool_calls with id, function.name, function.arguments
    const asst_msg = msgs_arr.array.items[1];
    try testing.expect(asst_msg == .object);
    const tool_calls = asst_msg.object.get("tool_calls");
    try testing.expect(tool_calls != null);
    try testing.expect(tool_calls.? == .array);
    try testing.expectEqual(tool_calls.?.array.items.len, 1);

    const tc = tool_calls.?.array.items[0];
    try testing.expect(tc == .object);
    try testing.expectEqualStrings(tc.object.get("id").?.string, "call_deepseek_1");
    try testing.expectEqualStrings(tc.object.get("type").?.string, "function");

    const func = tc.object.get("function").?;
    try testing.expect(func == .object);
    try testing.expectEqualStrings(func.object.get("name").?.string, "bash");
    try testing.expectEqualStrings(func.object.get("arguments").?.string, "{\"command\":\"ls\"}");
}
