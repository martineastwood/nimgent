#!/usr/bin/env python3
"""Small two-request OpenRouter chat-completions fixture."""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length))
            error = self.validate(body)
        except Exception as exc:
            error = str(exc)

        self.server.request_count += 1
        if error:
            self.send_json(
                400,
                {"error": {"message": error}},
            )
            return

        if self.server.request_count == 1:
            response = {
                "id": "fixture-1",
                "model": "deepseek/deepseek-v4-flash-0731",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": None,
                        "reasoning": "should I read?",
                        "reasoning_details": [{
                            "type": "reasoning.text",
                            "text": "should I read?",
                            "signature": "sig_fixture",
                            "format": "anthropic-claude-v1",
                            "index": 0,
                        }],
                        "tool_calls": [{
                            "id": "call_fixture",
                            "type": "function",
                            "function": {
                                "name": "read",
                                "arguments": '{"path":"README.md"}',
                            },
                        }],
                    },
                    "finish_reason": "tool_calls",
                }],
                "usage": {
                    "prompt_tokens": 1200,
                    "completion_tokens": 20,
                    "prompt_tokens_details": {
                        "cached_tokens": 0,
                        "cache_write_tokens": 1000,
                    },
                },
            }
        else:
            response = {
                "id": "fixture-2",
                "model": "deepseek/deepseek-v4-flash-0731",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "fixture complete",
                    },
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": 1400,
                    "completion_tokens": 4,
                    "prompt_tokens_details": {
                        "cached_tokens": 1000,
                        "cache_write_tokens": 0,
                    },
                },
            }
        self.send_json(200, response)

    def validate(self, body):
        if self.headers.get("Authorization") != "Bearer fixture-key":
            return "bad authorization header"
        if body.get("model") != "deepseek/deepseek-v4-flash-0731":
            return "bad model"
        if body.get("session_id") != "fixture-session":
            return "missing session_id"
        if body.get("messages", [{}])[0].get("role") != "system":
            return "missing system message"
        tools = body.get("tools", [])
        if not tools or tools[0].get("function", {}).get("name") != "read":
            return "bad tool schema"

        messages = body.get("messages", [])
        def last_text(msg):
            c = msg.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list) and c:
                return c[-1].get("text", "")
            return ""

        if self.server.request_count == 0:
            if last_text(messages[-1]) != "hello":
                return "bad initial user message"
        else:
            assistant = next((m for m in messages if m.get("role") == "assistant"), None)
            if assistant is None:
                return "missing assistant tool call"
            if assistant.get("reasoning") != "should I read?":
                return "missing reasoning replay"
            details = assistant.get("reasoning_details") or []
            if not details or details[0].get("signature") != "sig_fixture":
                return "missing reasoning_details replay"
            if not any(
                m.get("role") == "tool"
                and m.get("tool_call_id") == "call_fixture"
                and m.get("content") == "README contents"
                for m in messages
            ):
                return "bad tool result"
        return ""

    def send_json(self, status, body):
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


server = HTTPServer(("127.0.0.1", 0), Handler)
server.request_count = 0
print(server.server_port, flush=True)
server.handle_request()
server.handle_request()
