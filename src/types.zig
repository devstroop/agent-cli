const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// OpenCode SDK v2 Types for Zig
// ═══════════════════════════════════════════════════════════════════════

/// A session object returned by the server.
pub const Session = struct {
    id: []const u8,
    slug: []const u8,
    projectID: []const u8,
    workspaceID: ?[]const u8 = null,
    directory: []const u8,
    path: ?[]const u8 = null,
    parentID: ?[]const u8 = null,
    title: []const u8,
    agent: ?[]const u8 = null,
    model: ?ModelRef = null,
    version: []const u8,
    metadata: ?std.json.Value = null,
    time: SessionTime,
    cost: ?f64 = null,
    tokens: ?TokenUsage = null,
    share: ?SessionShare = null,

    /// Free all owned string fields. Does NOT free metadata (json.Value tree).
    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.slug);
        allocator.free(self.projectID);
        allocator.free(self.directory);
        allocator.free(self.title);
        allocator.free(self.version);
        if (self.workspaceID) |v| allocator.free(v);
        if (self.path) |v| allocator.free(v);
        if (self.parentID) |v| allocator.free(v);
        if (self.agent) |v| allocator.free(v);
        if (self.model) |m| {
            allocator.free(m.id);
            allocator.free(m.providerID);
            if (m.variant) |v| allocator.free(v);
        }
        if (self.share) |s| allocator.free(s.url);
    }

    /// Deep-clone all string fields into a new Session owned by the given allocator.
    pub fn clone(self: *const Session, allocator: std.mem.Allocator) !Session {
        return Session{
            .id = try allocator.dupe(u8, self.id),
            .slug = try allocator.dupe(u8, self.slug),
            .projectID = try allocator.dupe(u8, self.projectID),
            .directory = try allocator.dupe(u8, self.directory),
            .title = try allocator.dupe(u8, self.title),
            .version = try allocator.dupe(u8, self.version),
            .time = self.time,
            .workspaceID = if (self.workspaceID) |v| try allocator.dupe(u8, v) else null,
            .path = if (self.path) |v| try allocator.dupe(u8, v) else null,
            .parentID = if (self.parentID) |v| try allocator.dupe(u8, v) else null,
            .agent = if (self.agent) |v| try allocator.dupe(u8, v) else null,
            .cost = self.cost,
            .tokens = self.tokens,
            .model = if (self.model) |m| ModelRef{
                .id = try allocator.dupe(u8, m.id),
                .providerID = try allocator.dupe(u8, m.providerID),
                .variant = if (m.variant) |v| try allocator.dupe(u8, v) else null,
            } else null,
            .share = if (self.share) |s| SessionShare{
                .url = try allocator.dupe(u8, s.url),
            } else null,
            .metadata = null,
        };
    }
};

pub const ModelRef = struct {
    id: []const u8,
    providerID: []const u8,
    variant: ?[]const u8 = null,
};

pub const SessionTime = struct {
    created: u64,
    updated: u64,
    compacting: ?u64 = null,
    archived: ?u64 = null,
};

pub const TokenUsage = struct {
    input: u64,
    output: u64,
    reasoning: u64,
    cache: CacheUsage,
};

pub const CacheUsage = struct {
    read: u64,
    write: u64,
};

// ═══════════════════════════════════════════════════════════════════════
// Messages
// ═══════════════════════════════════════════════════════════════════════

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,

    pub fn role(self: Message) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const UserMessage = struct {
    id: []const u8,
    sessionID: []const u8,
    role: []const u8 = "user",
    time: MessageTime,
    agent: []const u8,
    model: ModelRef,
    system: ?[]const u8 = null,
    tools: ?std.json.Value = null,
};

pub const AssistantMessage = struct {
    id: []const u8,
    sessionID: []const u8,
    role: []const u8 = "assistant",
    time: AssistantTime,
    parentID: []const u8,
    modelID: []const u8,
    providerID: []const u8,
    mode: []const u8,
    agent: []const u8,
    path: MessagePath,
    summary: ?bool = null,
    cost: f64,
    tokens: TokenUsage,
    variant: ?[]const u8 = null,
    finish: ?[]const u8 = null,
};

pub const MessageTime = struct {
    created: u64,
};

pub const AssistantTime = struct {
    created: u64,
    completed: ?u64 = null,
};

pub const MessagePath = struct {
    cwd: []const u8,
    root: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════
// Parts
// ═══════════════════════════════════════════════════════════════════════

pub const TextPart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "text",
    text: []const u8,
    synthetic: ?bool = null,
    time: ?PartTime = null,
};

pub const ReasoningPart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "reasoning",
    text: []const u8,
    time: PartTime,
};

pub const ToolPart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "tool",
    callID: []const u8,
    tool: []const u8,
    state: ToolState,
};

pub const FilePart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "file",
    mime: []const u8,
    filename: ?[]const u8 = null,
    url: []const u8,
};

pub const StepStartPart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "step-start",
    snapshot: ?[]const u8 = null,
};

pub const StepFinishPart = struct {
    id: []const u8,
    sessionID: []const u8,
    messageID: []const u8,
    type: []const u8 = "step-finish",
    reason: []const u8,
    snapshot: ?[]const u8 = null,
    cost: f64,
    tokens: TokenUsage,
};

pub const PartTime = struct {
    start: u64,
    end: ?u64 = null,
};

// ═══════════════════════════════════════════════════════════════════════
// Tool State
// ═══════════════════════════════════════════════════════════════════════

pub const ToolState = union(enum) {
    pending: ToolStatePending,
    running: ToolStateRunning,
    completed: ToolStateCompleted,
    err: ToolStateError,

    pub fn status(self: ToolState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .err => "error",
        };
    }
};

pub const ToolStatePending = struct {
    status: []const u8 = "pending",
    input: std.json.Value,
    raw: []const u8,
};

pub const ToolStateRunning = struct {
    status: []const u8 = "running",
    input: std.json.Value,
    title: ?[]const u8 = null,
    time: PartTime,
};

pub const ToolStateCompleted = struct {
    status: []const u8 = "completed",
    input: std.json.Value,
    output: []const u8,
    title: []const u8,
    time: PartTime,
};

pub const ToolStateError = struct {
    status: []const u8 = "error",
    input: std.json.Value,
    err_msg: []const u8,
    time: PartTime,
};

// ═══════════════════════════════════════════════════════════════════════
// Parts discriminated union
// ═══════════════════════════════════════════════════════════════════════

pub const Part = union(enum) {
    text: TextPart,
    reasoning: ReasoningPart,
    tool: ToolPart,
    file: FilePart,
    step_start: StepStartPart,
    step_finish: StepFinishPart,
};

// ═══════════════════════════════════════════════════════════════════════
// Events (SSE payload types)
// ═══════════════════════════════════════════════════════════════════════

pub const Event = union(enum) {
    session_created: SessionEvent,
    session_updated: SessionEvent,
    session_deleted: SessionEvent,
    session_idle: SessionIdleEvent,
    session_status: SessionStatusEvent,
    session_error: SessionErrorEvent,
    message_updated: MessageEvent,
    message_removed: MessageRemovedEvent,
    message_part_updated: PartEvent,
    message_part_removed: PartRemovedEvent,
    message_part_delta: PartDeltaEvent,
    session_diff: SessionDiffEvent,
    session_compacted: SessionCompactedEvent,
    permission_asked: PermissionAskedEvent,
    question_asked: QuestionAskedEvent,
    todo_updated: TodoUpdatedEvent,
    tool_called: ToolEvent,
    tool_progress: ToolEvent,
    tool_success: ToolEvent,
    tool_failed: ToolEvent,
    step_started: StepEvent,
    step_ended: StepEvent,
    step_failed: StepEvent,
    text_started: TextEvent,
    text_delta: TextEvent,
    text_ended: TextEvent,
    reasoning_started: TextEvent,
    reasoning_delta: TextEvent,
    reasoning_ended: TextEvent,
    unknown: std.json.Value,
};

pub const SessionEvent = struct {
    sessionID: []const u8,
    info: Session,
};

pub const SessionIdleEvent = struct {
    sessionID: []const u8,
};

pub const SessionStatusEvent = struct {
    sessionID: []const u8,
    status: SessionStatus,
};

pub const SessionErrorEvent = struct {
    sessionID: []const u8,
    err_msg: []const u8,
};

pub const MessageEvent = struct {
    sessionID: []const u8,
    info: Message,
};

pub const MessageRemovedEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
};

pub const PartEvent = struct {
    sessionID: []const u8,
    part: Part,
    time: u64,
};

pub const PartRemovedEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
    partID: []const u8,
};

pub const PartDeltaEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
    partID: []const u8,
    delta: []const u8,
};

pub const SessionDiffEvent = struct {
    sessionID: []const u8,
    diff: []const u8,
};

pub const SessionCompactedEvent = struct {
    sessionID: []const u8,
};

pub const PermissionAskedEvent = struct {
    sessionID: []const u8,
    requestID: []const u8,
    permission: []const u8,
    pattern: []const u8,
};

pub const QuestionAskedEvent = struct {
    sessionID: []const u8,
    requestID: []const u8,
    question: []const u8,
    header: []const u8,
    options: []const u8,
};

pub const TodoUpdatedEvent = struct {
    sessionID: []const u8,
    todos: []const u8,
};

pub const ToolEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
    partID: []const u8,
    callID: []const u8,
    tool: []const u8,
    input: std.json.Value,
    output: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const StepEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
};

pub const TextEvent = struct {
    sessionID: []const u8,
    messageID: []const u8,
    partID: []const u8,
    text: []const u8,
};

pub const SessionStatus = union(enum) {
    idle,
    busy,
    retry: SessionRetry,

    pub fn typeStr(self: SessionStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .busy => "busy",
            .retry => "retry",
        };
    }
};

pub const SessionRetry = struct {
    type: []const u8 = "retry",
    attempt: u64,
    message: []const u8,
    next: u64,
};

// ═══════════════════════════════════════════════════════════════════════
// Global Event (SSE line format)
// ═══════════════════════════════════════════════════════════════════════

pub const GlobalEvent = struct {
    directory: []const u8,
    project: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    payload: EventPayload,
};

pub const EventPayload = struct {
    id: []const u8,
    type: []const u8,
    properties: std.json.Value,
};

// ═══════════════════════════════════════════════════════════════════════
// Request types
// ═══════════════════════════════════════════════════════════════════════

pub const SessionShare = struct {
    url: []const u8,
};

pub const SessionCreateRequest = struct {
    title: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    model: ?ModelInput = null,
    permission: ?[]const PermissionRule = null,
    variant: ?[]const u8 = null,
};

pub const CommandRequest = struct {
    sessionID: []const u8,
    command: []const u8,
    arguments: []const u8,
    agent: ?[]const u8 = null,
    model: ?[]const u8 = null, // "providerID/modelID" string format
    variant: ?[]const u8 = null,
};

pub const ModelInput = struct {
    providerID: []const u8,
    id: []const u8,
    variant: ?[]const u8 = null,
};

pub const PermissionRule = struct {
    permission: []const u8,
    pattern: []const u8,
    action: []const u8,
};

/// Agent info returned by GET /agent.
pub const AgentInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    mode: []const u8,
    hidden: ?bool = null,
    model: ?ModelRef = null,
    variant: ?[]const u8 = null,

    /// Free all owned string fields.
    pub fn deinit(self: *AgentInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.mode);
        if (self.description) |v| allocator.free(v);
        if (self.variant) |v| allocator.free(v);
        if (self.model) |m| {
            allocator.free(m.id);
            allocator.free(m.providerID);
            if (m.variant) |v| allocator.free(v);
        }
    }

    /// Deep-clone all string fields into a new AgentInfo owned by the given allocator.
    pub fn clone(self: *const AgentInfo, allocator: std.mem.Allocator) !AgentInfo {
        return AgentInfo{
            .name = try allocator.dupe(u8, self.name),
            .mode = try allocator.dupe(u8, self.mode),
            .hidden = self.hidden,
            .description = if (self.description) |v| try allocator.dupe(u8, v) else null,
            .variant = if (self.variant) |v| try allocator.dupe(u8, v) else null,
            .model = if (self.model) |m| ModelRef{
                .id = try allocator.dupe(u8, m.id),
                .providerID = try allocator.dupe(u8, m.providerID),
                .variant = if (m.variant) |v| try allocator.dupe(u8, v) else null,
            } else null,
        };
    }
};

pub const PromptRequest = struct {
    sessionID: []const u8,
    agent: ?[]const u8 = null,
    model: ?ModelInput = null,
    variant: ?[]const u8 = null,
    thinking: ?bool = null,
    parts: []const PromptPart,
};

pub const PromptPart = union(enum) {
    text: PromptTextPart,
    file: PromptFilePart,
};

pub const PromptTextPart = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const PromptFilePart = struct {
    type: []const u8 = "file",
    url: []const u8,
    filename: []const u8,
    mime: []const u8,
};

pub const ForkRequest = struct {
    sessionID: []const u8,
    messageID: ?[]const u8 = null,
};

pub const PermissionReplyRequest = struct {
    sessionID: []const u8,
    requestID: []const u8,
    action: []const u8, // "allow" or "deny"
};
