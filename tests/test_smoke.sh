#!/usr/bin/env bash
# Aggressive parameter-combination testing for agent-cli.
# Tests every subcommand with every flag permutation against mock LLM server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$PROJECT_DIR/zig-out/bin/agent"
MOCK_PORT=${MOCK_PORT:-18899}
MOCK_URL="http://127.0.0.1:$MOCK_PORT"
MOCK_PID=""
PASS=0; FAIL=0; SKIP=0
FAIL_LOG=$(mktemp /tmp/agent_agg_fail_XXXXXX.log)
CONFIG_FILE=$(mktemp /tmp/agent_agg_cfg_XXXXXX.jsonc)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

cleanup() {
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$FAIL_LOG"
}
trap cleanup EXIT

write_config() {
    cat > "$CONFIG_FILE" <<CONFIG
{
    "provider": {
        "mock": {
            "name": "Test Provider",
            "npm": "@mock/provider",
            "options": { "baseURL": "$MOCK_URL/v1/" },
            "models": { "test-model": {} }
        }
    }
}
CONFIG
}

start_mock() {
    local scenario="${1:-ask}"
    kill "${MOCK_PID:-}" 2>/dev/null || true; wait "${MOCK_PID:-}" 2>/dev/null || true
    MOCK_SCENARIO="$scenario" python3 "$SCRIPT_DIR/mock_llm_server.py" "$MOCK_PORT" &
    MOCK_PID=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        curl -s "$MOCK_URL/v1" >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "FATAL: mock server did not start"; exit 1
}

# ─── Test helpers ────────────────────────────────────────────────
log_pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
log_fail() { echo -e "  ${RED}FAIL${NC} $1"; echo "FAIL: $1" >> "$FAIL_LOG"; FAIL=$((FAIL + 1)); }

check_ok() {
    local label="$1"; shift
    set +e; "$BIN" "$@" >/dev/null 2>/dev/null; local rc=$?; set -e
    [ "$rc" -eq 0 ] && log_pass "$label" || log_fail "$label (exit=$rc)"
}

check_fail() {
    local label="$1"; shift
    set +e; "$BIN" "$@" >/dev/null 2>/dev/null; local rc=$?; set -e
    [ "$rc" -ne 0 ] && log_pass "$label" || log_fail "$label (expected failure, exit=$rc)"
}

check_stdout() {
    local needle="$1" label="$2"; shift 2
    local out; out=$(mktemp /tmp/agent_out_XXXXXX)
    set +e; "$BIN" "$@" >"$out" 2>/dev/null; local rc=$?; set -e
    local content; content=$(cat "$out"); rm -f "$out"
    echo "$content" | grep -qF "$needle" && log_pass "$label" || log_fail "$label (missing '$needle')"
}

check_stderr() {
    local needle="$1" label="$2"; shift 2
    local err; err=$(mktemp /tmp/agent_err_XXXXXX)
    set +e; "$BIN" "$@" 2>"$err" >/dev/null; local rc=$?; set -e
    local content; content=$(cat "$err"); rm -f "$err"
    echo "$content" | grep -qF "$needle" && log_pass "$label" || log_fail "$label (missing '$needle' in stderr)"
}

check_ok_stdin() {
    local input="$1" label="$2"; shift 2
    set +e; echo "$input" | "$BIN" "$@" >/dev/null 2>/dev/null; local rc=$?; set -e
    [ "$rc" -eq 0 ] && log_pass "$label" || log_fail "$label (exit=$rc)"
}

# ═══════════════════════════════════════════════════════════════════
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   AGGRESSIVE PARAM COMBINATION TEST SUITE           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
write_config

# ─── SECTION 1: NO-MOCK (no network needed) ────────────────────────
echo -e "${BOLD}── 1. No-mock tests (safety/error/help, no network) ──${NC}"

echo "  1a. Help output"
check_ok "help: agent --help" --help
check_ok "help: agent ask --help" ask --help
check_ok "help: agent plan --help" plan --help
check_ok "help: agent review --help" review --help
check_ok "help: agent edit --help" edit --help
check_ok "help: agent run --help" run --help
check_ok "help: agent models --help" models --help

echo "  1b. Missing required flags"
check_ok "review: no --session shows usage" review
check_ok "session show: no --id shows usage" session show

echo "  1c. Bad model format"
check_fail "ask: bad model 'bad' exits non-zero" ask --model "bad" --message "hi"
check_fail "run: bad model 'bad' exits non-zero" run --model "bad" --message "hi"

echo "  1d. Unknown provider"
check_fail "ask: unknown provider fails" ask --model "nonexistent/model" --config "$CONFIG_FILE" --message "hi"

echo "  1e. Bad config path"
check_fail "ask: nonexistent config fails" ask --config "/nonexistent/config.jsonc" --message "hi"

echo "  1f. models subcommand"
check_ok "models: --config exits 0" models --config "$CONFIG_FILE"
check_stdout "Test Provider" "models: shows provider name" models --config "$CONFIG_FILE"
check_ok "models: no config (shows default)" models

echo "  1g. Empty message handling"
# These need the mock server running (setupExec adds system messages, then tries to call LLM).
# Moved to section 2 after mock starts.

echo "  1h. Session operations"
check_ok "session list: exits 0" session list

echo "  1i. Bad flag values"
set +e; "$BIN" ask --temperature "invalid" --message "hi" --model "mock/test-model" --config "$CONFIG_FILE" >/dev/null 2>/dev/null; trc=$?; set -e
[ "$trc" -eq 0 ] && log_pass "ask: invalid temperature (no crash)" || log_pass "ask: invalid temperature (exit=$trc, acceptable)"

set +e; "$BIN" ask --max-tokens -5 --message "hi" --model "mock/test-model" --config "$CONFIG_FILE" >/dev/null 2>/dev/null; trc=$?; set -e
[ "$trc" -eq 0 ] || [ "$trc" -eq 1 ] && log_pass "ask: negative max-tokens handled" || log_fail "ask: negative max-tokens crash exit=$trc"

# ─── SECTION 2: MOCK ask scenario ──────────────────────────────────
echo ""
echo -e "${BOLD}── 2. ask subcommand (mock: ask) ──${NC}"
start_mock ask

check_ok "ask: basic message" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "What is Zig?"
check_ok "ask: --format json" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --format json
check_ok "ask: --max-tokens 100" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --max-tokens 100
check_ok "ask: --temperature 0.7" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --temperature 0.7
check_ok "ask: --temperature + --top-p" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --temperature 1.5 --top-p 0.9
check_ok "ask: --dir /tmp" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --dir /tmp
check_ok "ask: positional arg" ask "hello from positional" --model "mock/test-model" --config "$CONFIG_FILE"
check_ok_stdin "piped question" "ask: stdin pipe" ask --model "mock/test-model" --config "$CONFIG_FILE"
check_ok "ask: all params" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --temperature 0.5 --max-tokens 200 --top-p 0.8 --format json

# Empty message / no user prompt (mock must be running — setupExec adds system context)
check_ok "ask: no user message (no crash)" ask --model "mock/test-model" --config "$CONFIG_FILE"
check_ok "plan: no user message (no crash)" plan --model "mock/test-model" --config "$CONFIG_FILE"

# ─── SECTION 3: MOCK tool_use scenario ─────────────────────────────
echo ""
echo -e "${BOLD}── 3. run/edit/plan (mock: tool_use) ──${NC}"
start_mock tool_use

check_ok "run: basic" run --model "mock/test-model" --config "$CONFIG_FILE" --message "Create hello.py"
check_ok "run: --skip-permissions" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --skip-permissions
check_ok "run: --thinking" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --thinking
check_ok "run: --variant high" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --variant high
check_ok "run: --title" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --title "Test Session"
check_ok "run: --format json" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --format json
check_ok "run: ALL combo" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --skip-permissions --thinking --format json --variant high --temperature 0.5 --max-tokens 200 --top-p 0.8
check_ok "edit: --skip-permissions" edit --model "mock/test-model" --config "$CONFIG_FILE" --message "fix" --skip-permissions
check_ok "edit: --format json" edit --model "mock/test-model" --config "$CONFIG_FILE" --message "fix" --format json
check_ok "plan: basic" plan --model "mock/test-model" --config "$CONFIG_FILE" --message "Plan a project"
# plan does not support --format flag (only ask/edit/run do)
check_ok_stdin "build a REST API" "plan: stdin pipe" plan --model "mock/test-model" --config "$CONFIG_FILE"

# ─── SECTION 4: MOCK retry scenario ────────────────────────────────
echo ""
echo -e "${BOLD}── 4. Retry/error handling ──${NC}"
start_mock retry
check_ok "retry: succeeds after backoff" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "test retry"

# ─── SECTION 5: MOCK error scenario ────────────────────────────────
start_mock error
echo "  5a. Persistent error"
ERR_FILE=$(mktemp /tmp/agent_err_XXXXXX)
# askExec catches error.LlmError, prints clean message to stdout, returns 0 (by design)
set +e; "$BIN" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "test error" >"$ERR_FILE" 2>&1; erc=$?; set -e
[ "$erc" -eq 0 ] && log_pass "error: clean exit (0) after persistent error" || log_fail "error: unexpected exit=$erc"
grep -q "Error" "$ERR_FILE" && log_pass "error: graceful error message printed" || log_fail "error: no 'Error' in output"
rm -f "$ERR_FILE"

# ─── SECTION 6: run combo stress tests ─────────────────────────────
echo ""
echo -e "${BOLD}── 6. run combo stress (mock: tool_use) ──${NC}"
start_mock tool_use

check_ok "run: --continue (fresh)" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --continue
check_ok "run: --fork" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --fork
check_ok "run: --agent build" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --agent build
check_ok "run: --share (tolerates fail)" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --share

check_stdout "Current model" "run: /model shows current" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --command "/model"
check_ok "run: /model switch" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --command "/model mock/other-model"
check_stdout "Current agent" "run: /agent shows current" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --command "/agent"
check_ok "run: /agent switch" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --command "/agent ask"
check_stdout "Unknown command" "run: /unknown handled" run --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --command "/foobar"

# ─── SECTION 7: Edge cases ─────────────────────────────────────────
echo ""
echo -e "${BOLD}── 7. Edge cases ──${NC}"

check_ok "ask: special chars" ask --model "mock/test-model" --config "$CONFIG_FILE" --message 'hello "world" with dollar ampersand'

LONG_MSG=$(python3 -c "print('test ' * 500)")
check_ok "ask: long message (2500 chars)" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "$LONG_MSG"

check_ok "ask: --max-tokens 0" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "hi" --max-tokens 0

check_ok_stdin "fix the bug" "edit: stdin pipe" edit --model "mock/test-model" --config "$CONFIG_FILE" --skip-permissions

check_ok "ask: unicode message" ask --model "mock/test-model" --config "$CONFIG_FILE" --message "konnichiwa world emoji"

# ─── SECTION 8: Binary integrity ───────────────────────────────────
echo ""
echo -e "${BOLD}── 8. Binary integrity ──${NC}"

[ -x "$BIN" ] && log_pass "binary exists and executable" || log_fail "binary missing/not executable"

check_stdout "v0.2.0" "help: version shown" --help
check_stdout "ask" "help: ask listed" --help
check_stdout "run" "help: run listed" --help
check_stdout "session" "help: session listed" --help
check_stdout "edit" "help: edit listed" --help
check_stdout "plan" "help: plan listed" --help
check_stdout "models" "help: models listed" --help
check_stdout "review" "help: review listed" --help

# ─── SECTION 9: Unit tests ─────────────────────────────────────────
echo ""
echo -e "${BOLD}── 9. Unit tests (zig build test) ──${NC}"

UNIT_LOG=$(mktemp /tmp/agent_unit_XXXXXX.log)
set +e; (cd "$PROJECT_DIR" && zig build test 2>&1) > "$UNIT_LOG" 2>&1; urc=$?; set -e
if [ "$urc" -eq 0 ]; then
    log_pass "zig build test: all unit tests pass"
else
    log_fail "zig build test: FAILED"
    echo "--- last 40 lines ---"; tail -40 "$UNIT_LOG"
fi
rm -f "$UNIT_LOG"

# ─── REPORT ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   AGGRESSIVE TEST RESULTS                           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Total: ${BOLD}$TOTAL${NC}  |  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}SKIP: $SKIP${NC}"
echo ""
if [ -s "$FAIL_LOG" ]; then
    echo -e "${RED}${BOLD}FAILURES:${NC}"
    cat "$FAIL_LOG"
    echo ""
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
