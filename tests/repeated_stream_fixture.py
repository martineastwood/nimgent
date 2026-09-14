#!/usr/bin/env python3
"""Serve a fixed number of minimal OpenAI Responses streams."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        event = json.dumps({
            "type": "response.completed",
            "response": {
                "id": "response",
                "model": "test",
                "status": "completed",
                "output": [{
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "ok"}],
                }],
            },
        }).encode()
        body = b"data: " + event + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
for _ in range(int(sys.argv[1])):
    server.handle_request()
