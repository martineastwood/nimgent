#!/usr/bin/env python3
"""Chat Completions fixture that accepts native OpenAI request shape."""

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

        if error:
            self.send_json(400, {"error": {"message": error}})
            return

        self.send_json(200, {
            "id": "chatcmpl-fixture",
            "model": "gpt-5",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "hello from openai",
                    "reasoning": "cached plan",
                },
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": 20,
                "completion_tokens": 4,
                "prompt_tokens_details": {"cached_tokens": 8},
            },
        })

    def validate(self, body):
        if self.headers.get("Authorization") != "Bearer fixture-key":
            return "bad authorization header"
        if body.get("model") != "gpt-5":
            return "bad model"
        if "session_id" in body:
            return "native OpenAI must not send session_id"
        if "max_tokens" in body:
            return "native OpenAI must use max_completion_tokens"
        if body.get("max_completion_tokens") != 32:
            return "missing max_completion_tokens"
        if body.get("reasoning_effort") != "low":
            return "missing reasoning_effort"
        for msg in body.get("messages", []):
            content = msg.get("content")
            if isinstance(content, list):
                for part in content:
                    if "cache_control" in part:
                        return "native OpenAI must not send cache_control"
            elif isinstance(content, dict) and "cache_control" in content:
                return "native OpenAI must not send cache_control"
        for tool in body.get("tools", []):
            if "cache_control" in tool:
                return "native OpenAI must not send cache_control"
        return ""

    def send_json(self, status, body):
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.handle_request()
