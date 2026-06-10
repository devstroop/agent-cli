# Architecture

agent-cli is a self-contained Zig CLI for LLM-based agent workflows. It runs a multi-turn tool loop against an OpenAI-compatible `/chat/completions` endpoint.

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
│     c. User message                     (from flags/stdin)  │
│     d. File attachments                 (from --file)       │
│  6. Print banner                                            │
│  7. processTurn ← MAIN LOOP             processor.zig       │
│  8. Save session                        persistence.zig     │
└─────────────────────────────────────────────────────────────┘
```

## Core Loop (`processor.zig`)

```
┌─── Multi-Turn Loop (max 25) ──────────────────────────────────┐
│                                                                │
│  1. Build tool definitions (bash, read, write, glob,           │
│     grep, webfetch)                                            │
│  2. llm.zig: Provider.completeStream(...)                      │
│     ┌─ HTTP POST /chat/completions ────────────────────────┐   │
│     │  a. Build JSON body (model, messages, stream:true,   │   │
│     │     tools, temperature, max_tokens, top_p)            │   │
│     │  b. Send request with Bearer auth                     │   │
│     │  c. SSE: read data: {...} lines                       │   │
│     │  d. processSSEData:                                   │   │
│     │     - text delta → write to stdout (real-time)        │   │
│     │     - tool_call deltas → accumulate in ToolCallAccum  │   │
│     │     - finish_reason → capture                         │   │
│     │  e. Return ChatResponse (content + tool_calls + fr)   │   │
│     └───────────────────────────────────────────────────────┘   │
│  3. Store assistant message in session                         │
│  4. If tool_calls returned:                                    │
│     a. Permission check (stdin y/n/always)                     │
│     b. executeTool by name → tool.zig dispatch                 │
│     c. Store tool result in session                            │
│     d. Continue loop                                           │
│  5. If finish_reason: emit [reason], return                    │
└────────────────────────────────────────────────────────────────┘
```

## Module Map

| Module | Lines | Responsibility | Depends On |
|--------|-------|----------------|------------|
| `main.zig` | 360 | CLI entrypoint, flag wiring, model resolution, session lifecycle | config, llm, session, agent, processor, persistence, context |
| `config.zig` | 309 | JSONC config file parser, provider config, API key env lookup | (std.json) |
| `llm.zig` | 477 | HTTP chat completions client, SSE streaming, JSON response parser | config |
| `processor.zig` | 420 | Multi-turn tool loop (max 25), permission prompt, tool dispatch, compaction | llm, session, tool, permission, agent |
| `tool.zig` | 180 | 14 tool executors (bash, read, write, glob, grep, webfetch, editFile, question, skill, todoWrite, plan, webSearch, snapshot, task) | (std.process, std.Io) |
| `session.zig` | 83 | In-memory session state (messages, tool results) | llm |
| `agent.zig` | 78 | 7 built-in agent definitions and system prompts | (none) |
| `persistence.zig` | 258 | JSON file save/load for sessions | session, llm |
| `context.zig` | 98 | 7-source system context renderer | tool |
| `permission.zig` | 72 | Glob-based permission rule engine | (none) |
| `client.zig` | 533 | OpenCode server SDK (not used by `agent run`) | types, sse |
| `types.zig` | 573 | OpenCode SDK v2 type definitions (not used by `agent run`) | (none) |
| `sse.zig` | 181 | Server-protocol SSE parser (not used by `agent run`) | types |

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
  └── user message
       │
       ▼
processTurn() ──► LLM turn loop
       │
       ▼
persistence.saveSession()
persistence.saveLatestSession()
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
  ├── --thinking       → [NOT WIRED] future: show reasoning blocks
  ├── --variant        → [NOT WIRED] future: reasoning_effort
  ├── --share          → [NOT WIRED] future: /share endpoint
  └── --command        → [NOT WIRED] future: slash commands
```

## Tools

14 tools dispatched by name in `processor.zig` dispatch table:

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
| `skill` | `tool.skill()` | load skill from `.agent/skills/` or `~/.config/agent/skills/` |
| `todoWrite` | `tool.todoWrite()` | write TODO.md in workspace |
| `plan` | `tool.plan()` | write PLAN.md in workspace |
| `webSearch` | `tool.webSearch()` | shell out to `curl` DuckDuckGo |
| `snapshot` | `tool.snapshot()` | `git diff` capture |
| `task` | `tool.task()` | sub-agent spawn via LLM |
