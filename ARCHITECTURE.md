# Architecture

agent-cli is a thin Zig CLI for LLM-based agent workflows. It wires CLI flags to the [agent-sdk](https://github.com/devstroop/agent-sdk) library, which houses all agent logic. 8 source files, ~2,600 lines of Zig (SDK: 13 modules, ~5,800 lines).

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     agent run                                │
│  main.zig → exec.zig: runExec                               │
│                                                             │
│  1. Load config                  → sdk.config               │
│  2. Resolve model+provider       → exec.zig                 │
│  3. Resolve agent                → sdk.agent                │
│  4. Load/create session          → persistence.zig          │
│  5. Build messages                ─┐                       │
│     a. Context system message   context.zig                 │
│     b. Available skills listing → sdk.tool                  │
│     c. Agent system prompt      → sdk.agent                 │
│     d. .agent.md files          exec.zig                    │
│     e. User message             (from flags/stdin)          │
│     f. File attachments         (from --file)               │
│  6. Print banner                  exec.zig                  │
│  7. processTurnWithTools ← MAIN LOOP → sdk.processor        │
│  8. Save session + share        persistence.zig / share.zig │
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

**⚠️ Exfiltration risk**: Plan mode grants both `read` (filesystem access) and `webfetch` (network access) simultaneously. A prompt could read a secrets file and embed its contents in a URL query string. The current permission model authorizes tools individually and does not reason about cross-tool data flows. For sensitive codebases, consider running Plan mode with `--skip-permissions` off and denying `webfetch` calls that follow `read` calls on sensitive paths.

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

This is a **security boundary** against code execution, not a filesystem sandbox. Edit mode prevents arbitrary command execution (`bash`, `curl`, `git`) but the model can still read secrets, overwrite files, and corrupt repositories via `read`/`write`/`editFile`. Treat it as **non-executing**, not **safe without sandboxing**. Multi-turn with streaming, ask-tier permission by default.

### Execute Mode (Build) — Full Tools

The default mode. All 14 built-in tools + any configured MCP tools. Multi-turn loop (max 25). Streaming. Configurable permission tier (allow/ask/deny per tool pattern).

### Implementation

All modes share the same engine:

```
exec.zig                    sdk.processor
────────                    ─────────────
askExec()  ──────────────►  processAsk()           tools=null, single turn
planExec() ──────────────►  processTurnWithTools() tools=read-only (read,glob,grep,webfetch)
reviewExec() ────────────►  processTurnWithTools() tools=read+diff (read,glob,grep,webfetch,snapshot)
editExec() ──────────────►  processTurnWithTools() tools=filtered(read+write+search)
runExec()  ──────────────►  processTurnWithTools() tools=all, multi-turn, MCP
```

`buildToolDefsFiltered()` in `sdk.processor` constructs the constrained tool set for Edit mode by name whitelist. Plan and Review use `processTurnWithTools()` with filtered read-only tool sets — tools are available for codebase inspection before the LLM responds.

### What This Model Rejects

- ❌ "Modes are tool count on a slider from 0 to all" — tool *scope* matters more than count
- ❌ "Streaming vs non-streaming is a mode distinction" — streaming is orthogonal
- ❌ "Ask should have read-only tools for convenience" — that's what Plan is for
- ❌ "Edit is just Execute with substring-filtered tools" — Edit is a security boundary
- ❌ "Non-streaming modes are cheaper" — streaming cost is in output tokens, not protocol

## Core Loop (`sdk.processor`)

The agent loop lives in the SDK. It is invoked by CLI exec functions with appropriate tool sets and parameters.

```
┌─── Multi-Turn Loop (max 25) ──────────────────────────────────┐
│                                                                │
│  1. Build tool definitions                                     │
│     a. Built-in: bash, read, write, glob, grep, webfetch,     │
│        editFile, question, skill, todoWrite, plan,            │
│        webSearch, snapshot, task                              │
│     b. MCP tools (sdk.mcp): if configured, fetch from         │
│        MCP servers via tools/list → tools/call                │
│     c. Progressive skills (sdk.processor): compact → full     │
│        body loaded on first use                               │
│     d. Mode filter: Edit/Plan/Review constrain tool set       │
│        via buildToolDefsFiltered()                            │
│  2. sdk.llm: Provider.completeStream(...)                      │
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
│     b. executeTool by name → sdk.tool dispatch                 │
│     c. MCP tool dispatch → sdk.mcp if prefixed                 │
│     d. Store tool result in session                            │
│     e. Continue loop                                           │
│  5. If finish_reason: check stop hook, emit [reason], return   │
│  6. Compaction: if token count high, inline truncation         │
└────────────────────────────────────────────────────────────────┘
```

## Module Map

### agent-cli (this package)

| Module | Lines | Responsibility | Depends On |
|--------|-------|----------------|------------|
| `main.zig` | 193 | CLI entrypoint, subcommand registration, flag definitions | cli, exec |
| `exec.zig` | 809 | Mode exec functions (run/ask/plan/review/edit), model resolution, session lifecycle | sdk.*, persistence, context, share, wizard, markdown |
| `markdown.zig` | 477 | Streaming markdown-to-ANSI renderer | (none) |
| `cli.zig` | 446 | CLI framework (flag parsing, subcommands, help rendering) | (std.process.Init) |
| `wizard.zig` | 273 | Interactive config setup wizard — provider presets, model selection, API key detection | sdk.config |
| `persistence.zig` | 208 | Session file I/O (save/load/latest), delegates JSON serialization to SDK | sdk.session, sdk.session_json |
| `context.zig` | 136 | 7-source system context renderer (Date, OS, Shell, Workspace, Git Info, Env Summary, Tool Help) | sdk.tool |
| `share.zig` | 57 | Share session to opencode.ai, generates shareable URL | sdk.session |

### agent-sdk (core library)

| Module | Lines | Responsibility | Depends On |
|--------|-------|----------------|------------|
| `llm.zig` | 1,099 | HTTP chat completions client, SSE streaming, JSON response parser, tool call accumulation, model resolution | config, client |
| `processor.zig` | 1,012 | Multi-turn tool loop (max 25), permission prompt, tool dispatch, compaction, progressive skills, bash ! expansion, stop hook | llm, session, tool, permission, agent, mcp |
| `config.zig` | 684 | JSONC config parser with comment/trailing-comma stripping, provider config, API key env lookup, agent definitions, MCP server config | (std.json) |
| `types.zig` | 573 | Shared types: Message, ToolCall, ToolDef, ChatRequest, ChatResponse, ProviderConfig | (none) |
| `client.zig` | 533 | Low-level HTTP client (request construction, headers, response handling) | (std.http) |
| `mcp.zig` | 505 | MCP client — HTTP/stdio/SSE transports, JSON-RPC dispatch, tools/list + tools/call | tool, llm |
| `session_json.zig` | 332 | Session JSON serialization/deserialization (parse/serialize) | session, llm |
| `agent.zig` | 287 | 8 built-in agent definitions and system prompts (build, plan, ask, edit, review, summary, title, compaction) | tool |
| `tool.zig` | 262 | 14 tool executors (bash, read, write, glob, grep, webfetch, edit, question, skill, todowrite, plan, websearch, snapshot, task) | (std.process, std.Io) |
| `sse.zig` | 181 | Server-Sent Events protocol parser | types |
| `session.zig` | 167 | In-memory session state (messages, tool results, token counts), loaded skills cache | llm |
| `permission.zig` | 126 | Glob-based permission rule engine (allow/ask/deny tiers) | (none) |
| `lib.zig` | 18 | Module re-exports — single import point | (all modules) |

## Key Features

### MCP Multi-Transport (`sdk.mcp`)
External tools can be loaded from MCP-compatible servers via three transports:
- **HTTP**: POST JSON-RPC to a URL (`.url` in config, default transport)
- **Stdio**: Spawn command as child process, communicate via stdin/stdout (`.command` + `.args` in config)
- **SSE**: Connect to SSE endpoint, discover POST URL via `endpoint` event (`"transport": "sse"` in config)
- `tools/list` fetches tool definitions at startup
- `tools/call` dispatches prefixed tool calls (e.g., `mcp_hexmath__hex_add`)
- Supports multiple MCP servers simultaneously, mixed transports

### Progressive Skills (`sdk.processor`)
Skills are loaded lazily to keep system prompts compact:
- Initial load: skill name + description only (metadata listing at startup)
- On first use: full skill body loaded and injected as a **system message** (persists through compaction)
- Auto-load: any tool whose name matches a skill file triggers automatic skill body injection
- Dedup: `session.loaded_skills` cache prevents re-loading within a session
- Source: `.agent/skills/` or `~/.config/agent/skills/`

### .agent.md Loading (`exec.zig`)
If `.agent.md` exists in the workspace root, its contents are injected as a system message before the user message. This provides project-level context without modifying the agent definition.

### Bash `!` Expansion (`sdk.processor`)
Tool results can contain `!command` lines that get expanded by the processor before being sent back to the LLM, reducing tool-call roundtrips for common patterns.

### Task (Sub-Agent Spawn) (`sdk.tool`)

The `task` tool spawns a sub-agent for reasoning-only delegation. It is **not** a full multi-agent system:

- **Isolated context**: The sub-agent sees exactly 2 messages — its own system prompt (from `sdk.agent`) + the user's task description. Zero access to parent session history, file contents, or tool results.
- **No tools**: The sub-agent call uses `provider.complete()` (single-turn, `tools: null`). It cannot read files, run bash, search the web, or spawn further sub-agents.
- **No recursion**: The sub-agent has no access to the `task` tool. Recursive agent spawning is structurally impossible.
- **No permissions**: No permission checks — there's nothing to permit since the sub-agent has no capabilities.
- **No budget**: No `max_tokens` or token budget is enforced. The sub-agent inherits the provider's default limits.
- **Flat result**: The sub-agent's text response is returned as a plain `ToolResult.content` string. No structured output, no streaming passthrough.

This is the simplest possible delegation primitive: a pure reasoning sandbox. Useful for "review this code", "suggest a name", or "check for consistency" — anything that benefits from a fresh context window with a specialized system prompt, but requires no tool access.

## Data Flow — Request Through Provider

```
exec.zig                          sdk.config                    sdk.llm
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
  ├── sdk.agent system prompt → system msg
  ├── .agent.md (if present) → system msg
  └── user message
       │
       ▼
sdk.processor.processTurn() ──► LLM turn loop
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
  "model": { "providerID": "opencode", "id": "deepseek-v4-flash-free" },
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
  ├── --model          → provider/model resolution (exec.zig → sdk.config)
  ├── --agent          → sdk.agent.getBuiltin()
  ├── --dir            → config resolution + context.render()
  ├── --format         → json vs default output mode
  ├── --file (-f)      → read file → inject as user message
  ├── --continue (-c)  → persistence.loadLatestSession()
  ├── --session (-s)   → persistence.loadSession()
  ├── --fork           → clone session.id
  ├── --config         → sdk.config.loadFile() direct
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

14 built-in tools + MCP tools dispatched by name in `sdk.processor` dispatch table:

| Tool | Implementation | Mechanism |
|------|---------------|-----------|
| `bash` | `sdk.tool` | `std.process.spawn("bash", "-c", command)` |
| `read` | `sdk.tool` | `Dir.readFileAlloc()` |
| `write` | `sdk.tool` | `Dir.writeFile()` |
| `glob` | `sdk.tool` | shell out to `find -name` via bash |
| `grep` | `sdk.tool` | shell out to `rg --json` via bash |
| `webfetch` | `sdk.tool` | shell out to `curl -sL` via bash |
| `editFile` | `sdk.tool` | search-and-replace via exact string match |
| `question` | `sdk.tool` | `io.writer.print` + `io.reader.readLine` |
| `skill` | `sdk.tool` | progressive: load skill from `.agent/skills/` or `~/.config/agent/skills/` |
| `todoWrite` | `sdk.tool` | write TODO.md in workspace |
| `plan` | `sdk.tool` | write PLAN.md in workspace |
| `webSearch` | `sdk.tool` | shell out to `curl` DuckDuckGo |
| `snapshot` | `sdk.tool` | `git diff` capture |
| `task` | `sdk.tool` | sub-agent spawn via LLM |
| `mcp_*` | `sdk.mcp` | MCP tools: dispatched via `tools/call` to configured MCP servers |
