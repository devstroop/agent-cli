# Agent CLI

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/download/)

A CLI-native AI agent that reasons, runs tools, and edits code. Built in Zig — ships as a single static binary with zero runtime dependencies.

## Install

```bash
git clone https://github.com/devstroop/agent-cli
cd agent-cli
zig build
cp zig-out/bin/agent /usr/local/bin/
```

Requires [Zig 0.16.0](https://ziglang.org/download/). Output: `zig-out/bin/agent`.

## Usage

```
agent run [options]
```

```bash
# Basic prompt
agent run --message "Write a Python script to sort files by date"

# Specify model
agent run -m "deepseek/deepseek-v4-flash-free" --message "Say hello"

# Pipe input
echo "Refactor this code" | agent run

# Attach files
agent run --message "Review this" --file src/main.zig,src/config.zig

# Continue last session
agent run --continue
agent run -c --fork

# Resume by session ID
agent run -s "1748123456789"

# JSON output for programmatic use
agent run --message "List files" --format json

# Control sampling
agent run --message "Write a poem" --temperature 0.8 --max-tokens 200 --top-p 0.9

# Raw output (no markdown rendering)
agent run --message "Write a Zig function" --raw

# Show thinking/reasoning blocks (o1-style models)
agent run --message "Prove sqrt(2) is irrational" --thinking

# Reasoning effort variant (minimal/low/medium/high)
agent run --message "Design a distributed lock" --variant high

# Share session via opencode.ai link
agent run --message "Explain monads" --share

# Slash command: switch model or agent mid-session
agent run --command /model deepseek/deepseek-v4-flash-free
agent run --command "/agent ask"

# Use a different agent
agent run --message "Plan this task" --agent plan

# Skip permission prompts
agent run --message "Run this command" --skip-permissions

# Custom config path
agent run --message "Hello" --config ~/.config/agent/config.jsonc

# Full flag reference
agent run --help
```

## Configuration

Place `config.jsonc` at `~/.config/agent/config.jsonc` or `.agent/config.jsonc` in your project:

```jsonc
{
  "provider": {
    "openai": {
      "name": "OpenAI",
      "options": {
        "baseURL": "https://api.openai.com/v1",
        "chatEndpoint": "/chat/completions"
      },
      "models": {
        "gpt-4o": {
          "id": "gpt-4o",
          "name": "GPT-4o",
          "contextTokens": 8192,
          "toolCalls": 25,
          "supportsFiles": false
        },
        "gpt-3.5-turbo": {
          "id": "gpt-3.5-turbo",
          "name": "GPT-3.5 Turbo",
          "contextTokens": 4096,
          "toolCalls": 10,
          "supportsFiles": false
        }
      }
    }
  }
}
```

API keys are read from `{UPPERCASE_PROVIDER_ID}_API_KEY` environment variables (e.g. `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`).

### Quick setup

```bash
agent config init
```

Walks you through provider and model selection interactively — no manual JSON editing needed.

## MCP Servers

Add tool-augmenting MCP servers to `config.jsonc` under `mcpServers`. Three transports are supported:

```jsonc
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/files"]
    },
    "websearch": {
      "transport": "sse",
      "url": "http://localhost:8080/sse"
    },
    "api-gateway": {
      "transport": "http",
      "url": "https://my-mcp.example.com/rpc"
    }
  }
}
```

- **stdio** (default when `command` is set): spawns the command as a child process
- **sse** (`transport: "sse"`): connects via Server-Sent Events
- **http** (`transport: "http"` or default when only `url` is set): standard JSON-RPC over HTTP

MCP tools are discovered at startup and merged into the available tool set alongside built-in tools (bash, read, write, glob, grep, etc.). Use `agent models` to list configured providers and models.

## Custom Agents (`.agent/custom/*.md`)

Define custom agents as markdown files in `.agent/custom/` with YAML frontmatter:

```markdown
---
name: reviewer
description: Thorough code reviewer that catches bugs and style issues
mode: primary
---

You are a senior code reviewer. For every file you examine:
1. Check for correctness bugs
2. Suggest style improvements
3. Flag security concerns
```

Use with `--agent reviewer` or switch mid-session with `/agent reviewer`. The `mode` field can be `primary` (default) or `subagent` (invoked by the `task` tool).

Config-level agents can also be defined inline in `config.jsonc`:

```jsonc
{
  "agents": {
    "linter": {
      "description": "Runs linters and reports issues",
      "systemPrompt": "You are a code linter. Run the project linter and report all issues concisely."
    }
  }
}
```

## Progressive Skills

Skills are markdown files stored in `~/.config/agent/skills/` or `.agent/skills/`. The agent lists available skills in its system context automatically. Use the `skill` tool to load a skill's full instructions into the conversation.

```bash
# Create a skill
mkdir -p .agent/skills
cat > .agent/skills/react-patterns.md << 'EOF'
# React component patterns

## Use Cases
- When user asks about React component structure
- When reviewing React code

## Instructions
Always prefer functional components with hooks over class components.
Use composition over inheritance. Keep components small and focused.
EOF
```

The skill is then available in-session: the agent can call `skill("react-patterns")` to load it. The first `# Heading` in the file is used as the description shown in the skill list.

## Shell Expansion (`!command`)

System prompts support `!command` expansion — the output of the command is inlined into the prompt at startup. Useful for injecting dynamic context:

```
!cat .agent/instructions.md
!git log --oneline -5
!ls -1 src/
```

Use `\!` to escape a literal `!`. Commands run via bash and stderr is discarded. This works in agent system prompts and anywhere a prompt is resolved through the context engine.

## Slash Commands

Available at runtime during `agent run` sessions via `--command`:

| Command | Effect |
|---------|--------|
| `/model provider/model` | Switch the active model mid-session |
| `/agent name` | Switch the active agent mid-session |

Combined with `--fork`, you can start a conversation with one model and continue with another while preserving history.

## Output Formats

**Default (human-readable, markdown rendered):**

LLM output passes through a streaming markdown renderer. Code blocks get a dimmed gutter, headings are bold, inline formatting uses ANSI escapes:

```
> run · deepseek/deepseek-v4-flash-free
Here's a Zig snippet:
```zig
│ const std = @import("std");
│ std.debug.print("Hello!\n", .{});
```
[stop]
```

**Raw (passthrough, no rendering):**

Use `--raw` to bypass markdown rendering — output is printed verbatim:

```bash
agent run --raw --message "Write a Zig function"
```

**JSON (machine-parseable, no rendering):**
```
{"type":"text","text":"Hello! I can help..."}
{"type":"stop","finish_reason":"stop","input_tokens":0,"output_tokens":0}
```

## Session Persistence

Sessions are saved to `~/.config/agent/sessions/<id>.json`. Use `--continue` / `-c` to resume the most recent session or `--session` / `-s <id>` for a specific one.

## Architecture

18 source files, ~7,800 lines of Zig.

| File | Purpose |
|------|---------|
| `main.zig` | CLI entrypoint, flag parsing, model resolution, session lifecycle |
| `config.zig` | JSONC parser with comment/trailing-comma stripping, provider config, API key resolution |
| `llm.zig` | HTTP chat completions client with SSE streaming, tool call accumulation |
| `processor.zig` | Multi-turn tool loop (max 25), tool dispatch, permission prompts, JSON output |
| `tool.zig` | 14 tool executors: bash, read, write, glob, grep, webfetch, editFile, question, skill, todoWrite, plan, webSearch, snapshot, task |
| `session.zig` | In-memory session state (messages, tool results, token counts) |
| `agent.zig` | 8 built-in agent definitions and system prompts |
| `persistence.zig` | JSON file read/write for sessions |
| `context.zig` | Context renderer — date, OS, workspace, git, config, instructions |
| `permission.zig` | Glob-based permission rule engine with interactive prompts |
| `mcp.zig` | MCP client — HTTP/stdio/SSE transports, JSON-RPC dispatch, tools/list + tools/call |
| `cli.zig` | CLI framework — flag parsing, subcommands, help rendering |
| `share.zig` | Share session to opencode.ai, generates shareable URL |
| `wizard.zig` | Interactive config setup wizard — provider presets, model selection, API key detection |
| `sse.zig` | SSE protocol parser for server event streams |
| `markdown.zig` | Streaming markdown-to-ANSI renderer — headings, code blocks, inline formatting |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system design, data flow diagrams, and module dependency map.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — System design, core loop, data flow, persistence format
- [CHANGELOG.md](CHANGELOG.md) — Version history and release notes
- [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute, branch naming, commit conventions
- [SECURITY.md](SECURITY.md) — Security issue disclosure policy
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1

## License

MIT — see [LICENSE](LICENSE).
