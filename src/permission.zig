const std = @import("std");

/// Action to take for a permission request.
pub const Action = enum {
    allow,
    deny,
    ask,
};

/// A permission rule.
pub const Rule = struct {
    permission: []const u8,
    pattern: []const u8,
    action: Action,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.permission);
        allocator.free(self.pattern);
    }

    /// Check if this rule matches a given permission+pattern.
    pub fn matches(self: *const Rule, perm: []const u8, pattern: []const u8) bool {
        if (!globMatch(self.pattern, pattern)) return false;
        if (std.mem.eql(u8, self.permission, "*")) return true;
        return std.mem.eql(u8, self.permission, perm);
    }
};

/// Simple glob matching (* matches anything).
fn globMatch(pattern: []const u8, input: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.indexOfScalar(u8, pattern, '*')) |_| {
        // Simple prefix/suffix matching
        if (pattern[0] == '*') {
            const suffix = pattern[1..];
            if (suffix.len == 0) return true;
            return std.mem.endsWith(u8, input, suffix);
        }
        if (pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, input, prefix);
        }
    }
    return std.mem.eql(u8, pattern, input);
}

/// Permission manager.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayListUnmanaged(Rule) = .{},

    pub fn init(allocator: std.mem.Allocator) Manager {
        return Manager{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.rules.items) |*r| r.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    pub fn addRule(self: *Manager, rule: Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    /// Evaluate a permission request. Returns the action to take.
    pub fn evaluate(self: *const Manager, permission: []const u8, pattern: []const u8) Action {
        for (self.rules.items) |*rule| {
            if (rule.matches(permission, pattern)) return rule.action;
        }
        return .ask;
    }
};

test "globMatch basic" {
    const testing = @import("std").testing;
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("*.zig", "main.zig"));
    try testing.expect(!globMatch("*.zig", "main.ts"));
    try testing.expect(globMatch("foo*", "foobar"));
    try testing.expect(globMatch("*bar", "foobar"));
    try testing.expect(globMatch("exact", "exact"));
    try testing.expect(!globMatch("exact", "not-exact"));
}

test "globMatch prefix suffix" {
    const testing = @import("std").testing;
    try testing.expect(globMatch("/tmp/*", "/tmp/foo.txt"));
    try testing.expect(!globMatch("/tmp/*", "/var/foo.txt"));
}

test "Rule matches" {
    const testing = @import("std").testing;
    var rule = Rule{ .permission = "bash", .pattern = "*", .action = .allow };
    try testing.expect(rule.matches("bash", "echo hi"));
    try testing.expect(!rule.matches("read", "echo hi"));
}

test "Manager evaluate" {
    const testing = @import("std").testing;
    var man = Manager.init(testing.allocator);
    defer man.deinit();
    try man.addRule(.{ .permission = "bash", .pattern = "*", .action = .allow });
    try man.addRule(.{ .permission = "read", .pattern = "/tmp/*", .action = .deny });
    try testing.expectEqual(man.evaluate("bash", "echo hi"), .allow);
    try testing.expectEqual(man.evaluate("read", "/tmp/secret.txt"), .deny);
    try testing.expectEqual(man.evaluate("read", "/etc/passwd"), .ask);
    try testing.expectEqual(man.evaluate("write", "/tmp/test"), .ask);
}
