const std = @import("std");

pub fn shareSession(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, title: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://opencode.ai/api/share", .{});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var headers: std.http.Client.Request.Headers = .{};
    headers.content_type = .{ .override = "application/json" };

    if (std.c.getenv("OPENCODE_API_KEY")) |key| {
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{std.mem.span(key)});
        defer allocator.free(auth);
        headers.authorization = .{ .override = auth };
    }

    const body = try std.fmt.allocPrint(allocator, "{{\"sessionID\":\"{s}\",\"title\":\"{s}\"}}", .{ session_id, title });
    defer allocator.free(body);

    var redirect_buf: [4096]u8 = undefined;
    var request = try client.request(.POST, uri, .{ .headers = headers });
    defer request.deinit();

    try request.sendBodyComplete(@constCast(body));
    var response = try request.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        return error.ShareFailed;
    }

    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const resp_body = try reader.allocRemaining(allocator, std.Io.Limit.limited(65536));
    defer allocator.free(resp_body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    if (root.object.get("url")) |url_val| {
        if (url_val == .string) {
            return try allocator.dupe(u8, url_val.string);
        }
    }

    if (root.object.get("shareURL")) |url_val| {
        if (url_val == .string) {
            return try allocator.dupe(u8, url_val.string);
        }
    }

    return error.ShareUrlNotFound;
}
