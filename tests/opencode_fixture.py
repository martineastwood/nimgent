#!/usr/bin/env python3
"""OpenCode go fake.

Mirrors three gateway rules: every request carries the client's own session
header and user agent, each model is only served on its own wire format
(`grok-4.6` is Responses-only, like the real gateway's "not supported for format
oa-compat"), and a chat turn that carries tool calls must replay the thinking it
came from as `reasoning_content`.
Serves four requests, one per line the test drives.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

RESPONSES_ONLY = {"grok-4.6"}
MESSAGES_ONLY = {"qwen3.8-flash"}
REQUESTS = 4


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_json(self, code, payload):
        encoded = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def fail(self, kind, message):
        self.send_json(400, {"type": "error",
                             "error": {"type": kind, "message": message}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        session = self.headers.get("x-opencode-session", "")
        agent = self.headers.get("User-Agent", "")
        if not session or "nimlet" not in agent:
            return self.fail("AuthError", f"session={session!r} agent={agent!r}")
        model = body.get("model", "")
        responses = self.path.endswith("/responses")
        messages = self.path.endswith("/messages")
        if (model in RESPONSES_ONLY) != responses or (model in MESSAGES_ONLY) != messages:
            return self.fail("ModelError",
                             f"Model {model} is not supported for format "
                             f"{'responses' if responses else 'messages' if messages else 'oa-compat'}")
        if responses:
            return self.send_json(200, {
                "status": "completed",
                "model": model,
                "output": [{"type": "message", "content": [
                    {"type": "output_text", "text": "grok pong"}]}],
                "usage": {"input_tokens": 20, "output_tokens": 2},
            })
        if messages:
            return self.send_json(200, {
                "id": "msg-opencode",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": "qwen pong"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 14, "output_tokens": 2},
            })
        reasoning = ""
        for message in body.get("messages", []):
            if not message.get("tool_calls"):
                continue
            reasoning = message.get("reasoning_content", "")
            if not reasoning:
                return self.fail(
                    "invalid_request_error",
                    "The `reasoning_content` in the thinking mode must be "
                    "passed back to the API.")
        return self.send_json(200, {
            "id": "chatcmpl-opencode",
            "model": model,
            "choices": [{"index": 0,
                         "message": {"role": "assistant",
                                     "content": reasoning or "pong"},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 1,
                      "total_tokens": 13},
        })


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
for _ in range(REQUESTS):
    server.handle_request()
