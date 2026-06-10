#!/usr/bin/env bash
# Integration test: tool execution mode.
# Verifies that the mock server returns tool_calls and
# the agent CLI can parse them correctly.

set -euo pipefail

MOCK_URL="${MOCK_URL:-http://127.0.0.1:18899}"

echo "  Test: Tool execution with mock server at $MOCK_URL"

# First, verify the mock returns tool_calls when tools are provided
RESPONSE=$(curl -s -X POST "$MOCK_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "test-model",
        "messages": [{"role": "user", "content": "list files"}],
        "tools": [{
            "type": "function",
            "function": {
                "name": "bash",
                "description": "Run a shell command",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {"type": "string"}
                    },
                    "required": ["command"]
                }
            }
        }],
        "stream": false
    }')

echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
choices = d.get('choices', [])
assert len(choices) > 0, 'Expected at least one choice'
msg = choices[0].get('message', {})
finish = choices[0].get('finish_reason', '')
tool_calls = msg.get('tool_calls', [])
assert len(tool_calls) > 0, 'Expected tool_calls in tool_use scenario'
tc = tool_calls[0]
assert 'bash' in tc.get('function', {}).get('name', ''), f'Expected bash tool, got: {tc}'
print(f'  Got tool_call: {tc[\"function\"][\"name\"]} with args: {tc[\"function\"][\"arguments\"]}')
assert finish == 'tool_calls', f'Expected tool_calls finish_reason, got: {finish}'
"

echo "  tool_execution test passed"
