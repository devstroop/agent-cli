# Contributing to Agent CLI

Thanks for your interest. This document is long on purpose — read it before opening an issue or pull request.

## What this repo is

agent-cli is a self-contained Zig CLI for LLM-based agent workflows. It ships as a single static binary (`agent`) with zero runtime dependencies beyond the operating system's libc.

## What this repo is not

- **Not a general-purpose Zig framework.** It implements a specific tool-calling LLM protocol. We don't accept patches that add new LLM providers or protocols without prior discussion.
- **Not a TUI.** This is a CLI-only tool designed for scripting and non-interactive use.

If your issue or PR is outside this scope, please redirect rather than open it here.

## Reporting issues

Issues without the information below get closed with a label, not a discussion.

**Required for every bug report:**

1. **Zig version** (`zig version`)
2. **Target platform** (e.g. macOS 14 arm64, Linux x86_64)
3. **Build command** you used (`zig build`, `zig build --release=fast`)
4. **Steps to reproduce.** If it requires a specific LLM provider or config, say so explicitly.
5. **What you expected vs. what happened**
6. **Config file** (sanitize API keys) or a minimal reproduction setup

**Bug reports that won't be triaged:**

- "Doesn't connect" with no logs, no config, and no provider details
- "Crashes" with no reproduction steps
- Feature requests filed as bugs

**Feature requests** are welcome as `enhancement` issues. Please open a discussion first — don't write a 500-line PR before a conversation.

## Security

**Do not file security issues on the public tracker.**

Email security issues to the maintainer directly:

- **Email:** `info@devstroop.com`
- **Subject prefix:** `[SECURITY] agent-cli`
- **Include:** affected version, platform, reproduction, suggested fix if you have one

Expected response: acknowledgement within 7 days, fix or "won't fix with rationale" within 30 days for high-severity. No bug bounty is offered.

Public disclosure: 90 days from initial report, or upon release of a fix, whichever is earlier.

## Pull requests

**Talk first, code second.** Open an issue describing the change before writing more than ~50 lines of code. PRs without a prior discussion are reviewed last and may be closed.

**What we accept:**

- Bug fixes with a reproduction case
- Platform support fixes
- New tests for existing untested code paths
- Documentation improvements
- Protocol-correctness fixes against real LLM API behaviour

**What we don't accept without prior agreement:**

- Refactors for the sake of refactoring
- New abstractions ("I added a `Transport` trait")
- Style-only changes
- Adding dependencies (Zig stdlib is the stack — no external packages)
- Changes that break the existing CLI flag interface without a migration plan

**PR requirements:**

- `zig build` passes locally
- `zig fmt --check src/` passes locally
- `zig build test` passes locally
- New code follows existing error-handling patterns (return errors, not `unreachable`)
- No `unreachable` or panic-style crashes on user input — return errors
- Commits are signed (`git commit -S`) if possible
- No AI-generated commit messages or PR descriptions

**Review process:**

- Solo maintainer, best-effort, no SLA. Plan on weeks, not days.
- Review may include "please split this PR into N smaller PRs"
- The maintainer reserves the right to say no without elaborate justification

**Contributor licensing:** By opening a PR you agree your contribution is licensed under the MIT license. No separate CLA is required.

## Git workflow and branching

### Overview

This project follows **GitHub Flow**. The `main` branch is always considered deployable. All work is performed on short-lived branches created from `main` and merged back through pull requests.

```
main → feat/something → PR (squash) → main
```

### Branch rules

- All branches must be created from the latest `main`
- One logical change per branch
- Rebase on the latest `main` before merge
- Delete branches after merge

### Branch naming

```
<type>/<short-description>
```

Examples: `feat/websearch-tool`, `fix/session-load-null`, `docs/readme-examples`.

| Type | Purpose |
|------|---------|
| `feat` | New functionality |
| `fix` | Bug fixes |
| `docs` | Documentation changes |
| `refactor` | Internal restructuring without behaviour changes |
| `test` | Test additions or corrections |
| `perf` | Performance improvements |
| `chore` | Tooling, dependencies, configuration |

### Commit convention

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).

```
feat(tool): add websearch tool
fix(persistence): handle missing latest.json
docs(readme): add environment variable section
refactor(llm): extract buildRequestBody helper
test(sse): add processSSEData unit test
```

### Standard workflow

```bash
# Sync main
git checkout main
git pull

# Create branch
git checkout -b feat/my-feature

# Develop
zig build
zig build test
zig fmt --check src/

# Commit incrementally
git commit -m "feat(module): description"

# Push and open PR
git push -u origin feat/my-feature
gh pr create

# Merge via squash
gh pr merge --squash

# Cleanup
git checkout main
git pull
git branch -d feat/my-feature
```

## Development

### Prerequisites

- **Zig 0.16.0** — install via [ziglang.org/download](https://ziglang.org/download/) or Homebrew (`brew install zig`)

Zero external dependencies. The Zig stdlib is the only library — no packages, no vendored C code, no runtime deps.

### Build

```bash
zig build                    # debug build
zig build -Doptimize=ReleaseFast     # release build
zig build -Doptimize=ReleaseSafe     # release with safety checks
```

Output: `zig-out/bin/agent`

### Test

```bash
zig build test               # run all 60+ tests
```

### Code style

- Run `zig fmt` before committing: `zig fmt src/`
- Verify formatting matches CI: `zig fmt --check src/`
- Follow existing patterns in the codebase
- Allocators are passed explicitly, never hidden behind global state
- Prefer `defer` / `errdefer` over manual cleanup
- No `unreachable` for user-reachable paths — return errors
- Return errors from tool execution rather than crashing
- Comments: explain *why*, not *what*. Don't restate the code.

### Platform testing

The maintainer can verify changes on macOS arm64 directly. For changes affecting other platforms:

- **Linux:** include CI output or describe your local test setup
- **Windows:** not regularly tested; contributions should note their testing
- **Other platforms:** include device specifics

## What we won't do

To save everyone time, the following are out of scope and will be closed quickly if filed:

- Adding a TUI / interactive mode
- Replacing the HTTP client with cURL or libcurl
- Adding OpenSSL or TLS libraries (Zig's `std.http.Client` handles HTTPS)
- Build system rewrites (`build.zig` stays; no Makefile, no CMake)
- Porting to other languages (Rust, Go, etc.)
- Adding support for non-OpenAI-compatible LLM APIs without prior discussion

## CI / CD

Four workflows run on push and pull request. All must pass before merge:

| Workflow | File | What it checks |
|----------|------|----------------|
| **CI** | `.github/workflows/ci.yml` | `zig build` + `zig build test` on Ubuntu and macOS |
| **Lint** | `.github/workflows/lint.yml` | `zig fmt --check src/` |
| **Release** | `.github/workflows/release.yml` | Cross-compiles 5 targets on tag push `v*` |
| **Mirror** | `.github/workflows/mirror.yml` | Daily backup mirror to configured remote |

To trigger a release, push a tag: `git tag v0.2.0 && git push origin v0.2.0`. The release workflow builds static binaries for `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, and `x86_64-windows`, then uploads them as release artifacts.

## Releases

Tags follow `vMAJOR.MINOR.PATCH`. Pre-1.0; expect breaking changes between minor versions.

## Maintainer

Maintained by [Devstroop Technologies](https://devstroop.com). Contact `info@devstroop.com`.

Decisions are not made by committee. If you need a governance model with multiple core maintainers, this is not currently that project.

Thanks for reading. If you got this far and still want to contribute, you're exactly the kind of contributor this project benefits from.
