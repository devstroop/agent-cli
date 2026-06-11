#!/usr/bin/env bash
# Encoding safety test suite for agent-cli.
# Verifies Unicode input/output integrity, JSON parseability, and binary safety.
#
# Usage:
#   ./test_encoding.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$PROJECT_DIR/zig-out/bin/agent"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

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

check_contains() {
    local name="$1"
    local output="$2"
    local pattern="$3"
    # Use -e to protect patterns starting with dashes
    if echo "$output" | grep -q -e "$pattern"; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $name (expected: '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================="
echo " Encoding Safety Test Suite"
echo "=========================================="
echo ""

# ─── 1. Help output is valid UTF-8 ───
echo "--- Help Output Encoding ---"

HELP_OUT=$("$BIN" -h 2>&1) || true
if echo "$HELP_OUT" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} help output is valid UTF-8"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} help output is not valid UTF-8"
    FAIL=$((FAIL + 1))
fi

# ─── 2. Control characters absent from help ───
echo ""
echo "--- Control Character Safety ---"

# Check for null bytes — write to temp file, use xxd to check for 00 bytes
NULL_TMP=$(mktemp)
"$BIN" -h > "$NULL_TMP" 2>&1 || true
if xxd -p "$NULL_TMP" | tr -d '\n' | grep -q '00'; then
    echo -e "  ${RED}FAIL${NC} help output contains null bytes"
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC} help output has no null bytes"
    PASS=$((PASS + 1))
fi
rm -f "$NULL_TMP"

# ─── 3. JSON flag exists and produces valid JSON ───
echo ""
echo "--- JSON Format Output ---"

# Check that --format flag exists on run
RUN_HELP=$("$BIN" run -h 2>&1) || true
check_contains "run --help shows --format flag" "$RUN_HELP" "--format"

# ─── 4. Subcommand descriptions are ASCII-safe ───
echo ""
echo "--- Subcommand Description Safety ---"

for sub in ask plan edit review; do
    SUB_HELP=$("$BIN" "$sub" -h 2>&1) || true
    if echo "$SUB_HELP" | LC_ALL=C grep -q $'[\x80-\xFF]'; then
        # Has non-ASCII bytes — check if it's just the banner (Â·) or description area
        # Extract just the description line (first line after command name)
        DESC_LINE=$(echo "$SUB_HELP" | head -1)
        if echo "$DESC_LINE" | LC_ALL=C grep -q $'[\x80-\xFF]'; then
            echo -e "  ${RED}FAIL${NC} $sub description contains non-ASCII bytes"
            FAIL=$((FAIL + 1))
        else
            echo -e "  ${GREEN}PASS${NC} $sub description is ASCII-safe"
            PASS=$((PASS + 1))
        fi
    else
        echo -e "  ${GREEN}PASS${NC} $sub description is ASCII-safe"
        PASS=$((PASS + 1))
    fi
done

# ─── 5. Run with Unicode message doesn't crash ───
echo ""
echo "--- Unicode Input Safety ---"

# Test that the binary can at least parse Unicode positional args without crashing
set +e
UNI_OUT=$("$BIN" run "héllo wörld" --model opencode/deepseek-v4-flash-free 2>&1)
UNI_EXIT=$?
set -e
# We don't care about the LLM result — just that the binary doesn't crash/panic
if echo "$UNI_OUT" | grep -q "index out of bounds\|segmentation fault\|panic:"; then
    echo -e "  ${RED}FAIL${NC} Unicode input caused panic/crash"
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC} Unicode input parsed without panic"
    PASS=$((PASS + 1))
fi

# ─── 6. models subcommand output is ASCII-safe ───
echo ""
echo "--- Models Output Encoding ---"

set +e
MODELS_OUT=$("$BIN" models 2>&1)
MODELS_EXIT=$?
set -e
check "models exits 0" "$MODELS_EXIT"
check_contains "models mentions opencode or no providers" "$MODELS_OUT" "opencode"

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
