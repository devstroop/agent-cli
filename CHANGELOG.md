# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
until 1.0.0, after which it follows the [opencode version scheme](https://opencode.ai).

## [0.2.0] — 2026-06-10

### Added

- SSE streaming — `completeStream()` emits text in real-time via writer
- SystemContext — `context.zig` renders 7 sources (date, OS, workspace, git status, git diff, project config, instructions)
- Session persistence — JSON files at `~/.config/agent/sessions/` with save, load, latest pointer
- `--continue` / `-c` — resume last session
- `--session` / `-s` — resume by session ID
- `--fork` — clone session under new ID before processing
- `--file` / `-f` — attach files as user message
- `--config` — custom `config.jsonc` path
- `--max-tokens`, `--temperature`, `--top-p` — LLM sampling parameters
- Interactive permission prompts — `[y/n/always]` on stdin
- JSON output format — machine-parseable `{"type":"text","text":"..."}` lines

### Changed

- Renamed project from `oc` to `agent-cli` (binary: `agent`)
- `processTurn` uses `completeStream` exclusively (was blocking `complete`)
- Zig 0.16.0 API compatibility across all modules

## [0.1.0] — 2026-06-10

### Added

- Initial project scaffold
- `config.zig` — JSONC parser with comment/trailing-comma stripping
- `llm.zig` — chat completions client with tool call support
- `processor.zig` — multi-turn tool loop (max 25)
- `tool.zig` — 6 tool executors: bash, read, write, glob, grep, webfetch
- `session.zig` — in-memory session state
- `agent.zig` — 7 built-in agent definitions
- `permission.zig` — glob-based permission rule engine
- `client.zig` — OpenCode server SDK
- `types.zig` — OpenCode SDK v2 types
- `sse.zig` — SSE protocol parser
- `--message`, `--model`, `--agent`, `--dir`, `--format`, `--title`, `--skip-permissions` flags
