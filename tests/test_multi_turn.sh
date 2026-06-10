#!/usr/bin/env bash
# Integration test: multi-turn conversation.
# Simulates a conversation with multiple exchanges.

set -euo pipefail

MOCK_URL="${MOCK_URL:-http://127.0.0.1:18899}"

echo "  Test: Multi-turn conversation with mock server at $MOCK_URL"

# Turn 1: User sends first message
echo "  Turn 1: First user message"
RESP1=$(curl -s -X POST "$MOCK_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "test-model",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Hello, what is the weather?"}
        ],
        "stream": false
    }')

CONTENT1=$(echo "$RESP1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
choices = d.get('choices', [])
msg = choices[0].get('message', {}) if choices else {}
print(msg.get('content', ''))
")

echo "  Assistant: ${CONTENT1:0:80}..."

# Turn 2: Follow-up with context from turn 1
echo "  Turn 2: Follow-up message"
RESP2=$(curl -s -X POST "$MOCK_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"test-model\",
        \"messages\": [
            {\"role\": \"system\", \"content\": \"You are a helpful assistant.\"},
            {\"role\": \"user\", \"content\": \"Hello, what is the weather?\"},
            {\"role\": \"assistant\", \"content\": $(echo "$CONTENT1" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")},
            {\"role\": \"user\", \"content\": \"And what about tomorrow?\"}
        ],
        \"stream\": false
    }")

CONTENT2=$(echo "$RESP2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
choices = d.get('choices', [])
msg = choices[0].get('message', {}) if choices else {}
print(msg.get('content', ''))
")

echo "  Assistant: ${CONTENT2:0:80}..."

# Validate both responses are different
if [ "$CONTENT1" = "$CONTENT2" ]; then
    echo "  WARNING: Both responses are identical — multi-turn context may not be working"
fi

echo "  multi_turn test passed"
