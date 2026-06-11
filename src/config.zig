const std = @import("std");

const json = std.json;

pub const AgentConfig = struct {
    description: []const u8,
    systemPrompt: []const u8,

    pub fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.systemPrompt);
    }
};

pub const MCPServerConfig = struct {
    /// Transport type: "http" (default for url), "stdio" (default for command), "sse"
    transport: ?[]const u8 = null,
    url: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    env: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *MCPServerConfig, allocator: std.mem.Allocator) void {
        if (self.transport) |t| allocator.free(t);
        if (self.url) |u| allocator.free(u);
        if (self.command) |c| allocator.free(c);
        if (self.args) |arr| {
            for (arr) |a| allocator.free(a);
            allocator.free(arr);
        }
        if (self.env) |*env| {
            var iter = env.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            env.deinit();
        }
    }
};

pub const Config = struct {
    disabled_providers: ?[]const []const u8 = null,
    provider: ?std.StringHashMap(ProviderConfig) = null,
    agents: ?std.StringHashMap(AgentConfig) = null,
    mcp_servers: ?std.StringHashMap(MCPServerConfig) = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.provider) |*providers| {
            var iter = providers.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            providers.deinit();
        }
        if (self.disabled_providers) |dp| {
            for (dp) |p| allocator.free(p);
            allocator.free(dp);
        }
        if (self.agents) |*agents| {
            var iter = agents.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            agents.deinit();
        }
        if (self.mcp_servers) |*mcp| {
            var iter = mcp.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            mcp.deinit();
        }
    }

    pub fn empty() Config {
        return Config{
            .provider = null,
            .disabled_providers = null,
            .agents = null,
            .mcp_servers = null,
        };
    }
};

pub const ProviderConfig = struct {
    name: []const u8,
    npm: []const u8,
    options: ProviderOptions,
    models: ?std.StringHashMap(ModelConfig) = null,

    pub fn deinit(self: *ProviderConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.npm);
        self.options.deinit(allocator);
        if (self.models) |*models| {
            var iter = models.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            models.deinit();
        }
    }
};

pub const ProviderOptions = struct {
    baseURL: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *ProviderOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.baseURL);
        if (self.headers) |*h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            h.deinit();
        }
    }
};

pub const ModelConfig = struct {
    name: []const u8,

    pub fn deinit(self: *ModelConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Strip comments from JSONC text (// and /* */) and trailing commas.
/// Handles strings — does not strip `//` or `/*` inside string literals.
fn stripJsoncComments(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Handle string literals — pass through verbatim
        if (input[i] == '"') {
            try result.append(allocator, '"');
            i += 1;
            while (i < input.len and input[i] != '"') {
                if (input[i] == '\\') {
                    try result.append(allocator, input[i]);
                    i += 1;
                    if (i < input.len) {
                        try result.append(allocator, input[i]);
                        i += 1;
                    }
                } else {
                    try result.append(allocator, input[i]);
                    i += 1;
                }
            }
            if (i < input.len) {
                try result.append(allocator, '"');
                i += 1;
            }
            continue;
        }

        // Single-line comment
        if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '/') {
            i += 2;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            continue;
        }
        // Block comment
        if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < input.len) i += 2;
            continue;
        }
        // Trailing comma before } or ]
        if (input[i] == ',') {
            var j = i + 1;
            while (j < input.len and (input[j] == ' ' or input[j] == '\t' or input[j] == '\n' or input[j] == '\r')) : (j += 1) {}
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                i = j;
                continue;
            }
        }
        try result.append(allocator, input[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

/// Derive the expected API key env var name from a provider ID.
/// e.g. "my-provider" -> "MY_PROVIDER_API_KEY"
pub fn apiKeyEnvVar(provider_id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, provider_id.len + 9);
    errdefer buf.deinit(allocator);
    for (provider_id) |c| {
        if (c == '-') {
            try buf.append(allocator, '_');
        } else if (c >= 'a' and c <= 'z') {
            try buf.append(allocator, std.ascii.toUpper(c));
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.appendSlice(allocator, "_API_KEY");
    return buf.toOwnedSlice(allocator);
}

/// Load config from a file path. Returns null if file doesn't exist.
pub fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?Config {
    const dir = std.Io.Dir.cwd();
    const raw = std.Io.Dir.readFileAlloc(dir, io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);

    const cleaned = try stripJsoncComments(raw, allocator);
    defer allocator.free(cleaned);

    return (try parse(allocator, cleaned));
}

/// Parse config from a JSON string.
pub fn parse(allocator: std.mem.Allocator, json_text: []const u8) !Config {
    const parsed = try json.parseFromSlice(json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    var config = Config{};
    errdefer config.deinit(allocator);

    // disabled_providers
    if (root.object.get("disabled_providers")) |dp| {
        if (dp == .array) {
            const arr = try allocator.alloc([]const u8, dp.array.items.len);
            errdefer allocator.free(arr);
            for (dp.array.items, 0..) |item, i| {
                arr[i] = try allocator.dupe(u8, item.string);
            }
            config.disabled_providers = arr;
        }
    }

    // agent
    if (root.object.get("agent")) |agents_val| {
        if (agents_val == .object) {
            var agent_map = std.StringHashMap(AgentConfig).init(allocator);
            errdefer {
                var iter = agent_map.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                    allocator.free(entry.key_ptr.*);
                }
                agent_map.deinit();
            }
            var aiter = agents_val.object.iterator();
            while (aiter.next()) |entry| {
                const ak = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(ak);
                if (entry.value_ptr.* != .object) continue;
                const aobj = entry.value_ptr.*.object;
                const desc = try allocator.dupe(u8, aobj.get("description").?.string);
                errdefer allocator.free(desc);
                const sp = try allocator.dupe(u8, aobj.get("systemPrompt").?.string);
                errdefer allocator.free(sp);
                try agent_map.put(ak, .{ .description = desc, .systemPrompt = sp });
            }
            config.agents = agent_map;
        }
    }

    // mcpServers
    if (root.object.get("mcpServers")) |mcp_val| {
        if (mcp_val == .object) {
            var mcp_map = std.StringHashMap(MCPServerConfig).init(allocator);
            errdefer {
                var iter = mcp_map.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                    allocator.free(entry.key_ptr.*);
                }
                mcp_map.deinit();
            }
            var miter = mcp_val.object.iterator();
            while (miter.next()) |entry| {
                const mk = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(mk);
                if (entry.value_ptr.* != .object) continue;
                const obj = entry.value_ptr.*.object;

                var server_cfg = MCPServerConfig{};

                if (obj.get("transport")) |tv| {
                    if (tv == .string) server_cfg.transport = try allocator.dupe(u8, tv.string);
                }
                if (obj.get("url")) |uv| {
                    if (uv == .string) server_cfg.url = try allocator.dupe(u8, uv.string);
                }
                if (obj.get("command")) |cv| {
                    if (cv == .string) server_cfg.command = try allocator.dupe(u8, cv.string);
                }
                if (obj.get("args")) |av| {
                    if (av == .array) {
                        const arr = try allocator.alloc([]const u8, av.array.items.len);
                        errdefer allocator.free(arr);
                        for (av.array.items, 0..) |item, i| {
                            arr[i] = try allocator.dupe(u8, item.string);
                        }
                        server_cfg.args = arr;
                    }
                }
                if (obj.get("env")) |ev| {
                    if (ev == .object) {
                        var env_map = std.StringHashMap([]const u8).init(allocator);
                        errdefer {
                            var eiter = env_map.iterator();
                            while (eiter.next()) |eentry| {
                                allocator.free(eentry.key_ptr.*);
                                allocator.free(eentry.value_ptr.*);
                            }
                            env_map.deinit();
                        }
                        var eiter = ev.object.iterator();
                        while (eiter.next()) |eentry| {
                            const ek = try allocator.dupe(u8, eentry.key_ptr.*);
                            errdefer allocator.free(ek);
                            const evl = try allocator.dupe(u8, eentry.value_ptr.*.string);
                            errdefer allocator.free(evl);
                            try env_map.put(ek, evl);
                        }
                        server_cfg.env = env_map;
                    }
                }
                try mcp_map.put(mk, server_cfg);
            }
            config.mcp_servers = mcp_map;
        }
    }

    // provider
    if (root.object.get("provider")) |prov| {
        if (prov == .object) {
            var providers = std.StringHashMap(ProviderConfig).init(allocator);
            errdefer {
                var iter = providers.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                    allocator.free(entry.key_ptr.*);
                }
                providers.deinit();
            }

            var iter = prov.object.iterator();
            while (iter.next()) |entry| {
                const pkey = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(pkey);
                var pval = try parseProviderConfig(allocator, entry.value_ptr.*);
                errdefer pval.deinit(allocator);
                try providers.put(pkey, pval);
            }
            config.provider = providers;
        }
    }

    return config;
}

fn parseProviderConfig(allocator: std.mem.Allocator, val: json.Value) !ProviderConfig {
    if (val != .object) return error.InvalidConfig;
    const obj = val.object;

    const name = try allocator.dupe(u8, obj.get("name").?.string);
    errdefer allocator.free(name);

    const npm = try allocator.dupe(u8, obj.get("npm").?.string);
    errdefer allocator.free(npm);

    const opts_val = obj.get("options") orelse return error.InvalidConfig;
    var options = try parseProviderOptions(allocator, opts_val);
    errdefer options.deinit(allocator);

    var models: ?std.StringHashMap(ModelConfig) = null;
    if (obj.get("models")) |mval| {
        if (mval == .object) {
            var m = std.StringHashMap(ModelConfig).init(allocator);
            errdefer {
                var iter = m.iterator();
                while (iter.next()) |me| {
                    me.value_ptr.deinit(allocator);
                    allocator.free(me.key_ptr.*);
                }
                m.deinit();
            }
            var miter = mval.object.iterator();
            while (miter.next()) |me| {
                const mk = try allocator.dupe(u8, me.key_ptr.*);
                errdefer allocator.free(mk);
                var mv = try parseModelConfig(allocator, me.value_ptr.*);
                errdefer mv.deinit(allocator);
                try m.put(mk, mv);
            }
            models = m;
        }
    }

    return ProviderConfig{ .name = name, .npm = npm, .options = options, .models = models };
}

fn parseProviderOptions(allocator: std.mem.Allocator, val: json.Value) !ProviderOptions {
    if (val != .object) return error.InvalidConfig;
    const obj = val.object;

    const baseURL = try allocator.dupe(u8, obj.get("baseURL").?.string);
    errdefer allocator.free(baseURL);

    var headers: ?std.StringHashMap([]const u8) = null;
    if (obj.get("headers")) |hval| {
        if (hval == .object) {
            var h = std.StringHashMap([]const u8).init(allocator);
            errdefer {
                var iter = h.iterator();
                while (iter.next()) |he| {
                    allocator.free(he.key_ptr.*);
                    allocator.free(he.value_ptr.*);
                }
                h.deinit();
            }
            var hiter = hval.object.iterator();
            while (hiter.next()) |he| {
                const hk = try allocator.dupe(u8, he.key_ptr.*);
                errdefer allocator.free(hk);
                const hv = try allocator.dupe(u8, he.value_ptr.*.string);
                errdefer allocator.free(hv);
                try h.put(hk, hv);
            }
            headers = h;
        }
    }

    return ProviderOptions{ .baseURL = baseURL, .headers = headers };
}

fn parseModelConfig(allocator: std.mem.Allocator, val: json.Value) !ModelConfig {
    if (val != .object) return error.InvalidConfig;
    const name = if (val.object.get("name")) |n|
        try allocator.dupe(u8, n.string)
    else
        try allocator.dupe(u8, "unknown");
    return ModelConfig{ .name = name };
}

/// Find the config file. Checks project-level .agent/config.jsonc first,
/// then user-level ~/.config/agent/config.jsonc.
pub fn find(io: std.Io, allocator: std.mem.Allocator, project_dir: ?[]const u8) !?Config {
    const home = std.c.getenv("HOME") orelse return null;
    const home_path = try std.fmt.allocPrint(allocator, "{s}/.config/agent/config.jsonc", .{std.mem.span(home)});
    defer allocator.free(home_path);

    if (project_dir) |dir| {
        const proj_path = try std.fmt.allocPrint(allocator, "{s}/.agent/config.jsonc", .{dir});
        defer allocator.free(proj_path);
        if (try loadFile(io, allocator, proj_path)) |cfg| return cfg;
    }

    return loadFile(io, allocator, home_path);
}

test "stripJsoncComments: single-line" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const input = "{\"key\": \"value\" // comment\n}";
    const result = try stripJsoncComments(input, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "{\"key\": \"value\" \n}");
}

test "stripJsoncComments: block comment" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const input = "{\"key\": /* block */ \"value\"}";
    const result = try stripJsoncComments(input, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "{\"key\":  \"value\"}");
}

test "stripJsoncComments: trailing comma" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const input = "{\"a\": 1, \"b\": 2,}";
    const result = try stripJsoncComments(input, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "{\"a\": 1, \"b\": 2}");
}

test "stripJsoncComments: preserves string with // inside" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const input = "{\"url\": \"http://example.com\"}";
    const result = try stripJsoncComments(input, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, input);
}

test "apiKeyEnvVar: simple provider" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const result = try apiKeyEnvVar("my-provider", allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "MY_PROVIDER_API_KEY");
}

test "apiKeyEnvVar: all-caps provider" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const result = try apiKeyEnvVar("OPENCODE", allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "OPENCODE_API_KEY");
}

test "apiKeyEnvVar: with dots" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const result = try apiKeyEnvVar("my.provider", allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(result, "MY.PROVIDER_API_KEY");
}

test "parse: minimal provider config" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const json_text =
        \\{
        \\  "provider": {
        \\    "test-provider": {
        \\      "name": "Test",
        \\      "npm": "@test/provider",
        \\      "options": {
        \\        "baseURL": "http://localhost:8080/v1"
        \\      },
        \\      "models": {
        \\        "model-1": { "id": "m1", "name": "Model 1", "contextTokens": 4096 }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var cfg = try parse(allocator, json_text);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.provider != null);
    const entry = cfg.provider.?.get("test-provider").?;
    try testing.expectEqualStrings(entry.name, "Test");
    try testing.expectEqualStrings(entry.options.baseURL, "http://localhost:8080/v1");
    try testing.expect(entry.models != null);
    const m = entry.models.?.get("model-1").?;
    try testing.expectEqualStrings(m.name, "Model 1");
}

test "parse: with agents" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const json_text =
        \\{
        \\  "agent": {
        \\    "my-agent": {
        \\      "description": "My custom agent",
        \\      "systemPrompt": "You are a custom agent"
        \\    }
        \\  }
        \\}
    ;
    var cfg = try parse(allocator, json_text);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.agents != null);
    const a = cfg.agents.?.get("my-agent").?;
    try testing.expectEqualStrings(a.description, "My custom agent");
    try testing.expectEqualStrings(a.systemPrompt, "You are a custom agent");
}

test "parse: with disabled_providers" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const json_text =
        \\{ "disabled_providers": ["provider-a", "provider-b"] }
    ;
    var cfg = try parse(allocator, json_text);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.disabled_providers != null);
    try testing.expectEqualStrings(cfg.disabled_providers.?[0], "provider-a");
    try testing.expectEqualStrings(cfg.disabled_providers.?[1], "provider-b");
}

test "parse: empty config" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var cfg = try parse(allocator, "{}");
    defer cfg.deinit(allocator);
    try testing.expect(cfg.provider == null);
    try testing.expect(cfg.agents == null);
    try testing.expect(cfg.disabled_providers == null);
}
