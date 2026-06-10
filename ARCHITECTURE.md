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
│  5. If finish_reason: emit [reason], return                    │
│  6. Compaction: if token count high, summarise oldest messages │
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
