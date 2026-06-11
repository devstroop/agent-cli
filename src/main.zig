const std = @import("std");
const Io = std.Io;
const native_os = @import("builtin").os.tag;

const sdk = @import("agent-sdk");
const cli = @import("cli.zig");
const exec_mod = @import("exec.zig");

// ── Windows TTY detection ───────────────────────────────────────────────────

const Win32Console = struct {
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.winapi) i32;
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
};

fn stdinIsTty() bool {
    if (native_os == .windows) {
        const handle = Win32Console.GetStdHandle(Win32Console.STD_INPUT_HANDLE) orelse return false;
        var mode: u32 = 0;
        return Win32Console.GetConsoleMode(handle, &mode) != 0;
    }
    return std.c.isatty(std.posix.STDIN_FILENO) != 0;
}

// ── Main ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var wbuf: [4096]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [4096]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    const root = try cli.Cmd.init(gpa, io, stdout, stdin, .{
        .name = "agent",
        .description = "A lightweight CLI client for OpenCode",
        .version = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 0 },
    }, struct { fn exec(_: *cli.Cmd) !void {} }.exec);
    defer { root.deinit(); gpa.destroy(root); }

    // ── Subcommands ─────────────────────────────────────────────────────────

    try addRunCmd(root, gpa, io, stdout, stdin);
    try addAskCmd(root, gpa, io, stdout, stdin);
    try addPlanCmd(root, gpa, io, stdout, stdin);
    try addReviewCmd(root, gpa, io, stdout, stdin);
    try addEditCmd(root, gpa, io, stdout, stdin);
    try addSessionCmd(root, gpa, io, stdout, stdin);
    try addModelsCmd(root, gpa, io, stdout, stdin);
    try addConfigCmd(root, gpa, io, stdout, stdin);

    var args_iter = try std.process.Args.iterateAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    try root.execute(&args_iter);
}

// ── CLI registration helpers ────────────────────────────────────────────────

fn addRunCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "run", .description = "Send a prompt to an LLM and print the response" }, exec_mod.runExec);
    try cmd.addFlags(&runFlags);
    try root.addSub(cmd);
}

fn addAskCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "ask", .description = "Get a quick answer -- no tools, just knowledge" }, exec_mod.askExec);
    try cmd.addFlags(&askFlags);
    try root.addSub(cmd);
}

fn addPlanCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "plan", .description = "Create a structured plan and save to PLAN.md" }, exec_mod.planExec);
    try cmd.addFlags(&planFlags);
    try root.addSub(cmd);
}

fn addReviewCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "review", .description = "Review a session and provide assessment" }, exec_mod.reviewExec);
    try cmd.addFlags(&reviewFlags);
    try root.addSub(cmd);
}

fn addEditCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "edit", .description = "Edit files -- execute mode constrained to read/write/edit tools" }, exec_mod.editExec);
    try cmd.addFlags(&editFlags);
    try root.addSub(cmd);
}

fn addSessionCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const session_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "session", .description = "Manage sessions" }, exec_mod.sessionExec);
    const list_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "list", .description = "List all sessions" }, exec_mod.sessionListExec);
    try session_cmd.addSub(list_cmd);
    const show_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "show", .description = "Show a session by ID" }, exec_mod.sessionShowExec);
    try show_cmd.addFlag(.{ .name = "id", .type = .String, .description = "Session ID", .default_value = .{ .String = "" } });
    try session_cmd.addSub(show_cmd);
    try root.addSub(session_cmd);
}

fn addModelsCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "models", .description = "List available models from config" }, exec_mod.modelsExec);
    try cmd.addFlag(.{ .name = "config", .type = .String, .description = "Path to config file", .default_value = .{ .String = "" } });
    try root.addSub(cmd);
}

fn addConfigCmd(root: *cli.Cmd, gpa: std.mem.Allocator, io: std.Io, stdout: *Io.Writer, stdin: *Io.Reader) !void {
    const config_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "config", .description = "Manage agent configuration" }, struct { fn exec(_: *cli.Cmd) !void {} }.exec);
    const init_cmd = try cli.Cmd.init(gpa, io, stdout, stdin, .{ .name = "init", .description = "Interactive setup wizard — creates ~/.config/agent/config.jsonc" }, exec_mod.configInitExec);
    try config_cmd.addSub(init_cmd);
    try root.addSub(config_cmd);
}

// ── Shared flag definitions ─────────────────────────────────────────────────

const runFlags = [_]cli.FlagDef{
    .{ .name = "message", .type = .String, .description = "The prompt message", .default_value = .{ .String = "" } },
    .{ .name = "model", .type = .String, .description = "Model to use (provider/model)", .shortcut = "m", .default_value = .{ .String = "" } },
    .{ .name = "agent", .type = .String, .description = "Agent type to use", .default_value = .{ .String = "" } },
    .{ .name = "dir", .type = .String, .description = "Project directory", .default_value = .{ .String = "" } },
    .{ .name = "raw", .type = .Bool, .description = "Output raw text without markdown rendering", .default_value = .{ .Bool = false } },
    .{ .name = "format", .type = .String, .description = "Output format: default or json", .default_value = .{ .String = "default" } },
    .{ .name = "thinking", .type = .Bool, .description = "Show reasoning/thinking blocks", .default_value = .{ .Bool = false } },
    .{ .name = "skip-permissions", .type = .Bool, .description = "Skip permission prompts (use with caution)", .default_value = .{ .Bool = false } },
    .{ .name = "title", .type = .String, .description = "Session title", .default_value = .{ .String = "" } },
    .{ .name = "variant", .type = .String, .description = "Model variant (reasoning effort)", .default_value = .{ .String = "" } },
    .{ .name = "command", .type = .String, .description = "Slash command to execute", .default_value = .{ .String = "" } },
    .{ .name = "file", .type = .String, .description = "File(s) to attach", .shortcut = "f", .default_value = .{ .String = "" } },
    .{ .name = "continue", .type = .Bool, .description = "Continue the last session", .shortcut = "c", .default_value = .{ .Bool = false } },
    .{ .name = "session", .type = .String, .description = "Session ID to resume", .shortcut = "s", .default_value = .{ .String = "" } },
    .{ .name = "fork", .type = .Bool, .description = "Fork session before continuing", .default_value = .{ .Bool = false } },
    .{ .name = "share", .type = .Bool, .description = "Create a shareable link for the session", .default_value = .{ .Bool = false } },
    .{ .name = "config", .type = .String, .description = "Path to agent config.jsonc", .default_value = .{ .String = "" } },
    .{ .name = "max-tokens", .type = .Int, .description = "Maximum output tokens", .default_value = .{ .Int = 0 } },
    .{ .name = "temperature", .type = .String, .description = "Sampling temperature (0.0-2.0)", .default_value = .{ .String = "" } },
    .{ .name = "top-p", .type = .String, .description = "Nucleus sampling parameter (0.0-1.0)", .default_value = .{ .String = "" } },
};

const askFlags = [_]cli.FlagDef{
    .{ .name = "message", .type = .String, .description = "The question to ask", .default_value = .{ .String = "" } },
    .{ .name = "model", .type = .String, .description = "Model to use (provider/model)", .shortcut = "m", .default_value = .{ .String = "" } },
    .{ .name = "dir", .type = .String, .description = "Project directory", .default_value = .{ .String = "" } },
    .{ .name = "raw", .type = .Bool, .description = "Output raw text without markdown rendering", .default_value = .{ .Bool = false } },
    .{ .name = "format", .type = .String, .description = "Output format: default or json", .default_value = .{ .String = "default" } },
    .{ .name = "file", .type = .String, .description = "File(s) to attach", .shortcut = "f", .default_value = .{ .String = "" } },
    .{ .name = "config", .type = .String, .description = "Path to agent config.jsonc", .default_value = .{ .String = "" } },
    .{ .name = "max-tokens", .type = .Int, .description = "Maximum output tokens", .default_value = .{ .Int = 0 } },
    .{ .name = "temperature", .type = .String, .description = "Sampling temperature (0.0-2.0)", .default_value = .{ .String = "" } },
    .{ .name = "top-p", .type = .String, .description = "Nucleus sampling parameter (0.0-1.0)", .default_value = .{ .String = "" } },
    .{ .name = "continue", .type = .Bool, .description = "Continue the last session", .shortcut = "c", .default_value = .{ .Bool = false } },
    .{ .name = "session", .type = .String, .description = "Session ID to resume", .shortcut = "s", .default_value = .{ .String = "" } },
};

const planFlags = [_]cli.FlagDef{
    .{ .name = "message", .type = .String, .description = "The task to plan for", .default_value = .{ .String = "" } },
    .{ .name = "model", .type = .String, .description = "Model to use (provider/model)", .shortcut = "m", .default_value = .{ .String = "" } },
    .{ .name = "raw", .type = .Bool, .description = "Output raw text without markdown rendering", .default_value = .{ .Bool = false } },
    .{ .name = "dir", .type = .String, .description = "Project directory", .default_value = .{ .String = "" } },
    .{ .name = "file", .type = .String, .description = "File(s) to attach", .shortcut = "f", .default_value = .{ .String = "" } },
    .{ .name = "config", .type = .String, .description = "Path to agent config.jsonc", .default_value = .{ .String = "" } },
    .{ .name = "max-tokens", .type = .Int, .description = "Maximum output tokens", .default_value = .{ .Int = 0 } },
    .{ .name = "temperature", .type = .String, .description = "Sampling temperature (0.0-2.0)", .default_value = .{ .String = "" } },
    .{ .name = "continue", .type = .Bool, .description = "Continue the last session", .shortcut = "c", .default_value = .{ .Bool = false } },
    .{ .name = "session", .type = .String, .description = "Session ID to resume", .shortcut = "s", .default_value = .{ .String = "" } },
};

const reviewFlags = [_]cli.FlagDef{
    .{ .name = "raw", .type = .Bool, .description = "Output raw text without markdown rendering", .default_value = .{ .Bool = false } },
    .{ .name = "session", .type = .String, .description = "Session ID to review", .shortcut = "s", .default_value = .{ .String = "" } },
    .{ .name = "model", .type = .String, .description = "Model to use (provider/model)", .shortcut = "m", .default_value = .{ .String = "" } },
    .{ .name = "dir", .type = .String, .description = "Project directory", .default_value = .{ .String = "" } },
    .{ .name = "config", .type = .String, .description = "Path to agent config.jsonc", .default_value = .{ .String = "" } },
    .{ .name = "max-tokens", .type = .Int, .description = "Maximum output tokens", .default_value = .{ .Int = 0 } },
    .{ .name = "temperature", .type = .String, .description = "Sampling temperature (0.0-2.0)", .default_value = .{ .String = "" } },
};

const editFlags = [_]cli.FlagDef{
    .{ .name = "message", .type = .String, .description = "The edit instruction", .default_value = .{ .String = "" } },
    .{ .name = "model", .type = .String, .description = "Model to use (provider/model)", .shortcut = "m", .default_value = .{ .String = "" } },
    .{ .name = "dir", .type = .String, .description = "Project directory", .default_value = .{ .String = "" } },
    .{ .name = "raw", .type = .Bool, .description = "Output raw text without markdown rendering", .default_value = .{ .Bool = false } },
    .{ .name = "format", .type = .String, .description = "Output format: default or json", .default_value = .{ .String = "default" } },
    .{ .name = "skip-permissions", .type = .Bool, .description = "Skip permission prompts (use with caution)", .default_value = .{ .Bool = false } },
    .{ .name = "file", .type = .String, .description = "File(s) to edit", .shortcut = "f", .default_value = .{ .String = "" } },
    .{ .name = "config", .type = .String, .description = "Path to agent config.jsonc", .default_value = .{ .String = "" } },
    .{ .name = "max-tokens", .type = .Int, .description = "Maximum output tokens", .default_value = .{ .Int = 0 } },
    .{ .name = "temperature", .type = .String, .description = "Sampling temperature (0.0-2.0)", .default_value = .{ .String = "" } },
};
