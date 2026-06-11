#!/usr/bin/env bash
# Request validation tests for agent-cli.
# Validates that the agent sends well-formed request bodies to the LLM,
# specifically that tool messages contain tool_call_id (prevents DeepSeek 400 errors).
#
# Prerequisites:
#   - Mock LLM server running on MOCK_URL with /last-request endpoint
#   - agent binary built
#   - AGENT_CONFIG pointing to mock server
#
# Usage (via test.sh):
#   AGENT_CONFIG=/tmp/cfg.json MOCK_URL=http://127.0.0.1:18899 ./test_request_validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$PROJECT_DIR/zig-out/bin/agent"
MOCK_URL="${MOCK_URL:-http://127.0.0.1:18899}"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check() {
    local name="$1"
    local condition="$2"
    if [ "$condition" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================="
echo " Request Validation Test Suite"
echo "=========================================="
echo ""

# ─── 1. Retrieve last request from mock server ───
LAST_REQ=$(curl -s "$MOCK_URL/last-request" 2>/dev/null || echo '{"request":null}')
REQ_BODY=$(echo "$LAST_REQ" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('request', d)))" 2>/dev/null || echo "null")

if [ "$REQ_BODY" = "null" ] || [ -z "$REQ_BODY" ]; then
    echo -e "  ${RED}SKIP${NC} No request captured from mock server — agent may not have run yet"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 0
fi

# ─── 2. Validate messages array exists ───
HAS_MSGS=$(echo "$REQ_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msgs = d.get('messages', [])
    print(len(msgs))
except:
    print('ERROR')
" 2>/dev/null || echo "ERROR")

check "request body has messages array" "$([ "$HAS_MSGS" != "ERROR" ] && [ "$HAS_MSGS" -gt 0 ] && echo 0 || echo 1)"

# ─── 3. Validate all tool messages have tool_call_id ───
TOOL_MSGS_OK=$(echo "$REQ_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msgs = d.get('messages', [])
    tool_msgs = [m for m in msgs if m.get('role') == 'tool']
    if not tool_msgs:
        print('NO_TOOL_MSGS')
    else:
        missing = [i for i, m in enumerate(tool_msgs) if 'tool_call_id' not in m]
        if missing:
            print(f'MISSING:{missing}')
        else:
            print(f'OK:{len(tool_msgs)}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>/dev/null || echo "ERROR")

check "all tool messages have tool_call_id" "$(echo "$TOOL_MSGS_OK" | grep -q '^OK:' && echo 0 || echo 1)"

# ─── 4. Validate all assistant messages with tool_calls have proper structure ───
ASST_OK=$(echo "$REQ_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msgs = d.get('messages', [])
    asst_msgs = [m for m in msgs if m.get('role') == 'assistant' and m.get('tool_calls')]
    if not asst_msgs:
        print('NO_ASST_TOOL_CALLS')
    else:
        issues = []
        for i, m in enumerate(asst_msgs):
            for j, tc in enumerate(m['tool_calls']):
                if 'id' not in tc:
                    issues.append(f'msg{i}.tc{j}:missing_id')
                if 'function' not in tc:
                    issues.append(f'msg{i}.tc{j}:missing_function')
                else:
                    if 'name' not in tc['function']:
                        issues.append(f'msg{i}.tc{j}:missing_name')
                    if 'arguments' not in tc['function']:
                        issues.append(f'msg{i}.tc{j}:missing_arguments')
        if issues:
            print(f'ISSUES:{issues}')
        else:
            print(f'OK:{len(asst_msgs)}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>/dev/null || echo "ERROR")

check "assistant tool_calls have id, function.name, function.arguments" "$(echo "$ASST_OK" | grep -q '^OK:' && echo 0 || echo 1)"

# ─── 5. Validate model field exists ───
HAS_MODEL=$(echo "$REQ_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    model = d.get('model', '')
    print('OK' if model else 'MISSING')
except:
    print('ERROR')
" 2>/dev/null || echo "ERROR")

check "request body has model field" "$(echo "$HAS_MODEL" | grep -q '^OK$' && echo 0 || echo 1)"

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
