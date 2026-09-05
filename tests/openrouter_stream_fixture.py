#!/usr/bin/env python3
"""Chunked SSE fixture that pauses between deltas so buffering is detectable."""

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def sse_data(delta_text=None, finish=None, tool=None, reasoning=None, details=None):
    choice = {"index": 0, "delta": {}, "finish_reason": None}
    if delta_text is not None:
        choice["delta"] = {"content": delta_text}
    if reasoning is not None:
        choice["delta"]["reasoning"] = reasoning
    if details is not None:
        choice["delta"]["reasoning_details"] = details
    if tool is not None:
        tc = {"index": 0, "function": {}}
        if "id" in tool:
            tc["id"] = tool["id"]
        if "name" in tool:
            tc["function"]["name"] = tool["name"]
        if "arguments" in tool:
            tc["function"]["arguments"] = tool["arguments"]
        choice["delta"] = {"tool_calls": [tc]}
    if finish is not None:
        choice["finish_reason"] = finish
        if delta_text is None and tool is None:
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
            send_chunk(sse_data(tool={"id": "call_1", "name": "read", "arguments": ""}))
            time.sleep(0.08)
            send_chunk(sse_data(tool={"arguments": "{\"path\":\"x\"}"}))
            time.sleep(0.08)
            send_chunk(sse_data(finish="tool_calls"))
        else:
            send_chunk(sse_data("Hello", reasoning="planA", details=[{
                "type": "reasoning.text",
                "text": "planA",
                "index": 0,
                "format": "openai-responses-v1",
            }]))
            time.sleep(0.08)
            send_chunk(sse_data(" world", reasoning="planB", details=[{
                "type": "reasoning.text",
                "text": "planB",
                "signature": "sig_s",
                "index": 0,
                "format": "openai-responses-v1",
            }]))
            time.sleep(0.08)
            send_chunk(sse_data(finish="stop"))
        send_chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.handle_request()
