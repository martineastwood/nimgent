#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.headers.get("MCP-Protocol-Version") != "2026-07-28":
            self.send_error(400, "missing MCP protocol header")
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        self.method_name = request["method"]
        if self.headers.get("Mcp-Method") != self.method_name:
            self.send_error(400, "Mcp-Method mismatch")
            return
        request_id = request["id"]
        if request["method"] == "server/discover":
            fields = {"supportedVersions": ["2026-07-28"],
                      "_meta": {"io.modelcontextprotocol/serverInfo": {
                          "name": "http-fixture", "version": "1.0"}}}
        elif request["method"] == "tools/list":
            fields = {"tools": [{"name": "http-echo", "description": "Echo",
                                  "inputSchema": {"type": "object", "properties": {
                                      "token": {"type": "string",
                                                 "x-mcp-header": "X-Token"}}}}]}
        else:
            if self.headers.get("Mcp-Param-X-Token") != "secret":
                self.send_error(400, "missing mirrored tool header")
                return
            fields = {"content": [{"type": "text", "text": "ok"}]}
        value = {"resultType": "complete"}
        value.update(fields)
        body = json.dumps({"jsonrpc": "2.0", "id": request_id,
                           "result": value}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.handle_request()
server.handle_request()
server.handle_request()
