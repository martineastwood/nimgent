import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

mode = sys.argv[1]
metadata = {"groundingChunks": [{"web": {"uri": "https://nim-lang.org", "title": "Nim"}}]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        assert self.headers.get("x-goog-api-key") == "fixture-key"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        expected = "batchEmbedContents" if mode == "embed" else ("generateContent" if mode == "sync" else "streamGenerateContent?alt=sse")
        assert self.path == "/models/fixture:" + expected
        if mode == "embed":
            assert body == {"requests": [
                {"model": "models/fixture", "content": {"parts": [{"text": "one"}]}, "taskType": "RETRIEVAL_DOCUMENT"},
                {"model": "models/fixture", "content": {"parts": [{"text": "two"}]}, "taskType": "RETRIEVAL_DOCUMENT"},
            ]}
            encoded = json.dumps({"embeddings": [{"values": [1.0, 0.0]}, {"values": [0.0, 1.0]}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        assert "contents" in body
        first = {"candidates": [{"content": {"parts": [{"text": "Nim"}]}}]}
        last = {"candidates": [{"groundingMetadata": metadata}], "usageMetadata": {"promptTokenCount": 10}}
        if mode == "error":
            payload = json.dumps({"error": {"message": "slow down", "code": 429}})
        elif mode == "sync":
            first["candidates"][0].update(finishReason="STOP", groundingMetadata=metadata)
            first["usageMetadata"] = last["usageMetadata"]
            payload = json.dumps(first)
        else:
            events = [first]
            if mode != "cut":
                events += [{"candidates": [{"finishReason": "STOP"}]}, last]
            payload = "".join("data: " + json.dumps(event) + "\n\n" for event in events)
        encoded = payload.encode()
        self.send_response(429 if mode == "error" else 200)
        self.send_header("Content-Type", "application/json" if mode in ("sync", "error") else "text/event-stream")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.handle_request()
