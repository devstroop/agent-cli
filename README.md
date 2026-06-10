# Agent CLI

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/download/)

A lightweight CLI for LLM-powered agentic workflows. Built in Zig — no runtime dependencies, single static binary.

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
agent run -m "opencode/big-pickle" --message "Say hello"

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

# Use a different agent
agent run --message "Plan this task" --agent plan

# Skip permission prompts (dangerous)
agent run --message "Run this command" --dangerously-skip-permissions

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

API keys are read from `{UPPERCASE_PROVIDER_ID}_API_KEY` environment variables (e.g. `LLM_GATEWAY_API_KEY`, `OPENCODE_API_KEY`).

## Output Formats

**Default (human-readable):**
```
> build · openai/gpt-4o
Hello! I can help you with that...
[stop]
```

**JSON (machine-parseable):**
```
{"type":"text","text":"Hello! I can help..."}
{"type":"stop","finish_reason":"stop","input_tokens":0,"output_tokens":0}
```

## Session Persistence

Sessions are saved to `~/.config/agent/sessions/<id>.json`. Use `--continue` / `-c` to resume the most recent session or `--session` / `-s <id>` for a specific one.

## Architecture

| File | Purpose |
|------|---------|
| `main.zig` | CLI entrypoint, flag parsing, model resolution, session lifecycle |
| `config.zig` | JSONC parser with comment/trailing-comma stripping, provider config, API key resolution |
| `llm.zig` | HTTP chat completions client with SSE streaming, tool call accumulation |
| `processor.zig` | Multi-turn tool loop (max 25), tool dispatch, permission prompts, JSON output |
| `tool.zig` | 14 tool executors: bash, read, write, glob, grep, webfetch, editFile, question, skill, todoWrite, plan, webSearch, snapshot, task |
| `session.zig` | In-memory session state (messages, tool results, token counts) |
| `agent.zig` | 7 built-in agent definitions and system prompts |
| `persistence.zig` | JSON file read/write for sessions |
| `context.zig` | Context renderer — date, OS, workspace, git, config, instructions |
| `permission.zig` | Glob-based permission rule engine with interactive prompts |
| `client.zig` | OpenCode server SDK (not used by `agent run`) |
| `types.zig` | OpenCode SDK v2 type definitions |
| `sse.zig` | SSE protocol parser for server event streams |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system design, data flow diagrams, and module dependency map.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — System design, core loop, data flow, persistence format
- [CHANGELOG.md](CHANGELOG.md) — Version history and release notes
- [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute, branch naming, commit conventions
- [SECURITY.md](SECURITY.md) — Security issue disclosure policy
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1

## License

MIT — see [LICENSE](LICENSE).
