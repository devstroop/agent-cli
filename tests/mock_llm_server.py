#!/usr/bin/env python3
"""Mock LLM server for integration testing.

Provides an OpenAI-compatible /v1/chat/completions endpoint with
configurable scenarios: ask, tool_use, error, retry.

Usage:
    python3 mock_llm_server.py [port]
    # Serves on 127.0.0.1:<port> (default 18899)
"""

import http.server
import json
import os
import sys
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18899

# Stateful scenario counters (set via env var or query param)
SCENARIO = os.environ.get("MOCK_SCENARIO", "ask")
RETRY_COUNT = int(os.environ.get("MOCK_RETRY_COUNT", "0"))
_call_count = 0
_last_request = None  # Stores the last POST body for /last-request inspection


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/v1" or self.path == "/":
            self._ok({"status": "ok", "scenario": SCENARIO, "retry_count": RETRY_COUNT})
        elif self.path.startswith("/v1/models"):
            self._ok({
                "object": "list",
                "data": [{"id": "test-model", "object": "model"}],
            })
        elif self.path == "/reset":
            global _call_count
            _call_count = 0
            self._ok({"reset": True})
        elif self.path == "/last-request":
            global _last_request
            self._ok({"request": json.loads(_last_request) if _last_request else None})
        else:
            self._ok({"status": "mock running"})

    def do_POST(self):
        global _call_count, _last_request
        _call_count += 1
        path = urllib.parse.urlparse(self.path).path

        if path == "/v1/chat/completions":
            body = self._read_body()
            _last_request = body  # Save for validation tests
            self._handle_chat_completion(body)
        else:
            self._json(404, {"error": "not found"})

    def _handle_chat_completion(self, body):
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return self._json(400, {"error": "invalid json"})

        messages = data.get("messages", [])
        stream = data.get("stream", False)
        tools = data.get("tools", [])

        # Simulate retry scenario: return 429 for first N calls
        if SCENARIO == "retry" and _call_count <= RETRY_COUNT:
            self._json(429, {"error": "rate limited"})
            return

        # Simulate error scenario
        if SCENARIO == "error":
            self._json(500, {"error": "internal server error"})
            return

        # Simulate rate limit
        if SCENARIO == "rate_limit":
            self._json(429, {"error": "rate limited - try again"})
            return

        # Stream mode
        if stream:
            self._stream_response(data)
            return

        # Extract last user message for echo
        last_user = ""
        for msg in reversed(messages):
            if msg.get("role") == "user":
                last_user = msg.get("content", "")
                break

        # Simulate tool_use scenario
        if SCENARIO == "tool_use" and tools:
            tool_name = tools[0].get("function", {}).get("name", "bash")
            tool_desc = tools[0].get("function", {}).get("description", "")
            resp = {
                "id": "mock-call-1",
                "object": "chat.completion",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [{
                            "id": "call_mock_001",
                            "type": "function",
                            "function": {
                                "name": tool_name,
                                "arguments": json.dumps({"command": "echo mock"}) if tool_name == "bash" else "{}",
                            },
                        }],
                    },
                    "finish_reason": "tool_calls",
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5},
            }
        else:
            resp = {
                "id": "mock-call-1",
                "object": "chat.completion",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": f"Mock response to: {last_user[:100]}",
                    },
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5},
            }

        self._ok(resp)

    def _stream_response(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        # Send a few chunks
        chunks = ["Hello", " from", " mock", " stream"]
        for chunk in chunks:
            msg = json.dumps({
                "id": "mock-chunk",
                "object": "chat.completion.chunk",
                "choices": [{
                    "index": 0,
                    "delta": {"content": chunk},
                    "finish_reason": None,
                }],
            })
            self.wfile.write(f"data: {msg}\n\n".encode())

        # Final chunk with finish_reason
        final = json.dumps({
            "id": "mock-chunk",
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5},
        })
        self.wfile.write(f"data: {final}\n\n".encode())
        self.wfile.write("data: [DONE]\n\n".encode())

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 0:
            return self.rfile.read(length).decode()
        return ""

    def _ok(self, data):
        self._json(200, data)

    def _json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        if os.environ.get("MOCK_VERBOSE"):
            super().log_message(format, *args)


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Mock LLM server running on http://127.0.0.1:{PORT} (scenario={SCENARIO})")
    server.serve_forever()
