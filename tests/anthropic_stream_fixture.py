"""One-request Anthropic transport fixture; select behavior with model."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['stream'] is True
        assert self.headers['x-api-key'] == 'fixture-key'
        assert self.headers['anthropic-version'] == '2023-06-01'
        mode = body['model']
        if mode == 'rate':
            self.send_response(429)
            self.send_header('Retry-After', '2')
            self.send_header('x-request-id', 'req-anthropic-rate')
            self.end_headers()
            self.wfile.write(b'{"error":{"type":"rate_limit_error","message":"Slow down"}}')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('x-request-id', 'req-anthropic')
        self.end_headers()

        def emit(kind, **fields):
            frame = {'type': kind, **fields}
            self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps(frame) + '\n\n').encode())
            self.wfile.flush()

        try:
            emit('message_start', message={'model': mode, 'content': [], 'usage': {'input_tokens': 7}})
            if mode == 'cancel':
                emit('content_block_start', index=0, content_block={'type': 'tool_use', 'id': 'call1', 'name': 'bash', 'input': {}})
                emit('content_block_delta', index=0, delta={'type': 'input_json_delta', 'partial_json': '{"command":'})
                return
            if mode == 'search':
                parts = body['messages'][0]['content']
                assert parts[0]['type'] == 'server_tool_use'
                assert parts[1]['type'] == 'web_search_tool_result'
                assert parts[1]['content'][0]['encrypted_content'] == 'opaque'
                assert parts[2]['citations'][0]['url'] == 'https://example.com'
            emit('content_block_start', index=0, content_block={'type': 'text', 'text': ''})
            emit('content_block_delta', index=0, delta={'type': 'text_delta', 'text': 'Hello'})
            if mode == 'cut':
                return
            emit('content_block_stop', index=0)
            emit('message_delta', delta={'stop_reason': 'end_turn'}, usage={'output_tokens': 2})
            emit('message_stop')
        except (BrokenPipeError, ConnectionResetError):
            pass


server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.handle_request()
