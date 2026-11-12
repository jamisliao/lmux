#!/usr/bin/env python3
# A stand-in for the Anthropic Messages API, for running the real Claude Code binary offline
# (App/scripts/e2etest.sh). Every request gets a short canned reply:
#   - "OK <first words of the prompt>"
#   - a prompt containing SLOW: the reply waits 4s after it starts (time to press ⌘Z)
#   - a prompt containing WRITEFILE <path>: a Write tool call for <path>, then "Wrote it."
#   - a prompt containing STREAM: part of the reply at once, the rest 8s later (Claude mid-reply)
#   - a prompt containing ASKTOOL: a Bash tool call that needs permission (Claude's dialog stays up)
# Each /v1/messages request is logged as one JSON line: {"model", "texts": [user texts]}.
#
#   claude-api-mock.py <port> <log file>
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = open(sys.argv[2], 'a')


def user_texts(body):
    out = []
    for m in body.get('messages', []):
        if m.get('role') != 'user':
            continue
        c = m.get('content')
        blocks = [{'type': 'text', 'text': c}] if isinstance(c, str) else (c or [])
        for b in blocks:
            if b.get('type') == 'text' and not b['text'].lstrip().startswith('<'):
                out.append(b['text'])
    return out


def last_turn(body):
    """(text of the last user message, whether it carries a tool result)."""
    msgs = [m for m in body.get('messages', []) if m.get('role') == 'user']
    if not msgs:
        return '', False
    c = msgs[-1].get('content')
    if isinstance(c, str):
        return c, False
    texts = [b['text'] for b in c or [] if b.get('type') == 'text' and not b['text'].lstrip().startswith('<')]
    return (texts[-1] if texts else ''), bool(c) and c[-1].get('type') == 'tool_result'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        self.send_json(200, {})

    def do_HEAD(self):
        self.send_json(200, {})

    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        try:
            body = json.loads(self.rfile.read(n) or b'{}')
        except ValueError:
            body = {}
        path = self.path.split('?')[0]
        if path.endswith('/count_tokens'):
            return self.send_json(200, {'input_tokens': 10})
        if not path.endswith('/v1/messages'):
            return self.send_json(200, {})
        LOG.write(json.dumps({'model': body.get('model'), 'texts': user_texts(body)}) + '\n')
        LOG.flush()
        prompt, after_tool = last_turn(body)
        words = prompt.split()
        tool = None
        if 'WRITEFILE' in words and not after_tool and words.index('WRITEFILE') + 1 < len(words):
            tool = {'type': 'tool_use', 'id': 'toolu_mock_%d' % int(time.time() * 1000), 'name': 'Write',
                    'input': {'file_path': words[words.index('WRITEFILE') + 1], 'content': 'written by the mock\n'}}
        if 'ASKTOOL' in words and not after_tool:
            tool = {'type': 'tool_use', 'id': 'toolu_mock_%d' % int(time.time() * 1000), 'name': 'Bash',
                    'input': {'command': 'curl -s https://example.invalid/lmux-e2e', 'description': 'Fetch a page'}}
        text = 'Wrote it.' if after_tool else 'OK ' + ''.join(ch for ch in prompt[:24] if ch.isalnum() or ch == ' ').strip()
        usage = {'input_tokens': 10, 'output_tokens': 5, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}
        content = [tool] if tool else [{'type': 'text', 'text': text}]
        stop = 'tool_use' if tool else 'end_turn'
        msg = {'id': 'msg_mock', 'type': 'message', 'role': 'assistant', 'model': body.get('model', 'mock'),
               'content': content, 'stop_reason': stop, 'stop_sequence': None, 'usage': usage}
        if not body.get('stream'):
            return self.send_json(200, msg)
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.send_header('cache-control', 'no-cache')
        self.send_header('connection', 'close')
        self.end_headers()

        def event(kind, obj):
            self.wfile.write(('event: %s\ndata: %s\n\n' % (kind, json.dumps(obj))).encode())
            self.wfile.flush()

        event('message_start', {'type': 'message_start', 'message': dict(msg, content=[], stop_reason=None)})
        if tool:
            start = dict(tool, input={})
            event('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': start})
            event('content_block_delta', {'type': 'content_block_delta', 'index': 0,
                                          'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(tool['input'])}})
        else:
            event('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            if 'STREAM' in prompt and not after_tool:
                event('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Thinking it over. '}})
                time.sleep(8.0)
            time.sleep(4.0 if 'SLOW' in prompt and not after_tool else 0.2)
            event('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}})
        event('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        event('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None},
                                'usage': {'output_tokens': 5}})
        event('message_stop', {'type': 'message_stop'})
        self.close_connection = True


server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler)
print('ready', flush=True)
server.serve_forever()
