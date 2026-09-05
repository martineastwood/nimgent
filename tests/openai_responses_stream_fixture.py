#!/usr/bin/env python3
"""Chunked Responses SSE fixture. Text or tool-call events based on tools."""

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def sse(typ, payload):
    payload = dict(payload)
    payload["type"] = typ
    return f"event: {typ}\ndata: {json.dumps(payload)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw) if raw else {}
        except Exception:
            body = {}
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

        if body.get("tools"):
            send_chunk(sse("response.output_item.added", {
                "output_index": 0,
                "item": {
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_1",
                    "name": "read",
                    "arguments": "",
                },
            }))
            time.sleep(0.08)
            send_chunk(sse("response.function_call_arguments.delta", {
                "output_index": 0,
                "item_id": "fc_1",
                "delta": "{\"path\":\"x\"}",
            }))
            time.sleep(0.08)
            send_chunk(sse("response.output_item.done", {
                "output_index": 0,
                "item": {
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_1",
                    "name": "read",
                    "arguments": "{\"path\":\"x\"}",
                },
            }))
            send_chunk(sse("response.completed", {
                "response": {
                    "id": "resp-1",
                    "model": "gpt-5",
                    "status": "completed",
                    "output": [{
                        "type": "function_call",
                        "call_id": "call_1",
                        "name": "read",
                        "arguments": "{\"path\":\"x\"}",
                    }],
                },
            }))
        else:
            send_chunk(sse("response.output_text.delta", {"delta": "Hello"}))
            time.sleep(0.08)
            send_chunk(sse("response.output_text.delta", {"delta": " world"}))
            time.sleep(0.08)
            send_chunk(sse("response.completed", {
                "response": {
                    "id": "resp-1",
                    "model": "gpt-5",
                    "status": "completed",
                    "output": [{
                        "type": "message",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "Hello world"}],
                    }],
                },
            }))
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.handle_request()
