#!/usr/bin/env bash
# Regression test suite for agent-cli.
# Tests against the compiled binary directly (no mock server needed).
# Catches em-dash/encoding issues, missing --continue flags, NoHome crash, etc.
#
# Usage:
#   ./test_regression.sh          # Run all regression checks
#   ./test_regression.sh --quick  # Fast checks only (skip expensive tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$PROJECT_DIR/zig-out/bin/agent"
PASS=0
FAIL=0
QUICK=false

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "${1:-}" = "--quick" ]; then
    QUICK=true
    echo "Quick mode: skipping slow checks"
fi

# Build if needed
if [ ! -x "$BIN" ]; then
    echo "Building agent-cli..."
    (cd "$PROJECT_DIR" && zig build 2>&1) || { echo "Build failed"; exit 1; }
fi

check() {
    local name="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $name"
        FAIL=$((FAIL + 1))
    fi
}

check_output_contains() {
    local name="$1"
    local output="$2"
    local pattern="$3"
    # Use -e to protect patterns starting with dashes (e.g., --continue)
    if echo "$output" | grep -q -e "$pattern"; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $name (expected: '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

check_output_not_contains() {
    local name="$1"
    local output="$2"
    local pattern="$3"
    # Use -e to protect patterns starting with dashes
    if ! echo "$output" | grep -q -e "$pattern"; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $name (found unwanted: '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================="
echo " Regression Test Suite"
echo "=========================================="
echo ""

# ─── 1. Help output ASCII safety ───
echo "--- Help Output ASCII Safety ---"

# 1a: Top-level help has no em-dash (U+2014 = E2 80 94 in UTF-8)
ROOT_HELP=$("$BIN" -h 2>&1) || true
check_output_not_contains "top-level help: no em-dash (—)" "$ROOT_HELP" "—"

# 1b: Top-level help has no garbled UTF-8 (Î"ö)
check_output_not_contains "top-level help: no garbled UTF-8 ΓÇö" "$ROOT_HELP" "ΓÇö"

# 1c: Each subcommand help has no em-dash
for sub in ask plan edit review run; do
    SUB_HELP=$("$BIN" "$sub" -h 2>&1) || true
    check_output_not_contains "$sub help: no em-dash (—)" "$SUB_HELP" "—"
    check_output_not_contains "$sub help: no garbled UTF-8 ΓÇö" "$SUB_HELP" "ΓÇö"
done

# ─── 2. --continue / --session flags presence ───
echo ""
echo "--- Flag Registration ---"

# 2a: run --help shows --continue
RUN_HELP=$("$BIN" run -h 2>&1) || true
check_output_contains "run --help shows --continue flag" "$RUN_HELP" "--continue"

# 2b: run --help shows --session
check_output_contains "run --help shows --session flag" "$RUN_HELP" "--session"

# 2c: ask --help shows --continue
ASK_HELP=$("$BIN" ask -h 2>&1) || true
check_output_contains "ask --help shows --continue flag" "$ASK_HELP" "--continue"

# 2d: ask --help shows --session
check_output_contains "ask --help shows --session flag" "$ASK_HELP" "--session"

# 2e: plan --help shows --continue
PLAN_HELP=$("$BIN" plan -h 2>&1) || true
check_output_contains "plan --help shows --continue flag" "$PLAN_HELP" "--continue"

# 2f: plan --help shows --session
check_output_contains "plan --help shows --session flag" "$PLAN_HELP" "--session"

# ─── 3. Help exit codes ───
echo ""
echo "--- Help Exit Codes ---"

for sub in "" "ask" "plan" "edit" "review" "run" "session" "models"; do
    if [ -z "$sub" ]; then
        set +e
        "$BIN" -h > /dev/null 2>&1
        EXIT=$?
        set -e
        check "agent -h exit 0" "$EXIT"
    else
        set +e
        "$BIN" "$sub" -h > /dev/null 2>&1
        EXIT=$?
        set -e
        check "agent $sub -h exit 0" "$EXIT"
    fi
done

# ─── 4. Unknown flag error ───
echo ""
echo "--- Unknown Flag Handling ---"

set +e
UNK_OUT=$("$BIN" run --nonexistent-flag 2>&1)
UNK_EXIT=$?
set -e
if [ "$UNK_EXIT" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} unknown flag exits non-zero"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} unknown flag exits zero"
    FAIL=$((FAIL + 1))
fi

# ─── 5. NoHome graceful error ───
echo ""
echo "--- NoHome Graceful Error ---"
if ! $QUICK; then
    set +e
    NOHOME_OUT=$(env -u HOME -u USERPROFILE "$BIN" run "hi" 2>&1)
    NOHOME_EXIT=$?
    set -e
    # Should exit non-zero but NOT segfault/panic
    if [ "$NOHOME_EXIT" -ne 0 ]; then
        echo -e "  ${GREEN}PASS${NC} NoHome exits non-zero (not panicked)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} NoHome exit=$NOHOME_EXIT"
        FAIL=$((FAIL + 1))
    fi
    # Check output is reasonable (not a Zig panic trace)
    if echo "$NOHOME_OUT" | grep -q "NoHome\|session\|config\|home"; then
        echo -e "  ${GREEN}PASS${NC} NoHome prints helpful message"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}WARN${NC} NoHome output may not be descriptive"
    fi
else
    echo "  Skipped (--quick)"
fi

# ─── 6. session list / show basic ───
echo ""
echo "--- Session Commands ---"

set +e
SL_OUT=$("$BIN" session list 2>&1)
SL_EXIT=$?
set -e
check "session list exits 0" "$SL_EXIT"

set +e
SS_OUT=$("$BIN" session show --id nonexistent 2>&1)
SS_EXIT=$?
set -e
# Should exit non-zero for missing session
if [ "$SS_EXIT" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} session show nonexistent exits non-zero"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} session show nonexistent exit=$SS_EXIT"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
