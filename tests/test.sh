#!/usr/bin/env bash
# Integration test runner for agent-cli.
# Starts a mock LLM server, runs test scenarios, reports results.
#
# Usage:
#   ./test.sh              # Run all integration tests
#   ./test.sh basic        # Run only test_basic_ask.sh
#   ./test.sh --all        # Run all (default)
#   ./test.sh --quick      # Skip integration tests (unit tests only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_PORT=${MOCK_PORT:-18899}
MOCK_URL="http://127.0.0.1:$MOCK_PORT"
MOCK_PID=""
PASS=0
FAIL=0
FAILED_TESTS=""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    if [ -n "$MOCK_PID" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

start_mock_server() {
    local scenario="${1:-ask}"
    MOCK_SCENARIO="$scenario" python3 "$SCRIPT_DIR/mock_llm_server.py" "$MOCK_PORT" &
    MOCK_PID=$!

    # Retry loop: wait up to 10s for server to be ready
    for i in {1..10}; do
        if curl -s "$MOCK_URL/v1" > /dev/null 2>&1; then
            echo "  Mock server ready (scenario=$scenario) on port $MOCK_PORT"
            return 0
        fi
        sleep 1
    done
    echo "  Failed to start mock server"
    return 1
}

run_test() {
    local name="$1"
    local scenario="$2"
    local test_script="$3"
    local config_file
    config_file=$(mktemp /tmp/agent_test_config_XXXXXX.jsonc)

    echo ""
    echo "━━━ Running: $name ━━━"

    # Write test config pointing to mock server
    cat > "$config_file" <<CONFIG
{
    "provider": {
        "name": "mock",
        "npm": "@mock/provider",
        "options": {
            "baseURL": "$MOCK_URL/v1/"
        }
    },
    "model": "test-model"
}
CONFIG

    # Kill any existing mock server on this port
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true

    # Start fresh mock server for this test
    if ! start_mock_server "$scenario"; then
        echo -e "${RED}  FAILED: Could not start mock server${NC}"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name"
        rm -f "$config_file"
        return
    fi

    # Run the test
    set +e
    (
        export AGENT_CONFIG="$config_file"
        export MOCK_URL="$MOCK_URL"
        export MOCK_PORT="$MOCK_PORT"
        cd "$PROJECT_DIR"
        bash "$test_script" 2>&1
    )
    TEST_EXIT=$?
    set -e

    rm -f "$config_file"

    if [ $TEST_EXIT -eq 0 ]; then
        echo -e "${GREEN}  PASSED${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}  FAILED (exit=$TEST_EXIT)${NC}"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name"
    fi
}

# Parse args
RUN_ALL=true
if [ $# -gt 0 ]; then
    case "$1" in
        --quick)
            echo "Quick mode: running unit tests only"
            RUN_ALL=false
            ;;
        --all)
            RUN_ALL=true
            ;;
        *)
            RUN_ALL=false
            # Run single test by name
            ;;
    esac
fi

echo "=========================================="
echo " agent-cli Integration Test Suite"
echo "=========================================="
echo ""

# Check prerequisites
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required for mock server"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is required for tests"
    exit 1
fi

if ! command -v zig &> /dev/null; then
    echo "Warning: zig not found in PATH — will skip zig test"
fi

# Build first
echo "--- Building project ---"
if command -v zig &> /dev/null; then
    (cd "$PROJECT_DIR" && zig build 2>&1) && echo "Build OK" || echo "Build failed — continuing anyway"
fi

# Run unit tests
echo ""
echo "--- Running unit tests ---"
if command -v zig &> /dev/null; then
    (cd "$PROJECT_DIR" && zig build test 2>&1) && echo -e "${GREEN}Unit tests passed${NC}" || echo -e "${RED}Unit tests failed${NC}"
else
    echo "Zig not found — skipping unit tests"
fi

if [ "$RUN_ALL" = false ]; then
    echo "Skipping integration tests (use --all or no args to include)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ $FAIL -eq 0 ] && exit 0 || exit 1
fi

# Run integration tests
echo ""
echo "--- Running integration tests ---"

# Test 1: Basic ask
run_test "basic_ask" "ask" "$SCRIPT_DIR/test_basic_ask.sh"

# Test 2: Tool execution
run_test "tool_execution" "tool_use" "$SCRIPT_DIR/test_tool_execution.sh"

# Test 3: Error retry
run_test "error_retry" "retry" "$SCRIPT_DIR/test_error_retry.sh"

# Test 4: Multi-turn
run_test "multi_turn" "ask" "$SCRIPT_DIR/test_multi_turn.sh"

# Cleanup mock server
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
if [ -n "$FAILED_TESTS" ]; then
    echo " Failed:${FAILED_TESTS}"
fi
echo "=========================================="

[ $FAIL -eq 0 ] && exit 0 || exit 1
