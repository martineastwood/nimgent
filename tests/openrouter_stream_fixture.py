#!/usr/bin/env python3
"""Chunked SSE fixture that pauses between deltas so buffering is detectable."""

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def sse_data(delta_text=None, finish=None):
    choice = {"index": 0, "delta": {}, "finish_reason": None}
    if delta_text is not None:
        choice["delta"] = {"content": delta_text}
    if finish is not None:
        choice["finish_reason"] = finish
        choice["delta"] = {}
    payload = {
        "id": "stream-1",
        "model": "deepseek/deepseek-v4-flash-0731",
        "choices": [choice],
    }
    return ("data: " + json.dumps(payload) + "\n\n").encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def send_chunk(data: bytes):
            self.wfile.write(f"{len(data):x}\r\n".encode())
            self.wfile.write(data)
            self.wfile.write(b"\r\n")
            self.wfile.flush()

        send_chunk(sse_data("Hello"))
        time.sleep(0.08)
        send_chunk(sse_data(" world"))
        time.sleep(0.08)
        send_chunk(sse_data(finish="stop"))
        send_chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.handle_request()
