# Architecture

agent-cli is a self-contained Zig CLI for LLM-based agent workflows. It runs a multi-turn tool loop against an OpenAI-compatible `/chat/completions` endpoint. 16 source files, ~6,155 lines of Zig.

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     agent run                                │
│  main.zig: runExec                                          │
│                                                             │
│  1. Load config                          config.zig         │
│  2. Resolve model+provider               main.zig           │
│  3. Resolve agent                        agent.zig          │
│  4. Load/create session                  persistence.zig    │
│  5. Build messages                        ─┐               │
│     a. Context system message           context.zig         │
│     b. Agent system prompt              agent.zig           │
│     c. .agent.md file (if present)      main.zig            │
│     d. User message                     (from flags/stdin)  │
│     e. File attachments                 (from --file)       │
│  6. Print banner                                            │
│  7. processTurn ← MAIN LOOP             processor.zig       │
│  8. Save session + share                persistence.zig     │
└─────────────────────────────────────────────────────────────┘
```

## Mode Architecture

Modes are not separate code paths. They are the same engine loop with different **constraint profiles** applied to four independent dimensions:

| Dimension | What it controls | Examples |
|-----------|-----------------|----------|
| **Tool scope** | Which tools are available | none, read-only subset, full set |
| **Authority** | Whether tools auto-execute or need approval | ask tier (prompt y/n), always-allow, always-deny |
| **Loop** | Single turn or multi-turn with tool calls | one-shot, max-N turns |
| **Streaming** | Whether output streams in real-time | streaming, buffered |

These dimensions are **orthogonal** — streaming doesn't imply tools, tool scope doesn't imply authority, loop doesn't imply streaming. Each mode picks a point in this 4D space.

### Mode Profiles

```
                    TOOL SCOPE          LOOP        STREAMING   AUTHORITY
                    ─────────          ────        ─────────   ─────────
  ask               none               single      streaming   n/a
  plan              read-only (4)      single      streaming   n/a
  review            read+diff (5)      single      streaming   n/a
  edit              read+write (5)     multi       streaming   ask tier
  execute (build)   full (14 + MCP)    multi       streaming   configurable
```

### Why Ask Has No Tools

Ask mode intentionally sends `tools: null`. This is not a gap — it's a design choice:

- **Lower latency**: No tool schema processing, no tool-call parsing overhead
- **Lower cost**: Smaller request payload, fewer output tokens
- **Deterministic**: Pure text response, no tool-call variance between providers
- **Correct expectation**: The prompt says "You do not have access to tools — respond with your knowledge alone"

Adding read-only tools to Ask would blur the line between Ask and Plan. If you need research, use Plan.

### Plan Mode — Read-Only Tools

Plan mode is for research-before-execution. It gets **read-only** tools:
`read`, `glob`, `grep`, `webfetch`

These let the LLM inspect the codebase before writing a plan. The plan output is written to `PLAN.md` by the CLI wrapper, not by a tool call. Single-turn with streaming.

### Review Mode — Read-Only + Diff

Review mode inspects past sessions and current state. It gets read-only tools plus:
`read`, `glob`, `grep`, `webfetch`, `snapshot` (git diff)

The `snapshot` tool captures `git diff` output so the LLM can see what changed. Single-turn with streaming. Loads an existing session and provides analysis.

### Edit Mode — Read/Write, No Execution

Edit mode is for **targeted modifications** to files. It gets constrained tools:
`read`, `write`, `glob`, `grep`, `editFile`

**Hard exclusions** (not just substring filters — these tools are NEVER included):
- `bash` — arbitrary command execution
- `webfetch` / `webSearch` — external network access
- `snapshot` / `task` / `question` — session-level operations
- All `mcp_*` tools — external tool servers

This is a **security boundary**, not a convenience filter. Edit mode should be safe to run on untrusted input without sandboxing. Multi-turn with streaming, ask-tier permission by default.

### Execute Mode (Build) — Full Tools

The default mode. All 14 built-in tools + any configured MCP tools. Multi-turn loop (max 25). Streaming. Configurable permission tier (allow/ask/deny per tool pattern).

### Implementation

All modes share the same engine:

```
main.zig                    processor.zig
────────                    ─────────────
askExec()  ──────────────►  processAsk()           tools=null, single turn
planExec() ──────────────►  processAsk()           tools=null, then write PLAN.md
reviewExec() ────────────►  processAsk()           tools=null, loads session
editExec() ──────────────►  processTurnWithTools() tools=filtered(read+write+search)
runExec()  ──────────────►  processTurnWithTools() tools=all, multi-turn, MCP
```

`buildToolDefsFiltered()` in `processor.zig` constructs the constrained tool set for Edit mode by name whitelist. Plan and Review currently use `processAsk()` (tool-free); adding read-only tools to them means switching them to `processTurnWithTools()` with a filtered tool set.

### What This Model Rejects

- ❌ "Modes are tool count on a slider from 0 to all" — tool *scope* matters more than count
- ❌ "Streaming vs non-streaming is a mode distinction" — streaming is orthogonal
- ❌ "Ask should have read-only tools for convenience" — that's what Plan is for
- ❌ "Edit is just Execute with substring-filtered tools" — Edit is a security boundary
- ❌ "Non-streaming modes are cheaper" — streaming cost is in output tokens, not protocol

## Core Loop (`processor.zig`)

```
┌─── Multi-Turn Loop (max 25) ──────────────────────────────────┐
│                                                                │
│  1. Build tool definitions                                     │
│     a. Built-in: bash, read, write, glob, grep, webfetch,     │
│        editFile, question, skill, todoWrite, plan,            │
│        webSearch, snapshot, task                              │
│     b. MCP tools (mcp.zig): if configured, fetch from         │
│        MCP servers via tools/list → tools/call                │
│     c. Progressive skills (processor.zig): compact → full     │
│        body loaded on first use                               │
│     d. Mode filter: Edit/Plan/Review constrain tool set       │
│        via buildToolDefsFiltered()                            │
│  2. llm.zig: Provider.completeStream(...)                      │
│     ┌─ HTTP POST /chat/completions ────────────────────────┐   │
│     │  a. Build JSON body (model, messages, stream:true,   │   │
│     │     tools, temperature, max_tokens, top_p,           │   │
│     │     reasoning_effort if --variant)                    │   │
│     │  b. Send request with Bearer auth                     │   │
│     │  c. SSE: read data: {...} lines                       │   │
│     │  d. processSSEData:                                   │   │
│     │     - text delta → write to stdout (real-time)        │   │
│     │     - thinking/reasoning blocks if --thinking         │   │
│     │     - tool_call deltas → accumulate in ToolCallAccum  │   │
│     │     - finish_reason → capture                         │   │
│     │  e. Return ChatResponse (content + tool_calls + fr)   │   │
│     └───────────────────────────────────────────────────────┘   │
│  3. Store assistant message in session                         │
│  4. If tool_calls returned:                                    │
│     a. Permission check (stdin y/n/always)                     │
│     b. executeTool by name → tool.zig dispatch                 │
│     c. MCP tool dispatch → mcp.zig if prefixed                 │
│     d. Store tool result in session                            │
│     e. Continue loop                                           │
│  5. If finish_reason: check stop hook, emit [reason], return   │
│  6. Compaction: if token count high, inline truncation         │
└────────────────────────────────────────────────────────────────┘
```

## Module Map

| Module | Lines | Responsibility | Depends On |
|--------|-------|----------------|------------|
| `main.zig` | 862 | CLI entrypoint, flag wiring, model resolution, session lifecycle, .agent.md loading, command dispatch | config, llm, session, agent, processor, persistence, context, cli |
| `config.zig` | 541 | JSONC config file parser, provider config, API key env lookup, agent definitions, MCP server config, permission rules | (std.json) |
| `llm.zig` | 828 | HTTP chat completions client, SSE streaming, JSON response parser, model resolution | config |
| `processor.zig` | 753 | Multi-turn tool loop (max 25), permission prompt, tool dispatch, compaction, progressive skills, MCP tool integration, bash ! expansion | llm, session, tool, permission, agent, mcp |
| `tool.zig` | 217 | 14 tool executors (bash, read, write, glob, grep, webfetch, editFile, question, skill, todoWrite, plan, webSearch, snapshot, task) | (std.process, std.Io) |
| `session.zig` | 158 | In-memory session state (messages, tool results, token counts) | llm |
| `agent.zig` | 283 | 7 built-in agent definitions and system prompts (build, plan, ask, review, edit, general, research) | (none) |
| `persistence.zig` | 320 | JSON file save/load for sessions, latest-session pointer | session, llm |
| `context.zig` | 136 | 7-source system context renderer (Date, OS, Shell, Workspace, Git Info, Env Summary, Tool Help) | tool |
| `permission.zig` | 126 | Glob-based permission rule engine (allow/ask/deny tiers) | (none) |
| `cli.zig` | 434 | CLI framework (flag parsing, subcommands, help rendering) | (std.process.Init) |
| `mcp.zig` | 153 | MCP (Model Context Protocol) client — fetch tools from external servers, dispatch tool calls | (std.http) |
| `share.zig` | 57 | Share session to opencode.ai, generates shareable URL | (std.http, types) |
| `client.zig` | 533 | OpenCode server SDK (not used by `agent run`) | types, sse |
| `types.zig` | 573 | OpenCode SDK v2 type definitions (not used by `agent run`) | (none) |
| `sse.zig` | 181 | Server-protocol SSE parser (not used by `agent run`) | types |

## Key Phase 2 Features

### MCP Tool Provider (`mcp.zig`)
External tools can be loaded from MCP-compatible servers. Configured in `config.json`:
- `tools/list` fetches tool definitions at startup
- `tools/call` dispatches prefixed tool calls (e.g., `mcp_hexmath__hex_add`)
- Supports multiple MCP servers simultaneously

### Progressive Skills (`processor.zig`)
Skills are loaded lazily to keep system prompts compact:
- Initial load: skill name + description only (compact mode)
- On first use: full skill body loaded and added to messages
- Source: `.agent/skills/` or `~/.config/agent/skills/`

### .agent.md Loading (`main.zig`)
If `.agent.md` exists in the workspace root, its contents are injected as a system message before the user message. This provides project-level context without modifying the agent definition.

### Bash `!` Expansion (`processor.zig`)
Tool results can contain `!command` lines that get expanded by the processor before being sent back to the LLM, reducing tool-call roundtrips for common patterns.

## Data Flow — Request Through Provider

```
main.zig                         config.zig                    llm.zig
───────                          ──────────                    ───────
--model "open-code/mistral" ──>  resolveModelProvider()
                                    │
                                    ├── parse "open-code/mistral"
                                    ├── lookup provider config
                                    ├── resolve API_KEY from env
                                    └── return ProviderConfig    Provider.init(cfg, key)
                                                                     │
                                                                     ├── chatUrl()
                                                                     │   baseURL + /chat/completions
                                                                     │
                                                                     ├── buildRequestBody(req, stream)
                                                                     │   model, messages, stream:true,
                                                                     │   tools, temperature, max_tokens, top_p
                                                                     │
                                                                     ├── HTTP POST
                                                                     │   std.http.Client.request(.POST)
                                                                     │   sendBodyComplete(json_body)
                                                                     │   receiveHead()
                                                                     │
                                                                     ├── completeStream()
                                                                     │   SSE read loop:
                                                                     │     readSliceShort → buf
                                                                     │     parse "data: {...}" lines
                                                                     │     processSSEData → writer + accumulators
                                                                     │
                                                                     └── return ChatResponse
```

## Session Lifecycle

```
FRESH SESSION                              LOADED SESSION
─────────────                              ───────────────
session.init()                             persistence.loadSession(id)
  │                                          │
  ├── context.render() → system msg          └── messages restored from JSON
  ├── agent system prompt → system msg
  ├── .agent.md (if present) → system msg
  └── user message
       │
       ▼
processTurn() ──► LLM turn loop
       │
       ▼
persistence.saveSession()
persistence.saveLatestSession()
saveAndShare() → share.shareSession() if --share
```

## Persistence Format

Sessions stored as JSON at `~/.config/agent/sessions/<id>.json`:

```json
{
  "id": "1748123456789",
  "title": "Fix login bug",
  "agent": "build",
  "model": { "providerID": "opencode", "id": "big-pickle" },
  "created": 1748123456,
  "updated": 1748123500,
  "messages": [
    { "role": "system", "content": "## Date\n..." },
    { "role": "user", "content": "Fix the login bug" },
    { "role": "assistant", "content": "Let me look at...",
      "tool_calls": [{"id":"call_x","type":"function","function":{...}}] },
    { "role": "tool", "tool_call_id": "call_x", "content": "..." }
  ],
  "tokens": { "input": 1500, "output": 800 }
}
```

## Flags — Dispatch Overview

All flags are wired and functional:

```
agent run
  ├── --message        → user message content
  ├── --model          → provider/model resolution
  ├── --agent          → agent.zig::getBuiltin()
  ├── --dir            → config.find() + context.render()
  ├── --format         → json vs default output mode
  ├── --file (-f)      → read file → inject as user message
  ├── --continue (-c)  → persistence.loadLatestSession()
  ├── --session (-s)   → persistence.loadSession()
  ├── --fork           → clone session.id
  ├── --config         → config.loadFile() direct
  ├── --max-tokens     → ChatRequest.max_tokens
  ├── --temperature    → ChatRequest.temperature
  ├── --top-p          → ChatRequest.top_p
  ├── --skip-permissions → bypass permission prompt
  ├── --title          → session.title
  ├── --thinking       → show reasoning/thinking blocks in streaming output
  ├── --variant        → model variant (reasoning_effort), passed to ChatRequest
  ├── --share          → create shareable session link via opencode.ai
  └── --command        → execute named slash command (e.g., /help, /todos)
```

## Tools

14 built-in tools + MCP tools dispatched by name in `processor.zig` dispatch table:

| Tool | Implementation | Mechanism |
|------|---------------|-----------|
| `bash` | `tool.bash()` | `std.process.spawn("bash", "-c", command)` |
| `read` | `tool.readFile()` | `Dir.readFileAlloc()` |
| `write` | `tool.writeFile()` | `Dir.writeFile()` |
| `glob` | `tool.globSearch()` | shell out to `find -name` via bash |
| `grep` | `tool.grepSearch()` | shell out to `rg --json` via bash |
| `webfetch` | `tool.webFetch()` | shell out to `curl -sL` via bash |
| `editFile` | `tool.editFile()` | search-and-replace via exact string match |
| `question` | `tool.question()` | `io.writer.print` + `io.reader.readLine` |
| `skill` | `tool.skill()` | progressive: load skill from `.agent/skills/` or `~/.config/agent/skills/` |
| `todoWrite` | `tool.todoWrite()` | write TODO.md in workspace |
| `plan` | `tool.plan()` | write PLAN.md in workspace |
| `webSearch` | `tool.webSearch()` | shell out to `curl` DuckDuckGo |
| `snapshot` | `tool.snapshot()` | `git diff` capture |
| `task` | `tool.task()` | sub-agent spawn via LLM |
| `mcp_*` | `mcp.zig` | MCP tools: dispatched via `tools/call` to configured MCP servers |
