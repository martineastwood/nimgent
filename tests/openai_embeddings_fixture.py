import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/embeddings", self.path
        length = int(self.headers["Content-Length"])
        body = json.loads(self.rfile.read(length))
        assert body["model"] == "text-embedding-3-small"
        assert body["input"] in [["alpha", "beta"], ["single"]]
        assert body["encoding_format"] == "float"
        if body["input"] == ["alpha", "beta"]:
            assert body["dimensions"] == 2
            data = [
                {"index": 1, "embedding": [0.0, 1.0]},
                {"index": 0, "embedding": [1.0, 0.0]},
            ]
            tokens = 3
        else:
            data = [{"index": 0, "embedding": [0.5, 0.5]}]
            tokens = 1
        raw = json.dumps({
            "object": "list",
            "model": body["model"],
            "data": data,
            "usage": {"prompt_tokens": tokens, "total_tokens": tokens},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.handle_request()
server.handle_request()
