#!/usr/bin/env python3
"""Responses API fixture that accepts native OpenAI request shape."""

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
            "id": "resp-fixture",
            "model": "gpt-5",
            "status": "completed",
            "output": [
                {
                    "type": "reasoning",
                    "id": "rs_1",
                    "encrypted_content": "enc",
                    "summary": [{"type": "summary_text", "text": "cached plan"}],
                },
                {
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "hello from openai"}],
                },
            ],
            "usage": {
                "input_tokens": 20,
                "output_tokens": 4,
                "input_tokens_details": {"cached_tokens": 8},
            },
        })

    def validate(self, body):
        if self.headers.get("Authorization") != "Bearer fixture-key":
            return "bad authorization header"
        if body.get("model") != "gpt-5":
            return "bad model"
        if "session_id" in body:
            return "native OpenAI must not send session_id"
        if "messages" in body:
            return "native OpenAI must use input, not messages"
        if "max_tokens" in body or "max_completion_tokens" in body:
            return "native OpenAI must use max_output_tokens"
        if body.get("max_output_tokens") != 32:
            return "missing max_output_tokens"
        if body.get("store") is not False:
            return "store must be false"
        if "reasoning_effort" in body:
            return "use reasoning.effort, not reasoning_effort"
        reasoning = body.get("reasoning") or {}
        if reasoning.get("effort") != "low":
            return "missing reasoning.effort"
        if "You are a test agent." not in (body.get("instructions") or ""):
            return "missing instructions"
        for tool in body.get("tools", []):
            if "function" in tool:
                return "Responses tools must be flat"
            if "cache_control" in tool:
                return "native OpenAI must not send cache_control"
            if tool.get("type") != "function" or tool.get("name") != "read":
                return "bad tool"
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
