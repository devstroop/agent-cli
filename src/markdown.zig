//! Streaming markdown-to-ANSI renderer.
//!
//! Line-buffered state machine that renders common markdown patterns
//! (headings, code blocks, bold, italic, inline code, links, lists)
//! as ANSI escape sequences on a terminal writer.  The renderer
//! accumulates text until a newline arrives, then classifies and
//! renders the complete line immediately — this keeps latency under
//! one line (~50 ms for typical LLM output speeds).
//!
//! No external dependencies, no full-document parsing, no syntax
//! highlighting.  ~150 lines of pure Zig.

const std = @import("std");
const testing = std.testing;

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_bold_off = "\x1b[22m";
const ansi_dim = "\x1b[2m";
const ansi_italic = "\x1b[3m";
const ansi_italic_off = "\x1b[23m";
const ansi_underline = "\x1b[4m";
const ansi_cyan = "\x1b[96m";
const ansi_blue = "\x1b[94m";
const ansi_fg_off = "\x1b[39m";

pub const MdRenderer = struct {
    writer: *std.Io.Writer,
    in_code_block: bool,
    line_buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) !MdRenderer {
        return MdRenderer{
            .writer = writer,
            .in_code_block = false,
            .line_buf = try std.ArrayList(u8).initCapacity(allocator, 4096),
            .allocator = allocator,
        };
    }

    /// Append a text chunk.  Complete lines (terminated by \n) are
    /// rendered immediately; any trailing partial line stays buffered.
    pub fn feed(self: *MdRenderer, chunk: []const u8) !void {
        try self.line_buf.appendSlice(self.allocator, chunk);

        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.line_buf.items, '\n') orelse break;
            const line = self.line_buf.items[0..nl];
            try self.renderLine(line);
            // Remove the rendered line from the buffer.
            const keep = self.line_buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.line_buf.items[0..keep], self.line_buf.items[nl + 1 ..]);
            self.line_buf.shrinkRetainingCapacity(keep);
        }
    }

    /// Flush any remaining buffered text.  If a code block is still
    /// open it is closed first, then remaining bytes are rendered inline.
    pub fn flush(self: *MdRenderer) !void {
        if (self.in_code_block) {
            try self.writer.print(ansi_reset, .{});
            self.in_code_block = false;
        }
        if (self.line_buf.items.len > 0) {
            try self.renderInline(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
        try self.writer.flush();
    }

    pub fn deinit(self: *MdRenderer) void {
        self.line_buf.deinit(self.allocator);
    }

    // ── line classification ──────────────────────────────────────

    fn renderLine(self: *MdRenderer, line: []const u8) !void {
        if (self.in_code_block) {
            // Check for closing fence.
            if (isCodeFence(line)) {
                try self.writer.print(ansi_dim ++ "{s}" ++ ansi_reset ++ "\n", .{line});
                self.in_code_block = false;
            } else {
                try self.writer.print(ansi_dim ++ "│ {s}" ++ ansi_reset ++ "\n", .{line});
            }
            return;
        }

        // Opening code fence.
        if (isCodeFence(line)) {
            self.in_code_block = true;
            const lang = fenceLanguage(line);
            try self.writer.print(ansi_dim ++ "```" ++ ansi_cyan ++ "{s}" ++ ansi_reset ++ "\n", .{lang});
            return;
        }

        // Heading: # through ######
        if (line.len > 0 and line[0] == '#') {
            const level = countLeadingHash(line);
            if (level <= 6 and level < line.len and line[level] == ' ') {
                const text = line[level + 1 ..];
                if (level == 1) {
                    try self.writer.print(ansi_bold ++ ansi_underline ++ "{s}" ++ ansi_reset ++ "\n", .{text});
                } else {
                    try self.writer.print(ansi_bold ++ "{s}" ++ ansi_reset ++ "\n", .{text});
                }
                return;
            }
        }

        // Unordered list: "- " or "* " → "• "
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            try self.writer.print("• ", .{});
            try self.renderInline(line[2..]);
            try self.writer.print("\n", .{});
            return;
        }

        // Ordered list: "1. " etc.
        if (line.len >= 3 and isDigit(line[0])) {
            var i: usize = 1;
            while (i < line.len and isDigit(line[i])) : (i += 1) {}
            if (i < line.len and line[i] == '.' and i + 1 < line.len and line[i + 1] == ' ') {
                try self.writer.print("{s} ", .{line[0 .. i + 1]});
                try self.renderInline(line[i + 2 ..]);
                try self.writer.print("\n", .{});
                return;
            }
        }

        // Horizontal rule: --- or ***
        if (isHorizontalRule(line)) {
            try self.writer.print(ansi_dim ++ "───" ++ ansi_reset ++ "\n", .{});
            return;
        }

        // Blockquote: >
        if (line.len > 0 and line[0] == '>') {
            const rest = if (line.len > 1 and line[1] == ' ') line[2..] else line[1..];
            try self.writer.print(ansi_dim ++ "▎ " ++ ansi_reset, .{});
            try self.renderInline(rest);
            try self.writer.print("\n", .{});
            return;
        }

        // Regular paragraph.
        try self.renderInline(line);
        try self.writer.print("\n", .{});
    }

    // ── inline formatting state machine ──────────────────────────

    fn renderInline(self: *MdRenderer, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            // Bold ** ... **
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
                i += 2;
                if (std.mem.indexOf(u8, text[i..], "**")) |end| {
                    try self.writer.print(ansi_bold ++ "{s}" ++ ansi_bold_off, .{text[i .. i + end]});
                    i += end + 2;
                } else {
                    try self.writer.print("**", .{});
                }
                continue;
            }

            // Italic * ... *  (single *, not adjacent to space on inside)
            if (text[i] == '*' and (i == 0 or text[i - 1] != '*') and
                i + 1 < text.len and text[i + 1] != ' ' and text[i + 1] != '*')
            {
                var j = i + 1;
                var found: ?usize = null;
                while (j < text.len) : (j += 1) {
                    if (text[j] == '*') {
                        // Not part of **
                        if (j + 1 == text.len or text[j + 1] != '*') {
                            found = j;
                            break;
                        }
                        j += 1; // skip the second *
                    }
                }
                if (found) |end| {
                    try self.writer.print(ansi_italic ++ "{s}" ++ ansi_italic_off, .{text[i + 1 .. end]});
                    i = end + 1;
                } else {
                    try self.writer.print("*", .{});
                    i += 1;
                }
                continue;
            }

            // Inline code ` ... `
            if (text[i] == '`') {
                if (std.mem.indexOfScalar(u8, text[i + 1 ..], '`')) |end| {
                    try self.writer.print(ansi_cyan ++ "{s}" ++ ansi_fg_off, .{text[i + 1 .. i + 1 + end]});
                    i = i + 1 + end + 1;
                } else {
                    try self.writer.print("`", .{});
                    i += 1;
                }
                continue;
            }

            // Link [text](url)  —  only text is rendered (in blue), URL discarded.
            if (text[i] == '[') {
                if (std.mem.indexOfScalar(u8, text[i + 1 ..], ']')) |close_br| {
                    const br_end = i + 1 + close_br;
                    if (br_end + 1 < text.len and text[br_end + 1] == '(') {
                        if (std.mem.indexOfScalar(u8, text[br_end + 2 ..], ')')) |close_paren| {
                            const link_text = text[i + 1 .. br_end];
                            try self.writer.print(ansi_blue ++ "{s}" ++ ansi_fg_off, .{link_text});
                            i = br_end + 2 + close_paren + 1;
                            continue;
                        }
                    }
                }
                try self.writer.print("[", .{});
                i += 1;
                continue;
            }

            // Literal character.
            try self.writer.writeByte(text[i]);
            i += 1;
        }
    }
};

// ── helpers ──────────────────────────────────────────────────────

fn countLeadingHash(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and n < 6 and line[n] == '#') : (n += 1) {}
    return n;
}

fn isCodeFence(line: []const u8) bool {
    if (line.len < 3) return false;
    if (line[0] != '`' or line[1] != '`' or line[2] != '`') return false;
    // Must start with at least 3 backticks.
    return true;
}

fn fenceLanguage(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '`') : (i += 1) {}
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    return line[i..];
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const c = line[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == c) continue;
        if (line[i] != ' ') return false;
    }
    // Count: at least 3 of the same character
    var count: usize = 0;
    for (line) |ch| {
        if (ch == c) count += 1;
    }
    return count >= 3;
}

// ═══════════════════════════════════════════════════════════════════
//  Unit Tests
// ═══════════════════════════════════════════════════════════════════

fn captureInit(gpa: std.mem.Allocator) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(gpa);
}

fn captureWritten(cap: *std.Io.Writer.Allocating) []const u8 {
    return cap.written();
}

test "bold **text**" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("hello **world**\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1mworld\x1b[22m") != null);
}

test "italic *text*" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("hello *world* here\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3mworld\x1b[23m") != null);
}

test "inline code `code`" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("use `malloc` here\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[96mmalloc\x1b[39m") != null);
}

test "code block with gutter" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("```zig\ncode here\nmore code\n```\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "│ code here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "│ more code") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null); // dim
}

test "heading # level 1" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("# Title\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;4mTitle\x1b[0m") != null);
}

test "heading ## level 2 (bold, no underline)" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("## Subtitle\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1mSubtitle\x1b[0m") != null);
}

test "unordered list - and *" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("- item one\n* item two\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "• item one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "• item two") != null);
}

test "link [text](url) — URL discarded, text in blue" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("see [docs](https://example.com)\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[94mdocs\x1b[39m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "example.com") == null);
}

test "mixed inline **bold** *italic* `code`" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("**bold** *italic* `code`\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1mbold\x1b[22m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3mitalic\x1b[23m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[96mcode\x1b[39m") != null);
}

test "streaming: partial line across two feed calls" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("hello **wor");
    try md.feed("ld** done\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1mworld\x1b[22m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "done") != null);
}

test "blockquote > text" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("> quoted text\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "▎") != null);
    try testing.expect(std.mem.indexOf(u8, out, "quoted text") != null);
}

test "horizontal rule ---" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("---\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "───") != null);
}

test "ordered list 1. item" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("1. first\n2. second\n");
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "1. first") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2. second") != null);
}

test "flush renders trailing partial line raw" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("unfinished");
    // No \n — flush should emit it as-is.
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, "unfinished") != null);
}

test "flush closes open code block" {
    var cap = captureInit(testing.allocator);
    defer cap.deinit();
    var md = try MdRenderer.init(testing.allocator, &cap.writer);
    defer md.deinit();
    try md.feed("```zig\nsome code\n");
    // No closing fence — flush should reset to ANSI normal.
    try md.flush();

    const out = captureWritten(&cap);
    try testing.expect(std.mem.indexOf(u8, out, ansi_reset) != null);
}
