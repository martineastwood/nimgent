#!/usr/bin/env python3
"""Hyper chat-completions usage: cost/remaining, no token-details object."""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        encoded = json.dumps({
            "id": "chatcmpl-test",
            "model": "deepseek-v4-flash",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "pong"},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 1,
                "total_tokens": 11,
                "cost": {"usd": 0.000012, "hypercredits": 12},
                "remaining": {"hypercredits": 88},
            },
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.handle_request()
