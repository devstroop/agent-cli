const std = @import("std");
const types = @import("types.zig");

/// SSE parser for OpenCode event stream.
///
/// Reads from a raw reader (HTTP response body), parses standard SSE protocol,
/// and calls a callback for each parsed GlobalEvent. The callback receives
/// both the context and the parsed event.
pub const ParseError = error{
    JsonParse,
} || std.Io.Reader.Error || std.mem.Allocator.Error;

pub fn parseEvents(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    buf: []u8,
    context: anytype,
    callback: fn (@TypeOf(context), types.GlobalEvent) anyerror!void,
) anyerror!void {
    const State = enum {
        field_start,
        reading_data,
        reading_event,
        reading_id,
        reading_retry,
        skip_until_eol,
        skip_comment,
    };

    var state: State = .field_start;
    var data_buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer data_buf.deinit(allocator);
    var field_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer field_buf.deinit(allocator);

    while (true) {
        const n = try std.Io.Reader.readSliceShort(reader, buf);
        if (n == 0) {
            if (data_buf.items.len > 0) {
                try emitEventSse(allocator, data_buf.items, context, callback);
            }
            return;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ch = buf[i];

            switch (state) {
                .field_start => {
                    if (ch == '\n') {
                        if (data_buf.items.len > 0) {
                            const json_str = data_buf.items;
                            try emitEventSse(allocator, json_str, context, callback);
                            data_buf.clearRetainingCapacity();
                        }
                        continue;
                    }
                    if (ch == ':') {
                        state = .skip_comment;
                        continue;
                    }
                    if (ch == 'd') {
                        field_buf.clearRetainingCapacity();
                        try field_buf.append(allocator, ch);
                        state = .reading_data;
                        continue;
                    }
                    if (ch == 'e') {
                        field_buf.clearRetainingCapacity();
                        try field_buf.append(allocator, ch);
                        state = .reading_event;
                        continue;
                    }
                    if (ch == 'i') {
                        field_buf.clearRetainingCapacity();
                        try field_buf.append(allocator, ch);
                        state = .reading_id;
                        continue;
                    }
                    if (ch == 'r') {
                        field_buf.clearRetainingCapacity();
                        try field_buf.append(allocator, ch);
                        state = .reading_retry;
                        continue;
                    }
                    state = .skip_until_eol;
                },

                .reading_data => {
                    if (ch == ':') {
                        if (std.mem.eql(u8, field_buf.items, "data")) {
                            if (i + 1 < n and buf[i + 1] == ' ') i += 1;
                            i += 1;
                            while (i < n and buf[i] != '\n') : (i += 1) {
                                try data_buf.append(allocator, buf[i]);
                            }
                            state = .field_start;
                            continue;
                        } else {
                            state = .skip_until_eol;
                            continue;
                        }
                    }
                    if (ch == '\n') {
                        state = .field_start;
                        continue;
                    }
                    try field_buf.append(allocator, ch);
                },

                .reading_event => {
                    if (ch == ':') {
                        state = .skip_until_eol;
                        continue;
                    }
                    if (ch == '\n') {
                        state = .field_start;
                        continue;
                    }
                    try field_buf.append(allocator, ch);
                },

                .reading_id => {
                    if (ch == ':') {
                        state = .skip_until_eol;
                        continue;
                    }
                    if (ch == '\n') {
                        state = .field_start;
                        continue;
                    }
                    try field_buf.append(allocator, ch);
                },

                .reading_retry => {
                    if (ch == ':') {
                        state = .skip_until_eol;
                        continue;
                    }
                    if (ch == '\n') {
                        state = .field_start;
                        continue;
                    }
                    try field_buf.append(allocator, ch);
                },

                .skip_until_eol => {
                    if (ch == '\n') {
                        state = .field_start;
                    }
                },

                .skip_comment => {
                    if (ch == '\n') {
                        state = .field_start;
                    }
                },
            }
        }
    }
}

fn emitEventSse(
    allocator: std.mem.Allocator,
    json_str: []const u8,
    context: anytype,
    callback: fn (@TypeOf(context), types.GlobalEvent) anyerror!void,
) anyerror!void {
    const parsed = std.json.parseFromSlice(
        types.GlobalEvent,
        allocator,
        json_str,
        .{},
    ) catch |err| {
        std.log.warn("SSE: failed to parse JSON: {} (data: {s})", .{ err, json_str[0..@min(json_str.len, 200)] });
        return;
    };
    defer parsed.deinit();
    try callback(context, parsed.value);
}
