const std = @import("std");

pub const FlagType = enum { Bool, Int, String };

pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i32,
    String: []const u8,
};

pub const FlagDef = struct {
    name: []const u8,
    shortcut: ?[]const u8 = null,
    description: []const u8,
    type: FlagType,
    default_value: FlagValue,
    hidden: bool = false,
};

const ExecFn = *const fn (*Cmd) anyerror!void;

pub const Options = struct {
    name: []const u8,
    description: []const u8,
    version: ?std.SemanticVersion = null,
};

pub const Cmd = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    options: Options,
    exec_fn: ExecFn,
    flags_by_name: std.StringHashMap(FlagDef),
    flags_by_shortcut: std.StringHashMap(FlagDef),
    flag_values: std.StringHashMap(FlagValue),
    subcommands: std.StringHashMap(*Cmd),
    parent: ?*Cmd,
    max_len: usize,
    positional: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, reader: *std.Io.Reader, options: Options, exec_fn: ExecFn) !*Cmd {
        const cmd = try allocator.create(Cmd);
        errdefer allocator.destroy(cmd);
        cmd.* = .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .reader = reader,
            .options = options,
            .exec_fn = exec_fn,
            .flags_by_name = std.StringHashMap(FlagDef).init(allocator),
            .flags_by_shortcut = std.StringHashMap(FlagDef).init(allocator),
            .flag_values = std.StringHashMap(FlagValue).init(allocator),
            .subcommands = std.StringHashMap(*Cmd).init(allocator),
            .parent = null,
            .max_len = 0,
            .positional = std.ArrayList([]const u8).empty,
        };
        try cmd.addFlag(.{ .name = "help", .shortcut = "h", .description = "Shows the help for a command", .type = .Bool, .default_value = .{ .Bool = false } });
        return cmd;
    }

    pub fn deinit(self: *Cmd) void {
        {
            var it = self.flags_by_name.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        }
        self.flags_by_name.deinit();
        self.flags_by_shortcut.deinit();
        self.flag_values.deinit();
        {
            var it = self.subcommands.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.deinit();
                self.allocator.free(e.key_ptr.*);
                self.allocator.destroy(e.value_ptr.*);
            }
        }
        self.subcommands.deinit();
        self.positional.deinit(self.allocator);
    }

    pub fn addFlag(self: *Cmd, f: FlagDef) !void {
        const name = try self.allocator.dupe(u8, f.name);
        errdefer self.allocator.free(name);
        try self.flags_by_name.put(name, f);
        if (f.shortcut) |sc| try self.flags_by_shortcut.put(sc, f);
        try self.flag_values.put(f.name, f.default_value);
    }

    pub fn addFlags(self: *Cmd, flags: []const FlagDef) !void {
        for (flags) |fl| try self.addFlag(fl);
    }

    pub fn addSub(self: *Cmd, sub: *Cmd) !void {
        sub.parent = self;
        const name = try self.allocator.dupe(u8, sub.options.name);
        self.subcommands.put(name, sub) catch unreachable;
    }

    pub fn flag(self: *Cmd, flag_name: []const u8, comptime T: type) T {
        if (self.flag_values.get(flag_name)) |val| {
            return switch (val) {
                .Bool => |b| if (T == bool) b else default(T),
                .Int => |i| if (@typeInfo(T) == .int) @as(T, @intCast(i)) else default(T),
                .String => |s| if (T == []const u8) s else default(T),
            };
        }
        if (self.findFlag(flag_name)) |f| {
            return switch (f.default_value) {
                .Bool => |b| if (T == bool) b else default(T),
                .Int => |i| if (@typeInfo(T) == .int) @as(T, @intCast(i)) else default(T),
                .String => |s| if (T == []const u8) s else default(T),
            };
        }
        unreachable;
    }

    fn default(comptime T: type) T {
        return switch (@typeInfo(T)) {
            .bool => false,
            .int => 0,
            .pointer => |p| if (p.child == u8) "" else @compileError("unsupported pointer type"),
            else => @compileError("unsupported type for flag"),
        };
    }

    pub fn execute(self: *Cmd, args_iter: *std.process.Args.Iterator) !void {
        if (!args_iter.skip()) {
            try self.writer.flush();
            std.process.exit(1);
        }
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(self.allocator);
        while (args_iter.next()) |arg| try args.append(self.allocator, arg);
        const cmd = try self.findLeaf(&args);
        try cmd.parseFlags(&args);
        try cmd.exec_fn(cmd);
    }

    fn findLeaf(self: *Cmd, args: *std.ArrayList([]const u8)) !*Cmd {
        var current = self;
        while (args.items.len > 0 and !std.mem.startsWith(u8, args.items[0], "-")) {
            const next = current.subcommands.get(args.items[0]) orelse break;
            _ = args.orderedRemove(0);
            current = next;
        }
        return current;
    }

    fn parseFlags(self: *Cmd, args: *std.ArrayList([]const u8)) !void {
        while (args.items.len > 0) {
            const arg = args.items[0];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try self.printHelp();
                try self.writer.flush();
                std.process.exit(0);
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                if (std.mem.indexOf(u8, arg[2..], "=")) |eq| {
                    const fname = arg[2..][0..eq];
                    const val = arg[2 + eq + 1 ..];
                    const fd = self.findFlag(fname) orelse {
                        try self.writer.print("Unknown flag: --{s}\n", .{fname});
                        try self.writer.flush();
                        std.process.exit(1);
                    };
                    self.flag_values.put(fd.name, evaluate(fd, val) catch {
                        try self.writer.print("Invalid value for flag --{s}: '{s}'\n", .{ fname, val });
                        try self.writer.flush();
                        std.process.exit(1);
                    }) catch {};
                    _ = args.orderedRemove(0);
                } else {
                    const fname = arg[2..];
                    const fd = self.findFlag(fname) orelse {
                        try self.writer.print("Unknown flag: --{s}\n", .{fname});
                        try self.writer.flush();
                        std.process.exit(1);
                    };
                    if (fd.type == .Bool) {
                        if (args.items.len > 1) {
                            const nxt = args.items[1];
                            if (std.mem.eql(u8, nxt, "true") or std.mem.eql(u8, nxt, "false")) {
                                self.flag_values.put(fd.name, .{ .Bool = std.mem.eql(u8, nxt, "true") }) catch {};
                                _ = args.orderedRemove(0);
                                _ = args.orderedRemove(0);
                                continue;
                            }
                        }
                        self.flag_values.put(fd.name, .{ .Bool = true }) catch {};
                        _ = args.orderedRemove(0);
                    } else {
                        if (args.items.len < 2) {
                            try self.writer.print("Missing value for flag --{s}\n", .{fname});
                            try self.writer.flush();
                            std.process.exit(1);
                        }
                        const val = args.items[1];
                        self.flag_values.put(fd.name, evaluate(fd, val) catch {
                            try self.writer.print("Invalid value for flag --{s}: '{s}'\n", .{ fname, val });
                            try self.writer.flush();
                            std.process.exit(1);
                        }) catch {};
                        _ = args.orderedRemove(0);
                        _ = args.orderedRemove(0);
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                const shortcuts = arg[1..];
                for (shortcuts, 0..) |ch, j| {
                    const sc = [_]u8{ch};
                    const fd = self.findFlag(&sc) orelse {
                        try self.writer.print("Unknown flag: -{c}\n", .{ch});
                        try self.writer.flush();
                        std.process.exit(1);
                    };
                    if (fd.type == .Bool) {
                        self.flag_values.put(fd.name, .{ .Bool = true }) catch {};
                    } else {
                        if (j < shortcuts.len - 1) {
                            try self.writer.print("Flag -{c} ({s}) must be last in group since it expects a value\n", .{ ch, fd.name });
                            try self.writer.flush();
                            std.process.exit(1);
                        }
                        if (args.items.len < 2) {
                            try self.writer.print("Missing value for flag -{c} ({s})\n", .{ ch, fd.name });
                            try self.writer.flush();
                            std.process.exit(1);
                        }
                        self.flag_values.put(fd.name, evaluate(fd, args.items[1]) catch {
                            try self.writer.print("Invalid value for flag -{c} ({s}): '{s}'\n", .{ ch, fd.name, args.items[1] });
                            try self.writer.flush();
                            std.process.exit(1);
                        }) catch {};
                        _ = args.orderedRemove(0);
                    }
                }
                _ = args.orderedRemove(0);
            } else {
                try self.positional.append(self.allocator, args.orderedRemove(0));
            }
        }
    }

    fn findFlag(self: *Cmd, name: []const u8) ?FlagDef {
        if (self.flags_by_name.get(name)) |f| return f;
        if (self.flags_by_shortcut.get(name)) |f| return f;
        return null;
    }

    pub fn printHelp(self: *Cmd) !void {
        self.calcMaxLen();
        if (self.options.version) |ver| {
            try self.writer.print("{s}\n\x1b[2mv{f}\x1b[0m\n\n", .{ self.options.description, ver });
        } else {
            try self.writer.print("{s}\n\n", .{self.options.description});
        }
        var parents = std.ArrayList(*Cmd).empty;
        defer parents.deinit(self.allocator);
        {
            var cur: ?*Cmd = self;
            while (cur) |c| {
                if (c.parent) |p| try parents.append(self.allocator, p);
                cur = c.parent;
            }
        }
        try self.writer.print("Usage: ", .{});
        var i: usize = parents.items.len;
        while (i > 0) {
            i -= 1;
            try self.writer.print("{s} ", .{parents.items[i].options.name});
        }
        try self.writer.print("{s} [options]\n\n", .{self.options.name});
        if (self.subcommands.count() > 0) {
            try self.writer.print("Available commands:\n", .{});
            var subs = std.ArrayList(*Cmd).empty;
            defer subs.deinit(self.allocator);
            {
                var it = self.subcommands.iterator();
                while (it.next()) |e| try subs.append(self.allocator, e.value_ptr.*);
            }
            std.sort.insertion(*Cmd, subs.items, {}, struct {
                fn lt(_: void, a: *Cmd, b: *Cmd) bool {
                    return std.mem.order(u8, a.options.name, b.options.name) == .lt;
                }
            }.lt);
            for (subs.items) |sub| {
                try self.writer.print("   {s}", .{sub.options.name});
                try self.writer.splatByteAll(' ', self.max_len + 5 - sub.options.name.len);
                try self.writer.print("{s}\n", .{sub.options.description});
            }
            try self.writer.print("\n", .{});
        }
        if (self.flags_by_name.count() > 0) {
            try self.writer.print("Flags:\n", .{});
            var it = self.flags_by_name.valueIterator();
            while (it.next()) |f| {
                if (f.shortcut) |sc| {
                    try self.writer.print("   -{s}, ", .{sc});
                } else {
                    try self.writer.print("   ", .{});
                }
                try self.writer.print("--{s}", .{f.name});
                const len = f.name.len + 2 + (if (f.shortcut) |s| s.len + 3 else 0);
                try self.writer.splatByteAll(' ', self.max_len + 5 - len);
                try self.writer.print("{s} [{s}]", .{ f.description, @tagName(f.type) });
                switch (f.type) {
                    .Bool => try self.writer.print(" (default: {s})", .{if (f.default_value.Bool) "true" else "false"}),
                    .Int => try self.writer.print(" (default: {})", .{f.default_value.Int}),
                    .String => if (f.default_value.String.len > 0) try self.writer.print(" (default: \"{s}\")", .{f.default_value.String}),
                }
                try self.writer.print("\n", .{});
            }
            try self.writer.print("\n", .{});
        }
        try self.writer.print("Use \"", .{});
        i = parents.items.len;
        while (i > 0) {
            i -= 1;
            try self.writer.print("{s} ", .{parents.items[i].options.name});
        }
        try self.writer.print("{s}", .{self.options.name});
        if (self.subcommands.count() > 0) try self.writer.print(" [command]", .{});
        try self.writer.print(" --help\" for more information.\n", .{});
    }

    fn calcMaxLen(self: *Cmd) void {
        self.max_len = 0;
        {
            var it = self.subcommands.iterator();
            while (it.next()) |e| {
                const n = e.value_ptr.*.options.name.len;
                if (n > self.max_len) self.max_len = n;
            }
        }
        {
            var it = self.flags_by_name.iterator();
            while (it.next()) |e| {
                const n = e.value_ptr.*.name.len + 2 + (if (e.value_ptr.*.shortcut) |s| s.len + 3 else 0);
                if (n > self.max_len) self.max_len = n;
            }
        }
    }
};

fn evaluate(flag: FlagDef, value: []const u8) !FlagValue {
    return switch (flag.type) {
        .Bool => {
            if (std.mem.eql(u8, value, "true")) return .{ .Bool = true };
            if (std.mem.eql(u8, value, "false")) return .{ .Bool = false };
            return error.InvalidBooleanValue;
        },
        .Int => .{ .Int = try std.fmt.parseInt(i32, value, 10) },
        .String => .{ .String = value },
    };
}

test "evaluate: Bool true" {
    const testing = @import("std").testing;
    const result = try evaluate(.{ .name = "flag", .description = "", .type = .Bool, .default_value = .{ .Bool = false } }, "true");
    try testing.expect(result.Bool);
}

test "evaluate: Bool false" {
    const testing = @import("std").testing;
    const result = try evaluate(.{ .name = "flag", .description = "", .type = .Bool, .default_value = .{ .Bool = false } }, "false");
    try testing.expect(!result.Bool);
}

test "evaluate: Bool invalid" {
    const testing = @import("std").testing;
    try testing.expectError(error.InvalidBooleanValue, evaluate(.{ .name = "flag", .description = "", .type = .Bool, .default_value = .{ .Bool = false } }, "nope"));
}

test "evaluate: Int positive" {
    const testing = @import("std").testing;
    const result = try evaluate(.{ .name = "flag", .description = "", .type = .Int, .default_value = .{ .Int = 0 } }, "42");
    try testing.expectEqual(result.Int, 42);
}

test "evaluate: Int negative" {
    const testing = @import("std").testing;
    const result = try evaluate(.{ .name = "flag", .description = "", .type = .Int, .default_value = .{ .Int = 0 } }, "-1");
    try testing.expectEqual(result.Int, -1);
}

test "evaluate: Int invalid" {
    const testing = @import("std").testing;
    try testing.expectError(error.InvalidCharacter, evaluate(.{ .name = "flag", .description = "", .type = .Int, .default_value = .{ .Int = 0 } }, "abc"));
}

test "evaluate: String passthrough" {
    const testing = @import("std").testing;
    const result = try evaluate(.{ .name = "flag", .description = "", .type = .String, .default_value = .{ .String = "" } }, "hello");
    try testing.expectEqualStrings(result.String, "hello");
}

test "findFlag: by name" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cmd = try Cmd.init(allocator, undefined, undefined, undefined, .{ .name = "test", .description = "" }, struct {
        fn exec(_: *Cmd) !void {}
    }.exec);
    defer cmd.deinit();
    const f = cmd.findFlag("help");
    try testing.expect(f != null);
    try testing.expectEqualStrings(f.?.name, "help");
}

test "findFlag: by shortcut" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cmd = try Cmd.init(allocator, undefined, undefined, undefined, .{ .name = "test", .description = "" }, struct {
        fn exec(_: *Cmd) !void {}
    }.exec);
    defer cmd.deinit();
    const f = cmd.findFlag("h");
    try testing.expect(f != null);
    try testing.expectEqualStrings(f.?.name, "help");
}

test "findFlag: unknown" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cmd = try Cmd.init(allocator, undefined, undefined, undefined, .{ .name = "test", .description = "" }, struct {
        fn exec(_: *Cmd) !void {}
    }.exec);
    defer cmd.deinit();
    const f = cmd.findFlag("nonexistent");
    try testing.expect(f == null);
}
